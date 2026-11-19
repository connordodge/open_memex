//! Attachments (Spec #123 R1-R6, R15, R31, R33; WI #134): the one place that
//! stores attachment files in a vault's `objects/` folder and knows the
//! attachment reference grammar. The CLI (`memex attach`), the MCP tools and
//! the server upload route all call this module; none copies its logic.
//!
//! - [`store_file`] / [`store_bytes`] copy a file or bytes to
//!   `objects/<h2>/<h>/<stored name>` through `objects/.tmp-<random>` and a
//!   rename, and return a [`StoredAttachment`].
//! - [`stored_name`] is the stored-name rule (R1).
//! - [`markdown_for`] and [`encode_name`] build the reference markdown (R3).
//! - [`parse_reference`], [`parse_destination`] and [`parse_path`] are the
//!   grammar (R4).
//! - [`mime_for`] and [`is_inline_image`] are the type tables (R31).
//! - [`is_executable_name`] and [`is_executable`] are the script and
//!   executable table (R33, L17).
//!
//! Refusals (R15) are `MemexError::Io` with `ErrorKind::InvalidInput` (the
//! crate's invalid-argument form) whose message is the exact Spec text.
//!
//! An extension is what follows a name's last `.` (`archive.tar.gz` has
//! `gz`; `png` has none). Every table matches it in any letter case.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::error::MemexError;
use crate::vault::OBJECTS_DIR;
use crate::Result;

/// The largest attachment, in bytes (R15): 100 MiB. A larger one is refused;
/// exactly this many bytes is allowed.
pub const MAX_ATTACHMENT_BYTES: u64 = 104_857_600;

/// The inline image extensions (R31), lowercase, without the dot.
pub const INLINE_IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];

/// The script and executable extensions that are revealed, never opened
/// (R33), lowercase, without the dot.
pub const EXECUTABLE_EXTENSIONS: &[&str] = &[
    "command",
    "tool",
    "terminal",
    "sh",
    "zsh",
    "bash",
    "py",
    "rb",
    "pl",
    "pkg",
    "mpkg",
    "dmg",
    "app",
    "workflow",
    "scpt",
    "applescript",
    "jar",
    "exe",
];

/// The longest stored name, in UTF-8 bytes (R1).
const MAX_NAME_BYTES: usize = 255;

/// The stored name of an empty given name (R1).
const EMPTY_NAME: &str = "file";

/// Temp files of a store live directly in `objects/` under this prefix (R2);
/// the backup walk skips them.
pub(crate) const TMP_PREFIX: &str = ".tmp-";

const OCTET_STREAM: &str = "application/octet-stream";

/// Extension (lowercase) → MIME type. Types a browser would run as a page
/// (`html`, `svg`, `xhtml`) are left out on purpose, so they are served as
/// `application/octet-stream`.
const MIME_TYPES: &[(&str, &str)] = &[
    ("png", "image/png"),
    ("jpg", "image/jpeg"),
    ("jpeg", "image/jpeg"),
    ("gif", "image/gif"),
    ("webp", "image/webp"),
    ("heic", "image/heic"),
    ("heif", "image/heif"),
    ("tif", "image/tiff"),
    ("tiff", "image/tiff"),
    ("bmp", "image/bmp"),
    ("pdf", "application/pdf"),
    ("txt", "text/plain"),
    ("md", "text/markdown"),
    ("markdown", "text/markdown"),
    ("csv", "text/csv"),
    ("tsv", "text/tab-separated-values"),
    ("json", "application/json"),
    ("rtf", "application/rtf"),
    ("zip", "application/zip"),
    ("gz", "application/gzip"),
    ("tar", "application/x-tar"),
    ("mp3", "audio/mpeg"),
    ("m4a", "audio/mp4"),
    ("wav", "audio/wav"),
    ("mp4", "video/mp4"),
    ("mov", "video/quicktime"),
    ("doc", "application/msword"),
    (
        "docx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ),
    ("xls", "application/vnd.ms-excel"),
    (
        "xlsx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ),
    ("ppt", "application/vnd.ms-powerpoint"),
    (
        "pptx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ),
];

/// What a store returns (R1, R16, R18, R40): `{markdown, path, name, size,
/// type}` when serialized.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct StoredAttachment {
    /// The R3 markdown to place in a note.
    pub markdown: String,
    /// The decoded vault-relative path, `objects/<h2>/<h>/<name>`.
    pub path: String,
    /// The stored name (R1).
    pub name: String,
    /// The size in bytes.
    pub size: u64,
    /// The MIME type from the extension ([`mime_for`]).
    #[serde(rename = "type")]
    pub mime: String,
}

/// The form of an attachment reference.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ReferenceKind {
    /// `![text](destination)`.
    Image,
    /// `[text](destination)`.
    Link,
}

/// A destination that is an attachment path (R4), percent-decoded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentPath {
    /// `objects/<h2>/<h>/<name>`, decoded.
    pub path: String,
    /// The 64 lowercase hex characters.
    pub hash: String,
    /// The decoded name.
    pub name: String,
}

/// One attachment reference (R4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reference {
    pub kind: ReferenceKind,
    /// The decoded destination.
    pub target: AttachmentPath,
}

// ---- refusals (R15) ---------------------------------------------------------------------------

fn refuse(message: String) -> MemexError {
    MemexError::Io(io::Error::new(io::ErrorKind::InvalidInput, message))
}

fn too_large(name: &str) -> MemexError {
    refuse(format!("{name} is larger than 100 MB and wasn't attached."))
}

fn not_regular(name: &str) -> MemexError {
    refuse(format!("{name} isn't a regular file and wasn't attached."))
}

fn folder() -> MemexError {
    refuse("Folders can't be attached.".to_string())
}

// ---- store (R1, R2, R15) ----------------------------------------------------------------------

/// Stores the file at `source` (a symlink stores the file it points to).
/// The stored name starts from `name`, or the source's base name without it.
///
/// The source is checked before it is opened, and opened without blocking,
/// so a FIFO is refused rather than waited on. Its bytes are hashed first;
/// when the final path already holds a file of the same size, nothing is
/// written. Otherwise they are read again into `objects/.tmp-<random>`,
/// checked against the first hash, and renamed into place.
pub fn store_file(vault: &Path, source: &Path, name: Option<&str>) -> Result<StoredAttachment> {
    let given = match name {
        Some(name) => name.to_string(),
        None => source
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
    };
    let name = stored_name(&given);

    // Followed: a symlink is checked as the file it points to.
    let meta = fs::metadata(source)?;
    if meta.is_dir() {
        return Err(folder());
    }
    if !meta.is_file() {
        return Err(not_regular(&name));
    }
    if meta.len() > MAX_ATTACHMENT_BYTES {
        return Err(too_large(&name));
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(source)?;
    // It may have been replaced since it was checked.
    let opened = file.metadata()?;
    if opened.is_dir() {
        return Err(folder());
    }
    if !opened.is_file() {
        return Err(not_regular(&name));
    }

    let (hash, size) = digest(&name, &mut file, &mut io::sink())?;
    let target = Target::new(&hash, name);
    if target.reusable(vault, size)? {
        return Ok(target.stored(size));
    }
    file.seek(SeekFrom::Start(0))?;
    target.write(vault, |tmp| {
        let (again, copied) = digest(&target.name, &mut file, tmp)?;
        if again != hash || copied != size {
            return Err(MemexError::Io(io::Error::other(format!(
                "{} changed while it was being attached",
                target.name
            ))));
        }
        Ok(())
    })?;
    Ok(target.stored(size))
}

/// Stores `bytes` under a stored name that starts from `name`. When the
/// final path already holds a file of the same size, nothing is written.
pub fn store_bytes(vault: &Path, bytes: &[u8], name: &str) -> Result<StoredAttachment> {
    let name = stored_name(name);
    let size = bytes.len() as u64;
    if size > MAX_ATTACHMENT_BYTES {
        return Err(too_large(&name));
    }
    let target = Target::new(&hex(&Sha256::digest(bytes)), name);
    if !target.reusable(vault, size)? {
        target.write(vault, |tmp| Ok(tmp.write_all(bytes)?))?;
    }
    Ok(target.stored(size))
}

/// Hashes up to one byte more than the limit of `from`, copying what it reads
/// to `to`. Returns the lowercase hex SHA-256 and the byte count; more than
/// the limit (a file that grew) is refused.
fn digest(name: &str, from: &mut dyn Read, to: &mut dyn Write) -> Result<(String, u64)> {
    let mut limited = from.take(MAX_ATTACHMENT_BYTES + 1);
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut size = 0u64;
    loop {
        let n = match limited.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.into()),
        };
        hasher.update(&buf[..n]);
        to.write_all(&buf[..n])?;
        size += n as u64;
    }
    if size > MAX_ATTACHMENT_BYTES {
        return Err(too_large(name));
    }
    Ok((hex(&hasher.finalize()), size))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A stored name at a content address.
struct Target {
    hash: String,
    name: String,
    /// `objects/<h2>/<h>/<name>`.
    rel: String,
}

impl Target {
    fn new(hash: &str, name: String) -> Self {
        let rel = format!("{OBJECTS_DIR}/{}/{hash}/{name}", &hash[..2]);
        Target {
            hash: hash.to_string(),
            name,
            rel,
        }
    }

    /// Whether the final path already holds a regular file of `size` bytes
    /// (R2). Not followed: a symlink there is replaced, never read through.
    fn reusable(&self, vault: &Path, size: u64) -> Result<bool> {
        match fs::symlink_metadata(vault.join(&self.rel)) {
            Ok(meta) => Ok(meta.is_file() && meta.len() == size),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.into()),
        }
    }

    /// Fills a new `objects/.tmp-<random>` with `fill`, flushes it to disk and
    /// renames it to the final path, replacing what is there. On failure the
    /// temp file is removed and the final path is untouched.
    fn write(&self, vault: &Path, fill: impl FnOnce(&mut File) -> Result<()>) -> Result<()> {
        let objects = vault.join(OBJECTS_DIR);
        // Not `create_dir_all`: a missing vault folder is an error.
        match fs::create_dir(&objects) {
            Err(e) if e.kind() != io::ErrorKind::AlreadyExists => return Err(e.into()),
            _ => {}
        }
        let mut tmp = tempfile::Builder::new()
            .prefix(TMP_PREFIX)
            .permissions(fs::Permissions::from_mode(0o644))
            .tempfile_in(&objects)?;
        fill(tmp.as_file_mut())?;
        tmp.as_file().sync_all()?;
        let path = vault.join(&self.rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        tmp.persist(&path).map_err(|e| e.error)?;
        Ok(())
    }

    fn stored(&self, size: u64) -> StoredAttachment {
        StoredAttachment {
            markdown: markdown_for(&self.name, &self.hash),
            path: self.rel.clone(),
            name: self.name.clone(),
            size,
            mime: mime_for(&self.name).to_string(),
        }
    }
}

// ---- the stored-name rule (R1) ----------------------------------------------------------------

/// The stored-name rule (R1), in order:
/// - `/`, `\`, NUL, U+0001-U+001F and U+007F each become `_`;
/// - leading and trailing whitespace is trimmed;
/// - a name over 255 UTF-8 bytes is cut on a character boundary, keeping its
///   extension (the name's last `.` and what follows, when that is shorter
///   than 255 bytes);
/// - an empty result, `.` or `..` becomes `file`.
pub fn stored_name(given: &str) -> String {
    let replaced: String = given
        .chars()
        .map(|c| {
            if c == '/' || c == '\\' || c.is_ascii_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    let trimmed = replaced.trim();
    let cut = cut_name(trimmed);
    match cut.as_str() {
        "" | "." | ".." => EMPTY_NAME.to_string(),
        _ => cut,
    }
}

/// `name` cut to [`MAX_NAME_BYTES`], keeping its extension when it has one
/// that leaves room.
fn cut_name(name: &str) -> String {
    if name.len() <= MAX_NAME_BYTES {
        return name.to_string();
    }
    match name.rfind('.') {
        Some(dot) if name.len() - dot < MAX_NAME_BYTES => {
            let (stem, ext) = name.split_at(dot);
            let stem = prefix_within(stem, MAX_NAME_BYTES - ext.len());
            format!("{stem}{ext}")
        }
        _ => prefix_within(name, MAX_NAME_BYTES).to_string(),
    }
}

/// The longest prefix of `s` of at most `max` bytes that ends on a character
/// boundary.
fn prefix_within(s: &str, max: usize) -> &str {
    let mut end = std::cmp::min(max, s.len());
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

// ---- markdown (R3) ----------------------------------------------------------------------------

/// `name` percent-encoded for a reference URL (R3): every UTF-8 byte outside
/// `A-Z a-z 0-9 - . _ ~` as `%XX`, uppercase hex.
pub fn encode_name(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for b in name.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// `name` for the bracketed text: `[`, `]` and `\` backslash-escaped (R3).
fn escape_text(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for c in name.chars() {
        if matches!(c, '[' | ']' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// The reference markdown for the stored `name` of the content `hash` (R3):
/// `![<name>](<url>)` for an inline image type (R31), `[<name>](<url>)`
/// otherwise, where `<url>` is `objects/<h2>/<hash>/<encoded name>`.
pub fn markdown_for(name: &str, hash: &str) -> String {
    let bang = if is_inline_image(name) { "!" } else { "" };
    let h2 = hash.get(..2).unwrap_or(hash);
    format!(
        "{bang}[{}]({OBJECTS_DIR}/{h2}/{hash}/{})",
        escape_text(name),
        encode_name(name)
    )
}

// ---- the grammar (R4) -------------------------------------------------------------------------

/// `destination` as an attachment path, if it is one (R4): percent-decoded
/// (`%XX` in either hex case; a `%` not followed by two hex digits, or bytes
/// that aren't UTF-8, are not an attachment), it is a [`parse_path`] path.
pub fn parse_destination(destination: &str) -> Option<AttachmentPath> {
    parse_path(&percent_decode(destination)?)
}

/// An already-decoded vault-relative `path` as an attachment path, if it is
/// one (R4): `objects/<2 hex>/<64 lowercase hex>/<name>`, the two hex
/// characters equal to the first two of the 64, and a non-empty `<name>`
/// with no `/` that is not `.` or `..`. This is what a
/// [`StoredAttachment::path`] is.
pub fn parse_path(path: &str) -> Option<AttachmentPath> {
    let rel = path.strip_prefix(OBJECTS_DIR)?.strip_prefix('/')?;
    let (hash, name) = split_object_rel(rel)?;
    Some(AttachmentPath {
        path: path.to_string(),
        hash: hash.to_string(),
        name: name.to_string(),
    })
}

/// Whether `rel`, a path relative to `objects/`, is a content address
/// `<h2>/<h>/<name>` (R4). The backup fingerprint uses it (R51).
pub(crate) fn is_content_addressed(rel: &str) -> bool {
    split_object_rel(rel).is_some()
}

/// `<h2>/<h>/<name>` → `(h, name)` when it is a content address (R4).
fn split_object_rel(rel: &str) -> Option<(&str, &str)> {
    let (h2, rest) = rel.split_once('/')?;
    let (hash, name) = rest.split_once('/')?;
    let lower_hex = |s: &str| s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    let hash_ok = hash.len() == 64 && lower_hex(hash) && hash.as_bytes()[..2] == *h2.as_bytes();
    let name_ok = !name.is_empty() && !name.contains('/') && name != "." && name != "..";
    (h2.len() == 2 && hash_ok && name_ok).then_some((hash, name))
}

fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hi = char::from(*bytes.get(i + 1)?).to_digit(16)?;
            let lo = char::from(*bytes.get(i + 2)?).to_digit(16)?;
            out.push((hi * 16 + lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// `markdown`, the whole string, as one attachment reference (R4):
/// `![<text>](<destination>)` (image) or `[<text>](<destination>)` (link),
/// on one line.
/// - The text runs to its first `]` not escaped by a `\`; it may be empty.
/// - The destination is everything between the `(` right after that `]` and
///   the string's final `)`. It holds no whitespace, `(` or `)`, and is a
///   [`parse_destination`] attachment path.
/// - Anything before or after the reference makes it not one.
pub fn parse_reference(markdown: &str) -> Option<Reference> {
    if markdown.contains(['\n', '\r']) {
        return None;
    }
    let (kind, rest) = match markdown.strip_prefix("![") {
        Some(rest) => (ReferenceKind::Image, rest),
        None => (ReferenceKind::Link, markdown.strip_prefix('[')?),
    };
    // `]` and `\` are ASCII, so stepping over an escaped byte never matches
    // inside a multi-byte character.
    let bytes = rest.as_bytes();
    let mut i = 0;
    let close = loop {
        match bytes.get(i)? {
            b'\\' => i += 2,
            b']' => break i,
            _ => i += 1,
        }
    };
    let destination = rest[close + 1..].strip_prefix('(')?.strip_suffix(')')?;
    if destination.contains(|c: char| c.is_whitespace() || c == '(' || c == ')') {
        return None;
    }
    let target = parse_destination(destination)?;
    Some(Reference { kind, target })
}

// ---- type tables (R31, R33) -------------------------------------------------------------------

/// What follows `name`'s last `.`, if it has one.
fn extension(name: &str) -> Option<&str> {
    name.rsplit_once('.').map(|(_, ext)| ext)
}

fn has_extension_in(name: &str, table: &[&str]) -> bool {
    extension(name).is_some_and(|ext| table.iter().any(|t| t.eq_ignore_ascii_case(ext)))
}

/// The MIME type of `name` from its extension; `application/octet-stream`
/// when unknown (R16, R31).
pub fn mime_for(name: &str) -> &'static str {
    extension(name)
        .and_then(|ext| MIME_TYPES.iter().find(|(e, _)| e.eq_ignore_ascii_case(ext)))
        .map_or(OCTET_STREAM, |(_, mime)| mime)
}

/// Whether `name` has an inline image extension (R31), in any letter case.
pub fn is_inline_image(name: &str) -> bool {
    has_extension_in(name, INLINE_IMAGE_EXTENSIONS)
}

/// Whether `name` has a script or executable extension (R33), in any letter
/// case.
pub fn is_executable_name(name: &str) -> bool {
    has_extension_in(name, EXECUTABLE_EXTENSIONS)
}

/// Whether the file at `path` is revealed, never opened (R33): an
/// executable extension, or a regular file with any executable permission
/// bit (owner, group or other).
pub fn is_executable(path: &Path) -> bool {
    let by_name = path
        .file_name()
        .is_some_and(|n| is_executable_name(&n.to_string_lossy()));
    by_name || fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}
