use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Once;

use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use ulid::Ulid;

use crate::error::MemexError;
use crate::{schema, Result};

const MANIFEST_FILENAME: &str = "manifest.json";
const DB_FILENAME: &str = "memex.db";
const OBJECTS_DIR: &str = "objects";

static SQLITE_VEC_INIT: Once = Once::new();

fn ensure_sqlite_vec_registered() {
    SQLITE_VEC_INIT.call_once(|| {
        // Register sqlite-vec as an auto-extension so every new SQLite
        // connection in this process loads it without needing to call
        // `load_extension` from SQL (which is blocked by the macOS app sandbox).
        type AutoExtFn = unsafe extern "C" fn(
            *mut rusqlite::ffi::sqlite3,
            *mut *mut std::os::raw::c_char,
            *const rusqlite::ffi::sqlite3_api_routines,
        ) -> std::os::raw::c_int;
        unsafe {
            let init: AutoExtFn = std::mem::transmute(sqlite_vec::sqlite3_vec_init as *const ());
            rusqlite::ffi::sqlite3_auto_extension(Some(init));
        }
    });
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct VaultManifest {
    pub vault_id: String,
    pub schema_version: i64,
    pub created_at: i64,
}

pub struct Vault {
    root: PathBuf,
    manifest: VaultManifest,
    conn: Connection,
}

impl Vault {
    /// Create a new vault at `root`. The directory must not already contain a vault.
    pub fn create(root: impl AsRef<Path>) -> Result<Self> {
        ensure_sqlite_vec_registered();
        let root = root.as_ref().to_path_buf();
        if !root.is_absolute() {
            return Err(MemexError::InvalidPath(format!(
                "vault root must be absolute: {}",
                root.display()
            )));
        }
        fs::create_dir_all(&root)?;
        let manifest_path = root.join(MANIFEST_FILENAME);
        if manifest_path.exists() {
            return Err(MemexError::ManifestInvalid(format!(
                "vault already exists at {}",
                root.display()
            )));
        }
        fs::create_dir_all(root.join(OBJECTS_DIR))?;

        let manifest = VaultManifest {
            vault_id: Ulid::new().to_string(),
            schema_version: schema::APP_SCHEMA_VERSION,
            created_at: now_unix_ms(),
        };
        fs::write(&manifest_path, serde_json::to_vec_pretty(&manifest)?)?;

        let mut conn = Connection::open(root.join(DB_FILENAME))?;
        configure_connection(&mut conn)?;
        schema::apply(&mut conn)?;

        Ok(Self {
            root,
            manifest,
            conn,
        })
    }

    /// Open an existing vault at `root`.
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        ensure_sqlite_vec_registered();
        let root = root.as_ref().to_path_buf();
        if !root.is_absolute() {
            return Err(MemexError::InvalidPath(format!(
                "vault root must be absolute: {}",
                root.display()
            )));
        }
        let manifest_path = root.join(MANIFEST_FILENAME);
        if !manifest_path.exists() {
            return Err(MemexError::ManifestInvalid(format!(
                "no manifest at {}",
                manifest_path.display()
            )));
        }
        let manifest: VaultManifest = serde_json::from_slice(&fs::read(&manifest_path)?)?;
        if manifest.schema_version > schema::APP_SCHEMA_VERSION {
            return Err(MemexError::SchemaUnsupported {
                db: manifest.schema_version,
                app: schema::APP_SCHEMA_VERSION,
            });
        }
        let db_path = root.join(DB_FILENAME);
        let mut conn = Connection::open(&db_path)?;
        configure_connection(&mut conn)?;
        schema::apply(&mut conn)?;
        // Refresh manifest schema_version if migrations advanced.
        let current = schema::current_version(&conn)?;
        let manifest = if current != manifest.schema_version {
            let updated = VaultManifest {
                schema_version: current,
                ..manifest
            };
            fs::write(&manifest_path, serde_json::to_vec_pretty(&updated)?)?;
            updated
        } else {
            manifest
        };

        Ok(Self {
            root,
            manifest,
            conn,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn manifest(&self) -> &VaultManifest {
        &self.manifest
    }

    pub fn vault_id(&self) -> &str {
        &self.manifest.vault_id
    }

    pub fn schema_version(&self) -> i64 {
        self.manifest.schema_version
    }

    pub(crate) fn conn(&self) -> &Connection {
        &self.conn
    }

    pub(crate) fn conn_mut(&mut self) -> &mut Connection {
        &mut self.conn
    }

    /// Borrow the underlying SQLite connection. Exposed for low-level needs
    /// (smoke tests, future indexing module). Prefer the typed APIs.
    pub fn connection_ref(&self) -> &Connection {
        &self.conn
    }
}

fn configure_connection(conn: &mut Connection) -> Result<()> {
    // Don't fight the user about WAL or foreign keys.
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    Ok(())
}

pub(crate) fn now_unix_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
