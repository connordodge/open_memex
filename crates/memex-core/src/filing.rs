//! Day filing: where the blocks of one daily note are filed (Spec #233 R7,
//! R14, R15).

use std::collections::{BTreeSet, HashSet};

use rusqlite::Connection;
use serde::Serialize;

use crate::blocks::{self, Block};
use crate::daily::{self, ReviewState};
use crate::error::MemexError;
use crate::excerpts::{held_ords, DayBlocks};
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
///
/// A day never reviewed has `reviewed: false` and empty lists. Otherwise
/// `topics` holds every `role: topic` note with a resolving token of the day,
/// sorted by lowercased title then note id, each with the blocks it covers in
/// day order; `not_filed` holds, in day order, the blocks of the last review's
/// snapshot that still exist, are in no topic note and are not headings.
///
/// Errors: `InvalidDate`, `NotFound` (no daily note for `date`).
pub fn day_filing(vault: &Vault, date: &str) -> Result<DayFiling> {
    let day_date = daily::parse_iso_date(date)?;
    let conn = vault.connection_ref();
    let note_id = daily::daily_note_for_date(conn, day_date)?
        .ok_or_else(|| MemexError::NotFound(format!("no daily note for {date}")))?;
    let reviewed = daily::review_state(conn, &note_id)? != ReviewState::Unreviewed;
    if !reviewed {
        return Ok(DayFiling {
            date: date.to_string(),
            note_id,
            reviewed,
            topics: Vec::new(),
            not_filed: Vec::new(),
        });
    }

    let (stored, _) = daily::stored_blocks(conn, &note_id)?;
    let day_blocks = DayBlocks::from_blocks(&stored);
    let mut filed = BTreeSet::new();
    let mut topics = Vec::new();
    for (topic_note_id, title, body) in topics_mentioning(conn, date)? {
        let held = held_ords(&body, date, &day_blocks);
        let blocks: Vec<FiledBlock> = stored
            .iter()
            .filter(|b| held.contains(&(b.ord as i64)))
            .map(filed_block)
            .collect();
        if !blocks.is_empty() {
            topics.push(FiledTopic {
                topic_note_id,
                title,
                blocks,
            });
        }
        filed.extend(held);
    }
    topics.sort_by_cached_key(|t| (t.title.to_lowercase(), t.topic_note_id.clone()));

    let snapshot = snapshot_ids(conn, &note_id)?;
    let not_filed = stored
        .iter()
        .filter(|b| snapshot.contains(&b.block_id))
        .filter(|b| !filed.contains(&(b.ord as i64)))
        .filter(|b| !blocks::is_heading(b.text.trim_start()))
        .map(filed_block)
        .collect();

    Ok(DayFiling {
        date: date.to_string(),
        note_id,
        reviewed,
        topics,
        not_filed,
    })
}

fn filed_block(block: &Block) -> FiledBlock {
    FiledBlock {
        id: block.block_id.clone(),
        text: block.text.clone(),
    }
}

/// `(id, title, body)` of every `role: topic` note whose body has a token of
/// the day `date`, or text that looks like one.
fn topics_mentioning(conn: &Connection, date: &str) -> Result<Vec<(String, String, String)>> {
    let mut stmt = conn.prepare(
        "SELECT id, title, content_md FROM notes
         WHERE CASE WHEN json_valid(frontmatter) THEN json_extract(frontmatter, '$.role') END = 'topic'
           AND instr(content_md, ?) > 0",
    )?;
    let rows = stmt
        .query_map([format!("![[{date}#^")], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?
        .collect::<rusqlite::Result<_>>()?;
    Ok(rows)
}

/// The block ids of the note's last review snapshot.
fn snapshot_ids(conn: &Connection, note_id: &str) -> Result<HashSet<String>> {
    let mut stmt = conn.prepare("SELECT block_id FROM day_review_blocks WHERE note_id = ?")?;
    let ids = stmt
        .query_map([note_id], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(ids)
}
