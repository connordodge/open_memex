use thiserror::Error;

#[derive(Debug, Error)]
pub enum MemexError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("invalid id: {0}")]
    InvalidId(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("version conflict: expected {expected}, current {current}")]
    VersionConflict { expected: i64, current: i64 },

    #[error("manifest invalid: {0}")]
    ManifestInvalid(String),

    #[error("schema version unsupported: db={db}, app={app}")]
    SchemaUnsupported { db: i64, app: i64 },

    #[error("invalid path: {0}")]
    InvalidPath(String),

    #[error("embedder init failed: {0}")]
    EmbedderInit(String),

    #[error("embedder inference failed: {0}")]
    EmbedderInfer(String),
}

pub type Result<T> = std::result::Result<T, MemexError>;
