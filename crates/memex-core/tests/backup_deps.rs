//! WI #316 (R0, ruling D2): the backup dependencies. rusqlite gains its
//! `backup` feature, the workspace gains `zip` (deflate only) and `sha2`
//! 0.10, memex-core depends on zip, sha2 and tempfile; the lock test pins what zip pulls in.

use std::collections::BTreeSet;
use std::path::Path;

fn read(rel: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(rel);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The `name = …` lines of one `[section]` of a Cargo.toml, as
/// (name, rest of the line). Continuation lines (indented) are skipped.
fn section(toml: &str, name: &str) -> Vec<(String, String)> {
    let header = format!("[{name}]");
    let mut out = Vec::new();
    let mut inside = false;
    for line in toml.lines() {
        if line.starts_with('[') {
            inside = line.trim() == header;
            continue;
        }
        if !inside || line.starts_with(' ') || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            out.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    out
}

fn names(entries: &[(String, String)]) -> BTreeSet<String> {
    entries.iter().map(|(k, _)| k.clone()).collect()
}

fn line_of<'a>(entries: &'a [(String, String)], name: &str) -> &'a str {
    entries
        .iter()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.as_str())
        .unwrap_or_else(|| panic!("no `{name}` entry in {entries:?}"))
}

#[test]
fn workspace_adds_the_rusqlite_backup_feature_zip_deflate_only_and_sha2_0_10() {
    let ws = section(&read("../../Cargo.toml"), "workspace.dependencies");

    let rusqlite = line_of(&ws, "rusqlite");
    for feature in [
        "\"bundled\"",
        "\"load_extension\"",
        "\"vtab\"",
        "\"blob\"",
        "\"backup\"",
    ] {
        assert!(
            rusqlite.contains(feature),
            "rusqlite features keep {feature}: {rusqlite}"
        );
    }
    assert!(
        rusqlite.contains("\"0.39\""),
        "rusqlite stays 0.39: {rusqlite}"
    );

    let zip = line_of(&ws, "zip").replace(' ', "");
    assert!(zip.contains("default-features=false"), "zip: {zip}");
    assert!(
        zip.contains("features=[\"deflate\"]"),
        "zip features are deflate only: {zip}"
    );

    assert_eq!(line_of(&ws, "sha2"), "\"0.10\"");
}

#[test]
fn memex_core_depends_on_zip_sha2_and_tempfile_from_the_workspace() {
    let ws = section(&read("../../Cargo.toml"), "workspace.dependencies");
    for dep in ["zip", "sha2", "tempfile"] {
        assert!(
            names(&ws).contains(dep),
            "[workspace.dependencies] has {dep}"
        );
    }

    let core = section(&read("Cargo.toml"), "dependencies");
    for dep in ["zip", "sha2", "tempfile"] {
        assert!(
            line_of(&core, dep)
                .replace(' ', "")
                .contains("workspace=true"),
            "memex-core takes {dep} from the workspace: {}",
            line_of(&core, dep)
        );
    }
}

/// `[[package]]` entries of Cargo.lock as (name, version, dependency names).
fn lock_packages() -> Vec<(String, String, Vec<String>)> {
    read("../../Cargo.lock")
        .split("[[package]]")
        .skip(1)
        .map(|block| {
            let field = |key: &str| {
                block
                    .lines()
                    .find_map(|l| l.strip_prefix(&format!("{key} = \"")))
                    .map(|v| v.trim_end_matches('"').to_string())
                    .unwrap_or_default()
            };
            let deps = block
                .split_once("dependencies = [")
                .map(|(_, rest)| {
                    rest.split(']')
                        .next()
                        .unwrap_or("")
                        .lines()
                        .filter_map(|l| {
                            let l = l.trim().trim_end_matches(',').trim_matches('"');
                            l.split_whitespace().next().map(str::to_string)
                        })
                        .collect()
                })
                .unwrap_or_default();
            (field("name"), field("version"), deps)
        })
        .collect()
}

#[test]
fn cargo_lock_resolves_sha2_0_10_and_a_zip_without_other_codecs() {
    let pkgs = lock_packages();
    let core = pkgs
        .iter()
        .find(|(n, _, _)| n == "memex-core")
        .expect("memex-core in Cargo.lock");
    for dep in ["zip", "sha2", "tempfile"] {
        assert!(
            core.2.iter().any(|d| d == dep),
            "memex-core depends on {dep}: {:?}",
            core.2
        );
    }

    let sha2: Vec<&str> = pkgs
        .iter()
        .filter(|(n, _, _)| n == "sha2")
        .map(|(_, v, _)| v.as_str())
        .collect();
    assert!(
        !sha2.is_empty() && sha2.iter().all(|v| v.starts_with("0.10.")),
        "sha2 resolves to 0.10.x: {sha2:?}"
    );

    let zips: Vec<&(String, String, Vec<String>)> =
        pkgs.iter().filter(|(n, _, _)| n == "zip").collect();
    assert_eq!(zips.len(), 1, "one zip in the lock");
    let zip_deps = &zips[0].2;
    assert!(
        zip_deps.iter().any(|d| d == "flate2"),
        "zip has deflate (flate2): {zip_deps:?}"
    );
    for codec in [
        "aes",
        "bzip2",
        "zstd",
        "lzma-rs",
        "xz2",
        "deflate64",
        "pbkdf2",
        "hmac",
        "time",
    ] {
        assert!(
            !zip_deps.iter().any(|d| d == codec),
            "zip is built without default features ({codec} pulled in): {zip_deps:?}"
        );
    }
}
