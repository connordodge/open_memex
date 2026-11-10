//! The backup fingerprint (Spec #315 req 7, technical decision 4;
//! architecture D7). Filler: R1a. R1b is the only caller.

use std::io::Read;

use crate::Result;

/// Length-prefixed SHA-256 over the snapshot, `manifest.json` and each
/// `objects/` file, fed in that order.
#[derive(Debug)]
pub struct Fingerprinter {
    _private: (),
}

impl Default for Fingerprinter {
    fn default() -> Self {
        Self::new()
    }
}

impl Fingerprinter {
    pub fn new() -> Self {
        Fingerprinter { _private: () }
    }

    /// The snapshot's bytes (header fields zeroed while hashing).
    pub fn snapshot(&mut self, _bytes: &mut dyn Read) -> Result<()> {
        Ok(())
    }

    /// `manifest.json`'s bytes.
    pub fn manifest(&mut self, _bytes: &[u8]) {}

    /// One `objects/` file: its `/`-joined relative path and its bytes.
    pub fn object(&mut self, _rel: &str, _bytes: &mut dyn Read) -> Result<()> {
        Ok(())
    }

    /// The lowercase hex SHA-256.
    pub fn finish(self) -> String {
        String::new()
    }
}
