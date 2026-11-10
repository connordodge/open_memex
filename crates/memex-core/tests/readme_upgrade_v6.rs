//! README "Upgrading to schema V6" (WI #237, Spec #234 R52, run-dir
//! architecture.md "Released-client compatibility"): the first V6 open
//! migrates the vault in place and an older `memex` refuses it afterwards, so
//! the section must say how to keep a way back and what must be quit first.

use std::path::Path;

fn readme() -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../README.md");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The body of the `## <heading>` section, up to the next `## ` heading.
fn section(readme: &str, heading: &str) -> Option<String> {
    let start = readme
        .lines()
        .position(|l| l.trim_end() == format!("## {heading}"))?;
    let body: Vec<&str> = readme
        .lines()
        .skip(start + 1)
        .take_while(|l| !l.starts_with("## "))
        .collect();
    Some(body.join("\n"))
}

#[test]
fn readme_upgrading_to_schema_v6_states_backup_scratch_vault_and_quitting_clients() {
    let readme = readme();
    let v6 = section(&readme, "Upgrading to schema V6")
        .expect("README has an `## Upgrading to schema V6` section");
    let lower = v6.to_lowercase();

    // Back up with `memex backup` (Spec #315 req 38), not by copying the
    // three database files by hand.
    assert!(
        v6.contains("`memex backup"),
        "the V6 section must tell the reader to run `memex backup`: {v6}"
    );
    for file in ["memex.db-wal", "memex.db-shm"] {
        assert!(
            !v6.contains(file),
            "the V6 section no longer lists the manual copy of {file}: {v6}"
        );
    }
    // Try a scratch vault first.
    assert!(lower.contains("scratch vault"), "{v6}");
    // Quit every MCP client and `memex serve` before the first V6 open.
    assert!(lower.contains("quit"), "{v6}");
    assert!(lower.contains("mcp client"), "{v6}");
    assert!(v6.contains("`memex serve`"), "{v6}");
    assert!(
        lower.contains("before") && lower.contains("first"),
        "the section must say to quit before the first V6 open: {v6}"
    );
    // The order: quit, then back up, then install the new `memex` (the first
    // thing that opens the vault with it).
    let quit = lower.find("quit").expect("quit");
    let backup = v6.find("`memex backup").expect("memex backup");
    let install = v6.find("cargo install").expect("the install step");
    assert!(
        quit < backup && backup < install,
        "quit clients, then `memex backup`, then install the new binary: {v6}"
    );

    // The V5 section stays.
    assert!(
        section(&readme, "Upgrading to schema V5").is_some(),
        "the V5 upgrade section must stay"
    );
}
