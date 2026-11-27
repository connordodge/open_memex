//! WI #190 (Spec #189, ruling D2): the Docker image, its scripts and
//! `.github/workflows/docker.yml`.
//!
//! Nothing here starts a container or a Docker daemon (ruling D3): the image
//! build and the smoke run are proven by docker.yml's PR job on GitHub. These
//! tests pin the rest:
//!
//! - `Dockerfile` and `.dockerignore`, parsed into instructions and stages.
//! - `scripts/docker/image-tags.sh`, run under `/bin/bash` (3.2 on macOS) in a
//!   temp git repo with fabricated `v*` tags, an isolated git config and no
//!   network.
//! - `scripts/docker/smoke-test.sh`: its usage error path (with a recording
//!   `docker` on PATH), the text of every check Spec requirement 19 lists, and
//!   a run of the real script against scripted `docker`, `curl`, `sudo` and
//!   `date` fakes on PATH: a passing image, and one broken image per check.
//! - `docker.yml`, parsed with serde_yaml for the static contract, and walked
//!   by a small simulator (`simulate`) for the behaviour that only shows when
//!   the jobs run: which jobs start for an event, what each builds, pushes,
//!   smoke-tests and tags, and that a moved tag or a version mismatch stops a
//!   publish before anything is pushed.
//!
//! The simulator does what Actions does for one event: it orders the jobs by
//! `needs:`, evaluates each job's `if:` (a job whose needs did not all succeed
//! is skipped unless its `if:` calls a status function), expands
//! `strategy.matrix`, evaluates step `if:`s and `${{ }}` expressions, and runs
//! every `run:` step for real under `/bin/bash` (with `-eo pipefail` when the
//! shell is `bash`, as Actions does) from the root of a temp git repo, with
//! `GITHUB_OUTPUT`, `GITHUB_ENV` and `RUNNER_TEMP` wired up. `docker` on PATH
//! and `scripts/docker/smoke-test.sh` in the repo are recorders; the real
//! `scripts/docker/image-tags.sh` is copied in. Actions it knows:
//!
//!   actions/checkout            `git checkout --detach <ref>` (default
//!                               `github.sha`); records `ref` and
//!                               `fetch-depth` (default 1)
//!   docker/build-push-action    records its inputs; outputs a fake `digest`
//!                               (`sha256:<64 hex>`), `imageid` and `metadata`
//!   docker/login-action         records `registry` and `password`
//!   actions/upload-artifact,    copy files through a local artifact store
//!   actions/download-artifact   (`name`, `path`, `pattern`, `merge-multiple`)
//!
//! Any other action is a no-op. Expressions may use `github.*`, `env.*`,
//! `matrix.*`, `steps.*`, `needs.*`, `runner.*`, `secrets.GITHUB_TOKEN`,
//! string and number literals, `==`, `!=`, `!`, `&&`, `||`, parentheses,
//! `startsWith`, `endsWith`, `contains`, `format` and the status functions;
//! anything else fails the test with a message naming it.
//!
//! For a release event the simulator sets `github.sha` and `github.ref` to
//! the default branch (`main`), as Actions does for `workflow_run`, and
//! `github.event.workflow_run.head_branch` / `head_sha` to the tag and its
//! commit. Run steps must not need a real Docker daemon or network before the
//! build (the build itself is the build-push-action step).

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use regex::Regex;
use serde_yaml::Value;

const DOCKERFILE: &str = "Dockerfile";
const DOCKERIGNORE: &str = ".dockerignore";
const WORKFLOW: &str = ".github/workflows/docker.yml";
const RELEASE_WORKFLOW: &str = ".github/workflows/release.yml";
const IMAGE_TAGS: &str = "scripts/docker/image-tags.sh";
const SMOKE_TEST: &str = "scripts/docker/smoke-test.sh";
const IMAGE: &str = "ghcr.io/connordodge/memex";
const TOKEN: &str = "ghs_simulated_github_token";
const AMD64: (&str, &str) = ("linux/amd64", "ubuntu-24.04");
const ARM64: (&str, &str) = ("linux/arm64", "ubuntu-24.04-arm");

// ---------- files ----------

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn read_repo_file(rel: &str) -> String {
    let path = repo_root().join(rel);
    fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{rel} must exist and be readable ({}): {e}", path.display()))
}

fn squash(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Shell-like words: whitespace-separated, with '…' and "…" quoting and `\`
/// escapes; the quotes are removed.
fn shell_words(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                } else if c == '\\' && q == '"' {
                    if let Some(n) = chars.next() {
                        cur.push(n);
                    }
                } else {
                    cur.push(c);
                }
            }
            None => {
                if c.is_whitespace() {
                    if in_word {
                        out.push(std::mem::take(&mut cur));
                        in_word = false;
                    }
                } else if c == '"' || c == '\'' {
                    quote = Some(c);
                    in_word = true;
                } else if c == '\\' {
                    if let Some(n) = chars.next() {
                        cur.push(n);
                        in_word = true;
                    }
                } else {
                    cur.push(c);
                    in_word = true;
                }
            }
        }
    }
    if in_word {
        out.push(cur);
    }
    out
}

/// The commands of a shell line, split at `&&`, `||`, `;` and `|`.
fn shell_segments(run: &str) -> Vec<String> {
    Regex::new(r"&&|\|\||;|\|")
        .unwrap()
        .split(run)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

// ---------- Dockerfile ----------

#[derive(Debug, Clone)]
struct Instr {
    keyword: String,
    args: String,
}

#[derive(Debug)]
struct Stage {
    image: String,
    name: Option<String>,
    flags: Vec<String>,
    instrs: Vec<Instr>,
}

impl Stage {
    fn of(&self, keyword: &str) -> Vec<&Instr> {
        self.instrs
            .iter()
            .filter(|i| i.keyword == keyword)
            .collect()
    }

    /// The `RUN` instructions, white space squashed.
    fn runs(&self) -> Vec<String> {
        self.of("RUN").iter().map(|i| squash(&i.args)).collect()
    }
}

#[derive(Debug)]
struct Dockerfile {
    all: Vec<Instr>,
    stages: Vec<Stage>,
}

fn heredoc_delimiter(instr: &str) -> Option<String> {
    let first = instr.split_whitespace().next()?.to_uppercase();
    if first != "RUN" && first != "COPY" {
        return None;
    }
    let re = Regex::new(r#"<<-?\s*["']?([A-Za-z_][A-Za-z0-9_]*)["']?"#).unwrap();
    if instr.contains("<<<") {
        return None;
    }
    re.captures(instr).map(|c| c[1].to_string())
}

fn parse_dockerfile(text: &str) -> Dockerfile {
    let mut raw_instrs: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut heredoc: Option<String> = None;
    for line in text.lines() {
        if let Some(delim) = &heredoc {
            cur.push('\n');
            cur.push_str(line);
            if line.trim() == delim {
                heredoc = None;
                raw_instrs.push(std::mem::take(&mut cur));
            }
            continue;
        }
        let t = line.trim();
        if t.starts_with('#') || (cur.is_empty() && t.is_empty()) {
            continue;
        }
        if let Some(body) = line.trim_end().strip_suffix('\\') {
            cur.push_str(body);
            cur.push(' ');
            continue;
        }
        cur.push_str(line);
        if let Some(d) = heredoc_delimiter(&cur) {
            heredoc = Some(d);
            continue;
        }
        raw_instrs.push(std::mem::take(&mut cur));
    }
    if !cur.trim().is_empty() {
        raw_instrs.push(cur);
    }
    let all: Vec<Instr> = raw_instrs
        .iter()
        .map(|s| {
            let s = s.trim_start();
            let (k, rest) = s.split_once(char::is_whitespace).unwrap_or((s, ""));
            Instr {
                keyword: k.to_uppercase(),
                args: rest.trim().to_string(),
            }
        })
        .collect();
    let mut global_args: BTreeMap<String, String> = BTreeMap::new();
    let mut stages: Vec<Stage> = Vec::new();
    for i in &all {
        if i.keyword == "FROM" {
            let mut from = i.args.clone();
            for (k, v) in &global_args {
                from = from
                    .replace(&format!("${{{k}}}"), v)
                    .replace(&format!("${k}"), v);
            }
            let words: Vec<String> = from.split_whitespace().map(str::to_string).collect();
            let flags: Vec<String> = words
                .iter()
                .filter(|w| w.starts_with("--"))
                .cloned()
                .collect();
            let rest: Vec<&String> = words.iter().filter(|w| !w.starts_with("--")).collect();
            let image = rest.first().map(|s| s.to_string()).unwrap_or_default();
            let name = if rest.len() >= 3 && rest[1].eq_ignore_ascii_case("as") {
                Some(rest[2].to_string())
            } else {
                None
            };
            stages.push(Stage {
                image,
                name,
                flags,
                instrs: Vec::new(),
            });
        } else if let Some(stage) = stages.last_mut() {
            stage.instrs.push(i.clone());
        } else if i.keyword == "ARG" {
            let (k, v) = i.args.split_once('=').unwrap_or((i.args.as_str(), ""));
            global_args.insert(k.trim().to_string(), v.trim().trim_matches('"').to_string());
        }
    }
    Dockerfile { all, stages }
}

fn dockerfile() -> Dockerfile {
    parse_dockerfile(&read_repo_file(DOCKERFILE))
}

impl Dockerfile {
    fn runtime(&self) -> &Stage {
        assert!(
            self.stages.len() >= 2,
            "{DOCKERFILE} is multi-stage (a builder and a runtime stage): {} stage(s)",
            self.stages.len()
        );
        self.stages.last().unwrap()
    }

    /// The one stage that runs `cargo build`.
    fn builder(&self) -> (usize, &Stage) {
        let builders: Vec<(usize, &Stage)> = self
            .stages
            .iter()
            .enumerate()
            .filter(|(_, s)| s.runs().iter().any(|r| r.contains("cargo build")))
            .collect();
        assert_eq!(
            builders.len(),
            1,
            "exactly one {DOCKERFILE} stage runs `cargo build`"
        );
        builders[0]
    }
}

/// `COPY` words: (flags, sources, destination).
fn copy_parts(args: &str) -> (Vec<String>, Vec<String>, String) {
    let words: Vec<String> = if args.trim_start().starts_with('[') {
        serde_json::from_str(args.trim()).expect("COPY exec form is a JSON array")
    } else {
        shell_words(args)
    };
    let flags: Vec<String> = words
        .iter()
        .filter(|w| w.starts_with("--"))
        .cloned()
        .collect();
    let mut paths: Vec<String> = words.into_iter().filter(|w| !w.starts_with("--")).collect();
    let dest = paths.pop().unwrap_or_default();
    (flags, paths, dest)
}

/// Packages named by each `apt-get install` / `apt install` in `run`.
fn apt_installs(run: &str) -> Vec<String> {
    let mut pkgs = Vec::new();
    for seg in shell_segments(run) {
        let words: Vec<&str> = seg.split_whitespace().collect();
        let Some(pos) = words
            .windows(2)
            .position(|w| (w[0] == "apt-get" || w[0] == "apt") && w[1] == "install")
        else {
            continue;
        };
        for w in &words[pos + 2..] {
            if !w.starts_with('-') {
                pkgs.push(w.split('=').next().unwrap().to_string());
            }
        }
    }
    pkgs
}

fn has_flag_value(words: &[&str], flags: &[&str], values: &[&str]) -> bool {
    words
        .windows(2)
        .any(|w| flags.contains(&w[0]) && values.contains(&w[1]))
        || words.iter().any(|w| {
            flags.iter().any(|f| {
                values
                    .iter()
                    .any(|v| *w == format!("{f}={v}") || (f.len() == 2 && *w == format!("{f}{v}")))
            })
        })
}

#[test]
fn dockerfile_builder_is_rust_trixie_at_the_release_rust_version_and_runtime_is_trixie_slim() {
    let release = read_repo_file(RELEASE_WORKFLOW);
    let step = Regex::new(r"(?m)^\s*-?\s*name:\s*Set up Rust (\d+\.\d+\.\d+)\s*$")
        .unwrap()
        .captures(&release)
        .unwrap_or_else(|| panic!("{RELEASE_WORKFLOW} has a `Set up Rust <x.y.z>` step"))[1]
        .to_string();
    let installed = Regex::new(r"rustup toolchain install (\d+\.\d+\.\d+)")
        .unwrap()
        .captures(&release)
        .expect("release.yml installs a pinned toolchain")[1]
        .to_string();
    assert_eq!(
        step, installed,
        "release.yml's Rust step name and install agree"
    );

    let df = dockerfile();
    let runtime = df.runtime();
    let (bi, builder) = df.builder();
    assert!(
        bi < df.stages.len() - 1,
        "the builder is not the runtime (last) stage"
    );
    let rust = Regex::new(&format!(
        r"^rust:{}-trixie(@sha256:[0-9a-f]{{64}})?$",
        regex::escape(&step)
    ))
    .unwrap();
    assert!(
        rust.is_match(&builder.image),
        "the builder stage is FROM rust:{step}-trixie (release.yml's Rust), not `{}`",
        builder.image
    );
    let cargo_build = builder
        .runs()
        .iter()
        .flat_map(|r| shell_segments(r))
        .find(|s| s.contains("cargo build"))
        .expect("the builder runs cargo build");
    let words: Vec<&str> = cargo_build
        .split_whitespace()
        .skip_while(|w| *w != "cargo")
        .collect();
    assert_eq!(&words[..2], ["cargo", "build"], "{cargo_build}");
    for flag in ["--release", "--locked"] {
        assert!(
            words.contains(&flag),
            "cargo build has {flag}: `{cargo_build}`"
        );
    }
    assert!(
        has_flag_value(&words, &["-p", "--package"], &["memex-mcp"]),
        "cargo build builds -p memex-mcp: `{cargo_build}`"
    );
    let slim = Regex::new(r"^debian:trixie-slim(@sha256:[0-9a-f]{64})?$").unwrap();
    assert!(
        slim.is_match(&runtime.image),
        "the runtime stage is FROM debian:trixie-slim, not `{}`",
        runtime.image
    );
}

#[test]
fn dockerfile_runtime_installs_certificates_tzdata_and_shared_libraries_only_and_the_binary_at_usr_local_bin(
) {
    let df = dockerfile();
    let runtime = df.runtime();
    let runs = runtime.runs();
    let lib = Regex::new(r"^lib[a-z0-9.+-]*[a-z0-9]$").unwrap();
    let lists_removed =
        Regex::new(r"\brm\s+-(rf|fr|r)\s+(\S+\s+)*/var/lib/apt/lists(/\*|/)?(\s|$)").unwrap();
    let mut pkgs: BTreeSet<String> = BTreeSet::new();
    for run in &runs {
        let here = apt_installs(run);
        if here.is_empty() {
            continue;
        }
        assert!(
            lists_removed.is_match(run),
            "the RUN that installs packages removes /var/lib/apt/lists/* in the same layer: `{run}`"
        );
        pkgs.extend(here);
    }
    for needed in ["ca-certificates", "tzdata"] {
        assert!(
            pkgs.contains(needed),
            "the runtime stage installs {needed}: {pkgs:?}"
        );
    }
    for p in &pkgs {
        let shared_lib = lib.is_match(p) && !p.ends_with("-dev");
        assert!(
            p == "ca-certificates" || p == "tzdata" || shared_lib,
            "the runtime stage installs only ca-certificates, tzdata and shared libraries, not `{p}`"
        );
    }
    let tools = Regex::new(r"\b(curl|wget|rustup|rustc|cargo|gcc|g\+\+|clang|make)\b").unwrap();
    for run in &runs {
        assert!(
            !tools.is_match(run),
            "the runtime stage runs no compiler, curl, wget or Rust toolchain: `{run}`"
        );
    }
    let (bi, builder) = df.builder();
    let mut binary = false;
    for c in runtime.of("COPY").iter().chain(runtime.of("ADD").iter()) {
        let (flags, sources, dest) = copy_parts(&c.args);
        for s in &sources {
            assert!(
                !s.contains("/usr/local/cargo") && !s.contains("rustup"),
                "the runtime stage copies no Rust toolchain: `{}`",
                c.args
            );
        }
        let from = flags
            .iter()
            .find_map(|f| f.strip_prefix("--from="))
            .unwrap_or("");
        let from_builder = from == bi.to_string() || builder.name.as_deref() == Some(from);
        let dest_ok = dest == "/usr/local/bin/memex" || dest == "/usr/local/bin/";
        if c.keyword == "COPY"
            && from_builder
            && dest_ok
            && sources.len() == 1
            && sources[0].rsplit('/').next() == Some("memex")
        {
            binary = true;
        }
    }
    assert!(
        binary,
        "the runtime stage copies the memex binary from the builder to /usr/local/bin/memex"
    );
}

#[test]
fn dockerfile_creates_the_memex_user_1000_and_vaults_owned_by_it_and_runs_as_1000() {
    let df = dockerfile();
    let runtime = df.runtime();
    let segments: Vec<String> = runtime
        .runs()
        .iter()
        .flat_map(|r| shell_segments(r))
        .collect();
    let words_of = |s: &String| -> Vec<String> {
        s.split_whitespace()
            .skip_while(|w| {
                !matches!(
                    *w,
                    "groupadd" | "addgroup" | "useradd" | "adduser" | "mkdir" | "chown" | "install"
                )
            })
            .map(str::to_string)
            .collect()
    };
    let cmds: Vec<Vec<String>> = segments
        .iter()
        .map(words_of)
        .filter(|w| !w.is_empty())
        .collect();
    fn refs(w: &[String]) -> Vec<&str> {
        w.iter().map(String::as_str).collect()
    }
    let group = cmds.iter().any(|w| {
        let w = refs(w);
        matches!(w[0], "groupadd" | "addgroup")
            && has_flag_value(&w, &["--gid", "-g"], &["1000"])
            && w.contains(&"memex")
    });
    assert!(
        group,
        "the runtime stage creates group memex with gid 1000: {cmds:?}"
    );
    let user = cmds.iter().any(|w| {
        let w = refs(w);
        matches!(w[0], "useradd" | "adduser")
            && has_flag_value(&w, &["--uid", "-u"], &["1000"])
            && has_flag_value(&w, &["--gid", "-g", "--ingroup"], &["1000", "memex"])
            && w.contains(&"memex")
    });
    assert!(
        user,
        "the runtime stage creates user memex with uid 1000 in group 1000: {cmds:?}"
    );
    let owner = ["1000:1000", "memex:memex"];
    let made = cmds.iter().any(|w| {
        let w = refs(w);
        w[0] == "mkdir" && w.contains(&"/vaults")
    });
    let chowned = cmds.iter().any(|w| {
        let w = refs(w);
        w[0] == "chown" && w.iter().any(|x| owner.contains(x)) && w.contains(&"/vaults")
    });
    let installed = cmds.iter().any(|w| {
        let w = refs(w);
        w[0] == "install"
            && w.contains(&"-d")
            && has_flag_value(&w, &["-o", "--owner"], &["1000", "memex"])
            && has_flag_value(&w, &["-g", "--group"], &["1000", "memex"])
            && w.contains(&"/vaults")
    });
    assert!(
        (made && chowned) || installed,
        "the runtime stage creates /vaults owned by 1000:1000: {cmds:?}"
    );
    let users = runtime.of("USER");
    assert_eq!(
        users.last().map(|u| u.args.as_str()),
        Some("1000:1000"),
        "the runtime stage ends as USER 1000:1000"
    );
}

#[test]
fn dockerfile_exposes_7878_with_the_exact_serve_cmd_and_no_entrypoint_healthcheck_or_volume() {
    let df = dockerfile();
    let runtime = df.runtime();
    let exposed: Vec<String> = df
        .all
        .iter()
        .filter(|i| i.keyword == "EXPOSE")
        .flat_map(|i| {
            i.args
                .split_whitespace()
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .collect();
    assert!(
        exposed == ["7878"] || exposed == ["7878/tcp"],
        "the Dockerfile exposes 7878 and nothing else: {exposed:?}"
    );
    assert_eq!(
        runtime.of("EXPOSE").len(),
        1,
        "EXPOSE 7878 is in the runtime stage"
    );
    let cmds = runtime.of("CMD");
    assert_eq!(cmds.len(), 1, "the runtime stage has one CMD");
    let cmd: Vec<String> = serde_json::from_str(&cmds[0].args)
        .unwrap_or_else(|e| panic!("CMD is the exec (JSON) form: `{}`: {e}", cmds[0].args));
    assert_eq!(
        cmd,
        [
            "memex",
            "serve",
            "--root",
            "/vaults",
            "--listen",
            "0.0.0.0:7878"
        ],
        "CMD is exactly memex serve --root /vaults --listen 0.0.0.0:7878"
    );
    for k in ["ENTRYPOINT", "HEALTHCHECK", "VOLUME"] {
        let found: Vec<&Instr> = df.all.iter().filter(|i| i.keyword == k).collect();
        assert!(found.is_empty(), "the Dockerfile has no {k}: {found:?}");
    }
}

#[test]
fn dockerfile_bakes_in_no_access_token() {
    let text = read_repo_file(DOCKERFILE);
    assert!(
        !text.to_lowercase().contains("memex_access_token"),
        "the Dockerfile never sets or mentions MEMEX_ACCESS_TOKEN"
    );
    let df = parse_dockerfile(&text);
    assert!(!df.stages.is_empty(), "the Dockerfile has a FROM");
    for i in &df.all {
        match i.keyword.as_str() {
            "ENV" | "ARG" => assert!(
                !i.args.to_lowercase().contains("token"),
                "no {} names a token: `{}`",
                i.keyword,
                i.args
            ),
            "COPY" | "ADD" => {
                let (_, sources, dest) = copy_parts(&i.args);
                for p in sources.iter().chain(std::iter::once(&dest)) {
                    assert!(
                        !p.to_lowercase().contains("token"),
                        "the Dockerfile copies no token file: `{}`",
                        i.args
                    );
                }
            }
            _ => {}
        }
    }
}

#[test]
fn dockerfile_sets_the_oci_labels_and_the_version_label_from_a_version_build_arg() {
    let df = dockerfile();
    let runtime = df.runtime();
    let mut labels: BTreeMap<String, (String, usize)> = BTreeMap::new();
    for (idx, i) in runtime.instrs.iter().enumerate() {
        if i.keyword != "LABEL" {
            continue;
        }
        for w in shell_words(&i.args) {
            let (k, v) = w
                .split_once('=')
                .unwrap_or_else(|| panic!("LABEL uses key=value pairs: `{}`", i.args));
            labels.insert(k.to_string(), (v.to_string(), idx));
        }
    }
    let label = |k: &str| -> String {
        labels
            .get(k)
            .map(|(v, _)| v.clone())
            .unwrap_or_else(|| panic!("the runtime stage sets LABEL {k}: {labels:?}"))
    };
    assert_eq!(
        label("org.opencontainers.image.source"),
        "https://github.com/connordodge/open_memex"
    );
    assert_eq!(label("org.opencontainers.image.licenses"), "MIT");
    assert_eq!(label("org.opencontainers.image.title"), "memex");
    let description = label("org.opencontainers.image.description");
    assert!(
        !description.trim().is_empty()
            && !description.contains('\n')
            && description.to_lowercase().contains("vault server"),
        "the description is one line naming the vault server: `{description}`"
    );
    let version = label("org.opencontainers.image.version");
    assert!(
        version == "${VERSION}" || version == "$VERSION",
        "org.opencontainers.image.version comes from the VERSION build arg: `{version}`"
    );
    let label_at = labels["org.opencontainers.image.version"].1;
    let arg_at = runtime.instrs.iter().position(|i| {
        i.keyword == "ARG" && i.args.split('=').next().map(str::trim) == Some("VERSION")
    });
    assert!(
        arg_at.is_some_and(|a| a < label_at),
        "the runtime stage declares ARG VERSION before the version LABEL (an ARG before FROM is not visible in a stage)"
    );
}

#[test]
fn dockerignore_excludes_everything_except_cargo_manifests_and_crates() {
    let text = read_repo_file(DOCKERIGNORE);
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect();
    assert!(
        matches!(lines.first(), Some(&"*") | Some(&"**")),
        ".dockerignore starts by excluding everything (`*`): {lines:?}"
    );
    let included: BTreeSet<String> = lines
        .iter()
        .filter_map(|l| l.strip_prefix('!'))
        .map(|p| {
            let p = p.trim().trim_start_matches('/');
            let p = p.strip_suffix("/**").unwrap_or(p);
            p.trim_end_matches('/').to_string()
        })
        .collect();
    let expected: BTreeSet<String> = ["Cargo.toml", "Cargo.lock", "crates"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(
        included, expected,
        ".dockerignore re-includes only Cargo.toml, Cargo.lock and crates/"
    );
}

// ---------- scripts/docker/image-tags.sh ----------

/// Removes inherited git/Actions state and points git at an empty config.
fn isolate(cmd: &mut Command) {
    for (k, _) in std::env::vars() {
        if k.starts_with("GIT_") || k.starts_with("GITHUB_") || k.starts_with("RUNNER_") {
            cmd.env_remove(k);
        }
    }
    cmd.env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0");
}

fn git(dir: &Path, args: &[&str]) -> String {
    let mut cmd = Command::new("git");
    cmd.current_dir(dir).args(args);
    isolate(&mut cmd);
    let out = cmd.output().expect("run git");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

struct Fixture {
    _tmp: tempfile::TempDir,
    root: PathBuf,
    repo: PathBuf,
    shas: BTreeMap<String, String>,
}

impl Fixture {
    fn sha(&self, label: &str) -> String {
        self.shas[label].clone()
    }
}

const SIM_LOG_SEP: char = '\u{1f}';

fn write_exec(path: &Path, body: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, body).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn recorder(log_var: &str, word: &str) -> String {
    format!(
        "#!/bin/sh\n{{ printf '%s' {word}; for a in \"$@\"; do printf '\\037%s' \"$a\"; done; printf '\\n'; }} >> \"${log_var}\"\nexit 0\n"
    )
}

/// A temp git repo with one commit per `(label, cargo version, tags)`, each
/// tag annotated; the last commit is `main`. `Cargo.toml` has a decoy
/// `version` before `[workspace.package]`. The real image-tags.sh (when it
/// exists) and a recording smoke-test.sh are added untracked.
fn fixture(commits: &[(&str, &str, &[&str])]) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    let repo = root.join("repo");
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["-c", "init.defaultBranch=main", "init", "-q"]);
    for (k, v) in [
        ("user.name", "Fixture"),
        ("user.email", "fixture@example.com"),
        ("commit.gpgsign", "false"),
        ("tag.gpgsign", "false"),
    ] {
        git(&repo, &["config", k, v]);
    }
    let mut shas = BTreeMap::new();
    for (label, version, tags) in commits {
        fs::write(
            repo.join("Cargo.toml"),
            format!(
                "[workspace]\nresolver = \"2\"\nmembers = []\n\n[workspace.metadata.decoy]\nversion = \"0.0.1\"\n\n[workspace.package]\nversion = \"{version}\"\nedition = \"2021\"\n\n[workspace.dependencies]\nserde = {{ version = \"1\", features = [\"derive\"] }}\n"
            ),
        )
        .unwrap();
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-q", "--allow-empty", "-m", label]);
        for t in *tags {
            git(&repo, &["tag", "-a", "-m", t, t]);
        }
        shas.insert(label.to_string(), git(&repo, &["rev-parse", "HEAD"]));
    }
    let real = repo_root().join(IMAGE_TAGS);
    if real.is_file() {
        fs::create_dir_all(repo.join("scripts/docker")).unwrap();
        fs::copy(&real, repo.join(IMAGE_TAGS)).unwrap();
    }
    write_exec(&repo.join(SMOKE_TEST), &recorder("SIM_SMOKE_LOG", "smoke"));
    write_exec(
        &root.join("bin/docker"),
        &recorder("SIM_DOCKER_LOG", "docker"),
    );
    Fixture {
        _tmp: tmp,
        root,
        repo,
        shas,
    }
}

/// Runs `cmd` with stdout/stderr in files under `scratch` and a deadline.
fn run_bounded(mut cmd: Command, secs: u64, scratch: &Path) -> (Option<i32>, String, String) {
    static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let out_p = scratch.join(format!("out-{n}.txt"));
    let err_p = scratch.join(format!("err-{n}.txt"));
    cmd.stdin(Stdio::null())
        .stdout(fs::File::create(&out_p).unwrap())
        .stderr(fs::File::create(&err_p).unwrap());
    let mut child = cmd.spawn().expect("spawn");
    let deadline = Instant::now() + Duration::from_secs(secs);
    let status = loop {
        if let Some(st) = child.try_wait().unwrap() {
            break st.code();
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    (
        status,
        fs::read_to_string(&out_p).unwrap_or_default(),
        fs::read_to_string(&err_p).unwrap_or_default(),
    )
}

fn image_tags(fx: &Fixture, args: &[&str]) -> (Option<i32>, String, String) {
    let mut cmd = Command::new("/bin/bash");
    cmd.arg(repo_root().join(IMAGE_TAGS))
        .args(args)
        .current_dir(&fx.repo);
    isolate(&mut cmd);
    run_bounded(cmd, 30, &fx.root)
}

fn assert_tags(fx: &Fixture, version: &str, expected: &[&str]) {
    let (code, out, err) = image_tags(fx, &[version]);
    assert_eq!(
        code,
        Some(0),
        "image-tags.sh {version} exits 0 (stderr: {err})"
    );
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(
        lines, expected,
        "image-tags.sh {version} prints one tag per line (stdout: {out:?})"
    );
}

const AC_TAGS: &[(&str, &str, &[&str])] = &[
    ("a", "0.6.0", &["v0.6.0"]),
    ("b", "0.6.1", &["v0.6.1"]),
    ("c", "0.7.0", &["v0.7.0"]),
];
const TEN_TAGS: &[(&str, &str, &[&str])] = &[
    ("a", "0.9.0", &["v0.9.0"]),
    ("b", "0.9.1", &["v0.9.1"]),
    ("c", "0.10.0", &["v0.10.0"]),
];
const PATCH_TAGS: &[(&str, &str, &[&str])] = &[
    ("a", "1.2.9", &["v1.2.9"]),
    ("b", "1.2.10", &["v1.2.10"]),
    ("c", "1.3.0", &["v1.3.0"]),
];

#[test]
fn image_tags_for_the_highest_release_prints_version_minor_and_latest() {
    assert_tags(&fixture(AC_TAGS), "0.7.0", &["0.7.0", "0.7", "latest"]);
    // Version order, not text order: v0.10.0 is above v0.9.1.
    assert_tags(&fixture(TEN_TAGS), "0.10.0", &["0.10.0", "0.10", "latest"]);
}

#[test]
fn image_tags_for_the_highest_patch_of_an_older_minor_prints_version_and_minor() {
    assert_tags(&fixture(AC_TAGS), "0.6.1", &["0.6.1", "0.6"]);
    assert_tags(&fixture(TEN_TAGS), "0.9.1", &["0.9.1", "0.9"]);
    // v1.2.10 is above v1.2.9 (version order).
    assert_tags(&fixture(PATCH_TAGS), "1.2.10", &["1.2.10", "1.2"]);
    // v1.20.0 is not in the 1.2 line: 1.2.5 is still the highest v1.2.* tag.
    let fx = fixture(&[("a", "1.2.5", &["v1.2.5"]), ("b", "1.20.0", &["v1.20.0"])]);
    assert_tags(&fx, "1.2.5", &["1.2.5", "1.2"]);
}

#[test]
fn image_tags_for_an_older_patch_prints_only_the_version() {
    assert_tags(&fixture(AC_TAGS), "0.6.0", &["0.6.0"]);
    // Text order would put v1.2.9 above v1.2.10.
    assert_tags(&fixture(PATCH_TAGS), "1.2.9", &["1.2.9"]);
}

#[test]
fn image_tags_ignores_v_tags_that_are_not_releases() {
    // git's version sort puts v1.4.3-rc.1 and v1.4.2.1 above v1.4.2 inside the
    // 1.4 line, and v1.5, v2 and v10 above it overall. Only v<d>.<d>.<d> tags
    // count as releases, so none of them takes `1.4` or `latest` away.
    let stray: &[&str] = &[
        "v1.4.2",
        "v1.4.3-rc.1",
        "v1.4.2-rc.1",
        "v1.4.2.1",
        "v1.5",
        "v2",
        "v10",
        "v1.4.10-beta",
        "vnext",
    ];
    let fx = fixture(&[("a", "1.4.1", &["v1.4.1"]), ("b", "1.4.2", stray)]);
    assert_tags(&fx, "1.4.2", &["1.4.2", "1.4", "latest"]);
    // An older release is still only its own version.
    assert_tags(&fx, "1.4.1", &["1.4.1"]);
    // Stray tags above a later release do not take its tags either.
    let fx = fixture(&[
        ("a", "1.4.2", &["v1.4.2"]),
        ("b", "1.4.3", &["v1.4.3", "v9", "v1.5.0-rc.1"]),
    ]);
    assert_tags(&fx, "1.4.3", &["1.4.3", "1.4", "latest"]);
    assert_tags(&fx, "1.4.2", &["1.4.2"]);
}

#[test]
fn image_tags_rejects_a_malformed_version_with_no_output() {
    let fx = fixture(AC_TAGS);
    let (code, out, err) = image_tags(&fx, &["0.7.0"]);
    assert!(
        code == Some(0) && out.lines().any(|l| l == "latest"),
        "control: a well-formed version is accepted (exit {code:?}, stdout {out:?}, stderr {err})"
    );
    let malformed: &[&[&str]] = &[
        &[],
        &[""],
        &["0.7"],
        &["v0.7.0"],
        &["0.7.0.1"],
        &["0.7.x"],
        &["0.7.0-rc.1"],
        &[" 0.7.0"],
        &["0.7.0 "],
        &["0.7.0\n"],
        &["1..0"],
        &["a.b.c"],
    ];
    for args in malformed {
        let (code, out, err) = image_tags(&fx, args);
        assert!(
            matches!(code, Some(c) if c != 0 && c != 126 && c != 127),
            "image-tags.sh {args:?} exits non-zero from the script itself (exit {code:?}, stderr {err})"
        );
        assert_eq!(out, "", "image-tags.sh {args:?} prints nothing on stdout");
    }
}

// ---------- scripts/docker/smoke-test.sh ----------

#[test]
fn docker_scripts_are_executable_and_parse_under_bin_bash() {
    for rel in [IMAGE_TAGS, SMOKE_TEST] {
        let path = repo_root().join(rel);
        let text = read_repo_file(rel);
        assert!(
            text.starts_with("#!/usr/bin/env bash\n") || text.starts_with("#!/bin/bash\n"),
            "{rel} starts with a bash shebang"
        );
        let mode = fs::metadata(&path).unwrap().permissions().mode();
        assert!(mode & 0o111 != 0, "{rel} is executable (mode {mode:o})");
        let out = Command::new("/bin/bash")
            .arg("-n")
            .arg(&path)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{rel} parses under /bin/bash: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        for gnu_only in [
            "sort -V",
            "readarray",
            "mapfile",
            ",,}",
            "^^}",
            "declare -A",
        ] {
            assert!(
                !text.contains(gnu_only),
                "{rel} avoids `{gnu_only}` (macOS bash 3.2 / BSD tools)"
            );
        }
    }
}

#[test]
fn smoke_test_script_rejects_missing_arguments_without_running_docker() {
    let fx = fixture(&[("a", "1.0.0", &[])]);
    let log = fx.root.join("docker.log");
    let path = format!(
        "{}:{}",
        fx.root.join("bin").display(),
        std::env::var("PATH").unwrap_or_default()
    );
    for args in [&[][..], &["ghcr.io/connordodge/memex:ci"][..]] {
        let mut cmd = Command::new("/bin/bash");
        cmd.arg(repo_root().join(SMOKE_TEST))
            .args(args)
            .current_dir(&fx.repo)
            .env("PATH", &path)
            .env("SIM_DOCKER_LOG", &log);
        isolate(&mut cmd);
        let (code, _out, err) = run_bounded(cmd, 30, &fx.root);
        assert!(
            matches!(code, Some(c) if c != 0 && c != 126 && c != 127),
            "smoke-test.sh {args:?} fails with a usage error (exit {code:?}, stderr {err})"
        );
        assert!(
            err.to_lowercase().contains("usage"),
            "smoke-test.sh {args:?} prints its usage on stderr: {err:?}"
        );
        assert_eq!(
            fs::read_to_string(&log).unwrap_or_default(),
            "",
            "smoke-test.sh {args:?} runs no docker command"
        );
    }
}

// A scripted `docker`, `curl`, `sudo` and `date` on PATH let the real
// smoke-test.sh run every check with no daemon. `FAKE_*` variables set what
// each fake answers; every call is recorded in `FAKE_LOG`.
const FAKE_DOCKER: &str = r#"#!/bin/sh
{ printf 'docker'; for a in "$@"; do printf '\037%s' "$a"; done; printf '\n'; } >> "$FAKE_LOG"
n() { echo "${1#cid-}"; }
case "$1" in
  run)
    shift
    detached=0
    user=0
    for a in "$@"; do
      case "$a" in
        -d) detached=1 ;;
        --user) user=1 ;;
      esac
    done
    if [ "$detached" = 1 ]; then
      if [ "$user" = 1 ]; then echo cid-2; else echo cid-1; fi
    else
      printf '%s\n' "$FAKE_VERSION_OUT"
    fi
    ;;
  inspect)
    case "$3" in
      '{{.Config.User}}') printf '%s\n' "$FAKE_USER" ;;
      '{{json .Config.Healthcheck}}') printf '%s\n' "$FAKE_HEALTHCHECK" ;;
      '{{index .Config.Labels "org.opencontainers.image.version"}}') printf '%s\n' "$FAKE_LABEL" ;;
      '{{.State.Running}}') eval "printf '%s\n' \"\$FAKE_RUNNING_$(n "$4")\"" ;;
      '{{.State.ExitCode}}') printf '%s\n' "$FAKE_EXIT" ;;
      *) echo "fake docker: unexpected inspect format $3" >&2; exit 99 ;;
    esac
    ;;
  logs) eval "printf '%s\n' \"\$FAKE_LOGS_$(n "$2")\"" ;;
  stop | rm) exit 0 ;;
  *) echo "fake docker: unexpected command $*" >&2; exit 99 ;;
esac
"#;

const FAKE_CURL: &str = r#"#!/bin/sh
{ printf 'curl'; for a in "$@"; do printf '\037%s' "$a"; done; printf '\n'; } >> "$FAKE_LOG"
code=0
auth=0
for a in "$@"; do
  case "$a" in
    -w) code=1 ;;
    "Authorization: Bearer "*) auth=1 ;;
  esac
done
if [ "$code" = 1 ]; then
  if [ "$auth" = 1 ]; then printf '%s' "$FAKE_CODE_AUTH"; else printf '%s' "$FAKE_CODE_NOAUTH"; fi
else
  printf '%s' "$FAKE_BODY"
fi
"#;

const FAKE_SUDO: &str = r#"#!/bin/sh
{ printf 'sudo'; for a in "$@"; do printf '\037%s' "$a"; done; printf '\n'; } >> "$FAKE_LOG"
case "$1" in
  chown) exit 0 ;;
  rm) exec "$@" ;;
  stat)
    case "$3" in
      '%a %u:%g') printf '%s\n' "$FAKE_TOKEN_STAT" ;;
      '%u:%g') printf '%s\n' "$FAKE_TOKEN_OWNER2" ;;
      *) echo "fake sudo: unexpected stat format $3" >&2; exit 99 ;;
    esac
    ;;
  cat) printf '%s\n' "$FAKE_TOKEN" ;;
  sh) printf '%s\n' "$FAKE_SERVER_LOG" ;;
  *) echo "fake sudo: unexpected command $*" >&2; exit 99 ;;
esac
"#;

// The first `date` call answers 1000, the second 1000 + FAKE_DATE_STEP.
const FAKE_DATE: &str = r#"#!/bin/sh
f="$FAKE_DIR/date-next"
if [ -f "$f" ]; then
  cat "$f"
else
  echo 1000
  echo $((1000 + FAKE_DATE_STEP)) > "$f"
fi
"#;

const SMOKE_VERSION: &str = "1.2.3";
const SMOKE_TOKEN: &str = "fake-access-token-0123456789";
const SMOKE_LISTENING: &str = "memex serve: vault server listening on http://0.0.0.0:7878";
const SMOKE_GENERATED: &str =
    "memex serve: generated a new access token in /vaults/.memex/access-token";

/// What the fakes answer when the image is right.
fn smoke_env() -> BTreeMap<&'static str, String> {
    let both = format!("{SMOKE_GENERATED}\n{SMOKE_LISTENING}");
    [
        ("FAKE_VERSION_OUT", format!("memex {SMOKE_VERSION}")),
        ("FAKE_USER", "1000:1000".to_string()),
        ("FAKE_HEALTHCHECK", "null".to_string()),
        ("FAKE_LABEL", SMOKE_VERSION.to_string()),
        ("FAKE_RUNNING_1", "true".to_string()),
        ("FAKE_RUNNING_2", "true".to_string()),
        ("FAKE_LOGS_1", both),
        ("FAKE_LOGS_2", SMOKE_LISTENING.to_string()),
        ("FAKE_EXIT", "0".to_string()),
        ("FAKE_TOKEN_STAT", "600 1000:1000".to_string()),
        ("FAKE_TOKEN_OWNER2", "99:100".to_string()),
        ("FAKE_TOKEN", SMOKE_TOKEN.to_string()),
        ("FAKE_CODE_NOAUTH", "401".to_string()),
        ("FAKE_CODE_AUTH", "200".to_string()),
        (
            "FAKE_BODY",
            format!("{{\"server_version\":\"{SMOKE_VERSION}\",\"api_version\":1}}"),
        ),
        (
            "FAKE_SERVER_LOG",
            "2026-11-27T09:00:00.000000Z  INFO memex_mcp::server: vault server started utc_offset=+09:00 with_embeddings=false"
                .to_string(),
        ),
        ("FAKE_DATE_STEP", "1".to_string()),
    ]
    .into_iter()
    .collect()
}

struct SmokeRun {
    code: Option<i32>,
    stdout: String,
    stderr: String,
    /// Every fake call: the command and its arguments.
    calls: Vec<Vec<String>>,
    /// Entries left in the script's TMPDIR afterwards.
    leftovers: usize,
}

fn run_smoke(overrides: &[(&str, &str)]) -> SmokeRun {
    let fx = fixture(&[("a", "1.0.0", &[])]);
    let bin = fx.root.join("fakes");
    let tmp = fx.root.join("tmp");
    fs::create_dir_all(&tmp).unwrap();
    for (name, body) in [
        ("docker", FAKE_DOCKER),
        ("curl", FAKE_CURL),
        ("sudo", FAKE_SUDO),
        ("date", FAKE_DATE),
    ] {
        write_exec(&bin.join(name), body);
    }
    let log = fx.root.join("fake.log");
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let mut env = smoke_env();
    let overrides: BTreeMap<&str, String> =
        overrides.iter().map(|(k, v)| (*k, v.to_string())).collect();
    for (k, v) in &overrides {
        assert!(env.contains_key(k), "unknown fake setting {k}");
        env.insert(k, v.clone());
    }
    let mut cmd = Command::new("/bin/bash");
    cmd.arg(repo_root().join(SMOKE_TEST))
        .args(["memex:ci", SMOKE_VERSION])
        .current_dir(&fx.repo)
        .env("PATH", path)
        .env("TMPDIR", &tmp)
        .env("FAKE_LOG", &log)
        .env("FAKE_DIR", &fx.root);
    isolate(&mut cmd);
    for (k, v) in &env {
        cmd.env(k, v);
    }
    let (code, stdout, stderr) = run_bounded(cmd, 60, &fx.root);
    let calls = fs::read_to_string(&log)
        .unwrap_or_default()
        .lines()
        .map(|l| l.split(SIM_LOG_SEP).map(str::to_string).collect())
        .collect();
    SmokeRun {
        code,
        stdout,
        stderr,
        calls,
        leftovers: fs::read_dir(&tmp).map(|d| d.count()).unwrap_or(0),
    }
}

impl SmokeRun {
    fn has_call(&self, words: &[&str]) -> bool {
        self.calls
            .iter()
            .any(|c| c.len() >= words.len() && c.iter().zip(words).all(|(a, w)| a == w))
    }

    fn started(&self) -> Vec<String> {
        // `docker run -d ...` prints cid-1 for the first container, cid-2 for
        // the --user one.
        let mut ids = Vec::new();
        for c in &self.calls {
            if c.len() > 2 && c[0] == "docker" && c[1] == "run" && c.iter().any(|a| a == "-d") {
                ids.push(
                    if c.iter().any(|a| a == "--user") {
                        "cid-2"
                    } else {
                        "cid-1"
                    }
                    .to_string(),
                );
            }
        }
        ids
    }
}

#[test]
fn smoke_test_script_passes_and_runs_its_docker_commands_when_the_image_is_right() {
    let r = run_smoke(&[]);
    assert_eq!(
        r.code,
        Some(0),
        "stderr: {}\nstdout: {}",
        r.stderr,
        r.stdout
    );
    assert!(
        r.stdout
            .contains(&format!("all checks passed for memex:ci ({SMOKE_VERSION})")),
        "stdout: {}",
        r.stdout
    );
    assert!(
        !r.stderr.contains("FAIL"),
        "no failure on stderr: {}",
        r.stderr
    );
    assert!(
        r.has_call(&["docker", "run", "--rm", "memex:ci", "memex", "--version"]),
        "{:?}",
        r.calls
    );
    // The first container: TZ=Asia/Tokyo, loopback port, the vault bind mount.
    let first = r
        .calls
        .iter()
        .find(|c| c.len() > 2 && c[0] == "docker" && c[1] == "run" && c.contains(&"-d".to_string()))
        .expect("a detached docker run");
    for needle in [
        "-e",
        "TZ=Asia/Tokyo",
        "-p",
        "127.0.0.1:7878:7878",
        "memex:ci",
    ] {
        assert!(first.iter().any(|a| a == needle), "{needle}: {first:?}");
    }
    assert!(
        first
            .iter()
            .any(|a| a.ends_with(":/vaults") && a.contains('/')),
        "bind-mounts a host folder on /vaults: {first:?}"
    );
    assert!(
        r.calls.iter().any(|c| c.iter().any(|a| a == "99:100")
            && c.iter().any(|a| a == "--user")
            && c[0] == "docker"),
        "a second container runs --user 99:100: {:?}",
        r.calls
    );
    // Each vault folder is handed to its uid:gid.
    for owner in ["1000:1000", "99:100"] {
        assert!(
            r.calls.iter().any(|c| c[0] == "sudo"
                && c.get(1).map(String::as_str) == Some("chown")
                && c.get(2).map(String::as_str) == Some(owner)),
            "chown {owner}: {:?}",
            r.calls
        );
    }
    // The bearer token read from the token file is the one sent.
    assert!(
        r.calls.iter().any(|c| c[0] == "curl"
            && c.iter()
                .any(|a| a == &format!("Authorization: Bearer {SMOKE_TOKEN}"))),
        "curl sends the token: {:?}",
        r.calls
    );
    assert!(
        r.calls
            .iter()
            .any(|c| c[0] == "curl" && c.iter().any(|a| a == "http://127.0.0.1:7878/api/v1/info")),
        "{:?}",
        r.calls
    );
    assert!(
        r.has_call(&["docker", "stop", "-t", "10", "cid-1"]),
        "{:?}",
        r.calls
    );
    // Both containers and both vault folders are cleaned up.
    for id in ["cid-1", "cid-2"] {
        assert!(
            r.has_call(&["docker", "rm", "-f", id]),
            "{id}: {:?}",
            r.calls
        );
    }
    assert_eq!(r.leftovers, 0, "the temp vault folders are removed");
    assert!(
        !r.stderr.contains("--- docker logs"),
        "no container log dump on success: {}",
        r.stderr
    );
}

#[test]
fn smoke_test_script_fails_when_each_startup_contract_breaks() {
    let no_token_line = SMOKE_LISTENING.to_string();
    let not_listening = "memex serve: starting".to_string();
    #[allow(clippy::type_complexity)]
    let cases: Vec<(&str, Vec<(&str, String)>, &str)> = vec![
        (
            "a wrong memex --version",
            vec![("FAKE_VERSION_OUT", "memex 0.0.1".into())],
            "memex --version printed 'memex 0.0.1'",
        ),
        (
            "a --version without the memex prefix",
            vec![("FAKE_VERSION_OUT", SMOKE_VERSION.into())],
            "memex --version printed",
        ),
        (
            "an image running as root",
            vec![("FAKE_USER", "0:0".into())],
            "Config.User is '0:0'",
        ),
        (
            "an image with no user",
            vec![("FAKE_USER", "".into())],
            "Config.User is ''",
        ),
        (
            "an image with a Healthcheck",
            vec![("FAKE_HEALTHCHECK", "{\"Test\":[\"CMD\",\"true\"]}".into())],
            "the image has a Healthcheck",
        ),
        (
            "a wrong version label",
            vec![("FAKE_LABEL", "0.0.1".into())],
            "org.opencontainers.image.version is '0.0.1'",
        ),
        (
            "a missing version label",
            vec![("FAKE_LABEL", "".into())],
            "org.opencontainers.image.version is ''",
        ),
        (
            "a server that exits before listening",
            vec![
                ("FAKE_LOGS_1", not_listening.clone()),
                ("FAKE_RUNNING_1", "false".into()),
            ],
            "exited before printing",
        ),
        (
            "no generated-token line",
            vec![("FAKE_LOGS_1", no_token_line)],
            "no 'memex serve: generated a new access token",
        ),
        (
            "a token file with mode 644",
            vec![("FAKE_TOKEN_STAT", "644 1000:1000".into())],
            "the token file is '644 1000:1000'",
        ),
        (
            "a token file owned by root",
            vec![("FAKE_TOKEN_STAT", "600 0:0".into())],
            "the token file is '600 0:0'",
        ),
        (
            "an empty token file",
            vec![("FAKE_TOKEN", "".into())],
            "the token file is empty",
        ),
        (
            "200 without a token",
            vec![("FAKE_CODE_NOAUTH", "200".into())],
            "without a token answered 200, expected 401",
        ),
        (
            "403 without a token",
            vec![("FAKE_CODE_NOAUTH", "403".into())],
            "without a token answered 403, expected 401",
        ),
        (
            "401 with the token",
            vec![("FAKE_CODE_AUTH", "401".into())],
            "with the token answered 401, expected 200",
        ),
        (
            "a wrong server_version",
            vec![(
                "FAKE_BODY",
                "{\"server_version\":\"0.0.1\",\"api_version\":1}".into(),
            )],
            "expected server_version 1.2.3",
        ),
        (
            "a body without server_version",
            vec![("FAKE_BODY", "{}".into())],
            "expected server_version 1.2.3",
        ),
        (
            "a container killed on docker stop",
            vec![("FAKE_EXIT", "137".into())],
            "container exited 137, expected 0",
        ),
        (
            "a docker stop that takes 11 s",
            vec![("FAKE_DATE_STEP", "11".into())],
            "docker stop took 11s",
        ),
        (
            "a missing server.log startup line",
            vec![("FAKE_SERVER_LOG", "".into())],
            "has no 'vault server started' line",
        ),
        (
            "a UTC container ignoring TZ",
            vec![(
                "FAKE_SERVER_LOG",
                "vault server started utc_offset=+00:00 with_embeddings=false".into(),
            )],
            "does not record utc_offset=+09:00",
        ),
        (
            "a server started with embeddings",
            vec![(
                "FAKE_SERVER_LOG",
                "vault server started utc_offset=+09:00 with_embeddings=true".into(),
            )],
            "started with embeddings",
        ),
        (
            "a --user 99:100 server that exits before listening",
            vec![
                ("FAKE_LOGS_2", not_listening),
                ("FAKE_RUNNING_2", "false".into()),
            ],
            "exited before printing",
        ),
        (
            "a token file left owned by 1000:1000 under --user 99:100",
            vec![("FAKE_TOKEN_OWNER2", "1000:1000".into())],
            "the token file is owned by '1000:1000', expected 99:100",
        ),
    ];
    for (what, overrides, expected) in cases {
        let ov: Vec<(&str, &str)> = overrides.iter().map(|(k, v)| (*k, v.as_str())).collect();
        let r = run_smoke(&ov);
        assert_eq!(
            r.code,
            Some(1),
            "{what}: exits 1 (stderr: {}\nstdout: {})",
            r.stderr,
            r.stdout
        );
        assert!(
            r.stderr.contains("smoke-test: FAIL: ") && r.stderr.contains(expected),
            "{what}: stderr names the failed check `{expected}`: {}",
            r.stderr
        );
        assert!(
            !r.stdout.contains("all checks passed"),
            "{what}: no success line: {}",
            r.stdout
        );
        // Whatever the failure, every container that was started is removed,
        // and its log is printed for the person reading the CI run.
        for id in r.started() {
            assert!(
                r.has_call(&["docker", "rm", "-f", &id]),
                "{what}: removes {id}: {:?}",
                r.calls
            );
            assert!(
                r.stderr.contains(&format!("--- docker logs {id}")),
                "{what}: dumps the log of {id}: {}",
                r.stderr
            );
        }
        assert_eq!(r.leftovers, 0, "{what}: the temp vault folders are removed");
    }
}

#[test]
fn smoke_test_script_accepts_a_docker_stop_that_takes_exactly_ten_seconds() {
    let r = run_smoke(&[("FAKE_DATE_STEP", "10")]);
    assert_eq!(r.code, Some(0), "stderr: {}", r.stderr);
}

#[test]
fn smoke_test_script_checks_every_startup_contract() {
    let text = read_repo_file(SMOKE_TEST);
    let flat = squash(&text);
    for (needle, what) in [
        ("memex --version", "runs `memex --version`"),
        ("docker inspect", "inspects the image"),
        ("Config.User", "reads Config.User"),
        ("1000:1000", "expects user 1000:1000"),
        ("Healthcheck", "checks there is no Healthcheck"),
        ("TZ=Asia/Tokyo", "starts the server with TZ=Asia/Tokyo"),
        (
            "memex serve: vault server listening on http://0.0.0.0:7878",
            "waits for the listening line",
        ),
        (
            "memex serve: generated a new access token in /vaults/.memex/access-token",
            "checks the token line",
        ),
        ("docker logs", "reads docker logs"),
        (".memex/access-token", "checks the token file on the host"),
        ("600", "checks the token file mode 0600"),
        ("/api/v1/info", "calls GET /api/v1/info"),
        ("401", "expects 401 without the token"),
        ("200", "expects 200 with the token"),
        ("Authorization: Bearer", "sends the bearer token"),
        ("server_version", "checks server_version"),
        ("server.log.", "reads server.log.<date>"),
        ("utc_offset", "checks utc_offset"),
        ("+09:00", "expects +09:00"),
        ("--user", "starts a second container with --user"),
        ("99:100", "uses 99:100"),
        ("docker stop", "stops the server with docker stop"),
    ] {
        assert!(flat.contains(needle), "smoke-test.sh {what} (`{needle}`)");
    }
    assert!(
        Regex::new(r"\b60\b").unwrap().is_match(&flat),
        "smoke-test.sh waits up to 60 s for the listening line"
    );
    assert!(
        flat.contains("ExitCode") || flat.contains("docker wait"),
        "smoke-test.sh checks the container's exit code after docker stop"
    );
    for absent in ["--with-embeddings", "MEMEX_ACCESS_TOKEN"] {
        assert!(
            !flat.contains(absent),
            "smoke-test.sh never passes {absent} (no model download, token generated on start)"
        );
    }
    let sleeps = Regex::new(r"\bsleep\s+([0-9.]+)").unwrap();
    for c in sleeps.captures_iter(&text) {
        let secs: f64 = c[1].parse().unwrap();
        assert!(
            secs <= 2.0,
            "smoke-test.sh polls instead of sleeping a fixed time (`sleep {secs}`)"
        );
    }
}

// ---------- docker.yml: parsing ----------

fn workflow() -> Value {
    serde_yaml::from_str(&read_repo_file(WORKFLOW))
        .unwrap_or_else(|e| panic!("{WORKFLOW} is valid YAML: {e}"))
}

fn ytext(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::Null => String::new(),
        other => panic!("expected a scalar, got {other:?}"),
    }
}

fn ymap(v: Option<&Value>) -> BTreeMap<String, String> {
    match v {
        None | Some(Value::Null) => BTreeMap::new(),
        Some(Value::Mapping(m)) => m.iter().map(|(k, v)| (ytext(k), ytext(v))).collect(),
        Some(other) => panic!("expected a mapping, got {other:?}"),
    }
}

/// The `on:` block (YAML 1.1 readers turn a bare `on` into `true`).
fn triggers(wf: &Value) -> &serde_yaml::Mapping {
    wf.get("on")
        .or_else(|| wf.as_mapping().and_then(|m| m.get(Value::Bool(true))))
        .and_then(Value::as_mapping)
        .unwrap_or_else(|| panic!("{WORKFLOW} has an `on:` mapping"))
}

fn jobs(wf: &Value) -> Vec<(String, Value)> {
    wf.get("jobs")
        .and_then(Value::as_mapping)
        .unwrap_or_else(|| panic!("{WORKFLOW} has jobs"))
        .iter()
        .map(|(k, v)| (ytext(k), v.clone()))
        .collect()
}

fn needs(job: &Value) -> Vec<String> {
    match job.get("needs") {
        None => Vec::new(),
        Some(Value::String(s)) => vec![s.clone()],
        Some(Value::Sequence(s)) => s.iter().map(ytext).collect(),
        Some(other) => panic!("needs: is a job name or a list: {other:?}"),
    }
}

fn steps(job: &Value) -> Vec<Value> {
    job.get("steps")
        .and_then(Value::as_sequence)
        .cloned()
        .unwrap_or_default()
}

fn str_list(v: Option<&Value>) -> Vec<String> {
    match v {
        None => Vec::new(),
        Some(Value::Sequence(s)) => s.iter().map(ytext).collect(),
        Some(other) => vec![ytext(other)],
    }
}

// ---------- docker.yml: expressions ----------

#[derive(Clone, Debug, PartialEq)]
enum Ev {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
}

impl Ev {
    fn truthy(&self) -> bool {
        match self {
            Ev::Null => false,
            Ev::Bool(b) => *b,
            Ev::Num(n) => *n != 0.0 && !n.is_nan(),
            Ev::Str(s) => !s.is_empty(),
        }
    }

    fn text(&self) -> String {
        match self {
            Ev::Null => String::new(),
            Ev::Bool(b) => b.to_string(),
            Ev::Num(n) if n.fract() == 0.0 => format!("{}", *n as i64),
            Ev::Num(n) => n.to_string(),
            Ev::Str(s) => s.clone(),
        }
    }

    fn num(&self) -> f64 {
        match self {
            Ev::Null => 0.0,
            Ev::Bool(b) => f64::from(u8::from(*b)),
            Ev::Num(n) => *n,
            Ev::Str(s) if s.trim().is_empty() => 0.0,
            Ev::Str(s) => s.trim().parse().unwrap_or(f64::NAN),
        }
    }
}

fn loose_eq(a: &Ev, b: &Ev) -> bool {
    match (a, b) {
        (Ev::Str(x), Ev::Str(y)) => x.to_lowercase() == y.to_lowercase(),
        (Ev::Null, Ev::Null) => true,
        (Ev::Bool(x), Ev::Bool(y)) => x == y,
        _ => a.num() == b.num(),
    }
}

#[derive(Clone)]
struct Ctx {
    vars: BTreeMap<String, Ev>,
    success: bool,
    failure: bool,
}

impl Ctx {
    fn new() -> Self {
        Ctx {
            vars: BTreeMap::new(),
            success: true,
            failure: false,
        }
    }

    fn set(&mut self, k: &str, v: impl Into<String>) {
        self.vars.insert(k.to_lowercase(), Ev::Str(v.into()));
    }

    fn lookup(&self, path: &str) -> Ev {
        let p = path.to_lowercase();
        let root = p.split('.').next().unwrap_or("");
        match root {
            "github" | "env" | "matrix" | "steps" | "needs" | "runner" | "strategy" | "job"
            | "inputs" => self.vars.get(&p).cloned().unwrap_or(Ev::Null),
            "secrets" => {
                assert_eq!(
                    p, "secrets.github_token",
                    "{WORKFLOW} reads `{path}`; the only secret it may read is GITHUB_TOKEN"
                );
                Ev::Str(TOKEN.to_string())
            }
            _ => panic!("the docker.yml simulator does not know the context `{path}`"),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Lit(Ev),
    Ref(String),
    Func(String),
    Op(&'static str),
    LParen,
    RParen,
    Comma,
}

fn tokenize(src: &str) -> Vec<Tok> {
    let cs: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        let c = cs[i];
        if c.is_whitespace() {
            i += 1;
        } else if c == '\'' {
            let mut s = String::new();
            i += 1;
            loop {
                assert!(i < cs.len(), "unterminated string in `{src}`");
                if cs[i] == '\'' {
                    if i + 1 < cs.len() && cs[i + 1] == '\'' {
                        s.push('\'');
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                s.push(cs[i]);
                i += 1;
            }
            out.push(Tok::Lit(Ev::Str(s)));
        } else if c == '(' {
            out.push(Tok::LParen);
            i += 1;
        } else if c == ')' {
            out.push(Tok::RParen);
            i += 1;
        } else if c == ',' {
            out.push(Tok::Comma);
            i += 1;
        } else if let Some(op) = ["==", "!=", "&&", "||"].into_iter().find(|op| {
            let b: Vec<char> = op.chars().collect();
            i + 1 < cs.len() && cs[i] == b[0] && cs[i + 1] == b[1]
        }) {
            out.push(Tok::Op(op));
            i += 2;
        } else if c == '!' {
            out.push(Tok::Op("!"));
            i += 1;
        } else if c.is_ascii_digit() {
            let start = i;
            while i < cs.len() && (cs[i].is_ascii_digit() || cs[i] == '.') {
                i += 1;
            }
            let s: String = cs[start..i].iter().collect();
            out.push(Tok::Lit(Ev::Num(s.parse().unwrap())));
        } else if c.is_alphabetic() || c == '_' {
            let start = i;
            while i < cs.len() && (cs[i].is_alphanumeric() || "_-.*".contains(cs[i])) {
                i += 1;
            }
            let word: String = cs[start..i].iter().collect();
            let mut j = i;
            while j < cs.len() && cs[j].is_whitespace() {
                j += 1;
            }
            if j < cs.len() && cs[j] == '(' {
                out.push(Tok::Func(word.to_lowercase()));
            } else {
                match word.as_str() {
                    "true" => out.push(Tok::Lit(Ev::Bool(true))),
                    "false" => out.push(Tok::Lit(Ev::Bool(false))),
                    "null" => out.push(Tok::Lit(Ev::Null)),
                    _ => out.push(Tok::Ref(word)),
                }
            }
        } else {
            panic!("the docker.yml simulator cannot read `{c}` in the expression `{src}`");
        }
    }
    out
}

struct Parser<'a> {
    toks: Vec<Tok>,
    i: usize,
    ctx: &'a Ctx,
    src: String,
}

impl Parser<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.i)
    }

    fn eat(&mut self, t: &Tok) -> bool {
        if self.peek() == Some(t) {
            self.i += 1;
            true
        } else {
            false
        }
    }

    fn or(&mut self) -> Ev {
        let mut l = self.and();
        while self.eat(&Tok::Op("||")) {
            let r = self.and();
            if !l.truthy() {
                l = r;
            }
        }
        l
    }

    fn and(&mut self) -> Ev {
        let mut l = self.cmp();
        while self.eat(&Tok::Op("&&")) {
            let r = self.cmp();
            if l.truthy() {
                l = r;
            }
        }
        l
    }

    fn cmp(&mut self) -> Ev {
        let l = self.unary();
        if self.eat(&Tok::Op("==")) {
            let r = self.unary();
            return Ev::Bool(loose_eq(&l, &r));
        }
        if self.eat(&Tok::Op("!=")) {
            let r = self.unary();
            return Ev::Bool(!loose_eq(&l, &r));
        }
        l
    }

    fn unary(&mut self) -> Ev {
        if self.eat(&Tok::Op("!")) {
            return Ev::Bool(!self.unary().truthy());
        }
        self.primary()
    }

    fn primary(&mut self) -> Ev {
        let t = self
            .peek()
            .cloned()
            .unwrap_or_else(|| panic!("expression `{}` ends early", self.src));
        self.i += 1;
        match t {
            Tok::Lit(v) => v,
            Tok::Ref(r) => self.ctx.lookup(&r),
            Tok::LParen => {
                let v = self.or();
                assert!(self.eat(&Tok::RParen), "unbalanced ( in `{}`", self.src);
                v
            }
            Tok::Func(name) => {
                assert!(self.eat(&Tok::LParen));
                let mut args = Vec::new();
                if !self.eat(&Tok::RParen) {
                    loop {
                        args.push(self.or());
                        if self.eat(&Tok::RParen) {
                            break;
                        }
                        assert!(self.eat(&Tok::Comma), "bad arguments in `{}`", self.src);
                    }
                }
                self.call(&name, &args)
            }
            other => panic!("unexpected {other:?} in `{}`", self.src),
        }
    }

    fn call(&self, name: &str, args: &[Ev]) -> Ev {
        let s = |i: usize| args.get(i).map(Ev::text).unwrap_or_default().to_lowercase();
        match name {
            "startswith" => Ev::Bool(s(0).starts_with(&s(1))),
            "endswith" => Ev::Bool(s(0).ends_with(&s(1))),
            "contains" => Ev::Bool(s(0).contains(&s(1))),
            "format" => {
                let mut f = args.first().map(Ev::text).unwrap_or_default();
                for (n, a) in args.iter().enumerate().skip(1) {
                    f = f.replace(&format!("{{{}}}", n - 1), &a.text());
                }
                Ev::Str(f.replace("{{", "{").replace("}}", "}"))
            }
            "success" => Ev::Bool(self.ctx.success),
            "failure" => Ev::Bool(self.ctx.failure),
            "always" => Ev::Bool(true),
            "cancelled" => Ev::Bool(false),
            other => panic!(
                "the docker.yml simulator does not support `{other}()` (in `{}`)",
                self.src
            ),
        }
    }
}

fn eval(src: &str, ctx: &Ctx) -> Ev {
    let t = src.trim();
    let inner = t
        .strip_prefix("${{")
        .and_then(|r| r.strip_suffix("}}"))
        .filter(|r| !r.contains("${{"))
        .unwrap_or(t);
    let mut p = Parser {
        toks: tokenize(inner),
        i: 0,
        ctx,
        src: inner.to_string(),
    };
    let v = p.or();
    assert!(p.i == p.toks.len(), "trailing tokens in `{inner}`");
    v
}

fn interp(s: &str, ctx: &Ctx) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(start) = rest.find("${{") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 3..];
        let end = after
            .find("}}")
            .unwrap_or_else(|| panic!("unterminated ${{{{ in `{s}`"));
        out.push_str(&eval(&after[..end], ctx).text());
        rest = &after[end + 2..];
    }
    out.push_str(rest);
    out
}

fn has_status_fn(cond: &str) -> bool {
    Regex::new(r"\b(success|always|failure|cancelled)\s*\(")
        .unwrap()
        .is_match(cond)
}

// ---------- docker.yml: simulator ----------

#[derive(Debug, Clone)]
enum SimEv {
    Checkout {
        git_ref: String,
        fetch_depth: String,
    },
    Build {
        inputs: BTreeMap<String, String>,
        digest: String,
    },
    Login {
        registry: String,
        password: String,
    },
    Docker(Vec<String>),
    Smoke(Vec<String>),
}

#[derive(Debug)]
struct EntryRun {
    job: String,
    runs_on: String,
    events: Vec<SimEv>,
    ok: bool,
    error: String,
}

#[derive(Debug, Default)]
struct Sim {
    results: BTreeMap<String, String>,
    entries: Vec<EntryRun>,
}

impl Sim {
    fn ran(&self) -> BTreeSet<String> {
        self.results
            .iter()
            .filter(|(_, r)| *r != "skipped")
            .map(|(j, _)| j.clone())
            .collect()
    }

    fn failed(&self) -> Vec<String> {
        self.results
            .iter()
            .filter(|(_, r)| *r == "failure")
            .map(|(j, _)| j.clone())
            .collect()
    }

    fn summary(&self) -> String {
        let mut s = format!("job results: {:?}", self.results);
        for e in &self.entries {
            if !e.ok {
                s.push_str(&format!(
                    "\n  {} ({}) failed: {}",
                    e.job, e.runs_on, e.error
                ));
            }
        }
        s
    }

    fn builds(&self) -> Vec<(&EntryRun, &BTreeMap<String, String>, &str)> {
        let mut v = Vec::new();
        for e in &self.entries {
            for ev in &e.events {
                if let SimEv::Build { inputs, digest } = ev {
                    v.push((e, inputs, digest.as_str()));
                }
            }
        }
        v
    }

    fn docker_calls(&self) -> Vec<(&EntryRun, &Vec<String>)> {
        let mut v = Vec::new();
        for e in &self.entries {
            for ev in &e.events {
                if let SimEv::Docker(a) = ev {
                    v.push((e, a));
                }
            }
        }
        v
    }

    fn logins(&self) -> Vec<(&EntryRun, &str, &str)> {
        let mut v = Vec::new();
        for e in &self.entries {
            for ev in &e.events {
                if let SimEv::Login { registry, password } = ev {
                    v.push((e, registry.as_str(), password.as_str()));
                }
            }
        }
        v
    }

    /// Entries that pushed an image (a pushing build) or created a manifest.
    fn pushing_jobs(&self) -> BTreeSet<String> {
        let mut s: BTreeSet<String> = self
            .builds()
            .into_iter()
            .filter(|(_, b, _)| pushes(b))
            .map(|(e, _, _)| e.job.clone())
            .collect();
        for (e, a) in self.docker_calls() {
            if is_imagetools_create(a) {
                s.insert(e.job.clone());
            }
        }
        s
    }
}

fn kv_parts(s: &str) -> Vec<(String, String)> {
    s.split([',', '\n'])
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (
                k.trim().trim_matches('"').to_string(),
                v.trim().trim_matches('"').to_string(),
            )
        })
        .collect()
}

fn pushes(b: &BTreeMap<String, String>) -> bool {
    b.get("push").is_some_and(|v| v == "true")
        || b.get("outputs")
            .is_some_and(|o| kv_parts(o).iter().any(|(k, v)| k == "push" && v == "true"))
}

fn loads(b: &BTreeMap<String, String>) -> bool {
    b.get("load").is_some_and(|v| v == "true")
        || b.get("outputs").is_some_and(|o| {
            kv_parts(o)
                .iter()
                .any(|(k, v)| k == "type" && v == "docker")
        })
}

fn list_input(b: &BTreeMap<String, String>, key: &str) -> Vec<String> {
    b.get(key)
        .map(|v| {
            v.split([',', '\n'])
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn is_imagetools_create(a: &[String]) -> bool {
    a.len() >= 3 && a[0] == "buildx" && a[1] == "imagetools" && a[2] == "create"
}

fn parse_kv_file(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut lines = text.lines();
    while let Some(l) = lines.next() {
        if l.trim().is_empty() {
            continue;
        }
        let eq = l.find('=');
        let hd = l.find("<<");
        match (eq, hd) {
            (Some(e), hd) if hd.is_none_or(|h| e < h) => {
                out.push((l[..e].to_string(), l[e + 1..].to_string()));
            }
            (_, Some(h)) => {
                let key = l[..h].to_string();
                let delim = l[h + 2..].trim().to_string();
                let mut body = Vec::new();
                for b in lines.by_ref() {
                    if b == delim {
                        break;
                    }
                    body.push(b);
                }
                out.push((key, body.join("\n")));
            }
            _ => panic!("bad GITHUB_OUTPUT/GITHUB_ENV line `{l}`"),
        }
    }
    out
}

fn glob_match(pat: &str, s: &str) -> bool {
    let re = format!(
        "^{}$",
        regex::escape(pat).replace(r"\*", ".*").replace(r"\?", ".")
    );
    Regex::new(&re).unwrap().is_match(s)
}

fn files_in(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| p.is_file())
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

fn matrix_entries(job: &Value) -> Vec<BTreeMap<String, String>> {
    let Some(m) = job.get("strategy").and_then(|s| s.get("matrix")) else {
        return vec![BTreeMap::new()];
    };
    let map = m
        .as_mapping()
        .unwrap_or_else(|| panic!("the simulator needs a literal matrix mapping, got {m:?}"));
    let flat = |v: &Value| -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        for (k, x) in v.as_mapping().expect("matrix include entries are mappings") {
            match x {
                Value::Mapping(inner) => {
                    for (ik, iv) in inner {
                        out.insert(format!("{}.{}", ytext(k), ytext(ik)), ytext(iv));
                    }
                }
                _ => {
                    out.insert(ytext(k), ytext(x));
                }
            }
        }
        out
    };
    let mut combos: Vec<BTreeMap<String, String>> = vec![BTreeMap::new()];
    let mut base_keys = BTreeSet::new();
    for (k, v) in map {
        let k = ytext(k);
        if k == "include" {
            continue;
        }
        assert!(
            k != "exclude",
            "the simulator does not support matrix exclude"
        );
        base_keys.insert(k.clone());
        let vals = v.as_sequence().expect("matrix values are lists");
        let mut next = Vec::new();
        for c in &combos {
            for x in vals {
                let mut c = c.clone();
                c.insert(k.clone(), ytext(x));
                next.push(c);
            }
        }
        combos = next;
    }
    if base_keys.is_empty() {
        combos.clear();
    }
    if let Some(inc) = map.get("include").and_then(Value::as_sequence) {
        for e in inc {
            let e = flat(e);
            let mut matched = false;
            if !base_keys.is_empty() {
                for c in combos.iter_mut() {
                    let fits = e
                        .iter()
                        .filter(|(k, _)| base_keys.contains(*k))
                        .all(|(k, v)| c.get(k) == Some(v));
                    if fits {
                        for (k, v) in &e {
                            if !base_keys.contains(k) {
                                c.insert(k.clone(), v.clone());
                            }
                        }
                        matched = true;
                    }
                }
            }
            if !matched {
                combos.push(e);
            }
        }
    }
    combos
}

struct SimEnv<'a> {
    fx: &'a Fixture,
    store: PathBuf,
    fail_platform: Option<&'a str>,
    shell: Option<String>,
    digests: u64,
}

impl SimEnv<'_> {
    fn resolve(&self, p: &str) -> PathBuf {
        let p = Path::new(p.trim());
        if p.is_absolute() {
            p.to_path_buf()
        } else {
            self.fx.repo.join(p)
        }
    }

    /// Runs one matrix entry of a job: its steps, in order.
    fn run_entry(
        &mut self,
        job_name: &str,
        job: &Value,
        ctx: &mut Ctx,
        env: &mut BTreeMap<String, String>,
        temp: &Path,
    ) -> EntryRun {
        let mut run = EntryRun {
            job: job_name.to_string(),
            runs_on: interp(&ytext(job.get("runs-on").unwrap_or(&Value::Null)), ctx),
            events: Vec::new(),
            ok: true,
            error: String::new(),
        };
        let docker_log = temp.join("docker.log");
        let smoke_log = temp.join("smoke.log");
        for (idx, step) in steps(job).iter().enumerate() {
            let cond = step
                .get("if")
                .map(ytext)
                .unwrap_or_else(|| "success()".into());
            ctx.success = run.ok;
            ctx.failure = !run.ok;
            if !run.ok && !has_status_fn(&cond) {
                continue;
            }
            for (k, v) in env.iter() {
                ctx.set(&format!("env.{k}"), v.clone());
            }
            let mut step_env = env.clone();
            for (k, v) in ymap(step.get("env")) {
                let v = interp(&v, ctx);
                ctx.set(&format!("env.{k}"), v.clone());
                step_env.insert(k, v);
            }
            if !eval(&cond, ctx).truthy() {
                continue;
            }
            let id = step.get("id").map(ytext);
            let name = step.get("name").map(ytext).unwrap_or_default();
            let mut outputs: Vec<(String, String)> = Vec::new();
            let result: Result<(), String> = if let Some(uses) = step.get("uses").map(ytext) {
                let with: BTreeMap<String, String> = ymap(step.get("with"))
                    .into_iter()
                    .map(|(k, v)| (k, interp(&v, ctx)))
                    .collect();
                self.uses(&uses, &with, ctx, &mut run, &mut outputs)
            } else if let Some(script) = step.get("run").map(ytext) {
                let script = interp(&script, ctx);
                let r = self.run_step(idx, &script, step, &step_env, ctx, temp, &mut outputs, env);
                for (file, word) in [(&docker_log, "docker"), (&smoke_log, "smoke")] {
                    let text = fs::read_to_string(file).unwrap_or_default();
                    for line in text.lines() {
                        let mut parts = line.split(SIM_LOG_SEP);
                        if parts.next() != Some(word) {
                            continue;
                        }
                        let args: Vec<String> = parts.map(str::to_string).collect();
                        run.events.push(if word == "docker" {
                            SimEv::Docker(args)
                        } else {
                            SimEv::Smoke(args)
                        });
                    }
                    let _ = fs::write(file, "");
                }
                r
            } else {
                Err(format!("step {idx} has neither uses: nor run:"))
            };
            if let Some(id) = &id {
                for (k, v) in &outputs {
                    ctx.set(&format!("steps.{id}.outputs.{k}"), v.clone());
                }
                let outcome = if result.is_ok() { "success" } else { "failure" };
                ctx.set(&format!("steps.{id}.outcome"), outcome);
                ctx.set(&format!("steps.{id}.conclusion"), outcome);
            }
            if let Err(e) = result {
                run.ok = false;
                if run.error.is_empty() {
                    run.error = format!("step {idx} `{name}`: {e}");
                }
            }
        }
        run
    }

    fn uses(
        &mut self,
        uses: &str,
        with: &BTreeMap<String, String>,
        ctx: &Ctx,
        run: &mut EntryRun,
        outputs: &mut Vec<(String, String)>,
    ) -> Result<(), String> {
        let action = uses.split('@').next().unwrap_or("").to_lowercase();
        let w = |k: &str| with.get(k).cloned().unwrap_or_default();
        match action.as_str() {
            "actions/checkout" => {
                assert!(
                    w("path").is_empty(),
                    "the simulator checks out only to the workspace root"
                );
                let target = if w("ref").is_empty() {
                    ctx.lookup("github.sha").text()
                } else {
                    w("ref")
                };
                let depth = if with.contains_key("fetch-depth") {
                    w("fetch-depth")
                } else {
                    "1".to_string()
                };
                run.events.push(SimEv::Checkout {
                    git_ref: target.clone(),
                    fetch_depth: depth,
                });
                let mut cmd = Command::new("git");
                cmd.current_dir(&self.fx.repo)
                    .args(["checkout", "-q", "--detach", &target]);
                isolate(&mut cmd);
                let out = cmd.output().unwrap();
                if !out.status.success() {
                    return Err(format!(
                        "checkout {target}: {}",
                        String::from_utf8_lossy(&out.stderr)
                    ));
                }
                Ok(())
            }
            "docker/build-push-action" => {
                self.digests += 1;
                let digest = format!("sha256:{:064x}", 0xd16e_0000_u64 + self.digests);
                run.events.push(SimEv::Build {
                    inputs: with.clone(),
                    digest: digest.clone(),
                });
                if let Some(p) = self.fail_platform {
                    if list_input(with, "platforms").iter().any(|x| x == p) {
                        return Err(format!("simulated build failure on {p}"));
                    }
                }
                outputs.push(("digest".into(), digest.clone()));
                outputs.push(("imageid".into(), digest));
                outputs.push(("metadata".into(), "{}".into()));
                Ok(())
            }
            "docker/login-action" => {
                run.events.push(SimEv::Login {
                    registry: if w("registry").is_empty() {
                        "docker.io".into()
                    } else {
                        w("registry")
                    },
                    password: w("password"),
                });
                Ok(())
            }
            "actions/upload-artifact" => {
                let name = if w("name").is_empty() {
                    "artifact".to_string()
                } else {
                    w("name")
                };
                let dest = self.store.join(&name);
                if dest.exists() {
                    return Err(format!("an artifact named `{name}` was already uploaded"));
                }
                fs::create_dir_all(&dest).unwrap();
                let mut n = 0;
                for line in w("path").lines().map(str::trim).filter(|l| !l.is_empty()) {
                    let p = self.resolve(line);
                    let files: Vec<PathBuf> = if let Some(dir) = line.strip_suffix("/*") {
                        files_in(&self.resolve(dir))
                    } else if p.is_dir() {
                        files_in(&p)
                    } else if p.is_file() {
                        vec![p]
                    } else {
                        Vec::new()
                    };
                    for f in files {
                        fs::copy(&f, dest.join(f.file_name().unwrap())).unwrap();
                        n += 1;
                    }
                }
                if n == 0 && w("if-no-files-found") == "error" {
                    return Err(format!("artifact `{name}`: no files found"));
                }
                Ok(())
            }
            "actions/download-artifact" => {
                let dest = self.resolve(&if w("path").is_empty() {
                    ".".to_string()
                } else {
                    w("path")
                });
                let merge = w("merge-multiple") == "true";
                let mut names: Vec<String> = files_in_dirs(&self.store);
                if !w("name").is_empty() {
                    if !names.contains(&w("name")) {
                        return Err(format!("artifact `{}` not found", w("name")));
                    }
                    names = vec![w("name")];
                } else if !w("pattern").is_empty() {
                    names.retain(|n| glob_match(&w("pattern"), n));
                }
                for n in &names {
                    let to = if merge || !w("name").is_empty() {
                        dest.clone()
                    } else {
                        dest.join(n)
                    };
                    fs::create_dir_all(&to).unwrap();
                    for f in files_in(&self.store.join(n)) {
                        fs::copy(&f, to.join(f.file_name().unwrap())).unwrap();
                    }
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn run_step(
        &self,
        idx: usize,
        script: &str,
        step: &Value,
        step_env: &BTreeMap<String, String>,
        ctx: &Ctx,
        temp: &Path,
        outputs: &mut Vec<(String, String)>,
        job_env: &mut BTreeMap<String, String>,
    ) -> Result<(), String> {
        let file = temp.join(format!("step-{idx}.sh"));
        fs::write(&file, script).unwrap();
        let out_file = temp.join(format!("output-{idx}"));
        let env_file = temp.join(format!("env-{idx}"));
        fs::write(&out_file, "").unwrap();
        fs::write(&env_file, "").unwrap();
        let shell = step.get("shell").map(ytext).or_else(|| self.shell.clone());
        let mut cmd = match shell.as_deref() {
            None => {
                let mut c = Command::new("/bin/bash");
                c.arg("-e");
                c
            }
            Some("bash") => {
                let mut c = Command::new("/bin/bash");
                c.args(["--noprofile", "--norc", "-eo", "pipefail"]);
                c
            }
            Some("sh") => {
                let mut c = Command::new("/bin/sh");
                c.arg("-e");
                c
            }
            Some(other) => panic!("the simulator does not support `shell: {other}`"),
        };
        cmd.arg(&file);
        let wd = step
            .get("working-directory")
            .map(ytext)
            .map(|d| self.resolve(&interp(&d, ctx)))
            .unwrap_or_else(|| self.fx.repo.clone());
        cmd.current_dir(wd);
        isolate(&mut cmd);
        let path = format!(
            "{}:{}",
            self.fx.root.join("bin").display(),
            std::env::var("PATH").unwrap_or_default()
        );
        cmd.env("PATH", path)
            .env("CI", "true")
            .env("GITHUB_ACTIONS", "true")
            .env("GITHUB_OUTPUT", &out_file)
            .env("GITHUB_ENV", &env_file)
            .env("GITHUB_STEP_SUMMARY", temp.join("summary.md"))
            .env("GITHUB_PATH", temp.join("path.txt"))
            .env("GITHUB_WORKSPACE", &self.fx.repo)
            .env("GITHUB_EVENT_NAME", ctx.lookup("github.event_name").text())
            .env("GITHUB_SHA", ctx.lookup("github.sha").text())
            .env("GITHUB_REF", ctx.lookup("github.ref").text())
            .env("GITHUB_REPOSITORY", ctx.lookup("github.repository").text())
            .env("GITHUB_RUN_ID", ctx.lookup("github.run_id").text())
            .env("RUNNER_TEMP", temp)
            .env("RUNNER_OS", "Linux")
            .env("SIM_DOCKER_LOG", temp.join("docker.log"))
            .env("SIM_SMOKE_LOG", temp.join("smoke.log"));
        for (k, v) in step_env {
            cmd.env(k, v);
        }
        let (code, stdout, stderr) = run_bounded(cmd, 60, temp);
        for (k, v) in parse_kv_file(&fs::read_to_string(&out_file).unwrap_or_default()) {
            outputs.push((k, v));
        }
        for (k, v) in parse_kv_file(&fs::read_to_string(&env_file).unwrap_or_default()) {
            job_env.insert(k, v);
        }
        if code == Some(0) {
            Ok(())
        } else {
            Err(format!("exit {code:?}\nstdout: {stdout}\nstderr: {stderr}"))
        }
    }
}

fn files_in_dirs(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.path().is_dir())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

type Event = Vec<(&'static str, String)>;

fn event_ctx(event: &Event, wf: &Value) -> Ctx {
    let mut ctx = Ctx::new();
    for (k, v) in [
        ("github.repository", "connordodge/open_memex"),
        ("github.repository_owner", "connordodge"),
        ("github.actor", "release-maintainer"),
        ("github.server_url", "https://github.com"),
        ("github.token", TOKEN),
        ("runner.os", "Linux"),
    ] {
        ctx.set(k, v);
    }
    ctx.set(
        "github.workflow",
        wf.get("name").map(ytext).unwrap_or_default(),
    );
    for (k, v) in event {
        ctx.set(k, v.clone());
    }
    ctx
}

fn pr_event(fx: &Fixture, head: &str, number: &str, run_id: &str) -> Event {
    let sha = fx.sha(head);
    vec![
        ("github.event_name", "pull_request".into()),
        ("github.sha", sha.clone()),
        ("github.ref", format!("refs/pull/{number}/merge")),
        ("github.ref_name", format!("{number}/merge")),
        ("github.head_ref", "feature/docker".into()),
        ("github.base_ref", "main".into()),
        ("github.event.number", number.into()),
        ("github.event.pull_request.number", number.into()),
        ("github.event.pull_request.head.sha", sha),
        ("github.run_id", run_id.into()),
        ("github.run_attempt", "1".into()),
    ]
}

fn release_event(
    fx: &Fixture,
    head_branch: &str,
    head: &str,
    conclusion: &str,
    trigger: &str,
    run_id: &str,
) -> Event {
    vec![
        ("github.event_name", "workflow_run".into()),
        ("github.sha", fx.sha("main")),
        ("github.ref", "refs/heads/main".into()),
        ("github.ref_name", "main".into()),
        ("github.event.workflow_run.conclusion", conclusion.into()),
        ("github.event.workflow_run.event", trigger.into()),
        ("github.event.workflow_run.head_branch", head_branch.into()),
        ("github.event.workflow_run.head_sha", fx.sha(head)),
        ("github.event.workflow_run.name", "Release".into()),
        ("github.event.workflow_run.id", format!("9{run_id}")),
        ("github.run_id", run_id.into()),
        ("github.run_attempt", "1".into()),
    ]
}

/// Walks docker.yml's jobs for `event` (see the module comment).
fn simulate(fx: &Fixture, event: &Event, fail_platform: Option<&str>) -> Sim {
    static RUNS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = RUNS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let wf = workflow();
    let all = jobs(&wf);
    let names: Vec<String> = all.iter().map(|(n, _)| n.clone()).collect();
    let base = event_ctx(event, &wf);
    let sim_dir = fx.root.join(format!("sim-{n}"));
    let store = sim_dir.join("artifacts");
    fs::create_dir_all(&store).unwrap();
    git(&fx.repo, &["checkout", "-q", "main"]);
    let mut senv = SimEnv {
        fx,
        store,
        fail_platform,
        shell: wf
            .get("defaults")
            .and_then(|d| d.get("run"))
            .and_then(|r| r.get("shell"))
            .map(ytext),
        digests: n as u64 * 100,
    };
    let wf_env = ymap(wf.get("env"));
    let mut sim = Sim::default();
    let mut job_outputs: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    while sim.results.len() < all.len() {
        let (name, job) = all
            .iter()
            .find(|(n, j)| {
                !sim.results.contains_key(n) && needs(j).iter().all(|d| sim.results.contains_key(d))
            })
            .unwrap_or_else(|| panic!("{WORKFLOW}: needs: names an unknown job or has a cycle"));
        let deps = needs(job);
        for d in &deps {
            assert!(names.contains(d), "{name} needs unknown job {d}");
        }
        let mut ctx = base.clone();
        for (k, v) in &wf_env {
            ctx.set(&format!("env.{k}"), interp(v, &base));
        }
        for d in &deps {
            ctx.set(&format!("needs.{d}.result"), sim.results[d].clone());
            for (k, v) in job_outputs.get(d).cloned().unwrap_or_default() {
                ctx.set(&format!("needs.{d}.outputs.{k}"), v);
            }
        }
        let needs_ok = deps.iter().all(|d| sim.results[d] == "success");
        ctx.success = needs_ok;
        ctx.failure = deps.iter().any(|d| sim.results[d] == "failure");
        let cond = job
            .get("if")
            .map(ytext)
            .unwrap_or_else(|| "success()".into());
        let runs = if has_status_fn(&cond) {
            eval(&cond, &ctx).truthy()
        } else {
            needs_ok && eval(&cond, &ctx).truthy()
        };
        if !runs {
            sim.results.insert(name.clone(), "skipped".into());
            continue;
        }
        let mut all_ok = true;
        let mut outs = BTreeMap::new();
        for (ei, entry) in matrix_entries(job).iter().enumerate() {
            let mut ectx = ctx.clone();
            for (k, v) in entry {
                ectx.set(&format!("matrix.{k}"), v.clone());
            }
            ectx.set("github.job", name.clone());
            let temp = sim_dir.join(format!("{name}-{ei}"));
            fs::create_dir_all(&temp).unwrap();
            ectx.set("runner.temp", temp.display().to_string());
            ectx.set("github.workspace", fx.repo.display().to_string());
            let mut env: BTreeMap<String, String> = wf_env
                .iter()
                .map(|(k, v)| (k.clone(), interp(v, &ectx)))
                .collect();
            for (k, v) in ymap(job.get("env")) {
                let v = interp(&v, &ectx);
                env.insert(k, v);
            }
            let run = senv.run_entry(name, job, &mut ectx, &mut env, &temp);
            all_ok &= run.ok;
            for (k, v) in ymap(job.get("outputs")) {
                outs.insert(k, interp(&v, &ectx));
            }
            sim.entries.push(run);
        }
        job_outputs.insert(name.clone(), outs);
        sim.results.insert(
            name.clone(),
            if all_ok { "success" } else { "failure" }.into(),
        );
    }
    sim
}

/// Tags v1.3.0, v1.4.1 and v1.4.2 on their own commits, then `main` (1.5.0).
fn release_fixture() -> Fixture {
    fixture(&[
        ("v1.3.0", "1.3.0", &["v1.3.0"]),
        ("v1.4.1", "1.4.1", &["v1.4.1"]),
        ("v1.4.2", "1.4.2", &["v1.4.2"]),
        ("main", "1.5.0", &[]),
    ])
}

/// A PR whose Cargo.toml says 3.1.4, on top of a v1.4.2 release.
fn pr_fixture() -> Fixture {
    fixture(&[("base", "1.4.2", &["v1.4.2"]), ("main", "3.1.4", &[])])
}

fn good_release(fx: &Fixture) -> Sim {
    simulate(
        fx,
        &release_event(fx, "v1.4.2", "v1.4.2", "success", "push", "2001"),
        None,
    )
}

fn pr_run(fx: &Fixture) -> Sim {
    simulate(fx, &pr_event(fx, "main", "7", "1001"), None)
}

fn platform_of(b: &BTreeMap<String, String>) -> String {
    let p = list_input(b, "platforms");
    assert_eq!(
        p.len(),
        1,
        "each build names its one platform in `platforms:`: {b:?}"
    );
    p[0].clone()
}

fn expected_arches() -> BTreeSet<(String, String)> {
    [AMD64, ARM64]
        .iter()
        .map(|(p, r)| (p.to_string(), r.to_string()))
        .collect()
}

fn job_permissions(job: &Value) -> Option<BTreeMap<String, String>> {
    match job.get("permissions") {
        None => None,
        Some(Value::Mapping(_)) => Some(ymap(job.get("permissions"))),
        Some(other) => panic!("permissions are a mapping, not `{other:?}`"),
    }
}

fn perms(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

// ---------- docker.yml: static contract ----------

#[test]
fn docker_yml_triggers_are_exactly_release_workflow_run_and_pull_request_paths() {
    let wf = workflow();
    let on = triggers(&wf);
    let events: BTreeSet<String> = on.keys().map(ytext).collect();
    assert_eq!(
        events,
        ["pull_request", "workflow_run"]
            .iter()
            .map(|s| s.to_string())
            .collect::<BTreeSet<_>>(),
        "docker.yml triggers on workflow_run and pull_request only (no push, workflow_dispatch, schedule or pull_request_target)"
    );
    let wr = on.get("workflow_run").unwrap();
    // Exactly these keys: a `branches:` filter on workflow_run would match the
    // tag name of a tag-push Release and silently stop every publish, and an
    // extra filter on pull_request would quietly narrow when the PR job runs.
    let keys = |v: &Value| -> BTreeSet<String> {
        v.as_mapping()
            .unwrap_or_else(|| panic!("a trigger with filters is a mapping: {v:?}"))
            .keys()
            .map(ytext)
            .collect()
    };
    assert_eq!(
        keys(wr),
        ["types", "workflows"]
            .iter()
            .map(|s| s.to_string())
            .collect::<BTreeSet<_>>(),
        "workflow_run has only `workflows` and `types` (no branches, branches-ignore)"
    );
    assert_eq!(str_list(wr.get("workflows")), ["Release"]);
    assert_eq!(str_list(wr.get("types")), ["completed"]);
    let pr = on.get("pull_request").unwrap();
    assert_eq!(
        keys(pr),
        ["paths"]
            .iter()
            .map(|s| s.to_string())
            .collect::<BTreeSet<_>>(),
        "pull_request has only `paths` (no types, branches, paths-ignore)"
    );
    let mut paths = str_list(pr.get("paths"));
    paths.sort();
    let mut expected = vec![
        "Dockerfile",
        ".dockerignore",
        "deploy/**",
        "Cargo.toml",
        "Cargo.lock",
        "crates/**",
        "scripts/docker/**",
        ".github/workflows/docker.yml",
    ];
    expected.sort();
    assert_eq!(paths, expected, "the pull_request paths filter");
    assert!(
        pr.get("paths-ignore").is_none(),
        "the PR filter is paths only"
    );
}

#[test]
fn docker_yml_workflow_run_names_the_release_workflow_as_release_yml_names_itself() {
    let release: Value = serde_yaml::from_str(&read_repo_file(RELEASE_WORKFLOW)).unwrap();
    let name = release
        .get("name")
        .map(ytext)
        .expect("release.yml has a name");
    let wf = workflow();
    let wr = triggers(&wf)
        .get("workflow_run")
        .expect("docker.yml has a workflow_run trigger");
    assert_eq!(
        str_list(wr.get("workflows")),
        [name],
        "workflow_run.workflows equals release.yml's top-level name"
    );
}

#[test]
fn docker_yml_permissions_are_contents_read_with_packages_write_only_on_pushing_jobs() {
    let wf = workflow();
    assert_eq!(
        ymap(wf.get("permissions")),
        perms(&[("contents", "read")]),
        "the workflow-level permissions are exactly contents: read"
    );
    let fx = release_fixture();
    let sim = good_release(&fx);
    assert!(sim.failed().is_empty(), "{}", sim.summary());
    let pushing = sim.pushing_jobs();
    assert!(
        pushing.len() >= 2,
        "a release run has publish arch jobs and a merge job that push: {pushing:?}\n{}",
        sim.summary()
    );
    for (name, job) in jobs(&wf) {
        let p = job_permissions(&job);
        if pushing.contains(&name) {
            assert_eq!(
                p,
                Some(perms(&[("contents", "read"), ("packages", "write")])),
                "pushing job {name} has exactly contents: read and packages: write"
            );
        } else {
            assert!(
                p.is_none() || p == Some(perms(&[("contents", "read")])),
                "job {name} does not push, so it has contents: read only: {p:?}"
            );
        }
    }
}

#[test]
fn docker_yml_pull_request_jobs_never_log_in_or_push() {
    let fx = pr_fixture();
    let sim = pr_run(&fx);
    assert!(sim.failed().is_empty(), "{}", sim.summary());
    assert!(
        !sim.builds().is_empty(),
        "a PR run builds the image: {}",
        sim.summary()
    );
    assert!(
        sim.logins().is_empty(),
        "a PR run never logs in to a registry"
    );
    for (e, b, _) in sim.builds() {
        assert!(!pushes(b), "PR job {} pushes nothing: {b:?}", e.job);
    }
    for (e, a) in sim.docker_calls() {
        let first = a.first().map(String::as_str).unwrap_or("");
        assert!(
            !matches!(first, "login" | "push" | "tag") && !is_imagetools_create(a),
            "PR job {} runs `docker {}`",
            e.job,
            a.join(" ")
        );
    }
}

#[test]
fn docker_yml_logs_in_to_ghcr_with_github_token_and_reads_no_other_secret() {
    let text = read_repo_file(WORKFLOW);
    let refs = Regex::new(r"\bsecrets\s*(?:\.\s*([A-Za-z_][A-Za-z0-9_]*)|\[)").unwrap();
    for c in refs.captures_iter(&text) {
        assert_eq!(
            c.get(1).map(|m| m.as_str()),
            Some("GITHUB_TOKEN"),
            "docker.yml reads no secret but GITHUB_TOKEN: `{}`",
            &c[0]
        );
    }
    assert!(
        !text.contains("toJSON(secrets)") && !text.contains("toJson(secrets)"),
        "docker.yml never dumps the secrets context"
    );
    let fx = release_fixture();
    let sim = good_release(&fx);
    assert!(sim.failed().is_empty(), "{}", sim.summary());
    let pushing = sim.pushing_jobs();
    assert!(!pushing.is_empty(), "{}", sim.summary());
    for (e, registry, password) in sim.logins() {
        assert_eq!(registry, "ghcr.io", "job {} logs in to ghcr.io", e.job);
        assert_eq!(password, TOKEN, "job {} logs in with GITHUB_TOKEN", e.job);
    }
    for e in sim.entries.iter().filter(|e| pushing.contains(&e.job)) {
        let login = e
            .events
            .iter()
            .position(|ev| matches!(ev, SimEv::Login { .. }));
        let push = e.events.iter().position(|ev| match ev {
            SimEv::Build { inputs, .. } => pushes(inputs),
            SimEv::Docker(a) => is_imagetools_create(a),
            _ => false,
        });
        assert!(
            matches!((login, push), (Some(l), Some(p)) if l < p),
            "pushing job {} ({}) logs in to ghcr.io before it pushes",
            e.job,
            e.runs_on
        );
    }
    for (e, a) in sim.docker_calls() {
        assert!(
            a.first().map(String::as_str) != Some("login"),
            "job {} logs in with docker/login-action, not `docker login`",
            e.job
        );
    }
}

#[test]
fn docker_yml_publishes_only_for_a_successful_tag_push_release_and_pr_jobs_run_only_on_pull_request(
) {
    let fx = pr_fixture();
    let pr = pr_run(&fx);
    assert!(pr.failed().is_empty(), "{}", pr.summary());
    let pr_jobs = pr.ran();
    assert!(!pr_jobs.is_empty(), "a pull_request starts the PR jobs");
    assert!(
        pr.pushing_jobs().is_empty(),
        "a pull_request runs no publish job: {}",
        pr.summary()
    );

    let fx = release_fixture();
    let good = good_release(&fx);
    assert!(good.failed().is_empty(), "{}", good.summary());
    assert!(
        !good.pushing_jobs().is_empty(),
        "a successful v1.4.2 tag-push Release publishes: {}",
        good.summary()
    );
    let both: Vec<String> = good.ran().intersection(&pr_jobs).cloned().collect();
    assert!(
        both.is_empty(),
        "no job runs on both pull_request and workflow_run: {both:?}"
    );

    let fx = fixture(&[
        (
            "v1.4.2",
            "1.4.2",
            &["v1.4.2", "v1.4", "v1.4.2-rc.1", "v1.4.2.1", "release-1.4.2"],
        ),
        ("main", "1.4.2", &[]),
    ]);
    let quiet: Vec<(&str, &str, &str, &str)> = vec![
        ("v1.4.2", "v1.4.2", "failure", "push"),
        ("v1.4.2", "v1.4.2", "cancelled", "push"),
        ("main", "main", "success", "workflow_dispatch"),
        ("v1.4.2", "v1.4.2", "success", "workflow_dispatch"),
        ("main", "main", "success", "push"),
        ("v1.4", "v1.4.2", "success", "push"),
        ("v1.4.2-rc.1", "v1.4.2", "success", "push"),
        ("v1.4.2.1", "v1.4.2", "success", "push"),
        ("release-1.4.2", "v1.4.2", "success", "push"),
    ];
    for (branch, head, conclusion, trigger) in quiet {
        let sim = simulate(
            &fx,
            &release_event(&fx, branch, head, conclusion, trigger, "3001"),
            None,
        );
        let what = format!("head_branch {branch}, conclusion {conclusion}, event {trigger}");
        assert!(
            sim.failed().is_empty(),
            "{what}: the run publishes nothing and does not fail\n{}",
            sim.summary()
        );
        assert!(
            sim.builds().is_empty() && sim.logins().is_empty() && sim.docker_calls().is_empty(),
            "{what}: nothing is built, logged in or pushed\n{}",
            sim.summary()
        );
        let pr_ran: Vec<String> = sim.ran().intersection(&pr_jobs).cloned().collect();
        assert!(pr_ran.is_empty(), "{what}: no PR job runs: {pr_ran:?}");
    }
}

#[test]
fn docker_yml_publish_checks_out_the_release_sha_and_refuses_a_moved_tag_or_version_mismatch() {
    let fx = release_fixture();
    let good = good_release(&fx);
    assert!(good.failed().is_empty(), "{}", good.summary());
    let head = fx.sha("v1.4.2");
    let arch: Vec<&EntryRun> = good
        .entries
        .iter()
        .filter(|e| {
            e.events
                .iter()
                .any(|ev| matches!(ev, SimEv::Build { inputs, .. } if pushes(inputs)))
        })
        .collect();
    assert_eq!(
        arch.len(),
        2,
        "two publish arch entries push: {}",
        good.summary()
    );
    for e in arch {
        let checkout = e.events.iter().position(|ev| {
            matches!(ev, SimEv::Checkout { git_ref, fetch_depth } if *git_ref == head && fetch_depth == "0")
        });
        let first_build = e
            .events
            .iter()
            .position(|ev| matches!(ev, SimEv::Build { .. }));
        assert!(
            matches!((checkout, first_build), (Some(c), Some(b)) if c < b),
            "publish arch job {} ({}) checks out workflow_run.head_sha with fetch-depth 0 before building: {:?}",
            e.job,
            e.runs_on,
            e.events
        );
    }

    let cases: Vec<(&str, Fixture, &str)> = vec![
        (
            "the tag moved: v1.4.2 points at an older commit than head_sha",
            fixture(&[
                ("old", "1.4.2", &["v1.4.2"]),
                ("v1.4.2", "1.4.2", &[]),
                ("main", "1.5.0", &[]),
            ]),
            "v1.4.2",
        ),
        (
            "Cargo.toml's [workspace.package] version is 1.4.3, not 1.4.2",
            fixture(&[("v1.4.2", "1.4.3", &["v1.4.2"]), ("main", "1.5.0", &[])]),
            "v1.4.2",
        ),
        (
            "there is no v1.4.2 tag",
            fixture(&[("v1.4.2", "1.4.2", &["v1.4.1"]), ("main", "1.5.0", &[])]),
            "v1.4.2",
        ),
    ];
    for (what, fx, head) in &cases {
        let sim = simulate(
            fx,
            &release_event(fx, "v1.4.2", head, "success", "push", "4001"),
            None,
        );
        assert!(
            !sim.failed().is_empty(),
            "{what}: the publish run fails\n{}",
            sim.summary()
        );
        for (e, b, _) in sim.builds() {
            assert!(
                !pushes(b),
                "{what}: nothing is pushed ({} pushed {b:?})",
                e.job
            );
        }
        for (e, a) in sim.docker_calls() {
            assert!(
                !is_imagetools_create(a) && a.first().map(String::as_str) != Some("push"),
                "{what}: {} runs `docker {}`",
                e.job,
                a.join(" ")
            );
        }
    }
}

#[test]
fn docker_yml_run_scripts_take_event_values_through_env_not_inline_expressions() {
    let wf = workflow();
    let inline = Regex::new(r"\$\{\{[^}]*\b(github\.event\.|github\.head_ref|inputs\.)").unwrap();
    for (name, job) in jobs(&wf) {
        for step in steps(&job) {
            if let Some(run) = step.get("run").map(ytext) {
                assert!(
                    !inline.is_match(&run),
                    "job {name}: a run script interpolates an event value; pass it through env: instead:\n{run}"
                );
            }
        }
    }
}

#[test]
fn docker_yml_builds_each_arch_natively_on_its_own_runner_without_qemu() {
    let wf = workflow();
    for (name, job) in jobs(&wf) {
        for step in steps(&job) {
            if let Some(uses) = step.get("uses").map(ytext) {
                assert!(
                    !uses.to_lowercase().contains("qemu"),
                    "job {name} sets up QEMU: {uses}"
                );
            }
            if let Some(run) = step.get("run").map(ytext) {
                let lower = run.to_lowercase();
                for bad in ["qemu", "binfmt", "--target", "rustup target", "cross build"] {
                    assert!(
                        !lower.contains(bad),
                        "job {name} cross-builds (`{bad}`):\n{run}"
                    );
                }
            }
        }
    }
    let df = dockerfile();
    for s in &df.stages {
        assert!(
            !s.flags.iter().any(|f| f.starts_with("--platform")),
            "no FROM --platform (native builds): {}",
            s.image
        );
    }
    for i in &df.all {
        for bad in ["BUILDPLATFORM", "rustup target", "--target", "zigbuild"] {
            assert!(
                !i.args.contains(bad),
                "the Dockerfile does not cross-compile (`{bad}`): {}",
                i.args
            );
        }
    }

    let fx = pr_fixture();
    let pr = pr_run(&fx);
    assert!(pr.failed().is_empty(), "{}", pr.summary());
    let pr_arches: Vec<(String, String)> = pr
        .entries
        .iter()
        .filter(|e| e.events.iter().any(|ev| matches!(ev, SimEv::Build { .. })))
        .map(|e| {
            let platforms: BTreeSet<String> = e
                .events
                .iter()
                .filter_map(|ev| match ev {
                    SimEv::Build { inputs, .. } => Some(platform_of(inputs)),
                    _ => None,
                })
                .collect();
            assert_eq!(platforms.len(), 1, "PR entry {} builds one platform", e.job);
            (platforms.into_iter().next().unwrap(), e.runs_on.clone())
        })
        .collect();
    assert_eq!(
        pr_arches.len(),
        2,
        "two PR arch entries build: {pr_arches:?}"
    );
    assert_eq!(
        pr_arches.into_iter().collect::<BTreeSet<_>>(),
        expected_arches(),
        "PR builds: linux/amd64 on ubuntu-24.04 and linux/arm64 on ubuntu-24.04-arm"
    );

    let fx = release_fixture();
    let rel = good_release(&fx);
    assert!(rel.failed().is_empty(), "{}", rel.summary());
    let rel_arches: Vec<(String, String)> = rel
        .builds()
        .into_iter()
        .filter(|(_, b, _)| pushes(b))
        .map(|(e, b, _)| (platform_of(b), e.runs_on.clone()))
        .collect();
    assert_eq!(
        rel_arches.len(),
        2,
        "two publish arch pushes: {rel_arches:?}"
    );
    assert_eq!(
        rel_arches.into_iter().collect::<BTreeSet<_>>(),
        expected_arches(),
        "publish builds: linux/amd64 on ubuntu-24.04 and linux/arm64 on ubuntu-24.04-arm"
    );
    for (e, b, _) in rel.builds() {
        let (p, _) = [AMD64, ARM64]
            .into_iter()
            .find(|(_, r)| *r == e.runs_on)
            .unwrap_or_else(|| panic!("job {} builds on {}", e.job, e.runs_on));
        assert_eq!(
            platform_of(b),
            p,
            "job {} builds its runner's own arch",
            e.job
        );
    }
}

/// `docker buildx imagetools create` args: (tags, sources).
fn imagetools_parts(a: &[String]) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut tags = BTreeSet::new();
    let mut sources = BTreeSet::new();
    let mut i = 3;
    while i < a.len() {
        let w = &a[i];
        if w == "-t" || w == "--tag" {
            tags.insert(a.get(i + 1).cloned().unwrap_or_default());
            i += 2;
        } else if let Some(t) = w.strip_prefix("--tag=").or_else(|| w.strip_prefix("-t=")) {
            tags.insert(t.to_string());
            i += 1;
        } else if ["--annotation", "--builder", "-f", "--file"].contains(&w.as_str()) {
            i += 2;
        } else if w.starts_with('-') {
            i += 1;
        } else {
            sources.insert(w.clone());
            i += 1;
        }
    }
    (tags, sources)
}

fn assert_publish_tags(fx: &Fixture, expected: &[&str]) {
    let sim = good_release(fx);
    assert!(sim.failed().is_empty(), "{}", sim.summary());
    let pushes_by_arch: Vec<(&EntryRun, &BTreeMap<String, String>, &str)> = sim
        .builds()
        .into_iter()
        .filter(|(_, b, _)| pushes(b))
        .collect();
    assert_eq!(pushes_by_arch.len(), 2, "{}", sim.summary());
    let mut digests = BTreeSet::new();
    for (e, b, digest) in &pushes_by_arch {
        assert!(
            list_input(b, "tags").is_empty(),
            "publish arch job {} pushes by digest, with no tag: {b:?}",
            e.job
        );
        let outputs = kv_parts(b.get("outputs").map(String::as_str).unwrap_or(""));
        let has = |k: &str, v: &str| outputs.iter().any(|(a, b)| a == k && b == v);
        assert!(
            has("push-by-digest", "true") && has("name", IMAGE),
            "publish arch job {} pushes {IMAGE} by digest: {b:?}",
            e.job
        );
        digests.insert(format!("{IMAGE}@{digest}"));
    }
    let creates: Vec<(&EntryRun, &Vec<String>)> = sim
        .docker_calls()
        .into_iter()
        .filter(|(_, a)| is_imagetools_create(a))
        .collect();
    assert_eq!(
        creates.len(),
        1,
        "one manifest list is created: {}",
        sim.summary()
    );
    let (merge, args) = creates[0];
    assert!(
        !pushes_by_arch.iter().any(|(e, _, _)| e.job == merge.job),
        "the manifest is created by a merge job, not an arch job"
    );
    let (tags, sources) = imagetools_parts(args);
    let expected: BTreeSet<String> = expected.iter().map(|t| format!("{IMAGE}:{t}")).collect();
    assert_eq!(tags, expected, "the manifest list's tags: {args:?}");
    assert_eq!(
        sources, digests,
        "the manifest list joins both arch digests: {args:?}"
    );
    assert!(
        merge
            .events
            .iter()
            .any(|ev| matches!(ev, SimEv::Checkout { fetch_depth, .. } if fetch_depth == "0")),
        "the merge job checks out full tag history for image-tags.sh"
    );
    for (e, a) in sim.docker_calls() {
        let first = a.first().map(String::as_str).unwrap_or("");
        assert!(
            !matches!(first, "push" | "tag"),
            "job {} runs `docker {}`; tags come only from the manifest list",
            e.job,
            a.join(" ")
        );
    }
}

#[test]
fn docker_yml_publish_pushes_digests_then_merges_one_manifest_with_image_tags_sh_tags() {
    let wf = workflow();
    let merge_uses_script = jobs(&wf).iter().any(|(_, job)| {
        steps(job).iter().any(|s| {
            s.get("run")
                .map(ytext)
                .is_some_and(|r| r.contains(IMAGE_TAGS))
        })
    });
    assert!(merge_uses_script, "docker.yml runs {IMAGE_TAGS}");
    // The newest release gets all three tags.
    assert_publish_tags(&release_fixture(), &["1.4.2", "1.4", "latest"]);
    // A re-run for v1.4.2 after v1.5.0 shipped keeps `latest` on v1.5.0.
    let fx = fixture(&[
        ("v1.4.1", "1.4.1", &["v1.4.1"]),
        ("v1.4.2", "1.4.2", &["v1.4.2"]),
        ("v1.5.0", "1.5.0", &["v1.5.0"]),
        ("main", "1.6.0", &[]),
    ]);
    assert_publish_tags(&fx, &["1.4.2", "1.4"]);
}

#[test]
fn docker_yml_merge_job_needs_every_pushing_job_and_has_no_status_function_in_its_if() {
    let wf = workflow();
    let all = jobs(&wf);
    let pushes_by_digest = |job: &Value| {
        steps(job).iter().any(|s| {
            s.get("uses")
                .map(ytext)
                .is_some_and(|u| u.starts_with("docker/build-push-action@"))
                && s.get("with")
                    .and_then(|w| w.get("outputs"))
                    .map(ytext)
                    .is_some_and(|o| o.contains("push-by-digest=true"))
        })
    };
    let creates_manifest = |job: &Value| {
        steps(job).iter().any(|s| {
            s.get("run")
                .map(ytext)
                .is_some_and(|r| r.contains("imagetools create"))
        })
    };
    let arch_jobs: Vec<&str> = all
        .iter()
        .filter(|(_, j)| pushes_by_digest(j))
        .map(|(n, _)| n.as_str())
        .collect();
    assert!(
        !arch_jobs.is_empty(),
        "docker.yml has a job that pushes an arch image by digest"
    );
    let mergers: Vec<&(String, Value)> = all.iter().filter(|(_, j)| creates_manifest(j)).collect();
    assert_eq!(
        mergers.len(),
        1,
        "exactly one job creates the manifest list: {:?}",
        mergers.iter().map(|(n, _)| n).collect::<Vec<_>>()
    );
    let (name, merge) = mergers[0];
    assert!(
        !arch_jobs.contains(&name.as_str()),
        "the merge job {name} is not itself an arch job"
    );
    // Actions runs a job alongside its siblings unless `needs` orders it, and
    // a failed need skips it: this is what stops a one-arch manifest list.
    let have = needs(merge);
    for arch in &arch_jobs {
        assert!(
            have.iter().any(|n| n == arch),
            "merge job {name} must list the arch job {arch} in needs (needs: {have:?}), or it can run when an arch build failed"
        );
    }
    // A status function in `if:` (always(), failure(), ...) replaces the
    // implicit success() of `needs`, so the job would run after a failure.
    let cond = merge.get("if").map(ytext).unwrap_or_default();
    assert!(
        !has_status_fn(&cond),
        "merge job {name}'s if: has no status function (`{cond}`): it runs only when every needed job succeeded"
    );
    for arch in &arch_jobs {
        let job = &all.iter().find(|(n, _)| n == arch).unwrap().1;
        let cond = job.get("if").map(ytext).unwrap_or_default();
        assert!(
            !has_status_fn(&cond),
            "arch job {arch}'s if: has no status function (`{cond}`)"
        );
        assert!(
            job.get("continue-on-error").is_none(),
            "arch job {arch} does not continue on error: a failed arch must fail the run"
        );
    }
}

#[test]
fn docker_yml_publish_merges_nothing_when_one_arch_fails() {
    for platform in [AMD64.0, ARM64.0] {
        let fx = release_fixture();
        let sim = simulate(
            &fx,
            &release_event(&fx, "v1.4.2", "v1.4.2", "success", "push", "5001"),
            Some(platform),
        );
        assert!(!sim.failed().is_empty(), "{}", sim.summary());
        for (e, a) in sim.docker_calls() {
            assert!(
                !is_imagetools_create(a),
                "the {platform} build failed, yet {} creates the manifest list",
                e.job
            );
        }
    }
}

/// For every arch entry that builds: the smoke-test call, its position and
/// the build it tests.
fn assert_smoke_tests(sim: &Sim, version: &str, publish: bool) {
    let arch: Vec<&EntryRun> = sim
        .entries
        .iter()
        .filter(|e| {
            e.events.iter().any(|ev| match ev {
                SimEv::Build { inputs, .. } => !publish || pushes(inputs),
                _ => false,
            })
        })
        .collect();
    assert_eq!(arch.len(), 2, "two arch entries build: {}", sim.summary());
    for e in arch {
        let smokes: Vec<(usize, &Vec<String>)> = e
            .events
            .iter()
            .enumerate()
            .filter_map(|(i, ev)| match ev {
                SimEv::Smoke(a) => Some((i, a)),
                _ => None,
            })
            .collect();
        assert_eq!(
            smokes.len(),
            1,
            "job {} ({}) runs {SMOKE_TEST} once: {:?}",
            e.job,
            e.runs_on,
            e.events
        );
        let (at, args) = smokes[0];
        assert_eq!(
            args.len(),
            2,
            "{SMOKE_TEST} gets <image-ref> <expected-version>: {args:?}"
        );
        assert_eq!(
            args[1], version,
            "job {} smoke-tests version {version}",
            e.job
        );
        let load = e.events[..at].iter().rev().find_map(|ev| match ev {
            SimEv::Build { inputs, digest } if loads(inputs) => Some((inputs, digest)),
            _ => None,
        });
        let (inputs, digest) = load.unwrap_or_else(|| {
            panic!(
                "job {} loads the image it built into the runner's docker before the smoke test: {:?}",
                e.job, e.events
            )
        });
        let built: Vec<String> = list_input(inputs, "tags");
        assert!(
            built.contains(&args[0]) || args[0] == *digest,
            "job {} smoke-tests the image it just built ({built:?} / {digest}), not `{}`",
            e.job,
            args[0]
        );
        if let Some(push) = e
            .events
            .iter()
            .position(|ev| matches!(ev, SimEv::Build { inputs, .. } if pushes(inputs)))
        {
            assert!(
                at < push,
                "job {} smoke-tests before it pushes: {:?}",
                e.job,
                e.events
            );
        }
    }
}

#[test]
fn docker_yml_every_arch_job_smoke_tests_the_image_it_built_before_any_push() {
    let fx = pr_fixture();
    let pr = pr_run(&fx);
    assert!(pr.failed().is_empty(), "{}", pr.summary());
    // PR runs: the expected version is Cargo.toml's workspace version.
    assert_smoke_tests(&pr, "3.1.4", false);
    let fx = release_fixture();
    let rel = good_release(&fx);
    assert!(rel.failed().is_empty(), "{}", rel.summary());
    assert_smoke_tests(&rel, "1.4.2", true);
}

#[test]
fn docker_yml_builds_pass_the_expected_version_as_the_version_build_arg() {
    for (sim, version) in [
        (pr_run(&pr_fixture()), "3.1.4"),
        (good_release(&release_fixture()), "1.4.2"),
    ] {
        assert!(sim.failed().is_empty(), "{}", sim.summary());
        assert!(!sim.builds().is_empty(), "{}", sim.summary());
        for (e, b, _) in sim.builds() {
            let args = list_input(b, "build-args");
            assert!(
                args.contains(&format!("VERSION={version}")),
                "job {} builds with --build-arg VERSION={version}: {args:?}",
                e.job
            );
        }
    }
}

#[test]
fn docker_yml_pins_every_action_to_a_full_commit_sha_with_a_version_comment() {
    let text = read_repo_file(WORKFLOW);
    let line_re = Regex::new(r"^\s*(?:-\s+)?uses:\s*(\S+)(.*)$").unwrap();
    let target =
        Regex::new(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}$").unwrap();
    let comment = Regex::new(r"^\s+#\s*v\d+(\.\d+)*\S*\s*$").unwrap();
    let mut raw = 0;
    for line in text.lines() {
        let Some(c) = line_re.captures(line) else {
            continue;
        };
        raw += 1;
        assert!(
            target.is_match(&c[1]),
            "`uses:` is pinned to a 40-hex commit SHA: `{}`",
            line.trim()
        );
        assert!(
            comment.is_match(&c[2]),
            "`uses:` has a `# vX.Y.Z` version comment: `{}`",
            line.trim()
        );
    }
    let wf = workflow();
    let parsed: usize = jobs(&wf)
        .iter()
        .map(|(_, j)| steps(j).iter().filter(|s| s.get("uses").is_some()).count())
        .sum();
    assert!(parsed > 0, "docker.yml uses actions");
    assert_eq!(raw, parsed, "every `uses:` is on its own line");
}

#[test]
fn docker_yml_cancels_only_superseded_pr_runs_and_every_job_has_a_timeout() {
    let wf = workflow();
    let fx = release_fixture();
    let ctx_of = |e: &Event| event_ctx(e, &wf);
    let pr_a = ctx_of(&pr_event(&fx, "main", "7", "1001"));
    let pr_b = ctx_of(&pr_event(&fx, "v1.4.1", "7", "1002"));
    let rel_a = ctx_of(&release_event(
        &fx, "v1.4.2", "v1.4.2", "success", "push", "2001",
    ));
    let rel_b = ctx_of(&release_event(
        &fx, "v1.4.1", "v1.4.1", "success", "push", "2002",
    ));
    let cancel = |c: &Value, ctx: &Ctx| -> bool {
        match c.get("cancel-in-progress") {
            None => false,
            Some(Value::Bool(b)) => *b,
            Some(v) => eval(&ytext(v), ctx).truthy(),
        }
    };
    let group = |c: &Value, ctx: &Ctx| -> String {
        match c {
            Value::String(s) => interp(s, ctx),
            _ => interp(&c.get("group").map(ytext).unwrap_or_default(), ctx),
        }
    };
    let top = wf
        .get("concurrency")
        .unwrap_or_else(|| panic!("{WORKFLOW} sets a workflow-level concurrency"));
    assert!(
        cancel(top, &pr_a),
        "superseded pull_request runs are cancelled"
    );
    assert!(!cancel(top, &rel_a), "publish runs are never cancelled");
    assert_eq!(
        group(top, &pr_a),
        group(top, &pr_b),
        "two runs of one PR share a concurrency group, so the newer cancels the older"
    );
    assert_ne!(
        group(top, &rel_a),
        group(top, &rel_b),
        "two publish runs never share a concurrency group (a pending run in a shared group is cancelled)"
    );
    assert_ne!(
        group(top, &pr_a),
        group(top, &rel_a),
        "PR and publish runs never share a concurrency group"
    );
    for (name, job) in jobs(&wf) {
        if let Some(c) = job.get("concurrency") {
            assert!(!cancel(c, &rel_a), "job {name} never cancels a publish run");
        }
        let t = job.get("timeout-minutes").and_then(Value::as_u64);
        assert!(
            t.is_some_and(|t| (1..=360).contains(&t)),
            "job {name} sets timeout-minutes: {:?}",
            job.get("timeout-minutes")
        );
    }
}
