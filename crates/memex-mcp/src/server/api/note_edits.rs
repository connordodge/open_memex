//! `/vaults/{name}/api/v1/…`: the Agent read-only and agent-edit revision
//! routes (Spec #7 Req 37; rulings D13, D14).
//!
//! - `PUT /notes/{note_id}/agent-read-only {agent_read_only}` -> the
//!   `memex read-only set|clear` object
//! - `GET /notes/{note_id}/revisions` -> the `memex revisions list` object
//! - `POST /notes/{note_id}/revisions/{revision_id}/restore` (no body) -> the
//!   `memex revisions restore` object; a revision of another note is
//!   `not_found`

use axum::Router;

/// This domain's routes, nested under `/vaults/{name}/api/v1`.
pub fn router() -> Router {
    // WI #12 skeleton: no routes yet.
    Router::new()
}
