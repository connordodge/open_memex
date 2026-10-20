//! `/vaults/{name}/api/v1/revision` (#94, D9): the hosted vault revision.
//!
//! The value is `<open_id>-<total_changes>-<data_version>`, read on the
//! served vault's one connection:
//!
//! - `open_id` is the registry entry's ULID, new for every open, so a
//!   reopened vault or a restarted server never repeats a value;
//! - `total_changes()` moves with the server connection's own commits;
//! - `PRAGMA data_version` moves with commits by other connections.
//!
//! The route never waits on a busy vault: it `try_lock`s the vault and,
//! while another task holds it, answers the last value it computed for this
//! `open_id`, or `<open_id>-0-0` when it has computed none yet. The cache is
//! keyed by `open_id` and lives here (D8: `VaultEntry` gains no field).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError, Weak};

use axum::routing::get;
use axum::{Extension, Json, Router};
use serde_json::{json, Value};
use ulid::Ulid;

use crate::server::error::ApiError;
use crate::server::registry::{ServedVault, VaultEntry};

/// The last value computed for each open, with a weak handle on its entry
/// so entries of evicted opens can be dropped.
#[derive(Default)]
struct LastRevisions(Mutex<HashMap<Ulid, (Weak<VaultEntry>, String)>>);

impl LastRevisions {
    fn get(&self, open_id: Ulid) -> Option<String> {
        let map = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        map.get(&open_id).map(|(_, revision)| revision.clone())
    }

    /// Records `revision` for `entry`'s open and forgets the values of
    /// opens no request or registry can reach any more.
    fn set(&self, entry: &Arc<VaultEntry>, revision: String) {
        let mut map = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        map.retain(|_, (weak, _)| weak.strong_count() > 0);
        map.insert(entry.open_id, (Arc::downgrade(entry), revision));
    }
}

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    Router::new()
        .route("/revision", get(revision))
        .layer(Extension(Arc::new(LastRevisions::default())))
}

/// `GET /vaults/{name}/api/v1/revision`: `{"revision": "<opaque>"}`.
async fn revision(
    ServedVault(entry): ServedVault,
    Extension(last): Extension<Arc<LastRevisions>>,
) -> Result<Json<Value>, ApiError> {
    let Ok(guard) = entry.state.vault.clone().try_lock_owned() else {
        let revision = last
            .get(entry.open_id)
            .unwrap_or_else(|| format!("{}-0-0", entry.open_id));
        return Ok(Json(json!({ "revision": revision })));
    };
    // The owned guard moves into the blocking task: none is held across an
    // `.await`. The cache is written under the vault lock, so values are
    // recorded in the order they were read.
    let revision = tokio::task::spawn_blocking(move || -> Result<String, ApiError> {
        let conn = guard.connection_ref();
        let total_changes: i64 = conn
            .query_row("SELECT total_changes()", [], |r| r.get(0))
            .map_err(anyhow::Error::from)?;
        let data_version: i64 = conn
            .query_row("PRAGMA data_version", [], |r| r.get(0))
            .map_err(anyhow::Error::from)?;
        let revision = format!("{}-{total_changes}-{data_version}", entry.open_id);
        last.set(&entry, revision.clone());
        drop(guard);
        Ok(revision)
    })
    .await
    .map_err(|e| ApiError::from(anyhow::anyhow!("revision task failed: {e}")))??;
    Ok(Json(json!({ "revision": revision })))
}

#[cfg(test)]
mod tests {
    //! The cache's memory hygiene (#94). Not observable over HTTP: an
    //! evicted open is one no request can reach any more.

    use super::*;
    use crate::state::AppState;
    use memex_core::Vault;

    fn open_entry(root: &std::path::Path) -> Arc<VaultEntry> {
        let vault = Vault::create(root).expect("create vault");
        Arc::new(VaultEntry {
            open_id: Ulid::new(),
            state: AppState::new(vault, root.to_path_buf(), None),
        })
    }

    fn cached(last: &LastRevisions) -> usize {
        last.0.lock().unwrap().len()
    }

    #[test]
    fn last_revisions_drops_the_value_of_an_evicted_open_on_the_next_set() {
        let a_dir = tempfile::tempdir().unwrap();
        let b_dir = tempfile::tempdir().unwrap();
        let last = LastRevisions::default();
        let a = open_entry(a_dir.path());
        let a_open = a.open_id;
        last.set(&a, format!("{a_open}-3-2"));
        assert_eq!(last.get(a_open), Some(format!("{a_open}-3-2")));

        drop(a);
        // Kept until the next insert prunes it.
        assert_eq!(last.get(a_open), Some(format!("{a_open}-3-2")));

        let b = open_entry(b_dir.path());
        let b_open = b.open_id;
        last.set(&b, format!("{b_open}-0-2"));
        assert_eq!(last.get(a_open), None, "the evicted open is forgotten");
        assert_eq!(last.get(b_open), Some(format!("{b_open}-0-2")));
        assert_eq!(cached(&last), 1, "only the live open is cached");
    }

    #[test]
    fn last_revisions_keeps_every_live_open_when_another_is_recorded() {
        let dirs: Vec<_> = (0..3).map(|_| tempfile::tempdir().unwrap()).collect();
        let last = LastRevisions::default();
        let entries: Vec<_> = dirs.iter().map(|d| open_entry(d.path())).collect();
        for (i, e) in entries.iter().enumerate() {
            last.set(e, format!("{}-{i}-2", e.open_id));
        }
        // A newer value for one open replaces its old one.
        last.set(&entries[0], format!("{}-9-2", entries[0].open_id));

        assert_eq!(cached(&last), 3);
        assert_eq!(
            last.get(entries[0].open_id),
            Some(format!("{}-9-2", entries[0].open_id))
        );
        for (i, e) in entries.iter().enumerate().skip(1) {
            assert_eq!(last.get(e.open_id), Some(format!("{}-{i}-2", e.open_id)));
        }
    }
}
