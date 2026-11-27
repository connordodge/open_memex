//! WI #191 (Spec #189, requirements 21-33; ruling D2): `deploy/compose.yaml`
//! and the container docs.
//!
//! Nothing here starts a container or a Docker daemon (ruling D3). The tests
//! pin what can be checked from the files:
//!
//! - `deploy/compose.yaml`, parsed with serde_yaml for its keys and read as
//!   text for its comments.
//! - `docs/hosted-vault.md`: the NAS Docker route (published image), the NAS
//!   SSH route (its own source build), the new "Set up on Unraid" section (its
//!   compose block compared to `deploy/compose.yaml` line by line), first
//!   vault, token, embeddings and the troubleshooting entries.
//! - `docs/backups.md` "On a NAS, in Docker", `docs/releasing.md`
//!   "Docker image" and the README's `memex serve` bullet.
//!
//! The prose is reviewed by hand; the NAS and Unraid runs are MANUAL (they
//! need a real host). Helpers are copies of the `hosted_*` helpers in
//! `docs_readme.rs` (same behaviour) under a `docker_` prefix.

use std::path::{Path, PathBuf};

use regex::Regex;
use serde_yaml::{Mapping, Value};

const COMPOSE: &str = "deploy/compose.yaml";
const HOSTED_DOC: &str = "docs/hosted-vault.md";
const BACKUPS_DOC: &str = "docs/backups.md";
const RELEASING_DOC: &str = "docs/releasing.md";
const IMAGE: &str = "ghcr.io/connordodge/memex";

/// The `docker run` the NAS Docker route and the Spec (requirement 23) give.
const NAS_DOCKER_RUN: &str = "docker run -d --name memex-vault-server --restart unless-stopped \
-e TZ=Europe/London -p 7878:7878 -v /volume1/memex:/vaults \
ghcr.io/connordodge/memex:latest memex serve --root /vaults --listen 0.0.0.0:7878";

const SERVE_WITH_EMBEDDINGS: &str =
    "memex serve --root /vaults --listen 0.0.0.0:7878 --with-embeddings";

// ---------- files ----------

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn read_repo_file(rel: &str) -> String {
    let path = repo_root().join(rel);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{rel} must exist and be readable ({}): {e}", path.display()))
}

fn hosted_vault_doc() -> String {
    read_repo_file(HOSTED_DOC)
}

// ---------- markdown helpers (same behaviour as docs_readme.rs) ----------

struct DockerSection {
    level: usize,
    title: String,
    body: String,
}

/// A markdown heading (outside fenced blocks) and everything under it, down to
/// the next heading of the same or a shallower level.
fn docker_sections(md: &str) -> Vec<DockerSection> {
    let lines: Vec<&str> = md.lines().collect();
    let mut heads: Vec<(usize, String, usize)> = Vec::new();
    let mut in_fence = false;
    for (i, line) in lines.iter().enumerate() {
        if line.trim_start().starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            continue;
        }
        let hashes = line.chars().take_while(|c| *c == '#').count();
        if (1..=6).contains(&hashes) && line[hashes..].starts_with(' ') {
            heads.push((hashes, line[hashes..].trim().to_string(), i));
        }
    }
    let mut out = Vec::new();
    for (n, (level, title, start)) in heads.iter().enumerate() {
        let end = heads[n + 1..]
            .iter()
            .find(|(l, _, _)| l <= level)
            .map(|(_, _, i)| *i)
            .unwrap_or(lines.len());
        out.push(DockerSection {
            level: *level,
            title: title.clone(),
            body: lines[*start..end].join("\n"),
        });
    }
    out
}

/// The first section whose title matches `title_re` (case-insensitive).
fn docker_section(md: &str, what: &str, title_re: &str) -> DockerSection {
    let re = Regex::new(&format!("(?i){title_re}")).unwrap();
    let sections = docker_sections(md);
    let titles: Vec<String> = sections.iter().map(|s| s.title.clone()).collect();
    sections
        .into_iter()
        .find(|s| re.is_match(&s.title))
        .unwrap_or_else(|| {
            panic!("the doc has a section for {what} (a heading matching /{title_re}/): {titles:?}")
        })
}

/// `(language, body)` of every fenced code block.
fn docker_fenced_blocks(md: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut current: Option<(String, Vec<&str>)> = None;
    for line in md.lines() {
        let trimmed = line.trim_start();
        if let Some(info) = trimmed.strip_prefix("```") {
            match current.take() {
                Some((lang, body)) => out.push((lang, body.join("\n"))),
                None => current = Some((info.trim().to_lowercase(), Vec::new())),
            }
        } else if let Some((_, body)) = current.as_mut() {
            body.push(line);
        }
    }
    out
}

/// Lower-cased text with every run of whitespace collapsed to one space.
fn docker_flat_lower(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// A shell snippet as one line: `\` line continuations joined, whitespace
/// collapsed, case kept.
fn docker_one_line(text: &str) -> String {
    text.replace("\\\n", " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn docker_assert_mentions(what: &str, text: &str, needles: &[&str]) {
    let flat = docker_flat_lower(text);
    for needle in needles {
        assert!(
            flat.contains(&needle.to_lowercase()),
            "{what} mentions `{needle}`: {text}"
        );
    }
}

fn docker_assert_omits(what: &str, text: &str, needles: &[&str]) {
    let flat = docker_flat_lower(text);
    for needle in needles {
        assert!(
            !flat.contains(&needle.to_lowercase()),
            "{what} no longer mentions `{needle}`: {text}"
        );
    }
}

/// The NAS section of the hosted-vault doc (same title regex as docs_readme.rs).
fn nas_section(doc: &str) -> DockerSection {
    docker_section(doc, "a NAS (Synology or QNAP)", r"\bnas\b|synology|qnap")
}

/// The NAS section's "Run it with Docker" subsection.
fn nas_docker_route(doc: &str) -> DockerSection {
    let nas = nas_section(doc);
    docker_section(&nas.body, "the NAS Docker route", r"run it with docker")
}

/// The NAS section's "Run it over SSH" subsection.
fn nas_ssh_route(doc: &str) -> DockerSection {
    let nas = nas_section(doc);
    docker_section(&nas.body, "the NAS SSH route", r"run it over ssh")
}

fn unraid_section(doc: &str) -> DockerSection {
    docker_section(doc, "Unraid", r"unraid")
}

/// Everything the container docs say: the NAS Docker route and the Unraid
/// section, joined.
fn container_docs(doc: &str) -> String {
    format!(
        "{}\n\n{}",
        nas_docker_route(doc).body,
        unraid_section(doc).body
    )
}

// ---------- deploy/compose.yaml ----------

fn compose_text() -> String {
    read_repo_file(COMPOSE)
}

fn compose_value() -> Value {
    serde_yaml::from_str(&compose_text()).expect("deploy/compose.yaml parses as YAML")
}

fn key(name: &str) -> Value {
    Value::String(name.to_string())
}

fn services_of(compose: &Value) -> &Mapping {
    compose
        .get("services")
        .and_then(Value::as_mapping)
        .expect("the compose file has a `services` mapping")
}

fn memex_service(compose: &Value) -> &Mapping {
    services_of(compose)
        .get(key("memex"))
        .and_then(Value::as_mapping)
        .expect("the compose file defines the service `memex`")
}

fn string_list(value: Option<&Value>, what: &str) -> Vec<String> {
    value
        .and_then(Value::as_sequence)
        .unwrap_or_else(|| panic!("`{what}` is a list"))
        .iter()
        .map(|v| {
            v.as_str()
                .unwrap_or_else(|| panic!("`{what}` holds strings: {v:?}"))
                .to_string()
        })
        .collect()
}

/// The text of every YAML comment in the file.
fn compose_comments(text: &str) -> String {
    text.lines()
        .filter_map(|l| l.find('#').map(|i| l[i + 1..].trim().to_string()))
        .collect::<Vec<_>>()
        .join("\n")
}

// AC 1.
#[test]
fn compose_file_defines_the_one_memex_service_with_image_restart_tz_port_and_volume() {
    let compose = compose_value();
    let services = services_of(&compose);
    let names: Vec<&str> = services.keys().filter_map(Value::as_str).collect();
    assert_eq!(names, vec!["memex"], "exactly one service, named `memex`");
    let memex = memex_service(&compose);
    assert_eq!(
        memex.get(key("image")).and_then(Value::as_str),
        Some("ghcr.io/connordodge/memex:latest")
    );
    assert_eq!(
        memex.get(key("container_name")).and_then(Value::as_str),
        Some("memex")
    );
    assert_eq!(
        memex.get(key("restart")).and_then(Value::as_str),
        Some("unless-stopped")
    );
    let env = memex
        .get(key("environment"))
        .and_then(Value::as_mapping)
        .expect("`environment` is a mapping");
    assert_eq!(env.len(), 1, "the only variable is TZ: {env:?}");
    assert_eq!(
        env.get(key("TZ")).and_then(Value::as_str),
        Some("Europe/London")
    );
    assert_eq!(
        string_list(memex.get(key("ports")), "ports"),
        vec!["7878:7878"]
    );
    assert_eq!(
        string_list(memex.get(key("volumes")), "volumes"),
        vec!["./vaults:/vaults"]
    );
    // Nothing else: the service has exactly these six keys.
    let mut keys: Vec<&str> = memex.keys().filter_map(Value::as_str).collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        vec![
            "container_name",
            "environment",
            "image",
            "ports",
            "restart",
            "volumes"
        ]
    );
}

// AC 2.
#[test]
fn compose_file_memex_service_has_no_user_build_command_healthcheck_or_access_token() {
    let compose = compose_value();
    let memex = memex_service(&compose);
    for absent in ["user", "build", "command", "healthcheck", "entrypoint"] {
        assert!(
            !memex.contains_key(key(absent)),
            "the memex service has no `{absent}` key"
        );
    }
    let text = compose_text();
    assert!(
        !text.contains("MEMEX_ACCESS_TOKEN"),
        "the compose file never sets or names MEMEX_ACCESS_TOKEN"
    );
    // The image default (1000:1000, serve --root /vaults) applies, so no
    // top-level key adds a build, a volume or a network either.
    let top: Vec<&str> = compose
        .as_mapping()
        .unwrap()
        .keys()
        .filter_map(Value::as_str)
        .collect();
    assert_eq!(top, vec!["services"], "the file holds only `services`");
}

// AC 3.
#[test]
fn compose_file_comments_say_to_set_tz_chown_the_folder_and_enable_embeddings() {
    let text = compose_text();
    let comments = compose_comments(&text);
    let flat = docker_flat_lower(&comments);
    assert!(
        flat.contains("time zone") || Regex::new(r"\btz\b").unwrap().is_match(&flat),
        "a comment says to set your own time zone (TZ): {comments}"
    );
    assert!(
        flat.contains("your own") || flat.contains("your"),
        "the TZ comment is addressed to the reader: {comments}"
    );
    docker_assert_mentions(
        "the compose comments",
        &comments,
        &["./vaults", "1000:1000", "before the first start", "user:"],
    );
    assert!(
        Regex::new(r"owned|owner|chown").unwrap().is_match(&flat),
        "a comment says who must own ./vaults: {comments}"
    );
    assert!(
        Regex::new(r"permission denied|root")
            .unwrap()
            .is_match(&flat),
        "a comment says why (Docker creates a missing bind folder as root): {comments}"
    );
    assert!(
        comments
            .lines()
            .any(|l| docker_one_line(l).contains(&format!("command: {SERVE_WITH_EMBEDDINGS}"))),
        "a comment gives `command: {SERVE_WITH_EMBEDDINGS}`: {comments}"
    );
    docker_assert_mentions("the compose comments", &comments, &["embeddings"]);
}

/// Every file under `dir`, skipping build output, dependency and VCS dirs.
fn docker_walk(dir: &Path, out: &mut Vec<PathBuf>) {
    const SKIP: [&str; 10] = [
        ".git",
        "target",
        "node_modules",
        "build",
        ".dart_tool",
        "Pods",
        "ephemeral",
        ".symlinks",
        ".claude",
        "worktrees",
    ];
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !SKIP.contains(&name.as_str()) {
                docker_walk(&path, out);
            }
        } else if kind.is_file() {
            out.push(path);
        }
    }
}

// AC 4.
#[test]
fn repository_has_no_root_compose_file_env_example_or_unraid_template() {
    let root = repo_root();
    for rel in [
        "compose.yaml",
        "compose.yml",
        "docker-compose.yml",
        "docker-compose.yaml",
        ".env.example",
        ".env.sample",
    ] {
        assert!(!root.join(rel).exists(), "no root-level `{rel}` ships");
    }
    let mut files = Vec::new();
    docker_walk(&root, &mut files);
    assert!(files.len() > 50, "the walk reaches the repository's files");
    let offenders: Vec<String> = files
        .iter()
        .filter(|p| {
            let name = p.file_name().unwrap().to_string_lossy().to_lowercase();
            let rel = p
                .strip_prefix(&root)
                .unwrap()
                .to_string_lossy()
                .to_lowercase();
            let unraid_template = name.ends_with(".xml")
                && (rel.contains("unraid")
                    || std::fs::read_to_string(p)
                        .map(|t| t.contains("<Container ") && t.contains("<Repository>"))
                        .unwrap_or(false));
            name.starts_with(".env.example") || unraid_template || rel.contains("community-app")
        })
        .map(|p| p.strip_prefix(&root).unwrap().display().to_string())
        .collect();
    assert!(
        offenders.is_empty(),
        "no .env.example and no Unraid Community Applications template: {offenders:?}"
    );
    // deploy/ holds the one compose file and nothing else.
    let mut deploy: Vec<String> = std::fs::read_dir(root.join("deploy"))
        .expect("deploy/ exists")
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    deploy.sort();
    assert_eq!(
        deploy,
        vec!["compose.yaml"],
        "deploy/ holds only compose.yaml"
    );
}

// ---------- docs/hosted-vault.md: the NAS routes ----------

// AC 5.
#[test]
fn hosted_nas_docker_route_creates_the_owned_folder_and_runs_the_published_image() {
    let doc = hosted_vault_doc();
    let nas = nas_section(&doc);
    // The existing docs_readme.rs test reads the FIRST NAS block that mentions
    // docker: it must be this one (it needs TZ, serve, --root and --listen).
    let block = docker_fenced_blocks(&nas.body)
        .into_iter()
        .map(|(_, b)| b)
        .find(|b| b.to_lowercase().contains("docker"))
        .expect("the NAS section has a block that mentions docker");
    let one = docker_one_line(&block);
    assert!(
        one.contains("mkdir -p /volume1/memex"),
        "the first Docker block creates /volume1/memex: {block}"
    );
    assert!(
        one.contains("chown 1000:1000 /volume1/memex"),
        "the first Docker block gives /volume1/memex to 1000:1000: {block}"
    );
    assert!(
        one.contains(NAS_DOCKER_RUN),
        "the first Docker block runs `{NAS_DOCKER_RUN}`: {block}"
    );
    // That block is in the Docker route.
    let route = nas_docker_route(&doc);
    assert!(
        docker_one_line(&route.body).contains(NAS_DOCKER_RUN),
        "the Docker route holds that docker run"
    );
}

// AC 6.
#[test]
fn hosted_nas_docker_route_drops_the_source_build_and_names_the_first_image_release() {
    let doc = hosted_vault_doc();
    let route = nas_docker_route(&doc);
    docker_assert_omits(
        "the NAS Docker route",
        &route.body,
        &[
            "git clone",
            "rust:1-bookworm",
            "cargo build",
            "/usr/local/bin/memex:ro",
            "memex-bin",
            "debian:bookworm-slim",
            "missing shared library",
            "shared library",
            "no published",
        ],
    );
    docker_assert_mentions("the NAS Docker route", &route.body, &[IMAGE, "0.7.0"]);
    // The section's opening no longer says there is no image and both routes
    // build the binary.
    let nas = nas_section(&doc);
    let intro = nas.body.split("\n### ").next().unwrap();
    docker_assert_omits(
        "the NAS section's introduction",
        intro,
        &["no published", "both routes start by building"],
    );
}

// AC 7.
#[test]
fn hosted_nas_ssh_route_spells_out_its_own_build_and_the_token_text_drops_sudo_for_docker() {
    let doc = hosted_vault_doc();
    let ssh = nas_ssh_route(&doc);
    let one = docker_one_line(&ssh.body);
    assert!(
        one.contains("cargo build --release -p memex-mcp"),
        "the SSH route builds with `cargo build --release -p memex-mcp`: {}",
        ssh.body
    );
    docker_assert_mentions(
        "the SSH route",
        &ssh.body,
        &["rust:1-trixie", "linux machine", "processor", "glibc 2.38"],
    );
    docker_assert_omits("the SSH route", &ssh.body, &["the same way"]);
    // The token text: the path stays, the Docker-needs-sudo claim goes.
    docker_assert_mentions(
        "the SSH route",
        &ssh.body,
        &["/volume1/memex/.memex/access-token"],
    );
    let nas = nas_section(&doc);
    docker_assert_omits(
        "the NAS section",
        &nas.body,
        &["sudo cat", "docker route runs as root"],
    );
    // The first Docker block is unchanged in kind: still before the SSH route.
    let nas_flat = &nas.body;
    let docker_pos = nas_flat.find("### Run it with Docker").unwrap();
    let ssh_pos = nas_flat.find("### Run it over SSH").unwrap();
    assert!(docker_pos < ssh_pos, "the Docker route comes before SSH");
}

// ---------- docs/hosted-vault.md: Unraid ----------

// AC 8 (placement).
#[test]
fn hosted_unraid_section_sits_between_the_nas_and_linux_sections() {
    let doc = hosted_vault_doc();
    let sections = docker_sections(&doc);
    let pos = |re: &str| {
        let re = Regex::new(&format!("(?i){re}")).unwrap();
        sections
            .iter()
            .position(|s| s.level == 2 && re.is_match(&s.title))
    };
    let nas = pos(r"\bnas\b|synology|qnap").expect("a NAS section");
    let unraid = pos(r"unraid").expect("an Unraid section");
    let linux = pos(r"linux|systemd").expect("a Linux section");
    assert!(
        nas < unraid && unraid < linux,
        "Unraid sits between NAS and Linux: {nas} {unraid} {linux}"
    );
    let title = &sections[unraid].title;
    assert!(
        title.to_lowercase().contains("set up on unraid"),
        "the heading is `Set up on Unraid`: {title}"
    );
    // docs_readme.rs finds the platform sections by the first heading that
    // matches each regex; the Unraid heading must not take their place.
    for re in [
        r"\bnas\b|synology|qnap",
        r"linux|systemd",
        r"\bmac\b|launchd",
    ] {
        assert!(
            !Regex::new(&format!("(?i){re}")).unwrap().is_match(title),
            "the Unraid heading `{title}` does not match /{re}/"
        );
    }
}

/// The Unraid section's compose block: the YAML block that has `services:`.
fn unraid_compose_block(doc: &str) -> String {
    let unraid = unraid_section(doc);
    let blocks: Vec<String> = docker_fenced_blocks(&unraid.body)
        .into_iter()
        .filter(|(lang, b)| matches!(lang.as_str(), "yaml" | "yml") && b.contains("services:"))
        .map(|(_, b)| b)
        .collect();
    assert_eq!(
        blocks.len(),
        1,
        "the Unraid section has one yaml compose block: {blocks:?}"
    );
    blocks.into_iter().next().unwrap()
}

fn trimmed_lines(text: &str) -> Vec<String> {
    let mut lines: Vec<String> = text.lines().map(|l| l.trim_end().to_string()).collect();
    while lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    while lines.first().is_some_and(|l| l.is_empty()) {
        lines.remove(0);
    }
    lines
}

// AC 8 (content).
#[test]
fn hosted_unraid_compose_block_equals_the_compose_file_but_for_the_user_line_and_the_volume() {
    let doc = hosted_vault_doc();
    let block = unraid_compose_block(&doc);
    let file = compose_text();

    // Line by line: take the doc's block, drop the one added `user` line and
    // put the volume back, and it is the file.
    let user_lines = block
        .lines()
        .filter(|l| l.trim() == r#"user: "99:100""#)
        .count();
    assert_eq!(
        user_lines, 1,
        "exactly one `user: \"99:100\"` line:\n{block}"
    );
    let unraid_volume = "- /mnt/cache/appdata/memex:/vaults";
    let volume_lines = block.lines().filter(|l| l.trim() == unraid_volume).count();
    assert_eq!(volume_lines, 1, "exactly one Unraid volume line:\n{block}");
    let restored: Vec<String> = block
        .lines()
        .filter(|l| l.trim() != r#"user: "99:100""#)
        .map(|l| {
            if l.trim() == unraid_volume {
                let indent = &l[..l.len() - l.trim_start().len()];
                format!("{indent}- ./vaults:/vaults")
            } else {
                l.to_string()
            }
        })
        .collect();
    assert_eq!(
        trimmed_lines(&restored.join("\n")),
        trimmed_lines(&file),
        "the Unraid block is deploy/compose.yaml with two lines changed"
    );
    // The file side has exactly one volume line to change.
    assert_eq!(
        file.lines()
            .filter(|l| l.trim() == "- ./vaults:/vaults")
            .count(),
        1
    );

    // And as YAML: the same service, `user` added and the volume replaced.
    let doc_yaml: Value = serde_yaml::from_str(&block).expect("the Unraid block parses");
    let mut expected = compose_value();
    let service = expected
        .get_mut("services")
        .and_then(|s| s.get_mut("memex"))
        .and_then(Value::as_mapping_mut)
        .unwrap();
    service.insert(key("user"), key("99:100"));
    service.insert(
        key("volumes"),
        Value::Sequence(vec![key("/mnt/cache/appdata/memex:/vaults")]),
    );
    assert_eq!(doc_yaml, expected);
}

// AC 9.
#[test]
fn hosted_unraid_section_gives_the_mkdir_chown_start_token_and_raw_compose_link() {
    let doc = hosted_vault_doc();
    let unraid = unraid_section(&doc);
    let blocks: Vec<String> = docker_fenced_blocks(&unraid.body)
        .into_iter()
        .map(|(_, b)| docker_one_line(&b))
        .collect();
    let in_a_block = |needle: &str| blocks.iter().any(|b| b.contains(needle));
    assert!(
        in_a_block("mkdir -p /mnt/cache/appdata/memex && chown 99:100 /mnt/cache/appdata/memex"),
        "a block runs `mkdir -p … && chown 99:100 …`: {blocks:?}"
    );
    assert!(
        in_a_block("docker compose up -d"),
        "a block runs `docker compose up -d`: {blocks:?}"
    );
    assert!(
        in_a_block("cat /mnt/cache/appdata/memex/.memex/access-token"),
        "a block reads the token: {blocks:?}"
    );
    docker_assert_mentions("the Unraid section", &unraid.body, &["Compose Manager"]);
    let raw = Regex::new(
        r"\]\(https://raw\.githubusercontent\.com/connordodge/open_memex/[^/\s)]+/deploy/compose\.yaml\)",
    )
    .unwrap();
    assert!(
        raw.is_match(&unraid.body),
        "the Unraid section links the raw deploy/compose.yaml"
    );
}

// AC 10.
#[test]
fn hosted_unraid_section_explains_the_pool_name_exclusive_share_and_the_network_filesystem_refusal()
{
    let doc = hosted_vault_doc();
    let unraid = unraid_section(&doc);
    docker_assert_mentions(
        "the Unraid section",
        &unraid.body,
        &[
            "/mnt/<pool>/appdata/memex",
            "pool",
            "/mnt/user/appdata/memex",
            "Exclusive share",
            "6.12",
            "network_filesystem",
            "shfs",
            "FUSE",
        ],
    );
    let flat = docker_flat_lower(&unraid.body);
    assert!(
        Regex::new(r"never[^.]*\barray\b[^.]*user share|never[^.]*user share[^.]*\barray\b")
            .unwrap()
            .is_match(&flat),
        "the Unraid section says never to use an array or user share: {flat}"
    );
}

// ---------- docs/hosted-vault.md: first vault, token, embeddings ----------

// AC 11.
#[test]
fn container_docs_start_on_an_empty_folder_and_show_the_optional_cli_init() {
    let doc = hosted_vault_doc();
    for (what, body) in [
        ("the NAS Docker route", nas_docker_route(&doc).body),
        ("the Unraid section", unraid_section(&doc).body),
    ] {
        let flat = docker_flat_lower(&body);
        assert!(
            flat.contains("empty folder"),
            "{what} starts the server on an empty folder: {flat}"
        );
        assert!(
            flat.contains("first vault") && flat.contains("app"),
            "{what} creates the first vault from the app: {flat}"
        );
        assert!(
            flat.contains("optional"),
            "{what} offers the CLI init as optional: {flat}"
        );
    }
    let unraid_blocks: Vec<String> = docker_fenced_blocks(&unraid_section(&doc).body)
        .into_iter()
        .map(|(_, b)| docker_one_line(&b))
        .collect();
    assert!(
        unraid_blocks
            .iter()
            .any(|b| b.contains("docker compose run --rm memex memex init /vaults/home")),
        "the Unraid section shows the compose init: {unraid_blocks:?}"
    );
    let nas_blocks: Vec<String> = docker_fenced_blocks(&nas_docker_route(&doc).body)
        .into_iter()
        .map(|(_, b)| docker_one_line(&b))
        .collect();
    assert!(
        nas_blocks.iter().any(|b| b.contains(
            "docker run --rm -v /volume1/memex:/vaults ghcr.io/connordodge/memex:latest memex init /vaults/home"
        )),
        "the NAS Docker route shows the docker run init: {nas_blocks:?}"
    );
    // docs_readme.rs reads the FIRST docker block of the NAS section: the init
    // example, which has no `serve`, must not come before the run example.
    let nas = nas_section(&doc);
    let first = docker_fenced_blocks(&nas.body)
        .into_iter()
        .map(|(_, b)| b)
        .find(|b| b.to_lowercase().contains("docker"))
        .unwrap();
    assert!(
        first.contains("memex serve"),
        "the first NAS Docker block runs the server: {first}"
    );
}

// AC 12.
#[test]
fn container_docs_set_no_access_token_and_give_the_host_path_and_the_docker_logs_line() {
    let doc = hosted_vault_doc();
    for (what, body) in [
        ("the NAS Docker route", nas_docker_route(&doc).body),
        ("the Unraid section", unraid_section(&doc).body),
    ] {
        for (_, block) in docker_fenced_blocks(&body) {
            assert!(
                !block.contains("MEMEX_ACCESS_TOKEN"),
                "{what} sets no MEMEX_ACCESS_TOKEN:\n{block}"
            );
        }
    }
    docker_assert_mentions(
        "the NAS Docker route",
        &nas_docker_route(&doc).body,
        &["/volume1/memex/.memex/access-token"],
    );
    let container = container_docs(&doc);
    docker_assert_mentions(
        "the container docs",
        &container,
        &[
            "docker logs",
            "memex serve: generated a new access token in /vaults/.memex/access-token",
        ],
    );
}

// AC 13.
#[test]
fn container_docs_show_with_embeddings_in_both_forms_and_the_first_start_download() {
    let doc = hosted_vault_doc();
    let container = container_docs(&doc);
    let blocks: Vec<String> = docker_fenced_blocks(&container)
        .into_iter()
        .map(|(_, b)| docker_one_line(&b))
        .collect();
    assert!(
        blocks
            .iter()
            .any(|b| b.contains(&format!("command: {SERVE_WITH_EMBEDDINGS}"))),
        "a block shows the compose `command: {SERVE_WITH_EMBEDDINGS}`: {blocks:?}"
    );
    assert!(
        blocks.iter().any(|b| b.contains("docker run")
            && b.contains(IMAGE)
            && b.contains("memex serve --root /vaults --listen 0.0.0.0:7878 --with-embeddings")),
        "a block shows the docker run form with --with-embeddings: {blocks:?}"
    );
    docker_assert_mentions(
        "the container docs",
        &container,
        &["internet", "130 MB", "<root>/.memex/models"],
    );
}

// AC 14.
#[test]
fn hosted_troubleshooting_has_permission_denied_on_first_start_and_the_unraid_user_note() {
    let doc = hosted_vault_doc();
    let trouble = docker_section(&doc, "troubleshooting", r"troubleshoot");
    let perm = docker_section(
        &trouble.body,
        "permission denied on first start",
        r"permission denied on first start",
    );
    assert_eq!(perm.level, 3, "it is an entry under Troubleshooting");
    docker_assert_mentions(
        "the permission entry",
        &perm.body,
        &["owner", "1000:1000", "99:100", "chown", "user:"],
    );
    let net = docker_section(
        &trouble.body,
        "network drive refusal",
        r"network drive refusal",
    );
    docker_assert_mentions(
        "Network drive refusal",
        &net.body,
        &["unraid", "/mnt/user", "network_filesystem"],
    );
    // The existing entry text stays.
    docker_assert_mentions("Network drive refusal", &net.body, &["memex vault check"]);
}

// ---------- docs/backups.md, releasing.md, README.md ----------

// AC 15.
#[test]
fn backups_nas_docker_runs_the_published_image_with_the_vaults_mount_and_backup_dir() {
    let doc = read_repo_file(BACKUPS_DOC);
    let section = docker_section(&doc, "NAS Docker backups", r"on a nas, in docker");
    let blocks: Vec<String> = docker_fenced_blocks(&section.body)
        .into_iter()
        .map(|(_, b)| docker_one_line(&b))
        .collect();
    assert!(
        blocks.iter().any(|b| b.contains(
            "-v /volume1/memex:/vaults ghcr.io/connordodge/memex:latest memex serve --root /vaults --listen 0.0.0.0:7878 --backup-dir /vaults/.backups --backup-keep 30"
        )),
        "the docker run uses the image, /vaults and --backup-dir /vaults/.backups: {blocks:?}"
    );
    assert!(
        blocks
            .iter()
            .any(|b| b.contains("mkdir -p /volume1/memex/.backups")),
        "the folder is created on the NAS: {blocks:?}"
    );
    let joined = blocks.join("\n");
    for stale in ["/data", "debian:bookworm-slim", "memex-bin", ":ro"] {
        assert!(
            !joined.contains(stale),
            "the Docker backup example no longer has `{stale}`: {joined}"
        );
    }
    docker_assert_omits("the prose", &section.body, &["mounted at `/data`"]);
    docker_assert_mentions(
        "the prose",
        &section.body,
        &[
            "mounted at `/vaults`",
            "/vaults/.backups",
            "/volume1/memex/.backups",
            "1000:1000",
        ],
    );
    // The second-disk example still mounts at /backups.
    docker_assert_mentions(
        "the second-disk example",
        &section.body,
        &[
            "-v /volume2/memex-backups:/backups",
            "--backup-dir /backups",
        ],
    );
}

// AC 16.
#[test]
fn releasing_doc_has_a_docker_image_section_for_the_publish_rerun_and_package_visibility() {
    let doc = read_repo_file(RELEASING_DOC);
    let section = docker_section(&doc, "the Docker image", r"^docker image$");
    assert_eq!(section.level, 2, "`## Docker image` is a top-level section");
    docker_assert_mentions(
        "the Docker image section",
        &section.body,
        &[
            "docker.yml",
            "ghcr.io/connordodge/memex:<x.y.z>",
            ":<x.y>",
            ":latest",
            "Re-run jobs",
            "Public",
            "package",
            "linked",
        ],
    );
    let flat = docker_flat_lower(&section.body);
    assert!(
        Regex::new(r"backwards?").unwrap().is_match(&flat),
        "it says <x.y> and latest never move backwards: {flat}"
    );
    assert!(
        Regex::new(r"never[^.]*re-?runn?ing[^.]*release")
            .unwrap()
            .is_match(&flat),
        "it says never to fix a failed publish by re-running the Release: {flat}"
    );
    // The every-release steps point at the same trigger.
    let every = docker_section(&doc, "every release", r"^every release$");
    docker_assert_mentions("Every release", &every.body, &["docker.yml"]);
}

// AC 17.
#[test]
fn readme_serve_bullet_names_the_image_for_a_nas_or_unraid() {
    let readme = read_repo_file("README.md");
    let bullet = readme
        .lines()
        .find(|l| l.trim_start().starts_with("- `memex serve --root"))
        .expect("the README has the `memex serve --root` bullet");
    docker_assert_mentions(
        "the README's serve bullet",
        bullet,
        &[
            "docs/hosted-vault.md",
            "Docker image",
            IMAGE,
            "NAS",
            "Unraid",
        ],
    );
    docker_assert_mentions(
        "the README's serve bullet",
        bullet,
        &["always-on Mac", "Linux"],
    );
}

// ---------- D7: invented paths only ----------

#[test]
fn container_files_and_docs_use_invented_paths_never_a_home_directory() {
    let doc = hosted_vault_doc();
    let backups = read_repo_file(BACKUPS_DOC);
    let backups_docker = docker_section(&backups, "NAS Docker backups", r"on a nas, in docker");
    let releasing = read_repo_file(RELEASING_DOC);
    let releasing_docker = docker_section(&releasing, "the Docker image", r"^docker image$");
    let texts = [
        (COMPOSE.to_string(), compose_text()),
        (
            "the NAS Docker route".to_string(),
            nas_docker_route(&doc).body,
        ),
        ("the Unraid section".to_string(), unraid_section(&doc).body),
        (
            "the backups Docker section".to_string(),
            backups_docker.body,
        ),
        (
            "the releasing Docker section".to_string(),
            releasing_docker.body,
        ),
    ];
    let home = Regex::new(r"/Users/[A-Za-z0-9_.-]+|/home/[A-Za-z0-9_.-]+").unwrap();
    for (what, text) in texts {
        if let Some(m) = home.find(&text) {
            panic!("{what} names a home path `{}`", m.as_str());
        }
    }
}
