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

    #[error("title conflicts with existing note {existing_id}: {attempted_title}")]
    TitleConflict {
        existing_id: String,
        attempted_title: String,
    },

    #[error("title invalid: {0}")]
    TitleInvalid(String),

    #[error("too many duplicate-title collisions during migration: {count}")]
    TooManyDedupCollisions { count: i64 },

    #[error("invalid link kind: {0}")]
    InvalidLinkKind(String),

    #[error("yaml error: {0}")]
    Yaml(String),
}

impl From<serde_yaml::Error> for MemexError {
    fn from(e: serde_yaml::Error) -> Self {
        MemexError::Yaml(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, MemexError>;
