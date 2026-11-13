//! README "Upgrading to schema V8" (WI #8, Spec #7 requirement 3, run-dir
//! architecture.md "Released-client compatibility" and ruling D22): the
//! first V8 open migrates the vault in place, and every older `memex` (the
//! v0.3.x CLI, `memex serve`, an older app's bundled memex, an older hosted
//! vault server) refuses the vault afterwards with `SchemaUnsupported`. So
//! the section says how to keep a way back, which `memex` every client must
//! use, and that every existing note starts with Agent read-only off.

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

/// Every `## ` heading, in order.
fn headings(readme: &str) -> Vec<String> {
    readme
        .lines()
        .filter(|l| l.starts_with("## "))
        .map(|l| l.trim_end().to_string())
        .collect()
}

fn v8_section() -> String {
    section(&readme(), "Upgrading to schema V8")
        .expect("README has an `## Upgrading to schema V8` section")
}

#[test]
fn readme_v8_upgrade_section_covers_backup_refusal_and_the_bundled_memex() {
    let v8 = v8_section();
    let lower = v8.to_lowercase();

    // Back up first, with `memex backup`, before installing anything.
    let backup = v8.find("`memex backup").unwrap_or_else(|| {
        panic!("the V8 section must tell the reader to run `memex backup`: {v8}")
    });
    let install = lower.find("install").expect("an install step");
    assert!(
        backup < install,
        "back up before installing the new binaries: {v8}"
    );

    // A V7 `memex` refuses a V8 vault.
    assert!(
        v8.contains("SchemaUnsupported"),
        "the section names the SchemaUnsupported refusal: {v8}"
    );
    assert!(v8.contains("V7"), "it says which memex refuses: {v8}");

    // Install the app and the CLI together; point Claude Desktop at the
    // bundled memex; a hosted vault's server is upgraded too.
    assert!(
        lower.contains("together"),
        "install the app and the CLI together: {v8}"
    );
    assert!(v8.contains("Claude Desktop"), "{v8}");
    assert!(
        lower.contains("bundled"),
        "point Claude Desktop at the bundled memex: {v8}"
    );
    assert!(
        v8.contains("memex serve"),
        "a hosted vault's `memex serve` must be the new one too: {v8}"
    );

    // Try it on a scratch vault first.
    assert!(lower.contains("scratch vault"), "{v8}");
}

#[test]
fn readme_v8_upgrade_section_says_every_note_starts_with_agent_read_only_off() {
    let v8 = v8_section();
    assert!(
        v8.contains("Agent read-only"),
        "the section uses the glossary term Agent read-only: {v8}"
    );
    let lower = v8.to_lowercase();
    assert!(
        lower.contains("every note") || lower.contains("every existing note"),
        "it says the flag applies to every note: {v8}"
    );
    assert!(lower.contains(" off"), "and that it starts off: {v8}");
    // D22: never another word for the flag.
    for banned in ["locked", "protected", "pinned"] {
        assert!(
            !lower.contains(banned),
            "the V8 section must not call the flag {banned:?}: {v8}"
        );
    }
}

#[test]
fn readme_v8_upgrade_section_follows_the_v7_one_and_the_older_sections_stay() {
    let readme = readme();
    let all = headings(&readme);
    let position = |h: &str| all.iter().position(|x| x == h);
    let v5 = position("## Upgrading to schema V5").expect("the V5 upgrade section must stay");
    let v6 = position("## Upgrading to schema V6").expect("the V6 upgrade section must stay");
    let v7 = position("## Upgrading to schema V7").expect("the V7 upgrade section must stay");
    let v8 = position("## Upgrading to schema V8")
        .expect("README has an `## Upgrading to schema V8` section");
    assert!(v5 < v6 && v6 < v7, "{all:?}");
    assert_eq!(v8, v7 + 1, "the V8 section comes right after V7: {all:?}");
    assert_eq!(
        all.iter()
            .filter(|h| *h == "## Upgrading to schema V8")
            .count(),
        1
    );
}
