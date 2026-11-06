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

    #[error("a daily note for {date} already exists: {existing_id}")]
    DailyNoteExists { date: String, existing_id: String },

    #[error("marker rule: {0} (agents may not change the footer below <!-- memex:topics -->)")]
    MarkerRule(String),

    #[error("role rule: {0}")]
    RoleRule(String),

    /// `item` is a Smart Folder id, or `<folder id>/<note id>` for a pinned
    /// membership; `name` is the pinned item's human name (message only).
    #[error("pinned rule: {name} is pinned and cannot be changed by an agent")]
    PinnedRule { item: String, name: String },

    #[error("Smart Folder depth {required_depth} exceeds the vault maximum of {max_depth}")]
    DepthExceeded { max_depth: i64, required_depth: i64 },

    #[error("change entries invalid: {0}")]
    ChangeEntriesInvalid(String),

    #[error("review stale: reviewed version {version}, current version {current}")]
    ReviewStale { version: i64, current: i64 },

    #[error("name conflict: {0}")]
    NameConflict(String),

    #[error("folder cycle: {0}")]
    FolderCycle(String),

    #[error("invalid date: {0}")]
    InvalidDate(String),

    #[error("block not found: {0}")]
    BlockNotFound(String),

    #[error("setting invalid: {0}")]
    SettingInvalid(String),

    /// The detail names the path and the filesystem type (req 30).
    #[error("vault folder is on a network filesystem: {0}")]
    NetworkFilesystem(String),

    #[error("unknown tag: {0}")]
    UnknownTag(String),

    #[error("tag removed: {0}")]
    TagRemoved(String),

    #[error("guide rule: {0}")]
    GuideRule(String),

    #[error("feedback handled: {0}")]
    FeedbackHandled(String),

    #[error("feedback invalid: {0}")]
    FeedbackInvalid(String),
}

impl MemexError {
    /// The stable machine-readable code of the error contract (CONTRACTS.md
    /// C1). Variants outside the contract table are `internal`.
    pub fn code(&self) -> &'static str {
        match self {
            MemexError::VersionConflict { .. } => "version_conflict",
            MemexError::NotFound(_) => "not_found",
            MemexError::TitleConflict { .. } => "title_conflict",
            MemexError::InvalidId(_) => "invalid_id",
            MemexError::DailyNoteExists { .. } => "daily_note_exists",
            MemexError::MarkerRule(_) => "marker_rule",
            MemexError::RoleRule(_) => "role_rule",
            MemexError::PinnedRule { .. } => "pinned_rule",
            MemexError::DepthExceeded { .. } => "depth_exceeded",
            MemexError::ChangeEntriesInvalid(_) => "change_entries_invalid",
            MemexError::ReviewStale { .. } => "review_stale",
            MemexError::NameConflict(_) => "name_conflict",
            MemexError::FolderCycle(_) => "folder_cycle",
            MemexError::InvalidDate(_) => "invalid_date",
            MemexError::BlockNotFound(_) => "block_not_found",
            MemexError::SettingInvalid(_) => "setting_invalid",
            MemexError::NetworkFilesystem(_) => "network_filesystem",
            MemexError::UnknownTag(_) => "unknown_tag",
            MemexError::TagRemoved(_) => "tag_removed",
            MemexError::GuideRule(_) => "guide_rule",
            MemexError::FeedbackHandled(_) => "feedback_handled",
            MemexError::FeedbackInvalid(_) => "feedback_invalid",
            MemexError::Io(_)
            | MemexError::Sqlite(_)
            | MemexError::Json(_)
            | MemexError::ManifestInvalid(_)
            | MemexError::SchemaUnsupported { .. }
            | MemexError::InvalidPath(_)
            | MemexError::EmbedderInit(_)
            | MemexError::EmbedderInfer(_)
            | MemexError::TitleInvalid(_)
            | MemexError::TooManyDedupCollisions { .. }
            | MemexError::InvalidLinkKind(_)
            | MemexError::Yaml(_) => "internal",
        }
    }

    /// The JSON form of the error contract:
    /// `{"error":{"code":…,"message":…, …rule fields}}`, where `message` is
    /// the `Display` text and the rule fields are those C1 lists.
    pub fn to_error_json(&self) -> serde_json::Value {
        let mut error = serde_json::Map::new();
        error.insert("code".into(), self.code().into());
        error.insert("message".into(), self.to_string().into());
        for (key, value) in self.rule_fields() {
            error.insert(key.into(), value);
        }
        serde_json::json!({ "error": error })
    }

    /// The extra fields C1 lists for this variant, beyond `code` and `message`.
    fn rule_fields(&self) -> Vec<(&'static str, serde_json::Value)> {
        match self {
            MemexError::VersionConflict { expected, current } => {
                vec![
                    ("expected", (*expected).into()),
                    ("current", (*current).into()),
                ]
            }
            MemexError::TitleConflict { existing_id, .. } => {
                vec![("existing_id", existing_id.as_str().into())]
            }
            MemexError::DailyNoteExists { date, existing_id } => vec![
                ("date", date.as_str().into()),
                ("existing_id", existing_id.as_str().into()),
            ],
            MemexError::PinnedRule { item, .. } => vec![("item", item.as_str().into())],
            MemexError::DepthExceeded {
                max_depth,
                required_depth,
            } => vec![
                ("max_depth", (*max_depth).into()),
                ("required_depth", (*required_depth).into()),
            ],
            MemexError::ReviewStale { version, current } => {
                vec![
                    ("version", (*version).into()),
                    ("current", (*current).into()),
                ]
            }
            MemexError::NotFound(_)
            | MemexError::InvalidId(_)
            | MemexError::MarkerRule(_)
            | MemexError::RoleRule(_)
            | MemexError::ChangeEntriesInvalid(_)
            | MemexError::NameConflict(_)
            | MemexError::FolderCycle(_)
            | MemexError::InvalidDate(_)
            | MemexError::BlockNotFound(_)
            | MemexError::SettingInvalid(_)
            | MemexError::NetworkFilesystem(_)
            | MemexError::Io(_)
            | MemexError::Sqlite(_)
            | MemexError::Json(_)
            | MemexError::ManifestInvalid(_)
            | MemexError::SchemaUnsupported { .. }
            | MemexError::InvalidPath(_)
            | MemexError::EmbedderInit(_)
            | MemexError::EmbedderInfer(_)
            | MemexError::TitleInvalid(_)
            | MemexError::TooManyDedupCollisions { .. }
            | MemexError::InvalidLinkKind(_)
            | MemexError::Yaml(_)
            | MemexError::UnknownTag(_)
            | MemexError::TagRemoved(_)
            | MemexError::GuideRule(_)
            | MemexError::FeedbackHandled(_)
            | MemexError::FeedbackInvalid(_) => Vec::new(),
        }
    }
}

impl From<serde_yaml::Error> for MemexError {
    fn from(e: serde_yaml::Error) -> Self {
        MemexError::Yaml(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, MemexError>;
