//! One restore of a backup into a new vault folder (Spec #315 req 32-34;
//! architecture D14). Filler: R2.

use std::io;
use std::path::Path;

use super::{RestoreOutcome, RestoreRequest};
use crate::error::MemexError;
use crate::fs_guard::FsInfo;
use crate::Result;

/// See [`super::restore_with`].
pub fn restore_with(
    _r: &RestoreRequest,
    _probe: &dyn Fn(&Path) -> io::Result<FsInfo>,
) -> Result<RestoreOutcome> {
    Err(MemexError::BackupInvalid(
        "memex restore: not implemented yet".into(),
    ))
}
