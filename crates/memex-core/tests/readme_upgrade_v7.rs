//! README "Upgrading to schema V7" (WI #415, Spec #391 requirement 3, run-dir
//! architecture.md "Released-client compatibility"): the first V7 open
//! migrates the vault in place and rechunks every note, and a V6 `memex`
//! refuses the vault afterwards, so the section must say how to keep a way
//! back and which `memex` every client must use.

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

#[test]
fn readme_v7_upgrade_section_covers_backup_refusal_bundled_memex_and_rechunk() {
    let readme = readme();
    let v7 = section(&readme, "Upgrading to schema V7")
        .expect("README has an `## Upgrading to schema V7` section");
    let lower = v7.to_lowercase();

    // Back up first, with `memex backup`.
    let backup = v7.find("`memex backup").unwrap_or_else(|| {
        panic!("the V7 section must tell the reader to run `memex backup`: {v7}")
    });

    // A V6 `memex` (Claude Desktop's, say) refuses a V7 vault.
    assert!(
        v7.contains("SchemaUnsupported"),
        "the section names the SchemaUnsupported refusal: {v7}"
    );
    assert!(v7.contains("V6"), "it says which memex refuses: {v7}");
    assert!(v7.contains("Claude Desktop"), "{v7}");

    // Install the app and the CLI together; point Claude Desktop at the
    // bundled memex.
    assert!(
        lower.contains("together"),
        "install the app and the CLI together: {v7}"
    );
    assert!(lower.contains("cli"), "{v7}");
    assert!(
        lower.contains("bundled"),
        "point Claude Desktop at the bundled memex: {v7}"
    );
    let install = lower.find("install").expect("an install step");
    assert!(
        backup < install,
        "back up before installing the new binaries: {v7}"
    );

    // Try it on a scratch vault first.
    assert!(lower.contains("scratch vault"), "{v7}");

    // The first open rechunks every note; the backfill rebuilds the vectors.
    assert!(lower.contains("rechunk"), "the first open rechunks: {v7}");
    assert!(lower.contains("every note"), "{v7}");
    assert!(lower.contains("backfill"), "{v7}");
    assert!(lower.contains("vector"), "{v7}");
}

#[test]
fn readme_v7_upgrade_section_follows_the_v6_one_and_the_older_sections_stay() {
    let readme = readme();
    let all = headings(&readme);
    let v5 = all
        .iter()
        .position(|h| h == "## Upgrading to schema V5")
        .expect("the V5 upgrade section must stay");
    let v6 = all
        .iter()
        .position(|h| h == "## Upgrading to schema V6")
        .expect("the V6 upgrade section must stay");
    let v7 = all
        .iter()
        .position(|h| h == "## Upgrading to schema V7")
        .expect("README has an `## Upgrading to schema V7` section");
    assert!(v5 < v6, "{all:?}");
    assert_eq!(v7, v6 + 1, "the V7 section comes right after V6: {all:?}");
    assert_eq!(
        all.iter()
            .filter(|h| *h == "## Upgrading to schema V7")
            .count(),
        1
    );
}
