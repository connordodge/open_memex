//! MCP tools for attachments (Spec #123 R18-R21, TD "MCP transport"; Ledger
//! L3, L4, L15): `add_attachment` stores a file and `get_attachment` reads
//! one. Storing, names, sizes and the reference grammar are
//! `memex_core::attachments`' (R1); this module holds only the agent
//! channel's own rules:
//!
//! - exactly one of `file_path` or `data`, and `name` with `data`;
//! - `file_path` only on a Local transport, absolute, never hidden or inside
//!   a hidden folder, and never inside the vault folder outside `objects/`,
//!   checked on the given path and on the path with every symlink resolved
//!   (L15). On the resolved path, "inside the vault" is decided by folder
//!   identity (device and inode), so another spelling of the vault folder
//!   (the macOS `/System/Volumes/Data` firmlink, a letter-case variant, a
//!   bind mount) is still inside it. These checks run here, never only in a prompt. The CLI (the
//!   person's channel) has none of them;
//! - `get_attachment` reads only regular files under `objects/`, and gives
//!   `file_path` only on Local.
//!
//! Neither tool changes a note, and the activity hook logs neither
//! (`meta::is_logged`).

use std::fs::{self, File};
use std::io::{ErrorKind, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig};
use base64::engine::DecodePaddingMode;
use base64::{alphabet, Engine};
use memex_core::attachments::{self, AttachmentPath, StoredAttachment};
use memex_core::MemexError;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, Content};
use rmcp::{tool, tool_router};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::json;

use super::Memex;
use crate::state::McpTransport;

/// The largest image returned as image content (R21): 5 MB.
pub const IMAGE_LIMIT: u64 = 5_242_880;
/// The largest text file returned as text (R21): 1 MB.
pub const TEXT_LIMIT: u64 = 1_048_576;
/// The extensions returned as text (R21), lowercase, without the dot.
const TEXT_EXTENSIONS: [&str; 4] = ["txt", "md", "csv", "json"];

/// The folder of a vault that holds attachments (R1).
const OBJECTS: &str = "objects";

const EXACTLY_ONE: &str = "Send exactly one of file_path or data.";
const HOSTED_FILE_PATH: &str = "file_path works only with a local vault; send data instead.";
const NOT_ABSOLUTE: &str = "file_path must be an absolute path.";
const BAD_BASE64: &str = "data is not valid base64.";
const NAME_REQUIRED: &str = "name is required with data.";

/// Standard base64, with or without its `=` padding.
const BASE64: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct AddAttachmentParams {
    /// The absolute path of a file on this computer. Local `memex serve`
    /// only; send `data` to a hosted vault. Hidden files, files in hidden
    /// folders and files in the vault folder outside `objects/` are refused.
    #[serde(default)]
    pub file_path: Option<String>,
    /// The file's bytes, base64. Send this or `file_path`, not both.
    #[serde(default)]
    pub data: Option<String>,
    /// The file's name, such as `Q3 report.pdf`. Required with `data`; with
    /// `file_path` it defaults to the file's own name.
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetAttachmentParams {
    /// An attachment path from a note body, `objects/<h2>/<hash>/<name>`,
    /// as written in the markdown (percent-encoded) or decoded.
    pub path: String,
}

#[tool_router(router = attachments_router, vis = "pub(crate)")]
impl Memex {
    #[tool(description = "Store a file in the vault as an attachment. Send \
        exactly one of `file_path` (an absolute path on this computer; local \
        `memex serve` only) or `data` (the file's bytes as base64, with \
        `name`). `name` sets the stored name; with `file_path` it defaults to \
        the file's own name. Up to 100 MB; a hosted vault takes about 6 MB of \
        `data` per request. Hidden files, files in hidden folders and files \
        in the vault folder outside `objects/` are refused. This changes no \
        note: place the returned `markdown` in a note yourself with \
        `create_note`, `edit_note` or `append_to_daily_note`. Returns \
        markdown, path, name, size (bytes) and type (MIME).")]
    pub async fn add_attachment(&self, params: Parameters<AddAttachmentParams>) -> String {
        let vault = self.state.vault_path.clone();
        let transport = self.state.transport;
        let done = tokio::task::spawn_blocking(move || add(&vault, transport, params.0)).await;
        match done {
            Ok(Ok(stored)) => json!(stored).to_string(),
            Ok(Err(refusal)) => refusal,
            Err(e) => internal(&e.to_string()),
        }
    }

    #[tool(description = "Read an attachment named in a note body by its \
        path (`objects/<h2>/<hash>/<name>`, encoded or not). A PNG, JPEG, GIF \
        or WebP up to 5 MB comes back as an image, and a .txt, .md, .csv or \
        .json file up to 1 MB as its text. Anything else returns its name, \
        size (bytes) and type (MIME), plus file_path (its absolute path) on \
        local `memex serve`. There is no tool that lists every attachment.")]
    pub async fn get_attachment(&self, params: Parameters<GetAttachmentParams>) -> CallToolResult {
        let vault = self.state.vault_path.clone();
        let transport = self.state.transport;
        let done =
            tokio::task::spawn_blocking(move || read(&vault, transport, &params.0.path)).await;
        done.unwrap_or_else(|e| {
            CallToolResult::error(vec![Content::text(internal(&e.to_string()))])
        })
    }
}

// ---- add_attachment -----------------------------------------------------------------------

/// Stores the file `params` name in `vault`; a refusal is its C1 JSON.
fn add(
    vault: &Path,
    transport: McpTransport,
    params: AddAttachmentParams,
) -> Result<StoredAttachment, String> {
    let name = params.name.as_deref();
    let stored = match (params.file_path, params.data) {
        (Some(file_path), None) => store_path(vault, transport, &file_path, name)?,
        (None, Some(data)) => store_data(vault, &data, name)?,
        _ => return Err(invalid(EXACTLY_ONE)),
    };
    // R17 (#136): extract and index the stored file's text here.
    Ok(stored)
}

/// Stores the file at `given` after the L15 checks on the given and the
/// resolved path. The stored name defaults to the given path's base name.
fn store_path(
    vault: &Path,
    transport: McpTransport,
    given: &str,
    name: Option<&str>,
) -> Result<StoredAttachment, String> {
    if transport == McpTransport::Hosted {
        return Err(invalid(HOSTED_FILE_PATH));
    }
    let path = Path::new(given);
    if !path.is_absolute() {
        return Err(invalid(NOT_ABSOLUTE));
    }
    check_given(path, given, vault)?;
    let resolved = fs::canonicalize(path).map_err(|e| unreadable(given, &e))?;
    check_resolved(&resolved, given, vault)?;
    let base = path.file_name().map(|n| n.to_string_lossy().into_owned());
    let name = name.map(str::to_string).or(base).unwrap_or_default();
    attachments::store_file(vault, &resolved, Some(&name)).map_err(|e| core_error(&e))
}

/// Stores base64 `data` under `name`, which is required.
fn store_data(vault: &Path, data: &str, name: Option<&str>) -> Result<StoredAttachment, String> {
    let name = name.ok_or_else(|| invalid(NAME_REQUIRED))?;
    let bytes = BASE64.decode(data).map_err(|_| invalid(BAD_BASE64))?;
    attachments::store_bytes(vault, &bytes, name).map_err(|e| core_error(&e))
}

/// The vault folder as served (made absolute) and with its symlinks resolved.
fn vault_forms(vault: &Path) -> [PathBuf; 2] {
    let absolute = std::path::absolute(vault).unwrap_or_else(|_| vault.to_path_buf());
    let resolved = fs::canonicalize(vault).unwrap_or_else(|_| absolute.clone());
    [absolute, resolved]
}

/// Refuses the given path, before it is resolved (so a refusal tells
/// nothing about whether it exists), when it is hidden or, as text, inside a
/// vault folder form outside `objects/`.
fn check_given(path: &Path, given: &str, vault: &Path) -> Result<(), String> {
    check_hidden(path, given)?;
    if vault_forms(vault)
        .iter()
        .any(|v| inside_outside_objects(path, v))
    {
        return Err(inside_vault(given));
    }
    Ok(())
}

/// Refuses the resolved path when it is hidden or, by folder identity,
/// inside the vault folder outside `objects/`.
fn check_resolved(resolved: &Path, given: &str, vault: &Path) -> Result<(), String> {
    check_hidden(resolved, given)?;
    if resolves_inside_outside_objects(resolved, vault).map_err(|e| unreadable(given, &e))? {
        return Err(inside_vault(given));
    }
    Ok(())
}

/// Refuses `path` (`given`, or what it resolves to) when it is hidden or
/// inside a hidden folder. The refusal names the path the agent gave.
fn check_hidden(path: &Path, given: &str) -> Result<(), String> {
    if is_hidden(path) {
        return Err(invalid(&format!(
            "{given} is hidden or inside a hidden folder and can't be attached."
        )));
    }
    Ok(())
}

/// The refusal of a `file_path` inside the vault folder outside `objects/`.
fn inside_vault(given: &str) -> String {
    invalid(&format!(
        "{given} is inside the vault and can't be attached."
    ))
}

/// Whether any component of `path` starts with `.` (`.env`, `.ssh`, `..`).
fn is_hidden(path: &Path) -> bool {
    path.as_os_str()
        .as_bytes()
        .split(|&b| b == b'/')
        .any(|c| c.first() == Some(&b'.'))
}

/// Whether `path` is the vault folder or inside it, but not in `objects/`,
/// compared as text (the given path, before it is resolved).
fn inside_outside_objects(path: &Path, vault: &Path) -> bool {
    path.starts_with(vault) && !path.starts_with(vault.join(OBJECTS))
}

/// Whether `resolved` (a path with every symlink resolved) is the vault
/// folder or inside it, but not in `objects/`, compared by identity: the
/// nearest ancestor (or `resolved` itself) that is the vault's `objects/`
/// folder allows it, and one that is the vault folder refuses it. An
/// ancestor that can't be read is an error, so the check fails closed.
fn resolves_inside_outside_objects(resolved: &Path, vault: &Path) -> std::io::Result<bool> {
    let vault_id = identity(vault)?;
    // Not followed: an `objects` link never makes the folder it points to
    // count as `objects/`.
    let objects_id = fs::symlink_metadata(vault.join(OBJECTS))
        .ok()
        .map(|m| (m.dev(), m.ino()));
    for ancestor in resolved.ancestors() {
        let id = identity(ancestor)?;
        if Some(id) == objects_id {
            return Ok(false);
        }
        if id == vault_id {
            return Ok(true);
        }
    }
    Ok(false)
}

/// The (device, inode) pair naming the file or folder at `path`.
fn identity(path: &Path) -> std::io::Result<(u64, u64)> {
    let meta = fs::metadata(path)?;
    Ok((meta.dev(), meta.ino()))
}

// ---- get_attachment -----------------------------------------------------------------------

/// An attachment file found under `objects/`, opened.
struct Found {
    file: File,
    size: u64,
    /// Its absolute path, every symlink resolved.
    real: PathBuf,
    /// The stored name.
    name: String,
}

/// The `get_attachment` answer for `path` (R21).
fn read(vault: &Path, transport: McpTransport, path: &str) -> CallToolResult {
    match find(vault, path).and_then(|found| content(found, transport)) {
        Ok(content) => CallToolResult::success(vec![content]),
        Err(message) => CallToolResult::error(vec![Content::text(message)]),
    }
}

/// The attachment `path` names: tried as given, then percent-decoded once.
fn find(vault: &Path, path: &str) -> Result<Found, String> {
    let tries = [
        attachments::parse_path(path),
        attachments::parse_destination(path),
    ];
    if tries.iter().all(Option::is_none) {
        return Err(coded(
            "invalid_argument",
            &format!("Not an attachment path: {path}"),
        ));
    }
    tries
        .into_iter()
        .flatten()
        .find_map(|target| open(vault, &target))
        .ok_or_else(|| coded("not_found", &format!("Attachment not found: {path}")))
}

/// The regular file at `target` when, with every symlink resolved, it is
/// still under the vault's `objects/` folder.
fn open(vault: &Path, target: &AttachmentPath) -> Option<Found> {
    let objects = fs::canonicalize(vault.join(OBJECTS)).ok()?;
    let real = fs::canonicalize(vault.join(&target.path)).ok()?;
    let regular = real.starts_with(&objects) && fs::metadata(&real).ok()?.is_file();
    if !regular {
        return None;
    }
    let file = File::open(&real).ok()?;
    let size = file.metadata().ok()?.len();
    Some(Found {
        file,
        size,
        real,
        name: target.name.clone(),
    })
}

/// An image or text within its limit as its content; anything else as its
/// details.
fn content(found: Found, transport: McpTransport) -> Result<Content, String> {
    let mime = attachments::mime_for(&found.name);
    if attachments::is_inline_image(&found.name) && found.size <= IMAGE_LIMIT {
        let bytes = read_all(&found)?;
        return Ok(Content::image(BASE64.encode(bytes), mime));
    }
    if is_text(&found.name) && found.size <= TEXT_LIMIT {
        let bytes = read_all(&found)?;
        return Ok(Content::text(String::from_utf8_lossy(&bytes).into_owned()));
    }
    let mut details = json!({ "name": found.name, "size": found.size, "type": mime });
    if transport == McpTransport::Local {
        details["file_path"] = json!(found.real.to_string_lossy());
    }
    Ok(Content::text(details.to_string()))
}

/// Whether `name` has a text extension (R21), in any letter case.
fn is_text(name: &str) -> bool {
    name.rsplit_once('.')
        .is_some_and(|(_, ext)| TEXT_EXTENSIONS.iter().any(|t| t.eq_ignore_ascii_case(ext)))
}

/// The file's bytes, at most its size when it was opened.
fn read_all(found: &Found) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    (&found.file)
        .take(found.size)
        .read_to_end(&mut bytes)
        .map_err(|e| internal(&format!("read {}: {e}", found.name)))?;
    Ok(bytes)
}

// ---- errors -------------------------------------------------------------------------------

/// The C1 error object `{"error":{"code","message"}}`, as JSON text.
fn coded(code: &str, message: &str) -> String {
    json!({ "error": { "code": code, "message": message } }).to_string()
}

fn invalid(message: &str) -> String {
    coded("invalid_argument", message)
}

fn internal(message: &str) -> String {
    coded("internal", message)
}

/// A `file_path` that can't be resolved (missing, or not readable).
fn unreadable(given: &str, e: &std::io::Error) -> String {
    let code = if e.kind() == ErrorKind::NotFound {
        "not_found"
    } else {
        "invalid_argument"
    };
    coded(code, &format!("{given} can't be read: {e}"))
}

/// A store failure. Core's `Io(InvalidInput)` is its form of
/// `invalid_argument` (the R15 texts), which `to_error_json` alone reports
/// as `internal`.
fn core_error(e: &MemexError) -> String {
    match e {
        MemexError::Io(io) if io.kind() == ErrorKind::InvalidInput => invalid(&io.to_string()),
        _ => e.to_error_json().to_string(),
    }
}
