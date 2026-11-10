//! The backup zip and its fingerprint (Spec #315 req 1, 3, 7; architecture
//! D7). Filler: R1b.
//!
//! Members, all deflate-compressed: `memex.db`, `manifest.json`, `objects/`
//! (folders and files, sorted bytewise by name), `backup.json` last. The
//! write pass feeds the [`Fingerprinter`] the very bytes it puts in the zip,
//! so the recorded and printed fingerprint is the zip's own.

use std::cell::Cell;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufWriter, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use serde::Serialize;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::backup::fingerprint::Fingerprinter;
use crate::backup::{ArchiveSink, BackupSource, FORMAT};
use crate::error::MemexError;
use crate::vault::{DB_FILENAME, MANIFEST_FILENAME, OBJECTS_DIR};
use crate::Result;

const BACKUP_JSON: &str = "backup.json";

/// One `objects/` entry, by its `/`-joined path relative to `objects/`.
#[derive(Debug)]
pub(super) enum Entry {
    /// A folder; its path ends in `/`.
    Folder(String),
    File(String),
}

impl Entry {
    fn rel(&self) -> &str {
        match self {
            Entry::Folder(rel) | Entry::File(rel) => rel,
        }
    }
}

fn failed(what: &str, e: impl std::fmt::Display) -> MemexError {
    MemexError::BackupFailed(format!("{what}: {e}"))
}

/// Every entry under `objects_dir`, sorted bytewise by relative path (a
/// folder's path ends in `/`, so `a.txt` < `a/` < `a/x.bin`). Anything that
/// isn't a regular file or a folder, or has a name that isn't UTF-8, fails
/// the backup: it is never skipped (D9). No `objects/` folder is no objects.
pub(super) fn list_objects(objects_dir: &Path) -> Result<Vec<Entry>> {
    match fs::symlink_metadata(objects_dir) {
        Ok(meta) if meta.is_dir() => {}
        Ok(_) => {
            return Err(MemexError::BackupFailed(format!(
                "{} is not a folder",
                objects_dir.display()
            )))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(failed(&format!("read {}", objects_dir.display()), e)),
    }
    let mut out = Vec::new();
    walk(objects_dir, "", &mut out)?;
    out.sort_by(|a, b| a.rel().as_bytes().cmp(b.rel().as_bytes()));
    Ok(out)
}

fn walk(dir: &Path, prefix: &str, out: &mut Vec<Entry>) -> Result<()> {
    let read = |e: io::Error| failed(&format!("read {}", dir.display()), e);
    for entry in fs::read_dir(dir).map_err(read)? {
        let entry = entry.map_err(read)?;
        let name = entry.file_name().into_string().map_err(|name| {
            MemexError::BackupFailed(format!(
                "objects/{prefix}{} has a name that isn't UTF-8",
                name.to_string_lossy()
            ))
        })?;
        let rel = format!("{prefix}{name}");
        // Not followed: a symlink is reported as one.
        let kind = entry.file_type().map_err(read)?;
        if kind.is_dir() {
            let folder = format!("{rel}/");
            walk(&entry.path(), &folder, out)?;
            out.push(Entry::Folder(folder));
        } else if kind.is_file() {
            out.push(Entry::File(rel));
        } else {
            return Err(MemexError::BackupFailed(format!(
                "objects/{rel} is not a regular file or a folder"
            )));
        }
    }
    Ok(())
}

/// Opens an `objects/` file for reading without following a symlink or
/// blocking on a FIFO put there since the walk, and checks it is still a
/// regular file. Returns it with its length.
fn open_object(objects_dir: &Path, rel: &str) -> Result<(File, u64)> {
    let path = objects_dir.join(rel);
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&path)
        .map_err(|e| failed(&format!("read objects/{rel}"), e))?;
    let meta = file
        .metadata()
        .map_err(|e| failed(&format!("read objects/{rel}"), e))?;
    if !meta.is_file() {
        return Err(MemexError::BackupFailed(format!(
            "objects/{rel} is not a regular file or a folder"
        )));
    }
    Ok((file, meta.len()))
}

fn open_snapshot(path: &Path) -> Result<(File, u64)> {
    let file = File::open(path).map_err(|e| failed("read the snapshot", e))?;
    let len = file
        .metadata()
        .map_err(|e| failed("read the snapshot", e))?
        .len();
    Ok((file, len))
}

/// What a backup holds, read from disk as it is fingerprinted or written.
pub(super) struct Content<'a> {
    /// The snapshot of `memex.db` (a temp file).
    pub snapshot: &'a Path,
    /// `manifest.json`'s bytes.
    pub manifest: &'a [u8],
    pub objects_dir: &'a Path,
    /// From [`list_objects`].
    pub objects: &'a [Entry],
}

/// The fields of `backup.json` (req 3) other than the fingerprint.
pub(super) struct Info<'a> {
    pub vault_id: &'a str,
    pub schema_version: i64,
    pub created_at: i64,
    pub source: BackupSource,
}

/// `backup.json`, in req 3's key order.
#[derive(Serialize)]
struct BackupJson<'a> {
    format: i64,
    vault_id: &'a str,
    schema_version: i64,
    created_at: i64,
    memex_version: &'static str,
    fingerprint: &'a str,
    source: BackupSource,
}

impl Content<'_> {
    /// The `--if-changed` pre-pass: the fingerprint without writing.
    pub(super) fn fingerprint(&self) -> Result<String> {
        let mut fp = Fingerprinter::new();
        fp.snapshot(&mut open_snapshot(self.snapshot)?.0)?;
        fp.manifest(self.manifest);
        for entry in self.objects {
            if let Entry::File(rel) = entry {
                fp.object(rel, &mut open_object(self.objects_dir, rel)?.0)?;
            }
        }
        Ok(fp.finish())
    }

    /// Writes the zip into `sink` and returns its fingerprint. On failure
    /// the archive is abandoned without writing anything more.
    pub(super) fn write(&self, sink: Box<dyn ArchiveSink>, info: &Info) -> Result<String> {
        let aborted = Cell::new(false);
        let mut zip = ZipWriter::new(Abortable {
            inner: BufWriter::new(sink),
            aborted: &aborted,
            pos: 0,
        });
        match self.members(&mut zip, info) {
            Ok(fingerprint) => {
                let out = zip.finish().map_err(|e| failed("write the zip", e))?;
                let mut sink = out
                    .inner
                    .into_inner()
                    .map_err(|e| failed("write the zip", e.into_error()))?;
                sink.flush().map_err(|e| failed("write the zip", e))?;
                Ok(fingerprint)
            }
            Err(e) => {
                // ZipWriter finishes the archive on drop, writing to stderr
                // when that fails; the sink now swallows the rest instead.
                aborted.set(true);
                drop(zip);
                Err(e)
            }
        }
    }

    fn members(&self, zip: &mut ZipWriter<impl Write + Seek>, info: &Info) -> Result<String> {
        let mut fp = Fingerprinter::new();

        let (mut db, len) = open_snapshot(self.snapshot)?;
        start_file(zip, DB_FILENAME, len)?;
        tee(DB_FILENAME, &mut db, zip, |r| fp.snapshot(r))?;

        start_file(zip, MANIFEST_FILENAME, self.manifest.len() as u64)?;
        zip.write_all(self.manifest)
            .map_err(|e| failed(&format!("write {MANIFEST_FILENAME}"), e))?;
        fp.manifest(self.manifest);

        add_folder(zip, &format!("{OBJECTS_DIR}/"))?;
        for entry in self.objects {
            let name = format!("{OBJECTS_DIR}/{}", entry.rel());
            match entry {
                Entry::Folder(_) => add_folder(zip, &name)?,
                Entry::File(rel) => {
                    let (mut file, len) = open_object(self.objects_dir, rel)?;
                    start_file(zip, &name, len)?;
                    tee(&name, &mut file, zip, |r| fp.object(rel, r))?;
                }
            }
        }

        let fingerprint = fp.finish();
        let mut json = serde_json::to_vec_pretty(&BackupJson {
            format: FORMAT,
            vault_id: info.vault_id,
            schema_version: info.schema_version,
            created_at: info.created_at,
            memex_version: env!("CARGO_PKG_VERSION"),
            fingerprint: &fingerprint,
            source: info.source,
        })?;
        json.push(b'\n');
        start_file(zip, BACKUP_JSON, json.len() as u64)?;
        zip.write_all(&json)
            .map_err(|e| failed(&format!("write {BACKUP_JSON}"), e))?;
        Ok(fingerprint)
    }
}

fn options(len: u64) -> SimpleFileOptions {
    SimpleFileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        // Zip64 only where a member may not fit in 32-bit sizes (deflate
        // can grow incompressible data slightly).
        .large_file(len >= u64::from(u32::MAX) - (1 << 24))
}

fn start_file(zip: &mut ZipWriter<impl Write + Seek>, name: &str, len: u64) -> Result<()> {
    zip.start_file(name, options(len))
        .map_err(|e| failed(&format!("write {name}"), e))
}

fn add_folder(zip: &mut ZipWriter<impl Write + Seek>, name: &str) -> Result<()> {
    zip.add_directory(name, options(0))
        .map_err(|e| failed(&format!("write {name}"), e))
}

/// Runs `hash` over `from` while every byte it reads is also written to the
/// zip member being written. A failed write is the error returned.
fn tee(
    name: &str,
    from: &mut dyn Read,
    zip: &mut dyn Write,
    hash: impl FnOnce(&mut dyn Read) -> Result<()>,
) -> Result<()> {
    let mut reader = Tee {
        from,
        to: zip,
        write_error: None,
    };
    let hashed = hash(&mut reader);
    match reader.write_error {
        Some(e) => Err(failed(&format!("write {name}"), e)),
        None => hashed,
    }
}

struct Tee<'a> {
    from: &'a mut dyn Read,
    to: &'a mut dyn Write,
    write_error: Option<io::Error>,
}

impl Read for Tee<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.from.read(buf)?;
        if let Err(e) = self.to.write_all(&buf[..n]) {
            let message = e.to_string();
            self.write_error = Some(e);
            return Err(io::Error::other(message));
        }
        Ok(n)
    }
}

/// The archive sink, which once `aborted` is set takes every write and seek
/// without passing it on.
struct Abortable<'a, W> {
    inner: W,
    aborted: &'a Cell<bool>,
    /// The position reported while aborted.
    pos: u64,
}

impl<W: Write> Write for Abortable<'_, W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.aborted.get() {
            self.pos = self.pos.saturating_add(buf.len() as u64);
            return Ok(buf.len());
        }
        self.inner.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        if self.aborted.get() {
            return Ok(());
        }
        self.inner.flush()
    }
}

impl<W: Seek> Seek for Abortable<'_, W> {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        if self.aborted.get() {
            self.pos = match to {
                SeekFrom::Start(n) => n,
                SeekFrom::Current(d) | SeekFrom::End(d) => self.pos.saturating_add_signed(d),
            };
            return Ok(self.pos);
        }
        self.pos = self.inner.seek(to)?;
        Ok(self.pos)
    }
}
