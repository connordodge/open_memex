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

    // Back up all three database files.
    assert!(lower.contains("back up"), "{v6}");
    for file in ["`memex.db`", "`memex.db-wal`", "`memex.db-shm`"] {
        assert!(v6.contains(file), "the V6 section must name {file}: {v6}");
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

    // The V5 section stays.
    assert!(
        section(&readme, "Upgrading to schema V5").is_some(),
        "the V5 upgrade section must stay"
    );
}
