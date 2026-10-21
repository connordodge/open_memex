//! Daily notes.
//!
//! The canonical daily body (architect ruling D10, CONTRACTS C3), the footer
//! rendered from `footer_chips` (D11), the local-time "today" behind an
//! injectable clock (D14), the review state of a day (Req 19) and the single
//! daily write hook every save of a `role: daily` note runs inside its
//! transaction (D9).

use std::collections::HashMap;

use chrono::{DateTime, NaiveDate};
use rusqlite::{params, Connection};
use ulid::Ulid;

use crate::blocks::{self, Block};
use crate::caller::Caller;
use crate::canvas::Clock;
use crate::embedder::Embedder;
use crate::error::MemexError;
use crate::indexer;
use crate::notes::{self, CreateNote, Note, NoteId};
use crate::vault::Vault;
use crate::Result;

/// The Topics footer marker line (C3).
pub const TOPICS_MARKER: &str = "<!-- memex:topics -->";

/// The frontmatter `role` value of a daily note. The match is exact.
const DAILY_ROLE: &str = "daily";

/// A daily note body split at the Topics footer marker (C3).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DailyBody {
    /// Everything above the first marker line, plus any stray text from below
    /// it (Q1).
    pub person: String,
    /// Footer chip titles (`[[<title>~about]]`), in order.
    pub chips: Vec<String>,
}

/// A line without its `\n`, with trailing spaces and `\r` trimmed (C3).
fn trim_line_end(line: &str) -> &str {
    line.trim_end_matches([' ', '\r'])
}

/// The title of a footer chip line (`^\[\[(.+)~about\]\]$`, C3), if it is one.
fn chip_title(line: &str) -> Option<&str> {
    line.strip_prefix("[[")
        .and_then(|rest| rest.strip_suffix("~about]]"))
        .filter(|title| !title.is_empty())
}

/// Splits a daily note body into the person section and footer chips (C3).
///
/// Splits at the first marker line; without one the whole body is person.
/// Below the marker, chip lines become `chips` in order, blank lines and
/// further marker lines are dropped, and any other line is stray text moved
/// to the end of the person section (Q1).
pub fn split_body(body: &str) -> DailyBody {
    let mut start = 0;
    let mut marker = None;
    for line in body.split_inclusive('\n') {
        let end = start + line.len();
        if trim_line_end(line.strip_suffix('\n').unwrap_or(line)) == TOPICS_MARKER {
            marker = Some((start, end));
            break;
        }
        start = end;
    }
    let Some((marker_start, marker_end)) = marker else {
        return DailyBody {
            person: body.to_string(),
            chips: Vec::new(),
        };
    };

    let mut person = body[..marker_start].to_string();
    let mut chips = Vec::new();
    let mut stray = Vec::new();
    for line in body[marker_end..].split('\n') {
        let content = trim_line_end(line);
        if content.is_empty() || content == TOPICS_MARKER {
            continue;
        }
        match chip_title(content) {
            Some(title) => chips.push(title.to_string()),
            None => stray.push(line),
        }
    }
    if !stray.is_empty() {
        end_with_newline(&mut person);
        for line in stray {
            person.push_str(line);
            person.push('\n');
        }
    }
    DailyBody { person, chips }
}

/// Appends `\n` to a non-empty `text` that does not end with one.
fn end_with_newline(text: &mut String) {
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
}

/// Assembles the canonical daily body from a person section and chip titles (C3).
pub fn assemble<S: AsRef<str>>(person: &str, chips: &[S]) -> String {
    let mut body = person.to_string();
    end_with_newline(&mut body);
    body.push_str(TOPICS_MARKER);
    body.push('\n');
    for title in chips {
        body.push_str("[[");
        body.push_str(title.as_ref());
        body.push_str("~about]]\n");
    }
    body
}

/// Appends `text` to the end of a person section with the C3.1 separator: a
/// non-empty person section is first padded to end with `\n\n`, then
/// `text + "\n"` is appended. Q2 adoption uses it; append (#12) shares it.
pub fn append_to_person(person: &str, text: &str) -> String {
    let mut out = person.to_string();
    if !out.is_empty() {
        while !out.ends_with("\n\n") {
            out.push('\n');
        }
    }
    out.push_str(text);
    out.push('\n');
    out
}

/// The footer chip titles of a daily note, from `footer_chips` joined to
/// `notes`, in rowid order (D11).
pub fn render_footer(conn: &Connection, daily_note_id: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT n.title FROM footer_chips f JOIN notes n ON n.id = f.topic_note_id
         WHERE f.daily_note_id = ? ORDER BY f.rowid",
    )?;
    let titles = stmt
        .query_map([daily_note_id], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(titles)
}

/// Today's date at `clock`'s instant, in the UTC offset `clock` reports for
/// that instant (D14, D5): the machine's local offset unless the clock
/// overrides `utc_offset_at` (a `CallerClock`). Both are read on every call;
/// this is the only instant-to-date mapping.
pub fn today_with_clock(clock: &dyn Clock) -> NaiveDate {
    let now = clock.now_ms();
    DateTime::from_timestamp_millis(now)
        .unwrap_or_default()
        .with_timezone(&clock.utc_offset_at(now))
        .date_naive()
}

/// `None` → today (local); `Some(s)` → `s` when it is a real `YYYY-MM-DD`
/// calendar date, else `InvalidDate` (D14).
pub fn resolve_date(date: Option<&str>, clock: &dyn Clock) -> Result<NaiveDate> {
    match date {
        None => Ok(today_with_clock(clock)),
        Some(s) => parse_iso_date(s),
    }
}

/// Parses a strict `YYYY-MM-DD` calendar date (four-digit year, zero-padded
/// month and day, nothing else), else `InvalidDate`. Daily note titles must
/// pass it (D15).
pub fn parse_iso_date(s: &str) -> Result<NaiveDate> {
    let shaped = s.len() == 10
        && s.bytes().enumerate().all(|(i, b)| match i {
            4 | 7 => b == b'-',
            _ => b.is_ascii_digit(),
        });
    shaped
        .then(|| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
        .flatten()
        .ok_or_else(|| MemexError::InvalidDate(format!("not a YYYY-MM-DD calendar date: {s:?}")))
}

/// Whether `frontmatter` marks a daily note: `role` is exactly `daily`.
pub fn is_daily(frontmatter: &serde_json::Value) -> bool {
    frontmatter.get("role").and_then(|r| r.as_str()) == Some(DAILY_ROLE)
}

/// The review state of a daily note (Req 19, CONTRACTS C2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReviewState {
    /// `reviewed_content_version` is NULL.
    Unreviewed,
    /// `reviewed_content_version` equals `content_version`.
    Reviewed,
    /// Anything else.
    ChangedSinceReview,
}

impl ReviewState {
    /// The exact C2 label: `Unreviewed`, `Reviewed`, `Changed since review`.
    pub fn as_str(self) -> &'static str {
        match self {
            ReviewState::Unreviewed => "Unreviewed",
            ReviewState::Reviewed => "Reviewed",
            ReviewState::ChangedSinceReview => "Changed since review",
        }
    }
}

/// The review state of the daily note `note_id`, from its `day_reviews` row.
/// A note without a row has never been reviewed: `Unreviewed`.
pub fn review_state(conn: &Connection, note_id: &str) -> Result<ReviewState> {
    let row: Option<(i64, Option<i64>)> = conn
        .query_row(
            "SELECT content_version, reviewed_content_version FROM day_reviews WHERE note_id = ?",
            [note_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other),
        })?;
    Ok(match row {
        None | Some((_, None)) => ReviewState::Unreviewed,
        Some((current, Some(reviewed))) if reviewed == current => ReviewState::Reviewed,
        Some(_) => ReviewState::ChangedSinceReview,
    })
}

/// Who is appending to a daily note (R9).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppendSource {
    /// MCP `append_to_daily_note`: new blocks get `source: agent`; a
    /// role-less note titled with the date is a `TitleConflict` (Q2).
    Agent,
    /// `memex append`: new blocks get `source: quick-entry`; a role-less note
    /// titled with the date is adopted as the daily note (Q2).
    QuickEntry,
}

/// What an append did (CONTRACTS C2.12).
#[derive(Debug, Clone)]
pub struct AppendOutcome {
    /// The daily note as stored after the append (`version` is its new
    /// `notes.version`).
    pub note: Note,
    /// The day appended to.
    pub date: NaiveDate,
    /// The new blocks' ids, in order.
    pub block_ids: Vec<String>,
    /// `day_reviews.content_version` after the append.
    pub content_version: i64,
    /// The day's review state immediately before the append.
    pub prior_state: ReviewState,
}

/// Attempts an append makes against a daily note that keeps changing
/// underneath it before it gives up with `VersionConflict` (Req 31).
const APPEND_ATTEMPTS: u32 = 5;

impl AppendSource {
    /// The caller whose rules the append follows when it creates or adopts
    /// the day's note: quick entry is the person (adopts, Q2), not an agent.
    fn caller(self) -> Caller {
        match self {
            AppendSource::Agent => Caller::Agent,
            AppendSource::QuickEntry => Caller::Person,
        }
    }

    /// The `blocks.source` of the blocks an append adds.
    fn block_source(self) -> &'static str {
        match self {
            AppendSource::Agent => "agent",
            AppendSource::QuickEntry => "quick-entry",
        }
    }
}

/// Appends `text` verbatim to the end of the person section of the daily note
/// for `date` (default: today from `clock`), creating the note when absent.
/// See [`append_to_daily_note_with_hook`].
pub fn append_to_daily_note(
    vault: &mut Vault,
    text: &str,
    date: Option<&str>,
    source: AppendSource,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
) -> Result<AppendOutcome> {
    append_to_daily_note_with_hook(vault, text, date, source, clock, embedder, &mut |_, _| {})
}

/// [`append_to_daily_note`] with a deterministic interleaving seam for tests:
/// `before_write(vault, attempt)` runs in every attempt (counted from 1)
/// after it has read the latest body and before it writes. A write that
/// meets a newer version retries against the latest body, at most 5
/// attempts in all, then fails with `VersionConflict`.
///
/// Blank `text` is rejected before anything is read or written, then `date`
/// must be a strict `YYYY-MM-DD` (`InvalidDate`). One trailing `\n` of
/// `text` is dropped; the rest lands verbatim after the C3.1 separator
/// ([`append_to_person`]). A missing daily note is created empty first, and
/// a role-less note titled with the date is adopted on the quick-entry path
/// or a `TitleConflict` on the agent path (Q2). The write goes through
/// `notes::write_daily_internal` (D9), which stamps the new blocks with the
/// source; the note is reindexed from the stored body (D8). `prior_state`
/// is the review state read by the attempt that wrote.
pub fn append_to_daily_note_with_hook(
    vault: &mut Vault,
    text: &str,
    date: Option<&str>,
    source: AppendSource,
    clock: &dyn Clock,
    embedder: Option<&dyn Embedder>,
    before_write: &mut dyn FnMut(&mut Vault, u32),
) -> Result<AppendOutcome> {
    if text.trim().is_empty() {
        return Err(MemexError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "nothing to append: the text is empty",
        )));
    }
    let date = resolve_date(date, clock)?;
    let text = text.strip_suffix('\n').unwrap_or(text);

    let mut conflict = None;
    for attempt in 1..=APPEND_ATTEMPTS {
        let note = daily_note_for(vault, date, source.caller(), clock)?;
        let prior_state = review_state(vault.connection_ref(), note.id.as_str())?;
        before_write(vault, attempt);

        let person = append_to_person(&split_body(&note.content_md).person, text);
        let written = notes::write_daily_internal(
            vault,
            &note.id,
            note.version,
            &person,
            source.block_source(),
        );
        match written {
            Ok(saved) => return appended(vault, saved, date, prior_state, embedder),
            Err(e @ MemexError::VersionConflict { .. }) => conflict = Some(e),
            Err(e) => return Err(e),
        }
    }
    Err(conflict.expect("APPEND_ATTEMPTS is at least 1"))
}

/// Reindexes the appended daily note `saved` (D8) and reports the append.
fn appended(
    vault: &mut Vault,
    saved: Note,
    date: NaiveDate,
    prior_state: ReviewState,
    embedder: Option<&dyn Embedder>,
) -> Result<AppendOutcome> {
    indexer::reindex_note(
        vault.conn_mut(),
        saved.id.as_str(),
        &saved.content_md,
        embedder,
    )?;
    let conn = vault.connection_ref();
    Ok(AppendOutcome {
        block_ids: stored_blocks(conn, saved.id.as_str())?
            .0
            .into_iter()
            .filter(|b| b.created_version == saved.version)
            .map(|b| b.block_id)
            .collect(),
        content_version: conn.query_row(
            "SELECT content_version FROM day_reviews WHERE note_id = ?",
            [saved.id.as_str()],
            |r| r.get(0),
        )?,
        note: saved,
        date,
        prior_state,
    })
}

/// The latest daily note for `date`, created empty (or, for a person caller,
/// adopted from a role-less note titled with the date, Q2) when there is none.
fn daily_note_for(
    vault: &mut Vault,
    date: NaiveDate,
    caller: Caller,
    clock: &dyn Clock,
) -> Result<Note> {
    if let Some(id) = daily_note_for_date(vault.connection_ref(), date)? {
        return notes::get_note(vault, &NoteId::parse(&id)?);
    }
    let input = CreateNote {
        title: Some(date.to_string()),
        content_md: String::new(),
        frontmatter: Some(serde_json::json!({ "role": DAILY_ROLE })),
    };
    notes::create_or_adopt_note(vault, input, caller, clock).map(|outcome| outcome.note)
}

/// The id of the `role: daily` note for `date`, if any; a note titled with the
/// date but another role (or none) does not count. The one lookup of a day's
/// daily note (D27).
pub(crate) fn daily_note_for_date(conn: &Connection, date: NaiveDate) -> Result<Option<String>> {
    crate::links::daily_note_id_for_title(conn, &date.to_string())
}

/// The `blocks.source` of a write by `caller`.
pub(crate) fn block_source(caller: Caller) -> &'static str {
    match caller {
        Caller::Person => "person",
        Caller::Agent => "agent",
    }
}

/// The daily write hook (D9). Runs inside the write transaction of every save
/// of a daily note, before its `notes` row is written, and returns the body to
/// store:
///
/// - normalizes `new_body` (D10): its person section, the marker, then the
///   footer rendered from `footer_chips` (D11);
/// - re-splits the person section and matches it against the stored blocks
///   (D12): matched blocks keep their id, `source`, `created_version` and
///   `created_at`; new ones get `block_source` and `new_notes_version`;
/// - creates the `day_reviews` row lazily (`content_version` 1 for a
///   non-empty person section, else 0), or adds 1 to `content_version` when
///   `person.trim_end()` differs from that of `previous_body` (Req 19).
pub(crate) fn sync_daily_note(
    conn: &Connection,
    note_id: &str,
    previous_body: &str,
    new_body: &str,
    block_source: &str,
    new_notes_version: i64,
    now: i64,
) -> Result<String> {
    let person = split_body(new_body).person;
    let body = assemble(&person, &render_footer(conn, note_id)?);

    let (old, created_at) = stored_blocks(conn, note_id)?;
    let outcome = blocks::match_blocks(
        &old,
        &blocks::split(&person),
        block_source,
        new_notes_version,
        &mut || Ulid::new().random() as u64,
    );
    conn.execute("DELETE FROM blocks WHERE note_id = ?", [note_id])?;
    for b in &outcome.blocks {
        conn.execute(
            "INSERT INTO blocks (note_id, block_id, ord, start_byte, end_byte, text,
                                 content_hash, source, created_version, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                note_id,
                b.block_id,
                b.ord as i64,
                b.start_byte as i64,
                b.end_byte as i64,
                b.text,
                b.content_hash,
                b.source,
                b.created_version,
                created_at.get(&b.block_id).copied().unwrap_or(now),
            ],
        )?;
    }

    let trimmed = person.trim_end();
    let created = conn.execute(
        "INSERT OR IGNORE INTO day_reviews (note_id, content_version) VALUES (?, ?)",
        params![note_id, i64::from(!trimmed.is_empty())],
    )?;
    if created == 0 && split_body(previous_body).person.trim_end() != trimmed {
        conn.execute(
            "UPDATE day_reviews SET content_version = content_version + 1 WHERE note_id = ?",
            [note_id],
        )?;
    }
    Ok(body)
}

/// The stored blocks of a note in `ord` order, and each one's `created_at`.
pub(crate) fn stored_blocks(
    conn: &Connection,
    note_id: &str,
) -> Result<(Vec<Block>, HashMap<String, i64>)> {
    let mut stmt = conn.prepare(
        "SELECT block_id, ord, start_byte, end_byte, text, content_hash, source,
                created_version, created_at
         FROM blocks WHERE note_id = ? ORDER BY ord",
    )?;
    let rows = stmt
        .query_map([note_id], |r| {
            let block = Block {
                block_id: r.get(0)?,
                ord: r.get::<_, i64>(1)? as usize,
                start_byte: r.get::<_, i64>(2)? as usize,
                end_byte: r.get::<_, i64>(3)? as usize,
                text: r.get(4)?,
                content_hash: r.get(5)?,
                source: r.get(6)?,
                created_version: r.get(7)?,
            };
            Ok((block, r.get::<_, i64>(8)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let created_at = rows
        .iter()
        .map(|(b, at)| (b.block_id.clone(), *at))
        .collect();
    Ok((rows.into_iter().map(|(b, _)| b).collect(), created_at))
}

/// AC 21: `notes::write_daily_internal` is crate-private (D9), so its tests
/// live here rather than under `tests/`.
#[cfg(test)]
mod write_daily_internal_tests {
    use rusqlite::params;
    use serde_json::json;

    use super::{review_state, split_body, ReviewState};
    use crate::caller::Caller;
    use crate::error::MemexError;
    use crate::notes::{create_note_as, get_note, write_daily_internal, CreateNote, Note};
    use crate::vault::Vault;

    fn fresh_vault() -> (tempfile::TempDir, Vault) {
        let dir = tempfile::tempdir().unwrap();
        let vault = Vault::create(dir.path()).unwrap();
        (dir, vault)
    }

    fn create_daily(vault: &mut Vault, title: &str, body: &str) -> Note {
        create_note_as(
            vault,
            CreateNote {
                title: Some(title.into()),
                content_md: body.into(),
                frontmatter: Some(json!({ "role": "daily" })),
            },
            Caller::Person,
        )
        .unwrap()
    }

    /// `(block_id, text, source, created_version)` in `ord` order.
    fn blocks_of(vault: &Vault, note: &Note) -> Vec<(String, String, String, i64)> {
        let conn = vault.connection_ref();
        let mut stmt = conn
            .prepare(
                "SELECT block_id, text, source, created_version FROM blocks
                 WHERE note_id = ? ORDER BY ord",
            )
            .unwrap();
        stmt.query_map([note.id.as_str()], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap()
    }

    fn content_version(vault: &Vault, note: &Note) -> i64 {
        vault
            .connection_ref()
            .query_row(
                "SELECT content_version FROM day_reviews WHERE note_id = ?",
                [note.id.as_str()],
                |r| r.get(0),
            )
            .unwrap()
    }

    #[test]
    fn write_daily_internal_with_stale_version_returns_version_conflict() {
        let (_dir, mut vault) = fresh_vault();
        let note = create_daily(&mut vault, "2026-09-05", "Fixed the jump arc.\n");
        let before = blocks_of(&vault, &note);

        for stale in [0, 2, 5] {
            match write_daily_internal(&mut vault, &note.id, stale, "Changed.\n", "agent") {
                Err(MemexError::VersionConflict { expected, current }) => {
                    assert_eq!((expected, current), (stale, 1));
                }
                other => panic!("expected VersionConflict for {stale}, got {other:?}"),
            }
        }
        let kept = get_note(&vault, &note.id).unwrap();
        assert_eq!(
            kept.content_md,
            "Fixed the jump arc.\n<!-- memex:topics -->\n"
        );
        assert_eq!(kept.version, 1);
        assert_eq!(blocks_of(&vault, &note), before);
        assert_eq!(content_version(&vault, &note), 1);
    }

    #[test]
    fn write_daily_internal_normalizes_and_syncs_blocks_with_the_given_source() {
        let (_dir, mut vault) = fresh_vault();
        let note = create_daily(&mut vault, "2026-09-05", "Fixed the jump arc.\n");
        let first = blocks_of(&vault, &note);

        let saved = write_daily_internal(
            &mut vault,
            &note.id,
            1,
            "Fixed the jump arc.\n\nAgent line.\n<!-- memex:topics -->\n[[Ghost~about]]\n",
            "agent",
        )
        .unwrap();
        assert_eq!(
            saved.content_md,
            "Fixed the jump arc.\n\nAgent line.\n<!-- memex:topics -->\n"
        );
        assert_eq!(saved.version, 2);
        let stored = get_note(&vault, &note.id).unwrap();
        assert_eq!(stored.content_md, saved.content_md);
        assert_eq!(stored.version, 2);
        assert_eq!(content_version(&vault, &note), 2);
        assert_eq!(
            review_state(vault.connection_ref(), note.id.as_str()).unwrap(),
            ReviewState::Unreviewed
        );

        let rows = blocks_of(&vault, &note);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0], first[0], "matched person block unchanged");
        assert_eq!(rows[1].1, "Agent line.");
        assert_eq!((rows[1].2.as_str(), rows[1].3), ("agent", 2));

        // Quick entry, with stray text below the marker (Q1).
        let saved = write_daily_internal(
            &mut vault,
            &note.id,
            2,
            "Fixed the jump arc.\n\nAgent line.\n\nFrom Raycast.\n<!-- memex:topics -->\nstray\n",
            "quick-entry",
        )
        .unwrap();
        assert_eq!(saved.version, 3);
        assert_eq!(
            split_body(&saved.content_md).person,
            "Fixed the jump arc.\n\nAgent line.\n\nFrom Raycast.\nstray\n"
        );
        let rows = blocks_of(&vault, &note);
        assert_eq!(rows.len(), 3);
        assert_eq!((rows[1].2.as_str(), rows[1].3), ("agent", 2));
        assert_eq!(rows[2].1, "From Raycast.\nstray");
        assert_eq!((rows[2].2.as_str(), rows[2].3), ("quick-entry", 3));
        assert_eq!(content_version(&vault, &note), 3);
    }

    #[test]
    fn write_daily_internal_renders_the_footer_and_skips_content_version_for_footer_only() {
        let (_dir, mut vault) = fresh_vault();
        let topic = create_note_as(
            &mut vault,
            CreateNote {
                title: Some("Player Loop".into()),
                content_md: "jump".into(),
                frontmatter: Some(json!({ "role": "topic" })),
            },
            Caller::Person,
        )
        .unwrap();
        let note = create_daily(&mut vault, "2026-09-05", "Fixed the jump arc.\n");
        vault
            .connection_ref()
            .execute(
                "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
                 VALUES (?, ?, 'excerpt', 0)",
                params![note.id.as_str(), topic.id.as_str()],
            )
            .unwrap();

        let saved =
            write_daily_internal(&mut vault, &note.id, 1, &note.content_md, "agent").unwrap();
        assert_eq!(
            saved.content_md,
            "Fixed the jump arc.\n<!-- memex:topics -->\n[[Player Loop~about]]\n"
        );
        assert_eq!(saved.version, 2, "a footer write bumps notes.version");
        assert_eq!(
            content_version(&vault, &note),
            1,
            "but never content_version"
        );
        assert_eq!(blocks_of(&vault, &note)[0].2, "person");
    }
}
