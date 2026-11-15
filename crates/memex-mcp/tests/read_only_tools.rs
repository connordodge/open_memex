//! WI #9 (Spec #7 Req 5, 6, 8, 9; rulings D4, D6): Agent read-only over MCP,
//! tool by tool, on a `memex serve` subprocess.
//!
//! - On a flagged note every agent write tool answers the C1 object
//!   `{"error":{"code":"read_only_rule","message":<Req 9 text>}}` and writes
//!   nothing, including the answers that write nothing today: `add_link` for
//!   a link that already exists, `update_link` with nothing to change,
//!   `tag_note` on a tag the note has, `untag_note` on one it doesn't,
//!   `add_footer_topic` on a chip that is there, and `add_excerpt` of blocks
//!   already filed (which today still puts the day's chip back).
//! - `add_link` from an unflagged note TO a flagged note succeeds; reads,
//!   Smart Folder membership and canvas tools work on a flagged note.
//! - `get_note` reports `agent_read_only`.
//!
//! The person's side is written through core before the server starts; the
//! flag is set with raw SQL. Stored state is read back with a read-only
//! connection.

#[path = "support/server.rs"]
mod server;

#[path = "support/feedback_mcp.rs"]
mod feedback_mcp;

use std::path::Path;

use memex_core::excerpts::add_excerpt;
use memex_core::footer::{self, ChipOrigin, RemoveMode};
use memex_core::notes::NoteId;
use memex_core::smart_folders;
use memex_core::tags;
use memex_core::{Caller, SystemClock, Vault};
use rusqlite::params;
use serde_json::{json, Value};

use feedback_mcp::{fixture_day, open_db, person_note, person_topic, vault_with, Stdio, B7, DAY};

/// The flagged note's title, named by every refusal.
const FLAGGED: &str = "Pricing notes";

fn read_only_error(title: &str) -> Value {
    json!({
        "error": {
            "code": "read_only_rule",
            "message": format!(
                "\"{title}\" is read-only for agents; the person can change this in the app"
            ),
        }
    })
}

/// Sets the flag with raw SQL.
fn flag(vault: &Vault, id: &str) {
    let n = vault
        .connection_ref()
        .execute("UPDATE notes SET agent_read_only = 1 WHERE id = ?", [id])
        .unwrap();
    assert_eq!(n, 1, "the note exists");
}

/// Everything a refused tool must leave alone on one note.
#[derive(Debug, PartialEq)]
struct Stored {
    title: String,
    content_md: String,
    frontmatter: String,
    version: i64,
    updated_at: i64,
    agent_read_only: i64,
    tags: Vec<(String, String)>,
    links: Vec<(String, String, Option<String>)>,
    chips: Vec<(String, String)>,
}

fn stored(vault: &Path, id: &str) -> Stored {
    let conn = open_db(vault);
    let (title, content_md, frontmatter, version, updated_at, agent_read_only) = conn
        .query_row(
            "SELECT title, content_md, frontmatter, version, updated_at, agent_read_only
             FROM notes WHERE id = ?",
            [id],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .unwrap();
    let rows2 = |sql: &str| -> Vec<(String, String)> {
        conn.prepare(sql)
            .unwrap()
            .query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    let tags = rows2("SELECT tag, origin FROM tags WHERE note_id = ? ORDER BY tag");
    let chips = rows2(
        "SELECT topic_note_id, origin FROM footer_chips WHERE daily_note_id = ? ORDER BY rowid",
    );
    let links = conn
        .prepare(
            "SELECT link_text, link_kind, label FROM links WHERE from_note_id = ? ORDER BY position",
        )
        .unwrap()
        .query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    Stored {
        title,
        content_md,
        frontmatter,
        version,
        updated_at,
        agent_read_only,
        tags,
        links,
        chips,
    }
}

/// One vault for every tool:
/// - "Pricing notes" (flagged): body tag `#pricing`, an inline link to
///   "Roadmap", the agent tag `games`, and a chip for "Economy Design";
/// - "Roadmap" (not flagged); "Game ideas" puts `#games` and `#draft` in the
///   vocabulary;
/// - the day [`DAY`] and the topics "Player Loop" (not flagged) and
///   "Economy Design" (flagged), which already holds block [`B7`].
struct World {
    _dir: tempfile::TempDir,
    path: String,
    flagged: String,
    roadmap: String,
    day: String,
    player_loop: String,
    economy: String,
    link_id: String,
}

fn world() -> World {
    let mut ids = (
        String::new(),
        String::new(),
        String::new(),
        String::new(),
        String::new(),
        String::new(),
    );
    let (dir, path) = vault_with(|v| {
        person_note(v, "Game ideas", "Ideas for #games and #draft.\n", json!({}));
        let roadmap = person_note(v, "Roadmap", "Q1.\n", json!({})).id.to_string();
        let flagged = person_note(
            v,
            FLAGGED,
            "Tiers and #pricing, see [[Roadmap]].\n",
            json!({}),
        )
        .id
        .to_string();
        let day = fixture_day(v);
        let player_loop = person_topic(v, "Player Loop");
        let economy = person_topic(v, "Economy Design");
        let fid = NoteId::parse(&flagged).unwrap();
        tags::agent_tag_note(v, &fid, "games", None).unwrap();
        footer::set_chip(
            v,
            &fid,
            &NoteId::parse(&economy).unwrap(),
            ChipOrigin::Excerpt,
            None,
        )
        .unwrap();
        add_excerpt(
            v,
            &NoteId::parse(&economy).unwrap(),
            DAY,
            &[B7.to_string()],
            Caller::Person,
            None,
        )
        .unwrap();
        let link_id: String = v
            .connection_ref()
            .query_row(
                "SELECT id FROM links WHERE from_note_id = ?",
                [flagged.as_str()],
                |r| r.get(0),
            )
            .unwrap();
        flag(v, &flagged);
        flag(v, &economy);
        ids = (flagged, roadmap, day, player_loop, economy, link_id);
    });
    let (flagged, roadmap, day, player_loop, economy, link_id) = ids;
    World {
        _dir: dir,
        path,
        flagged,
        roadmap,
        day,
        player_loop,
        economy,
        link_id,
    }
}

impl World {
    fn path(&self) -> &Path {
        Path::new(&self.path)
    }

    /// Every note of the world, as stored.
    fn all(&self) -> Vec<Stored> {
        [
            &self.flagged,
            &self.roadmap,
            &self.day,
            &self.player_loop,
            &self.economy,
        ]
        .into_iter()
        .map(|id| stored(self.path(), id))
        .collect()
    }
}

/// Runs each `(what, tool, arguments)` against the server and asserts the
/// `read_only_rule` object for `title` and that no note of the world changed.
fn assert_refused(w: &World, server: &mut Stdio, title: &str, calls: &[(&str, &str, Value)]) {
    for (what, tool, arguments) in calls {
        let before = w.all();
        let got = server.call_raw(tool, arguments.clone());
        assert_eq!(got, read_only_error(title), "{what} ({tool}): {got}");
        assert_eq!(w.all(), before, "{what} ({tool}): nothing written");
    }
}

// ---------- links ----------

#[test]
fn add_link_from_a_flagged_note_is_read_only_rule_including_an_existing_link() {
    let w = world();
    let mut server = Stdio::start(&w.path);
    assert_refused(
        &w,
        &mut server,
        FLAGGED,
        &[
            (
                "a new link",
                "add_link",
                json!({ "from_id": w.flagged, "to_id": w.player_loop }),
            ),
            (
                "a new frontmatter link",
                "add_link",
                json!({ "from_id": w.flagged, "to_id": w.player_loop, "kind": "extends" }),
            ),
            (
                "the link that already exists (was_existing today)",
                "add_link",
                json!({ "from_id": w.flagged, "to_id": w.roadmap }),
            ),
        ],
    );
}

#[test]
fn add_link_from_an_unflagged_note_to_a_flagged_note_succeeds() {
    let w = world();
    let mut server = Stdio::start(&w.path);
    let flagged_before = stored(w.path(), &w.flagged);
    // Refused from the flagged side first: both directions in one test.
    assert_refused(
        &w,
        &mut server,
        FLAGGED,
        &[(
            "reverse direction",
            "add_link",
            json!({ "from_id": w.flagged, "to_id": w.roadmap, "kind": "extends" }),
        )],
    );
    let added = server.call(
        "add_link",
        json!({ "from_id": w.roadmap, "to_id": w.flagged }),
    );
    assert_eq!(added["was_existing"], json!(false), "{added}");
    let roadmap = stored(w.path(), &w.roadmap);
    assert!(
        roadmap.content_md.contains("[[Pricing notes]]"),
        "{}",
        roadmap.content_md
    );
    assert_eq!(
        stored(w.path(), &w.flagged),
        flagged_before,
        "the target is not written"
    );
}

#[test]
fn update_link_on_a_flagged_source_is_read_only_rule_including_nothing_to_change() {
    let w = world();
    let mut server = Stdio::start(&w.path);
    assert_refused(
        &w,
        &mut server,
        FLAGGED,
        &[
            (
                "a label change",
                "update_link",
                json!({ "link_id": w.link_id, "label": "the plan" }),
            ),
            (
                "a kind change",
                "update_link",
                json!({ "link_id": w.link_id, "kind": "extends" }),
            ),
            (
                "the kind it already has (changed=false today)",
                "update_link",
                json!({ "link_id": w.link_id, "kind": "references" }),
            ),
            (
                "no fields at all",
                "update_link",
                json!({ "link_id": w.link_id }),
            ),
            (
                "clear a label it doesn't have",
                "update_link",
                json!({ "link_id": w.link_id, "clear_label": true }),
            ),
        ],
    );
}

// ---------- tags and the Note footer ----------

#[test]
fn tag_note_and_untag_note_on_a_flagged_note_are_read_only_rule_including_no_ops() {
    let w = world();
    let mut server = Stdio::start(&w.path);
    assert_refused(
        &w,
        &mut server,
        FLAGGED,
        &[
            (
                "a new vocabulary tag",
                "tag_note",
                json!({ "note_id": w.flagged, "tag": "draft" }),
            ),
            (
                "already tagged (agent)",
                "tag_note",
                json!({ "note_id": w.flagged, "tag": "games" }),
            ),
            (
                "already tagged (body)",
                "tag_note",
                json!({ "note_id": w.flagged, "tag": "#pricing" }),
            ),
            (
                "an agent tag the note has",
                "untag_note",
                json!({ "note_id": w.flagged, "tag": "games" }),
            ),
            (
                "not tagged",
                "untag_note",
                json!({ "note_id": w.flagged, "tag": "draft" }),
            ),
        ],
    );
    // The unflagged note still takes the tag.
    let tagged = server.call("tag_note", json!({ "note_id": w.roadmap, "tag": "draft" }));
    assert_eq!(tagged["applied"], json!(true), "{tagged}");
}

#[test]
fn add_footer_topic_on_a_flagged_note_is_read_only_rule_including_a_chip_already_there() {
    let w = world();
    let mut server = Stdio::start(&w.path);
    assert_refused(
        &w,
        &mut server,
        FLAGGED,
        &[
            (
                "a new chip",
                "add_footer_topic",
                json!({ "note_id": w.flagged, "topic_note_id": w.player_loop }),
            ),
            (
                "the chip already there (changed=false today)",
                "add_footer_topic",
                json!({ "note_id": w.flagged, "topic_note_id": w.economy }),
            ),
        ],
    );
    // A chip FOR the flagged topic on a writable note is fine.
    let added = server.call(
        "add_footer_topic",
        json!({ "note_id": w.roadmap, "topic_note_id": w.economy }),
    );
    assert_eq!(added["changed"], json!(true), "{added}");
    assert_eq!(added["origin"], json!("excerpt"), "{added}");
}

// ---------- excerpts into a flagged topic ----------

#[test]
fn excerpt_tools_on_a_flagged_topic_are_read_only_rule_and_write_neither_note() {
    let w = world();
    let mut server = Stdio::start(&w.path);
    assert_refused(
        &w,
        &mut server,
        "Economy Design",
        &[
            (
                "new blocks",
                "add_excerpt",
                json!({ "topic_note_id": w.economy, "date": DAY, "block_ids": ["c3d4e5"] }),
            ),
            (
                "blocks already filed, chip there",
                "add_excerpt",
                json!({ "topic_note_id": w.economy, "date": DAY, "block_ids": [B7] }),
            ),
            (
                "remove_excerpt of a filed excerpt",
                "remove_excerpt",
                json!({ "topic_note_id": w.economy, "date": DAY, "block_ids": [B7] }),
            ),
            (
                "remove_excerpt_block of a filed block",
                "remove_excerpt_block",
                json!({ "topic_note_id": w.economy, "date": DAY, "block_id": B7 }),
            ),
        ],
    );
}

#[test]
fn add_excerpt_of_blocks_already_filed_in_a_flagged_topic_puts_no_chip_on_the_day() {
    let w = world();
    // The person took the day's chip off; today an agent's already-filed
    // add_excerpt answers Ok and puts it back on the daily note.
    {
        let mut v = Vault::open(&w.path).unwrap();
        footer::remove_chip(
            &mut v,
            &NoteId::parse(&w.day).unwrap(),
            &NoteId::parse(&w.economy).unwrap(),
            RemoveMode::AnyOrigin,
            None,
        )
        .unwrap();
    }
    assert!(stored(w.path(), &w.day)
        .chips
        .iter()
        .all(|(t, _)| t != &w.economy));
    let mut server = Stdio::start(&w.path);
    assert_refused(
        &w,
        &mut server,
        "Economy Design",
        &[(
            "already filed, chip missing",
            "add_excerpt",
            json!({ "topic_note_id": w.economy, "date": DAY, "block_ids": [B7] }),
        )],
    );
    assert!(
        stored(w.path(), &w.day)
            .chips
            .iter()
            .all(|(t, _)| t != &w.economy),
        "no chip on the daily note"
    );
    // An unflagged topic takes the excerpt and its chip as today.
    let filed = server.call(
        "add_excerpt",
        json!({ "topic_note_id": w.player_loop, "date": DAY, "block_ids": [B7] }),
    );
    assert_eq!(filed["filed_block_ids"], json!([B7]), "{filed}");
}

// ---------- Req 6: what still works on a flagged note ----------

#[test]
fn reads_smart_folders_and_canvas_tools_work_on_a_flagged_note() {
    let w = world();
    let folder = {
        let mut v = Vault::open(&w.path).unwrap();
        smart_folders::create_folder(&mut v, "Economy", None, Caller::Agent, &SystemClock)
            .unwrap()
            .id
    };
    let mut server = Stdio::start(&w.path);
    let before = w.all();

    let got = server.call("get_note", json!({ "note_id": w.flagged }));
    assert_eq!(got["title"], json!(FLAGGED), "{got}");
    let found = server.call("search", json!({ "query": "tiers", "mode": "fts" }));
    assert!(
        found["results"]
            .as_array()
            .unwrap()
            .iter()
            .any(|h| h["note_id"] == json!(w.flagged)),
        "search finds the flagged note: {found}"
    );
    let near = server.call("neighbors", json!({ "note_id": w.flagged }));
    assert!(
        near["results"]
            .as_array()
            .unwrap()
            .iter()
            .any(|h| h["note_id"] == json!(w.roadmap)),
        "neighbors of the flagged note: {near}"
    );

    let added = server.call(
        "add_to_smart_folder",
        json!({ "topic_note_id": w.economy, "smart_folder_id": folder }),
    );
    assert_eq!(added["added"], json!(true), "{added}");
    let removed = server.call(
        "remove_from_smart_folder",
        json!({ "topic_note_id": w.economy, "smart_folder_id": folder }),
    );
    assert_eq!(removed["removed"], json!(true), "{removed}");

    let canvas = server.call("create_canvas", json!({ "title": "Board" }));
    let canvas_id = canvas["canvas_id"].as_str().expect("canvas_id").to_string();
    server.call(
        "add_to_canvas",
        json!({ "canvas_id": canvas_id, "note_id": w.flagged, "x": 1.0, "y": 2.0 }),
    );
    server.call(
        "move_node",
        json!({ "canvas_id": canvas_id, "note_id": w.flagged, "x": 3.0, "y": 4.0 }),
    );
    server.call(
        "remove_from_canvas",
        json!({ "canvas_id": canvas_id, "note_id": w.flagged }),
    );
    assert_eq!(w.all(), before, "none of these writes a note");

    // ...while a write tool on the same note is still refused.
    assert_refused(
        &w,
        &mut server,
        FLAGGED,
        &[(
            "tag after the reads",
            "tag_note",
            json!({ "note_id": w.flagged, "tag": "draft" }),
        )],
    );
}

// ---------- get_note reports the flag ----------

#[test]
fn get_note_reports_agent_read_only_true_for_a_flagged_note_and_false_otherwise() {
    let w = world();
    let mut server = Stdio::start(&w.path);
    for (id, want) in [
        (&w.flagged, true),
        (&w.economy, true),
        (&w.roadmap, false),
        (&w.day, false),
        (&w.player_loop, false),
    ] {
        for include_backlinks in [false, true] {
            let got = server.call(
                "get_note",
                json!({ "note_id": id, "include_backlinks": include_backlinks }),
            );
            assert_eq!(
                got["agent_read_only"],
                json!(want),
                "note {id} (include_backlinks {include_backlinks}): {got}"
            );
        }
    }
    // The flag can be cleared by the person while the server runs; the next
    // read reports it.
    {
        let conn = rusqlite::Connection::open(w.path().join("memex.db")).unwrap();
        conn.busy_timeout(std::time::Duration::from_secs(10))
            .unwrap();
        conn.execute(
            "UPDATE notes SET agent_read_only = 0 WHERE id = ?",
            params![w.flagged],
        )
        .unwrap();
    }
    let got = server.call("get_note", json!({ "note_id": w.flagged }));
    assert_eq!(got["agent_read_only"], json!(false), "{got}");
}
