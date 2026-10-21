//! Read models the app API serves (the vault server's `/api/v1` routes).
//! Registered up front (D3); each slice fills its own file.

pub mod daily;
pub mod graph;
pub mod notes;
pub mod topics;
