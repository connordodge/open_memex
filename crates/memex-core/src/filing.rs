//! Day filing: where the blocks of one daily note are filed (Spec #233 R7,
//! R14, R15).

use serde::Serialize;

use crate::vault::Vault;
use crate::Result;

/// One block of the day, by id and current text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FiledBlock {
    pub id: String,
    pub text: String,
}

/// One topic note holding blocks of the day.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FiledTopic {
    pub topic_note_id: String,
    pub title: String,
    pub blocks: Vec<FiledBlock>,
}

/// The read model of [`day_filing`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DayFiling {
    pub date: String,
    pub note_id: String,
    pub reviewed: bool,
    pub topics: Vec<FiledTopic>,
    pub not_filed: Vec<FiledBlock>,
}

/// Where the blocks of the daily note dated `date` are filed. Read-only.
pub fn day_filing(_vault: &Vault, _date: &str) -> Result<DayFiling> {
    Ok(DayFiling {
        date: String::new(),
        note_id: String::new(),
        reviewed: false,
        topics: Vec::new(),
        not_filed: Vec::new(),
    })
}
