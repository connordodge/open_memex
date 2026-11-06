//! WI #16 (R13): `memex prompt review` / `memex prompt capture`.
//!
//! CONTRACTS C2.13: raw prompt text on stdout, no JSON. The text is the
//! `memex_mcp::prompts` constant byte-for-byte (D18), so the app's
//! `Copy review prompt` (which runs `memex prompt review`) copies exactly what
//! the MCP `review_daily_notes` prompt serves.

use std::process::{Command, Output, Stdio};

use memex_mcp::prompts::{CAPTURE, REVIEW_DAILY_NOTES};

/// Runs the real `memex` binary from an empty temp dir (no vault involved).
fn memex(args: &[&str]) -> Output {
    let cwd = tempfile::tempdir().unwrap();
    Command::new(env!("CARGO_BIN_EXE_memex"))
        .args(args)
        .current_dir(cwd.path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .expect("run memex")
}

fn assert_prints_exactly(name: &str, expected: &str) {
    assert!(
        !expected.trim().is_empty(),
        "the {name} prompt text in prompts.rs is empty"
    );
    let out = memex(&["prompt", name]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success(),
        "memex prompt {name} must exit 0, got {:?}; stderr: {stderr}",
        out.status.code()
    );
    assert_eq!(
        out.stdout,
        expected.as_bytes(),
        "memex prompt {name} must print the prompts.rs constant byte-for-byte; got:\n{stdout}"
    );
    assert!(
        stderr.is_empty(),
        "memex prompt {name} writes nothing to stderr: {stderr}"
    );
    assert!(
        serde_json::from_slice::<serde_json::Value>(&out.stdout).is_err(),
        "memex prompt {name} prints raw text, not JSON"
    );
    assert!(
        !stdout.ends_with("\n\n"),
        "memex prompt {name} prints no trailing blank lines"
    );
}

// ---------- AC 7: raw text, byte-for-byte ----------

#[test]
fn prompt_review_prints_the_review_constant_byte_for_byte() {
    assert_prints_exactly("review", REVIEW_DAILY_NOTES);
}

#[test]
fn prompt_capture_prints_the_capture_constant_byte_for_byte() {
    assert_ne!(CAPTURE, REVIEW_DAILY_NOTES, "the two prompts differ");
    assert_prints_exactly("capture", CAPTURE);
}

// ---------- WI #257: the Vault Guide and Feedback in the printed prompts ----------

#[test]
fn prompt_review_stdout_names_the_feedback_tools_before_step_one() {
    let out = memex(&["prompt", "review"]);
    assert!(out.status.success(), "memex prompt review exits 0");
    let stdout = String::from_utf8(out.stdout).expect("utf-8");
    let step1 = stdout
        .find("## 1. Take the oldest unreviewed day")
        .expect("step 1 keeps its heading");
    for tool in [
        "get_vault_guide",
        "list_open_feedback",
        "resolve_feedback",
        "update_vault_guide",
        "record_feedback",
    ] {
        let at = stdout
            .find(&format!("`{tool}`"))
            .unwrap_or_else(|| panic!("memex prompt review names `{tool}`:\n{stdout}"));
        assert!(at < step1, "`{tool}` comes before step 1:\n{stdout}");
    }
}

#[test]
fn prompt_capture_stdout_reads_the_vault_guide_before_the_first_append() {
    let out = memex(&["prompt", "capture"]);
    assert!(out.status.success(), "memex prompt capture exits 0");
    let stdout = String::from_utf8(out.stdout).expect("utf-8");
    let guide = stdout
        .find("`get_vault_guide`")
        .unwrap_or_else(|| panic!("memex prompt capture names `get_vault_guide`:\n{stdout}"));
    let append = stdout
        .find("`append_to_daily_note`")
        .expect("capture appends to the daily note");
    assert!(guide < append, "the guide is read first:\n{stdout}");
    assert!(
        stdout.contains("Vault Guide"),
        "capture says Vault Guide:\n{stdout}"
    );
}

// ---------- AC 8: unknown names ----------

#[test]
fn prompt_with_unknown_name_exits_non_zero_without_printing_a_prompt() {
    // Control: a known name succeeds, so the failures below are about the name.
    assert_prints_exactly("review", REVIEW_DAILY_NOTES);

    for args in [
        &["prompt", "bogus"][..],
        &["prompt", "Review"][..],
        &["prompt"][..],
    ] {
        let out = memex(args);
        assert!(
            !out.status.success(),
            "memex {args:?} must exit non-zero, got {:?}",
            out.status.code()
        );
        assert!(
            out.stdout.is_empty(),
            "memex {args:?} must print no prompt on stdout, got:\n{}",
            String::from_utf8_lossy(&out.stdout)
        );
    }
}
