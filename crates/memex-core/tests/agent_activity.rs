//! WI #451 (Spec #390 req 9, 11; rulings D2, D4): `agents::activity::insert`.
//!
//! - `insert(conn, &entry)` writes one `agent_activity` row with every field
//!   of the entry, in one transaction of its own, and prunes the table to its
//!   newest 1,000 rows: ordered by `created_at`, then `id`, so a tie on
//!   `created_at` keeps the larger id.
//! - `note_id` has no foreign key (D2): an entry naming a note that doesn't
//!   exist (deleted concurrently) still inserts.
//! - An insert or prune moves `content_revision.n` (D4).
//! - A failed insert returns `Err` and writes nothing, prune included.
//!
//! No test here drops `content_revision`: every other table's triggers would
//! then fail on every write.

use std::collections::BTreeSet;

use memex_core::agents::activity::{insert, ActivityEntry};
use memex_core::Vault;
use rusqlite::Connection;
use tempfile::TempDir;

/// The newest rows the table keeps (req 11).
const KEEP: usize = 1_000;
/// A created_at far from the real clock.
const T0: i64 = 1_700_000_000_000;

fn fresh_vault() -> (TempDir, Vault) {
    let dir = tempfile::tempdir().unwrap();
    let vault = Vault::create(dir.path().join("vault")).unwrap();
    (dir, vault)
}

/// A 26-char id that sorts by `n` (a ULID-shaped string, Crockford digits).
fn id_of(n: usize) -> String {
    format!("01HZ{n:022}")
}

/// Entry `n`, built from run-time values.
fn entry(n: usize, created_at: i64) -> ActivityEntry {
    ActivityEntry {
        id: id_of(n),
        session_id: format!("SESSION{}", n % 3),
        client_name: format!("agent-{}", n % 2),
        tool: "add_excerpt".to_string(),
        summary: format!("filed {} blocks → Topic {n}", n + 1),
        note_id: n.is_multiple_of(2).then(|| format!("NOTE{n}")),
        created_at,
    }
}

fn count(conn: &Connection) -> usize {
    conn.query_row("SELECT COUNT(*) FROM agent_activity", [], |r| {
        r.get::<_, i64>(0)
    })
    .map(|n| n as usize)
    .unwrap()
}

fn ids(conn: &Connection) -> BTreeSet<String> {
    let mut stmt = conn.prepare("SELECT id FROM agent_activity").unwrap();
    let rows = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap();
    rows.map(Result::unwrap).collect()
}

fn stored(conn: &Connection, id: &str) -> Option<ActivityEntry> {
    conn.query_row(
        "SELECT id, session_id, client_name, tool, summary, note_id, created_at
         FROM agent_activity WHERE id = ?",
        [id],
        |r| {
            Ok(ActivityEntry {
                id: r.get(0)?,
                session_id: r.get(1)?,
                client_name: r.get(2)?,
                tool: r.get(3)?,
                summary: r.get(4)?,
                note_id: r.get(5)?,
                created_at: r.get(6)?,
            })
        },
    )
    .ok()
}

fn revision(conn: &Connection) -> i64 {
    conn.query_row("SELECT n FROM content_revision WHERE id = 1", [], |r| {
        r.get(0)
    })
    .unwrap()
}

/// Rows `0..n` through raw SQL, `created_at` `T0 + i`: a full table without
/// going through `insert`.
fn seed(conn: &Connection, n: usize) {
    let tx = conn.unchecked_transaction().unwrap();
    for i in 0..n {
        let e = entry(i, T0 + i as i64);
        tx.execute(
            "INSERT INTO agent_activity
             (id, session_id, client_name, tool, summary, note_id, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            rusqlite::params![
                e.id,
                e.session_id,
                e.client_name,
                e.tool,
                e.summary,
                e.note_id,
                e.created_at
            ],
        )
        .unwrap();
    }
    tx.commit().unwrap();
}

// ---------- the row (req 9) ----------

#[test]
fn insert_writes_one_row_holding_every_field_of_the_entry() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let with_note = entry(4, T0 + 4);
    let without_note = entry(7, T0 + 7);
    assert!(
        without_note.note_id.is_none(),
        "precondition: odd n has no note"
    );

    insert(conn, &with_note).expect("insert with a note_id");
    insert(conn, &without_note).expect("insert without a note_id");

    assert_eq!(count(conn), 2);
    assert_eq!(stored(conn, &with_note.id), Some(with_note));
    assert_eq!(
        stored(conn, &without_note.id),
        Some(without_note),
        "a None note_id is stored as NULL"
    );
}

#[test]
fn insert_naming_a_note_that_does_not_exist_still_inserts() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let mut e = entry(2, T0);
    e.note_id = Some("01ARZ3NDEKTSV4RRFFQ69G5FAV".to_string());
    let notes: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM notes WHERE id = ?",
            [&e.note_id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(notes, 0, "precondition: no such note");

    insert(conn, &e).expect("note_id has no foreign key (D2)");
    assert_eq!(stored(conn, &e.id), Some(e));
}

#[test]
fn insert_moves_the_content_revision() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    let before = revision(conn);
    insert(conn, &entry(1, T0)).unwrap();
    assert!(
        revision(conn) > before,
        "an activity insert moves content_revision.n (D4)"
    );
}

// ---------- pruning (req 11) ----------

#[test]
fn after_1005_inserts_the_table_holds_the_newest_1000() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    for i in 0..1_005 {
        insert(conn, &entry(i, T0 + i as i64)).unwrap();
    }
    assert_eq!(count(conn), KEEP, "pruned to the newest 1,000");
    let want: BTreeSet<String> = (5..1_005).map(id_of).collect();
    assert_eq!(ids(conn), want, "the 5 oldest are the ones pruned");
}

#[test]
fn the_1000th_insert_prunes_nothing_and_the_1001st_prunes_the_oldest() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    seed(conn, KEEP - 1);

    insert(conn, &entry(KEEP - 1, T0 + (KEEP - 1) as i64)).unwrap();
    assert_eq!(count(conn), KEEP, "1,000 rows: nothing pruned");
    assert!(ids(conn).contains(&id_of(0)), "the oldest is kept at 1,000");

    insert(conn, &entry(KEEP, T0 + KEEP as i64)).unwrap();
    assert_eq!(count(conn), KEEP, "the 1,001st insert prunes one");
    let got = ids(conn);
    assert!(!got.contains(&id_of(0)), "the oldest row is pruned");
    assert!(got.contains(&id_of(1)), "only the oldest");
    assert!(got.contains(&id_of(KEEP)), "the new row is kept");
}

#[test]
fn a_prune_on_a_created_at_tie_keeps_the_larger_ids() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    // Every row at the same ms; ids inserted from largest to smallest, so
    // insertion order and id order disagree.
    for i in (0..KEEP + 2).rev() {
        insert(conn, &entry(i, T0)).unwrap();
    }
    assert_eq!(count(conn), KEEP);
    let want: BTreeSet<String> = (2..KEEP + 2).map(id_of).collect();
    assert_eq!(
        ids(conn),
        want,
        "on a created_at tie the newest are the larger ids, whatever the insert order"
    );
}

#[test]
fn a_backward_clock_jump_prunes_by_created_at_not_by_insert_order() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    seed(conn, KEEP);
    // The clock jumped back (NTP, manual change): this entry is written last
    // but is the oldest by created_at, and a larger id than every other row.
    let late = entry(KEEP + 50, T0 - 60_000);
    insert(conn, &late).unwrap();
    assert_eq!(count(conn), KEEP);
    assert!(
        stored(conn, &late.id).is_none(),
        "the oldest by created_at is pruned, even when it was written last"
    );
    assert!(ids(conn).contains(&id_of(0)), "the seeded rows stay");

    // Control: an entry newer than every row is kept and the oldest goes.
    let next = entry(KEEP + 51, T0 + KEEP as i64);
    insert(conn, &next).unwrap();
    assert_eq!(count(conn), KEEP);
    assert_eq!(stored(conn, &next.id), Some(next), "the newest is kept");
    assert!(
        !ids(conn).contains(&id_of(0)),
        "the oldest seeded row is pruned"
    );
}

// ---------- failure ----------

#[test]
fn a_failed_insert_returns_err_and_writes_nothing() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    seed(conn, KEEP);
    let before = ids(conn);
    let rev = revision(conn);

    // A newer entry reusing the oldest row's id: the insert fails on the
    // primary key, so no prune may run either.
    let mut dup = entry(0, T0 + 10_000);
    dup.summary = "a different line".to_string();
    let got = insert(conn, &dup);

    assert!(got.is_err(), "a primary-key clash is an error: {got:?}");
    assert_eq!(ids(conn), before, "nothing inserted and nothing pruned");
    assert_eq!(
        stored(conn, &id_of(0)).map(|e| e.summary),
        Some(entry(0, T0).summary),
        "the existing row is untouched"
    );
    assert_eq!(revision(conn), rev, "a failed insert moves no revision");
}

#[test]
fn a_prune_failure_rolls_back_the_insert_so_the_row_and_prune_are_one_transaction() {
    let (_dir, vault) = fresh_vault();
    let conn = vault.connection_ref();
    seed(conn, KEEP);
    let before = ids(conn);
    let rev = revision(conn);

    // The INSERT succeeds; only the prune's DELETE fails. Were the two
    // statements not one transaction, the new row would stay committed.
    conn.execute_batch(
        "CREATE TEMP TRIGGER test_fail_prune BEFORE DELETE ON agent_activity
         BEGIN SELECT RAISE(ABORT, 'prune forced to fail'); END;",
    )
    .unwrap();

    let next = entry(KEEP + 7, T0 + 10_000);
    let got = insert(conn, &next);

    assert!(got.is_err(), "a failing prune is an error: {got:?}");
    assert_eq!(count(conn), KEEP, "no 1,001st row is left behind");
    assert_eq!(
        ids(conn),
        before,
        "the new row is rolled back with the prune"
    );
    assert_eq!(stored(conn, &next.id), None, "the new row is absent");
    assert_eq!(
        revision(conn),
        rev,
        "a rolled-back insert moves no revision"
    );

    // The connection is left outside a transaction: with the trigger gone
    // the same insert goes through.
    conn.execute_batch("DROP TRIGGER test_fail_prune").unwrap();
    insert(conn, &next).unwrap();
    assert_eq!(count(conn), KEEP);
    assert_eq!(stored(conn, &next.id), Some(next));
}
