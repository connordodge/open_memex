//! The backup fingerprint (Spec #315 req 7, technical decision 4;
//! architecture D7). Filler: R1a. R1b is the only caller.
//!
//! SHA-256 over the tag `b"memex-backup-fp-1\0"`, then each part as a
//! little-endian u64 byte count followed by its bytes: the snapshot, with
//! bytes 24–27 and 92–99 of its header (file change counter,
//! version-valid-for number, SQLite version number) zeroed; `manifest.json`;
//! then for each `objects/` file its relative path and then its content. The
//! caller feeds objects sorted bytewise by path.
//!
//! A part's length comes before its bytes and a `Read` has no length, so each
//! snapshot or object is read whole into memory before it is hashed.

use std::io::Read;

use sha2::{Digest, Sha256};

use crate::error::MemexError;
use crate::Result;

const TAG: &[u8] = b"memex-backup-fp-1\0";
/// Database header fields that can differ between copies of the same content.
const ZEROED: [std::ops::Range<usize>; 2] = [24..28, 92..100];

/// Length-prefixed SHA-256 over the snapshot, `manifest.json` and each
/// `objects/` file, fed in that order.
#[derive(Debug)]
pub struct Fingerprinter {
    hasher: Sha256,
}

impl Default for Fingerprinter {
    fn default() -> Self {
        Self::new()
    }
}

fn read_all(what: &str, bytes: &mut dyn Read) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    bytes
        .read_to_end(&mut buf)
        .map_err(|e| MemexError::BackupFailed(format!("fingerprint: read {what}: {e}")))?;
    Ok(buf)
}

impl Fingerprinter {
    pub fn new() -> Self {
        let mut hasher = Sha256::new();
        hasher.update(TAG);
        Fingerprinter { hasher }
    }

    fn part(&mut self, bytes: &[u8]) {
        self.hasher.update((bytes.len() as u64).to_le_bytes());
        self.hasher.update(bytes);
    }

    /// The snapshot's bytes (header fields zeroed while hashing).
    pub fn snapshot(&mut self, bytes: &mut dyn Read) -> Result<()> {
        let mut buf = read_all("snapshot", bytes)?;
        for range in ZEROED {
            let end = range.end.min(buf.len());
            if range.start < end {
                buf[range.start..end].fill(0);
            }
        }
        self.part(&buf);
        Ok(())
    }

    /// `manifest.json`'s bytes.
    pub fn manifest(&mut self, bytes: &[u8]) {
        self.part(bytes);
    }

    /// One `objects/` file: its `/`-joined relative path and its bytes.
    pub fn object(&mut self, rel: &str, bytes: &mut dyn Read) -> Result<()> {
        let buf = read_all(&format!("object {rel}"), bytes)?;
        self.part(rel.as_bytes());
        self.part(&buf);
        Ok(())
    }

    /// The lowercase hex SHA-256.
    pub fn finish(self) -> String {
        self.hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }
}
