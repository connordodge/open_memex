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
