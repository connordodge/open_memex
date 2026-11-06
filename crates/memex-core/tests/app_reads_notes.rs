//! WI #81 (V1), AC 2 and AC 3: the list-notes snippet of the app API
//! (`app_reads::notes`) equals the app's local `VaultDb._snippet`
//! (db.dart:313-320) with the surrogate guard of ruling D10b.
//!
//! The cases live in `app/test/fixtures/api_v1/notes/snippet_cases.json`,
//! which the Dart test `app/test/db/notes_snippet_test.dart` runs through the
//! local `VaultDb.listNotes`, so both languages are held to one table.
//!
//! API under test:
//!   memex_core::app_reads::notes::snippet(&str) -> String
//!   memex_core::app_reads::notes::list_notes(&Vault, limit) -> Result<Vec<NoteListItem>>
//!   NoteListItem { id, title, snippet, version, updated_at }

use std::cell::Cell;
use std::path::PathBuf;

use memex_core::app_reads::notes::{list_notes, snippet, NoteListItem};
use memex_core::notes::{create_or_adopt_note, get_note, CreateNote, NoteId};
use memex_core::tags::{self, TagOrigin};
use memex_core::{Caller, Clock, Vault};
use serde_json::Value;

fn snippet_cases_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/test/fixtures/api_v1/notes/snippet_cases.json")
}

/// `(name, content_md, snippet)` for every shared case.
fn snippet_cases() -> Vec<(String, String, String)> {
    let path = snippet_cases_path();
    let raw =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let v: Value = serde_json::from_str(&raw).expect("snippet_cases.json is JSON");
    v["cases"]
        .as_array()
        .expect("snippet_cases.json has a cases array")
        .iter()
        .map(|c| {
            let s = |k: &str| {
                c[k].as_str()
                    .unwrap_or_else(|| panic!("case {c} has no string {k}"))
                    .to_string()
            };
            (s("name"), s("content_md"), s("snippet"))
        })
        .collect()
}

fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// The seed's Pacing Notes first line: 116 ASCII units, then a surrogate
/// pair at units 116-117 (crates/memex-mcp/tests/support/api_fixtures.rs).
const PACING_LINE: &str = "Pacing is the quiet half of design: each session needs a slow stretch, \
                           a sharp climb, and a short pause before a die\u{1F3B2} decides the next run.";

#[test]
fn snippet_matches_every_shared_snippet_case() {
    let cases = snippet_cases();
    assert!(cases.len() >= 20, "the shared table holds the edge cases");
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|(name, content, want)| {
            let got = snippet(content);
            (got != *want).then(|| format!("{name}: want {want:?}, got {got:?}"))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "snippet drift:\n{}",
        failures.join("\n")
    );
}

#[test]
fn snippet_backs_off_to_116_units_on_the_seed_pacing_notes_line() {
    let units: Vec<u16> = PACING_LINE.encode_utf16().collect();
    assert!(
        (0xD800..=0xDBFF).contains(&units[116]),
        "the pair straddles 117"
    );
    let content =
        format!("{PACING_LINE}\n\nShort runs, long arcs. See [[Player Loop|the loop]].\n");
    let got = snippet(&content);
    let want = format!("{}…", &PACING_LINE[..116]);
    assert_eq!(got, want);
    assert_eq!(utf16_len(&got), 117, "116 units plus the ellipsis");
    assert!(
        !got.contains('\u{1F3B2}'),
        "the split pair is dropped whole"
    );
}

#[test]
fn snippet_keeps_a_surrogate_pair_that_sits_fully_before_the_cut() {
    // The pair is units 115-116, so the 117-unit cut lands after it.
    let line = format!("{}\u{1F3B2}{}", "j".repeat(115), "k".repeat(10));
    assert_eq!(utf16_len(&line), 127);
    let got = snippet(&format!("{line}\n"));
    assert_eq!(got, format!("{}\u{1F3B2}…", "j".repeat(115)));
    assert_eq!(
        utf16_len(&got),
        118,
        "117 units plus the ellipsis: no back-off"
    );

    // A pair at the very start never moves the cut either.
    let early = format!("\u{1F3B2}{}", "l".repeat(130));
    assert_eq!(snippet(&early), format!("\u{1F3B2}{}…", "l".repeat(115)));
}

#[test]
fn snippet_counts_utf16_units_not_chars_for_the_120_limit() {
    // 60 emoji: 60 chars, 120 units -> kept whole.
    let sixty = "\u{1F3B2}".repeat(60);
    assert_eq!(snippet(&sixty), sixty);
    // 61 emoji: 61 chars (under 120) but 122 units -> cut; unit 116 is a high
    // surrogate, so 58 emoji survive.
    let sixty_one = "\u{1F3B2}".repeat(61);
    assert_eq!(snippet(&sixty_one), format!("{}…", "\u{1F3B2}".repeat(58)));
    // 120 ASCII units are kept, 121 are cut to 117.
    assert_eq!(snippet(&"a".repeat(120)), "a".repeat(120));
    assert_eq!(snippet(&"b".repeat(121)), format!("{}…", "b".repeat(117)));
}

/// A clock one minute later on every read.
struct StepClock(Cell<i64>);

impl Clock for StepClock {
    fn now_ms(&self) -> i64 {
        let now = self.0.get();
        self.0.set(now + 60_000);
        now
    }
}

fn add(vault: &mut Vault, clock: &StepClock, title: &str, content: &str) -> NoteId {
    let input = CreateNote {
        title: Some(title.to_string()),
        content_md: content.to_string(),
        frontmatter: None,
    };
    create_or_adopt_note(vault, input, Caller::Person, clock)
        .unwrap_or_else(|e| panic!("create {title}: {e}"))
        .note
        .id
}

#[test]
fn list_notes_returns_snippets_newest_first_up_to_the_limit() {
    let tmp = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(tmp.path().join("v")).expect("create vault");
    let clock = StepClock(Cell::new(1_760_000_000_000));
    let heading = add(&mut vault, &clock, "Heading", "# Heading\n\nBody text.\n");
    let pacing = add(&mut vault, &clock, "Pacing", &format!("{PACING_LINE}\n"));
    let blank = add(
        &mut vault,
        &clock,
        "Blank Start",
        "\n\n  \nFirst real line\n",
    );

    let all = list_notes(&vault, 200).expect("list notes");
    let expect = |id: &NoteId, snippet: &str| {
        let note = get_note(&vault, id).expect("read note");
        NoteListItem {
            id: note.id.to_string(),
            title: note.title,
            snippet: snippet.to_string(),
            version: note.version,
            updated_at: note.updated_at,
        }
    };
    assert_eq!(
        all,
        vec![
            expect(&blank, "First real line"),
            expect(&pacing, &format!("{}…", &PACING_LINE[..116])),
            expect(&heading, "Heading"),
        ],
        "newest updated_at first, every field as VaultDb.listNotes reads it"
    );
    assert!(all[0].updated_at > all[1].updated_at && all[1].updated_at > all[2].updated_at);

    let two = list_notes(&vault, 2).expect("list two notes");
    assert_eq!(two, all[..2].to_vec(), "limit keeps the newest");
    assert!(list_notes(&vault, 0).expect("limit 0").is_empty());
}

#[test]
fn list_notes_on_an_empty_vault_is_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let vault = Vault::create(tmp.path().join("v")).expect("create vault");
    assert_eq!(list_notes(&vault, 200).expect("list notes"), Vec::new());
}

// ---------------------------------------------------------------------------
// WI #242: `footer_tags` on `GET /notes/{note_id}`
// ---------------------------------------------------------------------------

#[test]
fn app_read_get_note_returns_footer_tags_beside_tags() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(dir.path().join("vault")).unwrap();
    let note = memex_core::notes::create_note_as(
        &mut vault,
        CreateNote {
            title: Some("Tagged".into()),
            content_md: "About #written today.\n".into(),
            frontmatter: None,
        },
        Caller::Person,
    )
    .unwrap();
    for (name, origin) in [
        ("zeta", TagOrigin::Person),
        ("agent-set", TagOrigin::Agent),
        ("inbox", TagOrigin::Agent),
    ] {
        tags::apply_tag(&mut vault, &note.id, name, origin, None).unwrap();
    }

    let detail = memex_core::app_reads::notes::get_note(&vault, &note.id).unwrap();

    let json = serde_json::to_value(&detail).unwrap();
    assert_eq!(
        json["footer_tags"],
        serde_json::json!(["agent-set", "zeta"]),
        "agent and person rows, no body row, no system tag, sorted"
    );
    assert_eq!(
        json["tags"],
        serde_json::json!(["agent-set", "inbox", "written", "zeta"]),
        "`tags` keeps every row"
    );
}
