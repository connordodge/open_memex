//! Daily notes.
//!
//! The canonical daily body (architect ruling D10, CONTRACTS C3), the footer
//! rendered from `footer_chips` (D11), the local-time "today" behind an
//! injectable clock (D14) and the review state of a day (Req 19).
//!
//! WI #7 test skeleton: signatures only, no behaviour yet.

use chrono::NaiveDate;
use rusqlite::Connection;

use crate::canvas::Clock;
use crate::Result;

/// The Topics footer marker line (C3).
pub const TOPICS_MARKER: &str = "<!-- memex:topics -->";

/// A daily note body split at the Topics footer marker (C3).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DailyBody {
    /// Everything above the first marker line, plus any stray text from below
    /// it (Q1).
    pub person: String,
    /// Footer chip titles (`[[<title>~about]]`), in order.
    pub chips: Vec<String>,
}

/// Splits a daily note body into the person section and footer chips (C3).
pub fn split_body(_body: &str) -> DailyBody {
    unimplemented!("WI #7: daily::split_body")
}

/// Assembles the canonical daily body from a person section and chip titles (C3).
pub fn assemble<S: AsRef<str>>(_person: &str, _chips: &[S]) -> String {
    unimplemented!("WI #7: daily::assemble")
}

/// The footer chip titles of a daily note, from `footer_chips` joined to
/// `notes`, in rowid order (D11).
pub fn render_footer(_conn: &Connection, _daily_note_id: &str) -> Result<Vec<String>> {
    unimplemented!("WI #7: daily::render_footer")
}

/// Today's date in the machine's local time zone, read from `clock` (D14).
pub fn today_with_clock(_clock: &dyn Clock) -> NaiveDate {
    unimplemented!("WI #7: daily::today_with_clock")
}

/// `None` → today (local); `Some(s)` → `s` when it is a real `YYYY-MM-DD`
/// calendar date, else `InvalidDate` (D14).
pub fn resolve_date(_date: Option<&str>, _clock: &dyn Clock) -> Result<NaiveDate> {
    unimplemented!("WI #7: daily::resolve_date")
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
        unimplemented!("WI #7: ReviewState::as_str")
    }
}

/// The review state of the daily note `note_id`, from its `day_reviews` row.
pub fn review_state(_conn: &Connection, _note_id: &str) -> Result<ReviewState> {
    unimplemented!("WI #7: daily::review_state")
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
