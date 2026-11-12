//! WI #402 (Spec #394 requirement 35; rulings D11, D12): `memex tools`.
//!
//! Drives the built `memex` binary. The expected list is never hand-copied:
//! tool and prompt names, and their order, come from the composed routers
//! (`Memex::routers()`, rmcp `list_all()`), and every other field from M0's
//! table (`memex_mcp::tools::meta`).
//!
//! The contract: exit 0 and one line of JSON on stdout,
//! `{"tools":[{"name","summary","group","writes"}],"prompts":[{"name","summary"}]}`,
//! with `group` the wire id (`Group::id()`), in router order. No `--json`
//! flag and no vault argument.

use std::collections::BTreeSet;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use memex_mcp::tools::meta;
use memex_mcp::tools::Memex;
use serde_json::{json, Value};

// ---------- harness ----------

fn memex() -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_memex"));
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    cmd
}

fn run(args: &[&str]) -> Output {
    memex().args(args).output().expect("run memex")
}

fn describe(out: &Output) -> String {
    format!(
        "exit={:?}\nstdout={}\nstderr={}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// Success: exit 0, an empty stderr, and stdout exactly one JSON line;
/// returns it parsed.
fn ok_json(out: Output) -> Value {
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(
        out.stderr.is_empty(),
        "stderr must be empty; {}",
        describe(&out)
    );
    let stdout = String::from_utf8(out.stdout).expect("utf8 stdout");
    let line = stdout
        .strip_suffix('\n')
        .unwrap_or_else(|| panic!("stdout ends with one newline: {stdout:?}"));
    assert!(
        !line.is_empty() && !line.contains('\n'),
        "stdout must be exactly one JSON line, got {stdout:?}"
    );
    serde_json::from_str(line).unwrap_or_else(|e| panic!("stdout is not JSON ({e}): {stdout}"))
}

/// `memex tools`, parsed.
fn tools_json() -> Value {
    ok_json(run(&["tools"]))
}

/// The composed tool router's names, in `list_all()` order.
fn router_tool_names() -> Vec<String> {
    let (tools, _) = Memex::routers();
    let names: Vec<String> = tools
        .list_all()
        .into_iter()
        .map(|t| t.name.to_string())
        .collect();
    assert!(!names.is_empty(), "Memex::routers() registers no tools");
    names
}

/// The composed prompt router's names, in `list_all()` order.
fn router_prompt_names() -> Vec<String> {
    let (_, prompts) = Memex::routers();
    let names: Vec<String> = prompts
        .list_all()
        .into_iter()
        .map(|p| p.name.to_string())
        .collect();
    assert!(!names.is_empty(), "Memex::routers() registers no prompts");
    names
}

/// The `name` of every object in `v[key]`, in order.
fn names_of(v: &Value, key: &str) -> Vec<String> {
    v[key]
        .as_array()
        .unwrap_or_else(|| panic!("{key:?} is an array: {v}"))
        .iter()
        .map(|o| {
            o["name"]
                .as_str()
                .unwrap_or_else(|| panic!("{key} entry has a string name: {o}"))
                .to_string()
        })
        .collect()
}

fn keys_of(v: &Value) -> BTreeSet<String> {
    v.as_object()
        .unwrap_or_else(|| panic!("an object: {v}"))
        .keys()
        .cloned()
        .collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

// ---------- AC 1: tools, in router order, with M0's metadata ----------

#[test]
fn memex_tools_lists_every_router_tool_in_router_order_with_its_meta_row() {
    let router = router_tool_names();
    // Router order is not the meta table's order, so a list built from the
    // table instead of the router fails here.
    let table: Vec<String> = meta::tools().iter().map(|r| r.name.to_string()).collect();
    assert_ne!(
        router, table,
        "precondition: router order differs from the table order"
    );

    let out = tools_json();

    assert_eq!(
        names_of(&out, "tools"),
        router,
        "tools in router order, each once"
    );
    for entry in out["tools"].as_array().unwrap() {
        let name = entry["name"].as_str().unwrap();
        let row = meta::tool(name).unwrap_or_else(|| panic!("{name} has a meta row"));
        assert_eq!(
            *entry,
            json!({
                "name": row.name,
                "summary": row.summary,
                "group": row.group.id(),
                "writes": row.writes,
            }),
            "{name}: exactly name, summary, group id and writes from meta"
        );
    }
}

#[test]
fn memex_tools_writes_and_group_ids_are_the_meta_contract() {
    let out = tools_json();
    let tools = out["tools"].as_array().expect("tools array");

    let writes: BTreeSet<String> = tools
        .iter()
        .filter(|t| t["writes"] == json!(true))
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect();
    let reads = tools.iter().filter(|t| t["writes"] == json!(false)).count();
    assert_eq!(
        writes,
        set(&meta::write_tools()),
        "writes is true for exactly meta::write_tools()"
    );
    assert_eq!(writes.len(), 24, "#390 requirement 8 has 24 write tools");
    assert_eq!(
        writes.len() + reads,
        tools.len(),
        "every writes is a JSON bool"
    );

    let groups: BTreeSet<String> = tools
        .iter()
        .map(|t| {
            t["group"]
                .as_str()
                .unwrap_or_else(|| panic!("group is a string id: {t}"))
                .to_string()
        })
        .collect();
    assert_eq!(
        groups,
        set(&["notes", "daily", "folders", "tags", "feedback", "canvas"]),
        "group ids are exactly Spec #394 requirement 34's"
    );
}

#[test]
fn memex_tools_prints_one_json_line_with_only_tools_and_prompts() {
    let out = tools_json();
    assert_eq!(keys_of(&out), set(&["tools", "prompts"]), "{out}");
    for t in out["tools"].as_array().unwrap() {
        assert_eq!(
            keys_of(t),
            set(&["name", "summary", "group", "writes"]),
            "{t}"
        );
    }
    for p in out["prompts"].as_array().unwrap() {
        assert_eq!(keys_of(p), set(&["name", "summary"]), "{p}");
    }
}

#[test]
fn memex_tools_takes_no_vault_or_json_argument() {
    // From any directory, with no vault anywhere near it.
    let cwd = tempfile::tempdir().unwrap();
    let out = memex()
        .arg("tools")
        .current_dir(cwd.path())
        .output()
        .expect("run memex tools");
    let v = ok_json(out);
    assert_eq!(names_of(&v, "tools"), router_tool_names());

    let vault = cwd.path().join("v");
    let vault = vault.to_str().unwrap();
    for args in [
        vec!["tools", "--json"],
        vec!["tools", "--vault", vault],
        vec!["tools", "extra"],
    ] {
        let out = run(&args);
        assert_eq!(
            out.status.code(),
            Some(2),
            "memex {} is a clap usage error; {}",
            args.join(" "),
            describe(&out)
        );
        assert!(out.stdout.is_empty(), "{}", describe(&out));
    }
    assert!(!Path::new(vault).exists(), "nothing was created");
}

#[test]
fn memex_tools_with_a_closed_stdout_exits_0_and_prints_no_error() {
    // A reader that went away is not an error (Spec #315 req 17a): the
    // command still exits 0 with nothing on stderr, never a panic.
    let (reader, writer) = std::io::pipe().expect("pipe");
    drop(reader);
    let out = Command::new(env!("CARGO_BIN_EXE_memex"))
        .arg("tools")
        .stdin(Stdio::null())
        .stdout(writer)
        .stderr(Stdio::piped())
        .output()
        .expect("run memex tools");
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert!(out.stderr.is_empty(), "{}", describe(&out));
}

// ---------- AC 2: the two prompts ----------

#[test]
fn memex_tools_lists_the_two_prompts_in_router_order_with_their_summaries() {
    let out = tools_json();
    let names = names_of(&out, "prompts");
    assert_eq!(names, router_prompt_names(), "prompts in router order");
    assert_eq!(
        names.iter().map(String::as_str).collect::<BTreeSet<_>>(),
        ["review_daily_notes", "capture"].into_iter().collect(),
        "exactly the two prompts"
    );
    for entry in out["prompts"].as_array().unwrap() {
        let name = entry["name"].as_str().unwrap();
        let row = meta::prompt(name).unwrap_or_else(|| panic!("{name} has a meta row"));
        assert_eq!(
            *entry,
            json!({ "name": row.name, "summary": row.summary }),
            "{name}: exactly name and summary from meta"
        );
    }
}

// ---------- AC 3: help ----------

#[test]
fn memex_tools_help_matches_its_golden_text() {
    let golden_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/help/tools.txt");
    let golden = std::fs::read_to_string(&golden_path)
        .unwrap_or_else(|e| panic!("{}: {e}", golden_path.display()));
    let out = run(&["tools", "--help"]);
    assert_eq!(out.status.code(), Some(0), "{}", describe(&out));
    assert_eq!(String::from_utf8(out.stdout).unwrap(), golden);
}
