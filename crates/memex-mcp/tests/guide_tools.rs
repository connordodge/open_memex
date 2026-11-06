//! WI #254 (Spec #233 R28-R30, R39, R40): `get_vault_guide`, `update_vault_guide`
//! and the `guide_rule` of `add_link` and `update_link`, over the wire.
//!
//! The person's side is written through core before the server's first call. The
//! dates of the guide's Activity entries are proved over `/mcp` with
//! `X-Memex-UTC-Offset` at a date boundary, on a base clock the test fixes.

#[path = "support/server.rs"]
mod server;

#[path = "support/feedback_mcp.rs"]
mod feedback_mcp;

use std::path::Path;

use memex_core::daily::today_with_clock;
use memex_core::guide;
use memex_core::notes::{get_note, update_note_as, NoteId, RenameOptions, UpdateNote};
use memex_core::{Caller, SystemClock, Vault};
use serde_json::{json, Value};

use feedback_mcp::{
    activity, assert_c1, count, keys, open_db, person_topic, set, str_of, vault_with, FixedClock,
    Hosted, Stdio, BOUNDARY_MS, BOUNDARY_UTC_DATE, BOUNDARY_WEST_DATE, T0, TOPIC, UTC, WEST,
};

const SEED: &str = "## Framework\n\n## Decisions\n";

/// A vault whose guide already exists, read through core; returns `(id, version)`.
fn seed_guide(vault: &mut Vault) -> (String, i64) {
    let doc = guide::get_or_create(vault, &FixedClock(T0), None).unwrap();
    (doc.note_id, doc.version)
}

fn revision_count(path: &str) -> i64 {
    count(
        Path::new(path),
        "SELECT count(*) FROM vault_guide_revisions",
    )
}

/// `(content_md, version)` of a note, from disk.
fn stored(path: &str, id: &str) -> (String, i64) {
    open_db(Path::new(path))
        .query_row(
            "SELECT content_md, version FROM notes WHERE id = ?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}

// ======================================================================
// AC: get_vault_guide creates the guide on first call and returns its version.
// ======================================================================

#[test]
fn get_vault_guide_creates_the_guide_on_first_call_and_returns_its_version() {
    let (_dir, path) = vault_with(|_| {});
    assert_eq!(
        count(
            Path::new(&path),
            "SELECT count(*) FROM notes WHERE json_extract(frontmatter, '$.role') = 'guide'"
        ),
        0,
        "migration doesn't create the guide"
    );

    let mut server = Stdio::start(&path);
    let first = server.call("get_vault_guide", json!({}));
    assert_eq!(
        keys(&first),
        set(&["note_id", "version", "content_md"]),
        "exactly the Contract fields, no vault_id: {first}"
    );
    assert_eq!(first["version"], json!(1), "{first}");
    assert_eq!(first["content_md"], json!(SEED), "{first}");

    let id = str_of(&first, "note_id").to_string();
    let role: String = open_db(Path::new(&path))
        .query_row(
            "SELECT json_extract(frontmatter, '$.role') FROM notes WHERE id = ?",
            [&id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(role, "guide");

    let second = server.call("get_vault_guide", json!({}));
    assert_eq!(second, first, "a later call reads the same guide");
    assert_eq!(
        count(
            Path::new(&path),
            "SELECT count(*) FROM notes WHERE json_extract(frontmatter, '$.role') = 'guide'"
        ),
        1,
        "one guide per vault"
    );
}

#[test]
fn get_vault_guide_returns_the_persons_current_text_and_version() {
    let mut id = String::new();
    let (_dir, path) = vault_with(|v| {
        let (guide_id, version) = seed_guide(v);
        id = guide_id;
        person_edits_guide(
            v,
            &id,
            version,
            "## Framework\n\nGames first.\n\n## Decisions\n",
        );
    });
    let mut server = Stdio::start(&path);
    let read = server.call("get_vault_guide", json!({}));
    assert_eq!(
        read,
        json!({
            "note_id": id,
            "version": 2,
            "content_md": "## Framework\n\nGames first.\n\n## Decisions\n",
        })
    );
}

#[tokio::test]
async fn get_vault_guide_over_mcp_creates_the_guide_on_the_calls_clock() {
    let srv = Hosted::at(BOUNDARY_MS).await;
    let path = srv.vault("v", |_| {});

    let doc = srv.call("v", None, "get_vault_guide", json!({})).await;
    let created_at: i64 = open_db(&path)
        .query_row(
            "SELECT created_at FROM notes WHERE id = ?",
            [str_of(&doc, "note_id")],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(created_at, BOUNDARY_MS);
}

// ======================================================================
// AC: update_vault_guide writes on the current version; stale is
// version_conflict; invalid bullets are change_entries_invalid.
// ======================================================================

#[test]
fn update_vault_guide_with_the_current_version_writes_and_keeps_the_previous_text() {
    let (_dir, path) = vault_with(|_| {});
    let mut server = Stdio::start(&path);
    let read = server.call("get_vault_guide", json!({}));
    let id = str_of(&read, "note_id").to_string();

    let new_text = "## Framework\n\nGames before tools.\n\n## Decisions\n";
    let written = server.call(
        "update_vault_guide",
        json!({
            "version": read["version"],
            "content_md": new_text,
            "bullets": ["Added the games-first rule", "Noted why"],
        }),
    );
    assert_eq!(
        written,
        json!({ "note_id": id, "version": 2 }),
        "exactly note_id and version"
    );

    let after = server.call("get_vault_guide", json!({}));
    assert_eq!(
        after,
        json!({ "note_id": id, "version": 2, "content_md": new_text })
    );

    let rows = activity(Path::new(&path), &id);
    assert_eq!(rows.len(), 1, "one Activity row per write: {rows:?}");
    assert_eq!(
        rows[0].2,
        json!(["Added the games-first rule", "Noted why"]),
        "the bullets are the Activity entry"
    );
    let previous: String = open_db(Path::new(&path))
        .query_row(
            "SELECT previous_md FROM vault_guide_revisions WHERE note_id = ?",
            [&id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(previous, SEED, "the previous text is kept");
}

#[test]
fn update_vault_guide_with_a_stale_version_returns_version_conflict_and_writes_nothing() {
    let mut id = String::new();
    let (_dir, path) = vault_with(|v| {
        let (guide_id, version) = seed_guide(v);
        id = guide_id;
        person_edits_guide(v, &id, version, "## Framework\n\nThe person's line.\n");
    });
    let mut server = Stdio::start(&path);

    let stale = server.call_raw(
        "update_vault_guide",
        json!({ "version": 1, "content_md": "clobbered", "bullets": ["Rewrote it"] }),
    );
    assert_c1(&stale, "version_conflict", "stale update");
    assert_eq!(stale["error"]["expected"], json!(1), "{stale}");
    assert_eq!(stale["error"]["current"], json!(2), "{stale}");

    assert_eq!(
        stored(&path, &id),
        ("## Framework\n\nThe person's line.\n".to_string(), 2),
        "the person's edit stands"
    );
    assert_eq!(revision_count(&path), 0);
    assert!(activity(Path::new(&path), &id).is_empty());

    // Read again, and the agent may rewrite the person's line (R29).
    let read = server.call("get_vault_guide", json!({}));
    let written = server.call(
        "update_vault_guide",
        json!({
            "version": read["version"],
            "content_md": "## Framework\n\nRewritten.\n",
            "bullets": ["Reworded the framework"],
        }),
    );
    assert_eq!(written["version"], json!(3), "{written}");
}

#[test]
fn update_vault_guide_with_invalid_bullets_returns_change_entries_invalid_and_writes_nothing() {
    let (_dir, path) = vault_with(|_| {});
    let mut server = Stdio::start(&path);
    let read = server.call("get_vault_guide", json!({}));
    let id = str_of(&read, "note_id").to_string();

    let too_long = "x".repeat(201);
    let cases: Vec<(&str, Value)> = vec![
        ("no bullets", json!([])),
        ("four bullets", json!(["one", "two", "three", "four"])),
        ("a newline", json!(["one\ntwo"])),
        ("a leading list marker", json!(["- one"])),
        ("over 200 characters", json!([too_long])),
    ];
    for (what, bullets) in cases {
        let v = server.call_raw(
            "update_vault_guide",
            json!({ "version": 1, "content_md": "changed", "bullets": bullets }),
        );
        assert_c1(&v, "change_entries_invalid", what);
    }

    assert_eq!(stored(&path, &id), (SEED.to_string(), 1));
    assert_eq!(revision_count(&path), 0);
    assert!(activity(Path::new(&path), &id).is_empty());
}

#[test]
fn update_vault_guide_before_the_guide_exists_returns_not_found_and_creates_nothing() {
    let (_dir, path) = vault_with(|_| {});
    let mut server = Stdio::start(&path);
    let v = server.call_raw(
        "update_vault_guide",
        json!({ "version": 1, "content_md": "text", "bullets": ["Wrote it"] }),
    );
    assert_c1(&v, "not_found", "update with no guide");
    assert_eq!(
        count(
            Path::new(&path),
            "SELECT count(*) FROM notes WHERE json_extract(frontmatter, '$.role') = 'guide'"
        ),
        0
    );
}

// ======================================================================
// R40: `day` of the guide's Activity entry is today, in the caller's time zone.
// ======================================================================

#[tokio::test]
async fn update_vault_guide_dates_its_entry_today_in_the_callers_time_zone_over_mcp() {
    let srv = Hosted::at(BOUNDARY_MS).await;
    let path = srv.vault("v", |_| {});
    let read = srv.call("v", None, "get_vault_guide", json!({})).await;
    let id = str_of(&read, "note_id").to_string();

    let first = srv
        .call(
            "v",
            Some(WEST),
            "update_vault_guide",
            json!({ "version": 1, "content_md": "west", "bullets": ["From the west"] }),
        )
        .await;
    let second = srv
        .call(
            "v",
            Some(UTC),
            "update_vault_guide",
            json!({
                "version": first["version"],
                "content_md": "utc",
                "bullets": ["From UTC"],
            }),
        )
        .await;
    assert_eq!(second["version"], json!(3), "{second}");

    let rows = activity(&path, &id);
    assert_eq!(
        rows.iter()
            .map(|(day, at, _)| (day.as_str(), *at))
            .collect::<Vec<_>>(),
        vec![
            (BOUNDARY_WEST_DATE, BOUNDARY_MS),
            (BOUNDARY_UTC_DATE, BOUNDARY_MS),
        ],
        "each entry is dated in that call's offset, on the call's clock"
    );

    // The person's Activity tab reads the same rows.
    let hosted = srv.agent_changes("v", &id).await;
    assert_eq!(hosted[0]["day"], json!(BOUNDARY_UTC_DATE), "{hosted:?}");
    assert_eq!(hosted[0]["bullets"], json!(["From UTC"]), "{hosted:?}");
    assert_eq!(hosted[1]["day"], json!(BOUNDARY_WEST_DATE), "{hosted:?}");
}

#[test]
fn update_vault_guide_over_stdio_dates_its_entry_with_the_machines_date() {
    let (_dir, path) = vault_with(|_| {});
    let mut server = Stdio::start(&path);
    let read = server.call("get_vault_guide", json!({}));
    let id = str_of(&read, "note_id").to_string();

    let before = today_with_clock(&SystemClock).to_string();
    server.call(
        "update_vault_guide",
        json!({ "version": 1, "content_md": "text", "bullets": ["Wrote it"] }),
    );
    let after = today_with_clock(&SystemClock).to_string();

    let rows = activity(Path::new(&path), &id);
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert!(
        rows[0].0 == before || rows[0].0 == after,
        "{} is neither {before} nor {after}",
        rows[0].0
    );
}

// ======================================================================
// AC: add_link and update_link from the guide return guide_rule over MCP.
// ======================================================================

/// The person's edit of the guide's body.
fn person_edits_guide(vault: &mut Vault, id: &str, version: i64, body: &str) {
    let note_id = NoteId::parse(id).unwrap();
    update_note_as(
        vault,
        &note_id,
        version,
        UpdateNote {
            content_md: Some(body.into()),
            ..Default::default()
        },
        RenameOptions::default(),
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("person edit of the guide: {e}"));
    let body = get_note(vault, &note_id).unwrap().content_md;
    memex_core::indexer::reindex_note(vault.connection_mut(), id, &body, None).unwrap();
}

/// The C1 `guide_rule` object: the code, and a message that names the one write
/// path an agent has.
fn assert_guide_rule(v: &Value, what: &str) {
    assert_c1(v, "guide_rule", what);
    assert_eq!(
        keys(&v["error"]),
        set(&["code", "message"]),
        "{what}: exactly the C1 fields: {v}"
    );
    assert!(
        str_of(&v["error"], "message").contains("update_vault_guide"),
        "{what}: {v}"
    );
}

/// A guide linking to a topic note, with the person's text in place. Returns
/// `(guide id, topic id, link id)`.
fn guide_linking_to_a_topic(vault: &mut Vault) -> (String, String, String) {
    let (id, version) = seed_guide(vault);
    let topic = person_topic(vault, TOPIC);
    person_edits_guide(vault, &id, version, "Filing rule: see [[Player Loop]].\n");
    let link = vault
        .connection_ref()
        .query_row(
            "SELECT id FROM links WHERE from_note_id = ? AND to_note_id = ?",
            [&id, &topic],
            |r| r.get(0),
        )
        .unwrap_or_else(|e| panic!("the guide's link: {e}"));
    (id, topic, link)
}

#[test]
fn add_link_from_the_guide_returns_guide_rule_over_mcp() {
    let mut guide_id = String::new();
    let mut unlinked = String::new();
    let mut linked = String::new();
    let (_dir, path) = vault_with(|v| {
        let (id, topic, _) = guide_linking_to_a_topic(v);
        guide_id = id;
        linked = topic;
        unlinked = person_topic(v, "Level Design");
    });
    let before = stored(&path, &guide_id);
    let mut server = Stdio::start(&path);

    let new_link = server.call_raw(
        "add_link",
        json!({ "from_id": guide_id, "to_id": unlinked, "kind": "extends" }),
    );
    assert_guide_rule(&new_link, "a new link from the guide");

    // A link the guide already has is refused too, not answered as a no-op.
    let existing = server.call_raw(
        "add_link",
        json!({ "from_id": guide_id, "to_id": linked, "kind": "references" }),
    );
    assert_guide_rule(&existing, "a link the guide already has");

    assert_eq!(stored(&path, &guide_id), before, "the guide is untouched");
}

#[test]
fn update_link_from_the_guide_returns_guide_rule_over_mcp() {
    let mut guide_id = String::new();
    let mut link_id = String::new();
    let (_dir, path) = vault_with(|v| {
        let (id, _, link) = guide_linking_to_a_topic(v);
        guide_id = id;
        link_id = link;
    });
    let before = stored(&path, &guide_id);
    let mut server = Stdio::start(&path);

    let edit = server.call_raw(
        "update_link",
        json!({ "link_id": link_id, "kind": "extends" }),
    );
    assert_guide_rule(&edit, "a kind edit of the guide's link");

    // An edit that changes nothing is refused too, not answered unsaved.
    let no_op = server.call_raw(
        "update_link",
        json!({ "link_id": link_id, "kind": "references" }),
    );
    assert_guide_rule(&no_op, "a no-op edit of the guide's link");

    assert_eq!(stored(&path, &guide_id), before, "the guide is untouched");
}
