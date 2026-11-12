//! The vaults a vault server serves (D8).
//!
//! A served vault is an immediate subfolder of the vault root that holds
//! `manifest.json` and `memex.db` and whose folder name passes
//! [`validate_vault_name`]. Names compare case-insensitively. Folders are
//! rediscovered on every request: dot folders, invalid names, incomplete
//! folders, symlinks and case-only duplicates are never served.
//!
//! Each vault is opened once, on first use, and kept as one [`VaultEntry`]
//! until its folder vanishes or is replaced. The map lock is never held
//! while a vault opens or migrates; opening runs on the blocking pool.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use memex_core::embedder::Embedder;
use memex_core::vault::VaultManifest;
use memex_core::Vault;
use tokio::sync::OnceCell;
use ulid::Ulid;

use super::error::ApiError;
use crate::state::AppState;

const MANIFEST_FILE: &str = "manifest.json";
const DB_FILE: &str = "memex.db";

/// The longest vault name.
const MAX_NAME_LEN: usize = 64;

/// One open vault. Frozen (D8): later slices key their own caches by
/// `open_id` and add no fields here.
pub struct VaultEntry {
    /// New for every open of the vault by this registry (D9).
    pub open_id: Ulid,
    /// The vault's one connection and the shared embedder.
    pub state: AppState,
}

/// Checks a vault name: letters, digits, `-` and `_` (ASCII only), 1 to 64
/// characters. 400 `invalid_vault_name` otherwise.
pub fn validate_vault_name(name: &str) -> Result<(), ApiError> {
    let ok = (1..=MAX_NAME_LEN).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if ok {
        Ok(())
    } else {
        Err(ApiError::new(
            "invalid_vault_name",
            "vault names use letters, digits, - and _ (1-64 characters)",
        ))
    }
}

/// 404 `vault_not_found` for `name`.
fn vault_not_found(name: &str) -> ApiError {
    ApiError::new("vault_not_found", format!("no vault named {name}"))
}

/// 409 `vault_exists` for `name`.
fn vault_exists(name: &str) -> ApiError {
    ApiError::new(
        "vault_exists",
        format!("a vault named {name} already exists"),
    )
}

/// The served vaults of one vault root.
pub struct Registry {
    inner: Arc<Inner>,
}

struct Inner {
    /// The canonical vault root.
    root: PathBuf,
    embedder: Option<Arc<dyn Embedder>>,
    /// Lower-cased name → its slot. Locked only to look up, insert or
    /// remove a slot, never across an open.
    vaults: Mutex<HashMap<String, Arc<Slot>>>,
    /// The server-wide create lock.
    create_lock: tokio::sync::Mutex<()>,
    /// Folders already logged as not served, so each is logged once.
    logged: Mutex<HashSet<String>>,
    /// Notified after each fresh open, once the entry is in the map, for
    /// the embedding backfill (#422).
    opened: tokio::sync::Notify,
}

/// A vault opened (or being opened) under one name.
type Slot = OnceCell<Opened>;

/// An open vault and what it was opened from.
struct Opened {
    entry: Arc<VaultEntry>,
    folder: PathBuf,
    vault_id: String,
}

/// Why a vault folder found by the scan could not be opened.
enum OpenFailed {
    /// Its vault files were gone by the time it was opened.
    Gone,
    Error(ApiError),
}

/// A served vault folder found on disk.
struct VaultFolder {
    /// The folder name, as on disk.
    name: String,
    /// `<root>/<name>`.
    path: PathBuf,
}

/// A row of `GET /api/v1/vaults`.
#[derive(Debug, Clone)]
pub struct ListedVault {
    pub name: String,
    pub vault_id: String,
}

impl Registry {
    /// A registry for the vault root `root`. Every vault it opens shares
    /// `embedder`.
    pub fn new(root: PathBuf, embedder: Option<Arc<dyn Embedder>>) -> Self {
        let root = fs::canonicalize(&root).unwrap_or(root);
        Self {
            inner: Arc::new(Inner {
                root,
                embedder,
                vaults: Mutex::new(HashMap::new()),
                create_lock: tokio::sync::Mutex::new(()),
                logged: Mutex::new(HashSet::new()),
                opened: tokio::sync::Notify::new(),
            }),
        }
    }

    /// The canonical vault root.
    pub fn root(&self) -> &Path {
        &self.inner.root
    }

    /// The vault served as `name` (any case), opened on first use. An
    /// unknown, invalid or vanished name is 404 `vault_not_found`; a
    /// vanished vault's entry is evicted, and a vault replaced on disk is
    /// reopened with a new `open_id`.
    pub async fn get(&self, name: &str) -> Result<Arc<VaultEntry>, ApiError> {
        if validate_vault_name(name).is_err() {
            return Err(vault_not_found(name));
        }
        let key = name.to_ascii_lowercase();
        // The slot this scan can speak for: a not-found evicts only it, so
        // an entry a concurrent request opens meanwhile survives (D8).
        let seen = self.inner.current(&key);
        let inner = self.inner.clone();
        let lookup = key.clone();
        let found = blocking(move || Ok(inner.find(&lookup))).await?;
        let Some((folder, vault_id)) = found else {
            if let Some(seen) = seen {
                self.inner.evict(&key, Some(&seen));
            }
            return Err(vault_not_found(name));
        };

        let mut slot = self.inner.slot(&key);
        if let Some(opened) = slot.get() {
            let same = opened.folder == folder.path
                && vault_id.as_deref().is_none_or(|id| id == opened.vault_id);
            if !same {
                self.inner.evict(&key, Some(&slot));
                slot = self.inner.slot(&key);
            }
        }
        let fresh = !slot.initialized();
        let inner = self.inner.clone();
        let opened = slot
            .get_or_try_init(|| async move {
                let path = folder.path;
                match blocking(move || match inner.open(path.clone()) {
                    Ok(opened) => Ok(Ok(opened)),
                    // Deleted between the scan and the open.
                    Err(_) if !has_vault_files(&path) => Ok(Err(OpenFailed::Gone)),
                    Err(e) => Err(e),
                })
                .await
                {
                    Ok(opened) => opened,
                    Err(e) => Err(OpenFailed::Error(e)),
                }
            })
            .await;
        match opened {
            Ok(opened) => {
                if fresh {
                    self.inner.opened.notify_one();
                }
                Ok(opened.entry.clone())
            }
            Err(OpenFailed::Gone) => {
                self.inner.evict(&key, Some(&slot));
                Err(vault_not_found(name))
            }
            Err(OpenFailed::Error(e)) => Err(e),
        }
    }

    /// The embedder every vault this registry opens shares.
    pub(crate) fn embedder(&self) -> Option<Arc<dyn Embedder>> {
        self.inner.embedder.clone()
    }

    /// Every vault open now, in no particular order.
    pub(crate) fn open_entries(&self) -> Vec<Arc<VaultEntry>> {
        lock(&self.inner.vaults)
            .values()
            .filter_map(|slot| slot.get().map(|opened| opened.entry.clone()))
            .collect()
    }

    /// Resolves after a vault opens, or at once when one opened since the
    /// last call returned. Meant for one waiter (the backfill task).
    pub(crate) async fn opened(&self) {
        self.inner.opened.notified().await;
    }

    /// Every served vault, sorted by lower-cased name.
    pub async fn list(&self) -> Result<Vec<ListedVault>, ApiError> {
        let inner = self.inner.clone();
        blocking(move || {
            let mut out: Vec<ListedVault> = inner
                .scan()
                .into_iter()
                .filter_map(|folder| {
                    let vault_id = read_vault_id(&folder.path)?;
                    Some(ListedVault {
                        name: folder.name,
                        vault_id,
                    })
                })
                .collect();
            out.sort_by_key(|v| v.name.to_ascii_lowercase());
            Ok(out)
        })
        .await
    }

    /// Creates the vault `name` as `memex init` would and returns its
    /// `vault_id`. 400 `invalid_vault_name`; 409 `vault_exists` when any
    /// entry of the root already has that name in any case.
    pub async fn create(&self, name: &str) -> Result<String, ApiError> {
        validate_vault_name(name)?;
        let _create = self.inner.create_lock.lock().await;
        let inner = self.inner.clone();
        let name = name.to_string();
        blocking(move || inner.create(&name)).await
    }
}

/// Runs `f` on the blocking pool.
async fn blocking<T, F>(f: F) -> Result<T, ApiError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, ApiError> + Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| ApiError::from(anyhow::anyhow!("vault task failed: {e}")))?
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Inner {
    fn slot(&self, key: &str) -> Arc<Slot> {
        lock(&self.vaults)
            .entry(key.to_string())
            .or_insert_with(|| Arc::new(OnceCell::new()))
            .clone()
    }

    /// The slot in the map for `key` now, if any.
    fn current(&self, key: &str) -> Option<Arc<Slot>> {
        lock(&self.vaults).get(key).cloned()
    }

    /// Drops the slot for `key`: any slot, or only `only` when given.
    fn evict(&self, key: &str, only: Option<&Arc<Slot>>) {
        let mut vaults = lock(&self.vaults);
        let matches = match (vaults.get(key), only) {
            (Some(current), Some(only)) => Arc::ptr_eq(current, only),
            (Some(_), None) => true,
            (None, _) => false,
        };
        if matches {
            vaults.remove(key);
        }
    }

    /// The served folder for the lower-cased `key`, with the `vault_id` its
    /// manifest holds now (`None` if it can't be read).
    fn find(&self, key: &str) -> Option<(VaultFolder, Option<String>)> {
        let folder = self
            .scan()
            .into_iter()
            .find(|f| f.name.to_ascii_lowercase() == key)?;
        let vault_id = read_vault_id(&folder.path);
        Some((folder, vault_id))
    }

    /// Opens the vault in `folder` (migrating it as `Vault::open` does).
    fn open(&self, folder: PathBuf) -> Result<Opened, ApiError> {
        let vault = Vault::open(&folder)?;
        let vault_id = vault.manifest().vault_id.clone();
        let state = AppState::new(vault, folder.clone(), self.embedder.clone());
        Ok(Opened {
            entry: Arc::new(VaultEntry {
                open_id: Ulid::new(),
                state,
            }),
            folder,
            vault_id,
        })
    }

    /// Exclusive create of `<root>/<name>`, then `Vault::create` in it.
    /// The caller holds the create lock.
    fn create(&self, name: &str) -> Result<String, ApiError> {
        let entries = fs::read_dir(&self.root)
            .map_err(|e| anyhow::anyhow!("read the vault root {}: {e}", self.root.display()))?;
        for entry in entries.filter_map(|e| e.ok()) {
            if entry
                .file_name()
                .to_string_lossy()
                .eq_ignore_ascii_case(name)
            {
                return Err(vault_exists(name));
            }
        }
        let path = self.root.join(name);
        match fs::create_dir(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == ErrorKind::AlreadyExists => return Err(vault_exists(name)),
            Err(e) => {
                return Err(
                    anyhow::anyhow!("create the vault folder {}: {e}", path.display()).into(),
                )
            }
        }
        match Vault::create(&path) {
            Ok(vault) => {
                let vault_id = vault.manifest().vault_id.clone();
                drop(vault);
                self.evict(&name.to_ascii_lowercase(), None);
                Ok(vault_id)
            }
            Err(e) => {
                let _ = fs::remove_dir_all(&path);
                Err(e.into())
            }
        }
    }

    /// Every served vault folder now on disk, in no particular order. Logs
    /// each folder that looks like a vault but is not served, once.
    fn scan(&self) -> Vec<VaultFolder> {
        let Ok(entries) = fs::read_dir(&self.root) else {
            return Vec::new();
        };
        let mut found: Vec<VaultFolder> = Vec::new();
        for entry in entries.filter_map(|e| e.ok()) {
            let os_name = entry.file_name();
            let lossy = os_name.to_string_lossy();
            if lossy.starts_with('.') {
                continue;
            }
            let path = entry.path();
            let Some(name) = os_name.to_str().filter(|n| validate_vault_name(n).is_ok()) else {
                if is_real_dir(&path) && has_vault_files(&path) {
                    self.log_once(&format!("name:{lossy}"), || {
                        tracing::warn!(
                            folder = %lossy,
                            "not serving a vault folder whose name is not a valid vault name \
                             (letters, digits, - and _, 1-64 characters)"
                        );
                    });
                }
                continue;
            };
            if !is_real_dir(&path) {
                if path.is_dir() && has_vault_files(&path) {
                    self.log_once(&format!("link:{name}"), || {
                        tracing::warn!(folder = %name, "not serving a symlinked vault folder");
                    });
                }
                continue;
            }
            // Refuse anything that resolves outside `<root>/<name>`.
            if fs::canonicalize(&path).ok().as_deref() != Some(self.root.join(name).as_path()) {
                continue;
            }
            if has_vault_files(&path) {
                found.push(VaultFolder {
                    name: name.to_string(),
                    path,
                });
            }
        }

        let mut by_key: HashMap<String, Vec<VaultFolder>> = HashMap::new();
        for folder in found {
            by_key
                .entry(folder.name.to_ascii_lowercase())
                .or_default()
                .push(folder);
        }
        let mut served = Vec::new();
        for (_, mut group) in by_key {
            if group.len() == 1 {
                served.extend(group);
                continue;
            }
            group.sort_by(|a, b| a.name.cmp(&b.name));
            let names = group
                .iter()
                .map(|f| f.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            self.log_once(&format!("case:{names}"), || {
                tracing::warn!(
                    folders = %names,
                    "not serving vault folders whose names differ only by case"
                );
            });
        }
        served
    }

    fn log_once(&self, key: &str, log: impl FnOnce()) {
        if lock(&self.logged).insert(key.to_string()) {
            log();
        }
    }
}

/// A directory itself, not a symlink to one.
fn is_real_dir(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.is_dir())
}

/// Whether `dir` holds both `manifest.json` and `memex.db` (as files).
fn has_vault_files(dir: &Path) -> bool {
    dir.join(MANIFEST_FILE).is_file() && dir.join(DB_FILE).is_file()
}

/// The `vault_id` in `<dir>/manifest.json`, read without opening the vault.
fn read_vault_id(dir: &Path) -> Option<String> {
    let bytes = fs::read(dir.join(MANIFEST_FILE)).ok()?;
    let manifest: VaultManifest = serde_json::from_slice(&bytes).ok()?;
    Some(manifest.vault_id)
}

/// The vault a `/vaults/{name}/…` request resolved to: the vault guard
/// puts it in the request extensions before any handler runs.
#[derive(Clone)]
pub struct ServedVault(pub Arc<VaultEntry>);

impl<S> FromRequestParts<S> for ServedVault
where
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        parts
            .extensions
            .get::<ServedVault>()
            .cloned()
            .ok_or_else(|| {
                ApiError::from(anyhow::anyhow!(
                    "no vault was resolved for this request (route outside /vaults/{{name}})"
                ))
            })
    }
}

/// Runs `f` with the entry's vault on the blocking pool. The vault lock is
/// owned by the blocking task, so no guard is held across an `.await`.
pub async fn with_vault<T, F>(entry: &VaultEntry, f: F) -> Result<T, ApiError>
where
    T: Send + 'static,
    F: FnOnce(&mut Vault) -> Result<T, ApiError> + Send + 'static,
{
    let mut guard = entry.state.vault.clone().lock_owned().await;
    blocking(move || f(&mut guard)).await
}
