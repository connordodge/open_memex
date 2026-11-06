//! WI #238 (T2): server writes that add or move body text keep it above the
//! Note footer marker (Spec #234 R15; rulings D14, D15).
//!
//! - `add_excerpt` / `remove_excerpt` on a topic note with a footer: the
//!   `write_topic` edit touches only the person section and the footer is
//!   reassembled after it (D14).
//! - The rename pass rewrites body links and footer chip lines of a non-daily
//!   linker, each on its own side of the marker (D15).
//!
//! `add_link` (`md_links`) lives in `crates/memex-mcp/tests/add_link_footer.rs`.
//! Real SQLite, real schema, temp vaults only.

use memex_core::daily;
use memex_core::excerpts::{add_excerpt, remove_excerpt};
use memex_core::footer::{self, ChipOrigin};
use memex_core::indexer;
use memex_core::notes::{
    create_note_as, get_note, update_note_as, CreateNote, Note, NoteId, RenameOptions, UpdateNote,
};
use memex_core::{Caller, Vault};
use rusqlite::params;
use serde_json::{json, Value};
use tempfile::TempDir;

const M: &str = "<!-- memex:topics -->";
const DAY: &str = "2026-09-05";
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const DAY_BLOCKS: [&str; 3] = ["b7k2m9", "c3d4e5", "f6g7h8"];
const T_B7: &str = "![[2026-09-05#^b7k2m9]]";
const T_C3: &str = "![[2026-09-05#^c3d4e5]]";

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path()).unwrap();
    (dir, vault)
}

fn create(vault: &mut Vault, title: &str, body: &str, fm: Option<Value>) -> Note {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: fm,
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"));
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note
}

fn create_topic(vault: &mut Vault, title: &str, body: &str) -> Note {
    create(vault, title, body, Some(json!({ "role": "topic" })))
}

/// The fixture day with its block ids pinned by ord.
fn create_day(vault: &mut Vault) -> Note {
    let day = create(vault, DAY, DAY_BODY, Some(json!({ "role": "daily" })));
    for (ord, id) in DAY_BLOCKS.iter().enumerate() {
        let n = vault
            .connection_ref()
            .execute(
                "UPDATE blocks SET block_id = ? WHERE note_id = ? AND ord = ?",
                params![id, day.id.as_str(), ord as i64],
            )
            .unwrap();
        assert_eq!(n, 1, "setup: block {ord} of {DAY}");
    }
    day
}

fn stored(vault: &Vault, id: &NoteId) -> Note {
    get_note(vault, id).unwrap()
}

/// Gives `host` a footer straight in the tables: a chip row for `chip`, an
/// agent tag row `x`, and the body as the server renders it from them.
fn give_footer(vault: &mut Vault, host: &Note, chip: &Note) -> String {
    let conn = vault.connection_ref();
    conn.execute(
        "INSERT INTO footer_chips (daily_note_id, topic_note_id, origin, created_at)
         VALUES (?, ?, 'person', 0)",
        params![host.id.as_str(), chip.id.as_str()],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO tags (note_id, tag, origin) VALUES (?, 'x', 'agent')",
        params![host.id.as_str()],
    )
    .unwrap();
    let footer = format!("{M}\n[[{}~about]]\n#x\n", chip.title);
    let body = format!("{}{footer}", host.content_md);
    conn.execute(
        "UPDATE notes SET content_md = ? WHERE id = ?",
        params![body, host.id.as_str()],
    )
    .unwrap();
    indexer::reindex_note(vault.connection_mut(), host.id.as_str(), &body, None).unwrap();
    footer
}

fn rename(vault: &mut Vault, id: &NoteId, title: &str) -> Note {
    let version = stored(vault, id).version;
    update_note_as(
        vault,
        id,
        version,
        UpdateNote {
            title: Some(title.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("rename to {title}: {e}"))
}

/// `(link_text, link_kind)` of a note's outgoing links.
fn links_from(vault: &Vault, id: &NoteId) -> Vec<(String, String)> {
    vault
        .connection_ref()
        .prepare("SELECT link_text, link_kind FROM links WHERE from_note_id = ? ORDER BY position")
        .unwrap()
        .query_map([id.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

// ---------- AC 9: add_excerpt / remove_excerpt keep tokens above the marker ----------

#[test]
fn add_excerpt_and_remove_excerpt_on_a_topic_with_a_footer_keep_tokens_above_the_marker() {
    let (_dir, mut v) = fresh_vault();
    let day = create_day(&mut v);
    let sleep = create_topic(&mut v, "Sleep", "All about sleep.\n");
    let topic = create_topic(&mut v, "Player Loop", "All about the player loop.\n");
    let footer = give_footer(&mut v, &topic, &sleep);
    let person = "All about the player loop.\n";

    // No `## <date>` section yet: heading and token go at the end of the
    // person section, not after the footer.
    let saved = add_excerpt(
        &mut v,
        &topic.id,
        DAY,
        &["b7k2m9".to_string()],
        Caller::Agent,
        None,
    )
    .expect("add the first excerpt");
    let one = format!("{person}\n## {DAY}\n\n{T_B7}\n");
    assert_eq!(saved.content_md, format!("{one}{footer}"));

    // An existing section ends at the marker, not at the end of the body.
    add_excerpt(
        &mut v,
        &topic.id,
        DAY,
        &["c3d4e5".to_string()],
        Caller::Agent,
        None,
    )
    .expect("add the second excerpt");
    let two = format!("{one}\n{T_C3}\n");
    let body = stored(&v, &topic.id).content_md;
    assert_eq!(body, format!("{two}{footer}"));
    let split = daily::split_note_body(&body);
    assert_eq!(split.person, two);
    assert_eq!(split.chips, ["Sleep"]);
    assert_eq!(split.tags, ["x"]);
    // The day's footer gained the topic's chip as before.
    assert_eq!(
        daily::split_body(&stored(&v, &day.id).content_md).chips,
        ["Player Loop"]
    );

    // Removing leaves the footer where it was.
    remove_excerpt(
        &mut v,
        &topic.id,
        DAY,
        &["c3d4e5".to_string()],
        Caller::Agent,
        None,
    )
    .expect("remove the second excerpt");
    assert_eq!(stored(&v, &topic.id).content_md, format!("{one}{footer}"));
    remove_excerpt(
        &mut v,
        &topic.id,
        DAY,
        &["b7k2m9".to_string()],
        Caller::Agent,
        None,
    )
    .expect("remove the first excerpt");
    assert_eq!(
        stored(&v, &topic.id).content_md,
        format!("{person}{footer}"),
        "the section goes; the footer stays"
    );
}

// ---------- AC 11: the rename pass on a non-daily note ----------

#[test]
fn rename_pass_keeps_body_links_and_footer_chips_on_their_side_of_the_marker() {
    let (_dir, mut v) = fresh_vault();
    let renamed = create_topic(&mut v, "Player Loop", "About.\n");
    let sleep = create_topic(&mut v, "Sleep", "About sleep.\n");
    let plain = create(&mut v, "Loose", "See [[Player Loop]] today.\n", None);
    let host_topic = create_topic(
        &mut v,
        "Game Design",
        "Built on [[Player Loop|the loop]].\n",
    );
    let daily = create(
        &mut v,
        DAY,
        "Played [[Player Loop]].\n",
        Some(json!({ "role": "daily" })),
    );
    let fenced = create(
        &mut v,
        "Snippet",
        &format!("```\n{M}\n```\nSee [[Player Loop]].\n"),
        None,
    );
    for host in [&plain, &host_topic, &daily] {
        v.connection_ref()
            .execute(
                "INSERT INTO tags (note_id, tag, origin) VALUES (?, 'x', 'agent')",
                params![host.id.as_str()],
            )
            .unwrap();
        footer::set_chip(&mut v, &host.id, &renamed.id, ChipOrigin::Person, None)
            .unwrap_or_else(|e| panic!("set_chip on {}: {e}", host.title));
        footer::set_chip(&mut v, &host.id, &sleep.id, ChipOrigin::Excerpt, None)
            .unwrap_or_else(|e| panic!("set_chip on {}: {e}", host.title));
    }

    rename(&mut v, &renamed.id, "Game Loop");

    let tail = format!("{M}\n[[Game Loop~about]]\n[[Sleep~about]]\n#x\n");
    for (host, person) in [
        (&plain, "See [[Game Loop]] today.\n"),
        (&host_topic, "Built on [[Game Loop|the loop]].\n"),
        (&daily, "Played [[Game Loop]].\n"),
    ] {
        let body = stored(&v, &host.id).content_md;
        assert_eq!(body, format!("{person}{tail}"), "{}", host.title);
        let split = daily::split_note_body(&body);
        assert_eq!(split.person, person, "{}: the link stays above", host.title);
        assert_eq!(
            split.chips,
            ["Game Loop", "Sleep"],
            "{}: the chip stays below",
            host.title
        );
        assert!(
            links_from(&v, &host.id)
                .iter()
                .all(|(text, _)| text != "Player Loop"),
            "{}: reindexed: {:?}",
            host.title,
            links_from(&v, &host.id)
        );
    }
    // A fenced marker stays body text: the link is renamed, no footer added.
    assert_eq!(
        stored(&v, &fenced.id).content_md,
        format!("```\n{M}\n```\nSee [[Game Loop]].\n")
    );
}
