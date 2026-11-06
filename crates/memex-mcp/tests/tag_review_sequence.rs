//! WI #243 (T5): Review's tool order with tagging, over a real vault (Spec #234
//! R41-R44, User Story 5).
//!
//! The `review_daily_notes` prompt (crates/memex-mcp/src/prompts.rs) now says:
//! call `list_tags` once, `tag_note` the daily note under review and the topic
//! notes touched in the run, then `mark_day_reviewed` with `Tagged #name`
//! bullets in those notes' change entries. Each test starts `memex serve` as a
//! subprocess over a temp vault, checks that the prompt text describes that
//! order, and then drives the tools in it.
//!
//! The vocabulary is written the way a person writes it: `#pricing` in a
//! person-authored note body through core (an agent body is never scanned).
//! The person's daily note is written through core too. No embedding model is
//! used; JSON is compared as parsed values. Helpers carry a `wi243_` prefix so
//! sibling WIs editing neighbouring test files never collide with them.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

use memex_core::guide;
use memex_core::notes::{create_note_as, CreateNote, NoteId};
use memex_core::tags;
use memex_core::{indexer, Caller, Clock, Vault};
use memex_mcp::prompts::REVIEW_DAILY_NOTES;
use serde_json::{json, Value};
use tempfile::TempDir;

const DAY: &str = "2026-09-05";
/// Three blocks: "Fixed the jump arc.", "- tried coyote time", "Sleep was bad."
const DAY_BODY: &str = "Fixed the jump arc.\n\n- tried coyote time\n\nSleep was bad.\n";
const MARKER: &str = "<!-- memex:topics -->";

// ---------- harness: `memex serve` over stdio ----------

/// A `memex serve` subprocess spoken to over newline-delimited JSON-RPC.
struct Wi243Server {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    next_id: i64,
}

impl Wi243Server {
    fn start(vault: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_memex"))
            .args(["serve", "--vault", vault])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn memex serve");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let mut server = Self {
            child,
            stdin,
            lines,
            next_id: 1,
        };
        let init = server.request(
            "initialize",
            json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": { "name": "wi243-test", "version": "0" },
            }),
        );
        assert!(init["result"].is_object(), "initialize failed: {init}");
        server.send(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));
        server
    }

    fn send(&mut self, msg: Value) {
        writeln!(self.stdin, "{msg}").expect("write to server");
        self.stdin.flush().unwrap();
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        loop {
            let line = self
                .lines
                .recv_timeout(Duration::from_secs(30))
                .unwrap_or_else(|e| panic!("no response to {method}: {e}"));
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v["id"] == json!(id) {
                return v;
            }
        }
    }

    /// Calls a tool and parses the JSON string it returns, rule errors
    /// (`{"error": …}`) included.
    fn call_raw(&mut self, name: &str, arguments: Value) -> Value {
        let resp = self.request(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        );
        let result = &resp["result"];
        assert!(result.is_object(), "tools/call {name} failed: {resp}");
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name} returned no text content: {resp}"));
        serde_json::from_str(text)
            .unwrap_or_else(|e| panic!("{name} returned non-JSON ({e}): {text}"))
    }

    /// Like `call_raw`, but fails the test on an error object.
    fn call(&mut self, name: &str, arguments: Value) -> Value {
        let v = self.call_raw(name, arguments);
        assert!(v.get("error").is_none(), "{name} errored: {v}");
        v
    }
}

impl Drop for Wi243Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ---------- the person's writes, through core before the server starts ----------

fn wi243_person_note(vault: &mut Vault, title: &str, body: &str, frontmatter: Value) -> String {
    create_note_as(
        vault,
        CreateNote {
            title: Some(title.into()),
            content_md: body.into(),
            frontmatter: Some(frontmatter),
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create {title}: {e}"))
    .id
    .to_string()
}

/// A clock that stays where it is put (no wall-clock reads).
struct Wi243Clock(i64);

impl Clock for Wi243Clock {
    fn now_ms(&self) -> i64 {
        self.0
    }
}

/// The vault's real guide, built the only way the guide guard (#233) allows:
/// `guide::get_or_create` (`create_note_as` rejects `role: guide`).
fn wi243_guide(vault: &mut Vault) -> String {
    let clock = Wi243Clock(1_759_500_000_000);
    let seeded = guide::get_or_create(vault, &clock, None).expect("create the guide");
    seeded.note_id.to_string()
}

/// A person-written daily note, indexed as the app would.
fn wi243_person_daily(vault: &mut Vault, date: &str, body: &str) -> String {
    let note = create_note_as(
        vault,
        CreateNote {
            title: Some(date.into()),
            content_md: body.into(),
            frontmatter: Some(json!({ "role": "daily" })),
        },
        Caller::Person,
    )
    .unwrap_or_else(|e| panic!("create daily {date}: {e}"));
    indexer::reindex_note(
        vault.connection_mut(),
        note.id.as_str(),
        &note.content_md,
        None,
    )
    .unwrap();
    note.id.to_string()
}

/// What the setup leaves in the vault.
struct Wi243Ids {
    daily: String,
    /// A person-written topic note the person once saw `roadmap` on and removed.
    roadmap_topic: String,
    guide: String,
}

/// A vault whose person-written vocabulary note holds `#pricing` and
/// `#roadmap`, with the day to review. `roadmap_topic` carries a person's
/// removal of `roadmap`; `guide` is a guide note.
fn wi243_vault() -> (TempDir, String, Wi243Ids) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let ids = {
        let mut vault = Vault::create(&path).unwrap();
        wi243_person_note(&mut vault, "Vocabulary", "#pricing #roadmap\n", json!({}));
        let daily = wi243_person_daily(&mut vault, DAY, DAY_BODY);
        let roadmap_topic = wi243_person_note(
            &mut vault,
            "Roadmap",
            "A topic.\n",
            json!({ "role": "topic" }),
        );
        let guide = wi243_guide(&mut vault);
        let id = NoteId::parse(&roadmap_topic).unwrap();
        tags::agent_tag_note(&mut vault, &id, "roadmap", None).unwrap();
        tags::person_remove_tag(&mut vault, &id, "roadmap", None).unwrap();
        Wi243Ids {
            daily,
            roadmap_topic,
            guide,
        }
    };
    let path = path.to_str().unwrap().to_string();
    (dir, path, ids)
}

// ---------- helpers over tool results and the prompt ----------

fn wi243_str<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key]
        .as_str()
        .unwrap_or_else(|| panic!("`{key}` is not a string in {v}"))
}

fn wi243_strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap_or_else(|| panic!("expected an array: {v}"))
        .iter()
        .map(|s| s.as_str().expect("a string").to_string())
        .collect()
}

fn wi243_block_ids(changes: &Value) -> Vec<String> {
    changes["added"]
        .as_array()
        .unwrap_or_else(|| panic!("added blocks: {changes}"))
        .iter()
        .map(|b| wi243_str(b, "id").to_string())
        .collect()
}

fn wi243_list_dates(server: &mut Wi243Server) -> Vec<String> {
    let v = server.call("list_unreviewed_days", json!({}));
    v["days"]
        .as_array()
        .unwrap_or_else(|| panic!("days array: {v}"))
        .iter()
        .map(|d| wi243_str(d, "date").to_string())
        .collect()
}

/// The Review prompt names `list_tags`, then `tag_note`, then
/// `mark_day_reviewed`, in code formatting: the order the sequence runs.
fn wi243_assert_prompt_describes_the_tagging_order() {
    let mut from = 0;
    for name in ["list_tags", "tag_note", "mark_day_reviewed"] {
        let needle = format!("`{name}`");
        let found = REVIEW_DAILY_NOTES[from..].find(&needle).unwrap_or_else(|| {
            panic!(
                "the review prompt must name {needle} after the tools before it in \
                 [list_tags, tag_note, mark_day_reviewed]:\n{REVIEW_DAILY_NOTES}"
            )
        });
        from += found + needle.len();
    }
    assert!(
        REVIEW_DAILY_NOTES.contains("Tagged #"),
        "the review prompt must show the `Tagged #name` change-entry bullet:\n{REVIEW_DAILY_NOTES}"
    );
}

/// Filing before tagging, as the prompt's steps run: fetch the changes, create
/// a topic note, file all three blocks into it. Returns `(changes, topic_id)`.
fn wi243_file_into_a_topic(server: &mut Wi243Server, daily_id: &str) -> (Value, String) {
    assert_eq!(wi243_list_dates(server), vec![DAY.to_string()]);
    let changes = server.call("get_daily_note_changes", json!({ "date": DAY }));
    assert_eq!(wi243_str(&changes, "note_id"), daily_id, "{changes}");
    assert_eq!(changes["content_version"], json!(1), "{changes}");
    let ids = wi243_block_ids(&changes);
    assert_eq!(ids.len(), 3, "{changes}");
    let topic = server.call(
        "create_note",
        json!({
            "title": "Pricing",
            "content_md": "How the product is priced.",
            "role": "topic",
        }),
    );
    let topic_id = wi243_str(&topic, "note_id").to_string();
    server.call(
        "add_excerpt",
        json!({ "topic_note_id": topic_id, "date": DAY, "block_ids": ids }),
    );
    (changes, topic_id)
}

fn wi243_assert_c1(v: &Value, code: &str) {
    assert!(v["error"].is_object(), "expected an error object, got {v}");
    assert_eq!(v["error"]["code"], json!(code), "{v}");
}

// ======================================================================
// AC 7: Review's tool order with tagging, against a real vault.
// ======================================================================

#[test]
fn review_sequence_with_tagging_lists_tags_tags_the_day_and_a_topic_and_marks_the_day_reviewed() {
    wi243_assert_prompt_describes_the_tagging_order();
    let (_dir, path, ids) = wi243_vault();
    let mut server = Wi243Server::start(&path);
    let (changes, topic_id) = wi243_file_into_a_topic(&mut server, &ids.daily);

    // list_tags, once: the person's `#pricing` and `#roadmap` are the vocabulary.
    let listed = server.call("list_tags", json!({}));
    let tags: Vec<&str> = listed["tags"]
        .as_array()
        .unwrap_or_else(|| panic!("tags array: {listed}"))
        .iter()
        .map(|t| wi243_str(t, "tag"))
        .collect();
    assert_eq!(tags, ["pricing", "roadmap"], "{listed}");

    // tag_note on the day under review and on the topic note touched.
    let day_tag = server.call(
        "tag_note",
        json!({ "note_id": ids.daily, "tag": "pricing" }),
    );
    assert_eq!(day_tag["applied"], json!(true), "{day_tag}");
    assert_eq!(day_tag["tag"], json!("pricing"), "{day_tag}");
    assert_eq!(wi243_str(&day_tag, "note_id"), ids.daily, "{day_tag}");
    let topic_tag = server.call("tag_note", json!({ "note_id": topic_id, "tag": "pricing" }));
    assert_eq!(topic_tag["applied"], json!(true), "{topic_tag}");
    assert_eq!(wi243_str(&topic_tag, "note_id"), topic_id, "{topic_tag}");

    // mark_day_reviewed with the version fetched before tagging: tagging the
    // day moved no content version, so the mark is not stale.
    let marked = server.call(
        "mark_day_reviewed",
        json!({
            "date": DAY,
            "version": changes["content_version"],
            "changes": [
                { "note_id": ids.daily, "bullets": ["Tagged #pricing"] },
                {
                    "note_id": topic_id,
                    "bullets": ["Filed 3 blocks into Pricing", "Tagged #pricing"],
                },
            ],
        }),
    );
    assert_eq!(marked["state"], json!("Reviewed"), "{marked}");
    assert_eq!(marked["content_version"], json!(1), "{marked}");
    assert_eq!(marked["reviewed_content_version"], json!(1), "{marked}");
    assert_eq!(
        wi243_list_dates(&mut server),
        Vec::<String>::new(),
        "the day leaves the unreviewed list"
    );
}

#[test]
fn review_sequence_with_tagging_leaves_the_tags_in_the_footer_and_the_persons_text_alone() {
    wi243_assert_prompt_describes_the_tagging_order();
    let (_dir, path, ids) = wi243_vault();
    let mut server = Wi243Server::start(&path);
    let (changes, topic_id) = wi243_file_into_a_topic(&mut server, &ids.daily);
    server.call("list_tags", json!({}));
    for id in [&ids.daily, &topic_id] {
        server.call("tag_note", json!({ "note_id": id, "tag": "pricing" }));
    }
    server.call(
        "mark_day_reviewed",
        json!({
            "date": DAY,
            "version": changes["content_version"],
            "changes": [
                { "note_id": ids.daily, "bullets": ["Tagged #pricing"] },
                { "note_id": topic_id, "bullets": ["Tagged #pricing"] },
            ],
        }),
    );

    // The day: tags are footer text below the marker; the person's text above
    // it is byte for byte what they wrote, and the review state is Reviewed.
    let day = server.call("get_note", json!({ "note_id": ids.daily }));
    assert_eq!(wi243_strings(&day["agent_tags"]), ["pricing"], "{day}");
    let body = wi243_str(&day, "content_md");
    let (person, footer) = body
        .split_once(MARKER)
        .unwrap_or_else(|| panic!("the daily note carries the marker: {body:?}"));
    assert_eq!(person, DAY_BODY, "the person's text is untouched: {body:?}");
    assert!(
        footer.lines().any(|l| l.trim() == "#pricing"),
        "the tag is footer text: {body:?}"
    );
    assert_eq!(day["review"]["state"], json!("Reviewed"), "{day}");
    assert_eq!(day["latest_change"]["day"], json!(DAY), "{day}");
    assert_eq!(
        day["latest_change"]["bullets"],
        json!(["Tagged #pricing"]),
        "a note touched only by tagging has its entry: {day}"
    );

    // The topic note: the tag, and no `#pricing` written into its body text.
    let topic = server.call("get_note", json!({ "note_id": topic_id }));
    assert_eq!(wi243_strings(&topic["agent_tags"]), ["pricing"], "{topic}");
    let topic_body = wi243_str(&topic, "content_md");
    let topic_person = topic_body.split_once(MARKER).map_or(topic_body, |(a, _)| a);
    assert!(
        !topic_person.contains("#pricing"),
        "no #tag in the topic note's body text: {topic_body:?}"
    );
}

#[test]
fn review_sequence_with_tagging_carries_on_after_the_tag_errors_and_still_marks_the_day_reviewed() {
    wi243_assert_prompt_describes_the_tagging_order();
    let (_dir, path, ids) = wi243_vault();
    let mut server = Wi243Server::start(&path);
    let (changes, topic_id) = wi243_file_into_a_topic(&mut server, &ids.daily);
    server.call("list_tags", json!({}));

    // unknown_tag: a name outside the vocabulary. Not retried.
    wi243_assert_c1(
        &server.call_raw(
            "tag_note",
            json!({ "note_id": topic_id, "tag": "not-in-the-vocabulary" }),
        ),
        "unknown_tag",
    );
    // tag_removed: the person took `roadmap` off that note. Not retried.
    wi243_assert_c1(
        &server.call_raw(
            "tag_note",
            json!({ "note_id": ids.roadmap_topic, "tag": "roadmap" }),
        ),
        "tag_removed",
    );
    // guide_rule: a guide note takes no tags. Not retried.
    wi243_assert_c1(
        &server.call_raw(
            "tag_note",
            json!({ "note_id": ids.guide, "tag": "pricing" }),
        ),
        "guide_rule",
    );

    // Carry on: the tag that works is applied, the entries name only what was
    // applied, and the day is marked reviewed.
    let ok = server.call(
        "tag_note",
        json!({ "note_id": ids.daily, "tag": "pricing" }),
    );
    assert_eq!(ok["applied"], json!(true), "{ok}");
    let marked = server.call(
        "mark_day_reviewed",
        json!({
            "date": DAY,
            "version": changes["content_version"],
            "changes": [
                { "note_id": ids.daily, "bullets": ["Tagged #pricing"] },
                { "note_id": topic_id, "bullets": ["Filed 3 blocks into Pricing"] },
            ],
        }),
    );
    assert_eq!(marked["state"], json!("Reviewed"), "{marked}");

    let removed = server.call("get_note", json!({ "note_id": ids.roadmap_topic }));
    assert_eq!(
        wi243_strings(&removed["agent_tags"]),
        Vec::<String>::new(),
        "the person's removal stands: {removed}"
    );
    let topic = server.call("get_note", json!({ "note_id": topic_id }));
    assert_eq!(
        wi243_strings(&topic["agent_tags"]),
        Vec::<String>::new(),
        "the unknown tag was not applied: {topic}"
    );
}

#[test]
fn review_sequence_with_tagging_applies_nothing_when_list_tags_is_empty() {
    wi243_assert_prompt_describes_the_tagging_order();
    // A vault with no vocabulary: list_tags is empty, so the review applies
    // no tag and marks the day reviewed with the usual entries.
    let dir = tempfile::tempdir().unwrap();
    let vault_path = dir.path().join("vault");
    let daily_id = {
        let mut vault = Vault::create(&vault_path).unwrap();
        wi243_person_daily(&mut vault, DAY, DAY_BODY)
    };
    let mut server = Wi243Server::start(vault_path.to_str().unwrap());
    let (changes, topic_id) = wi243_file_into_a_topic(&mut server, &daily_id);

    let listed = server.call("list_tags", json!({}));
    assert_eq!(listed["tags"], json!([]), "{listed}");

    let marked = server.call(
        "mark_day_reviewed",
        json!({
            "date": DAY,
            "version": changes["content_version"],
            "changes": [
                { "note_id": daily_id, "bullets": ["Nothing new to file"] },
                { "note_id": topic_id, "bullets": ["Filed 3 blocks into Pricing"] },
            ],
        }),
    );
    assert_eq!(marked["state"], json!("Reviewed"), "{marked}");
    let day = server.call("get_note", json!({ "note_id": daily_id }));
    assert_eq!(
        wi243_strings(&day["agent_tags"]),
        Vec::<String>::new(),
        "no tag applied: {day}"
    );
    let body = wi243_str(&day, "content_md");
    assert!(
        !body.contains('#'),
        "no #tag text anywhere in the daily note: {body:?}"
    );
}
