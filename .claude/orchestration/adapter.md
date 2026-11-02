---
repo: connordodge/open_memex
main_branch: main
stack: flutter
worktrees_dir: worktrees
max_implementers_per_feature: 5
lead_flags: "--permission-mode auto"
ui_paths: '^app/lib/src/(widgets|screens|theme)/'
security_paths: 'crates/memex-mcp/src/tools\.rs|crates/memex-mcp/src/main\.rs|api_key|secret'
# No CI: merge-pr.sh REQUIRED_GH_CHECKS defaults to empty and merge-check.sh never exits 2.
---

# Repo adapter: Open Memex

The repo-specific half of the generic orchestration skills (`/orchestrate`,
`/feature-lead`, `/orchestrate-retro`, all in `~/.claude/skills/`). The scripts are in
`scripts/`. Each run gets a frozen copy in `<runDir>/bin/`.

The repo is a Rust workspace (`crates/memex-core` for storage, indexing and search;
`crates/memex-mcp` for the `memex` CLI and the MCP server) plus a Flutter macOS app
(`app/`). The app reads the vault's SQLite directly and writes through the `memex` CLI.
Released clients: none are distributed yet. Connor runs the app and `memex` locally
against his real vault, so **schema migrations touch real data** on first open.

**There is no CI.** Every check runs locally in `merge-check.sh` on the merged tree.
Connor's decision (2026-10-03): ignore CI and coverage Actions; do local builds only.

## Scripts

| Script | Use |
|---|---|
| `wi-setup.sh <id> <branch> [base-ref]` | First command in every new worktree. Creates or takes over the branch, copies `.claude/settings.local.json`, runs `flutter pub get` in `app/` and `cargo fetch`. Refuses the main checkout and the gate worktree. |
| `suite-slot.sh <cmd…>` | Every FULL `cargo test --workspace` and every full `flutter test` runs through this. 3 slots machine-wide. Focused single-file runs skip it. |
| `merge-check.sh <pr> [--base ref] [--complexity auto\|routine\|tricky] [--skip-suites] [--ac-map-only] [--pr-body-file f]` | The merged-tree check, below. Exit 0 pass, 1 fail. |
| `mutation-spot.sh …` | Operator mutants on the PR's added `.rs` and `.dart` lines. Called by merge-check on tricky WIs. |
| `merge-pr.sh <pr> <runDir> "<note>"` | Runs the merge check (log in `<runDir>/gate-<pr>-<stamp>.log`), waits for mergeable, re-gates if main moved, checks GitHub mergeable before gating, merges exactly the tested head with a merge commit, ticks the WI's ACs, and appends to the ledger. No required GitHub checks. Exit 0 merged, 1 fail, 3 not mergeable. |
| `merge-queue.sh <runDir>` | The one merge queue: pops `<runDir>/merge-queue.txt` (append or reorder it), runs merge-pr per PR, drops a PR that fails, and stops (PR kept) on infra failures. `MUTATION_OFF=1` pauses the MUTATION stage. Never run two at once. |

**What merge-check verifies** on `origin/main` + the PR, cheapest first:
- no conflicts;
- **AC MAP** for Work Item PRs (a `Closes #N` / `Part of #N` line or a `feat/` branch):
  every AC maps to a test cell `<repo-relative path> :: <test name>` that exists in the
  merged tree; GATE and MANUAL rows follow PROTOCOL.md §5;
- **SCHEMA**: `APP_SCHEMA_VERSION` in `crates/memex-core/src/schema.rs` is main's or
  main's + 1, the new version constant doesn't already exist on main, and no added
  `DROP TABLE`;
- `cargo fmt --check`, clippy, `cargo test --workspace`;
- `flutter analyze` and `flutter test` in `app/`;
- **RED ON MAIN**: the PR's test changes fail against main's code;
- **MUTATION** on tricky WIs (unlabeled counts as tricky): at most 25% of mutants on
  added lines survive; a truly equivalent mutant goes under `## Mutation exemptions`.

The exact strictness (clippy and analyze) and baseline counts are in the script header
and the "Lead addendum" below.

## Lead addendum

These rules are appended to PROTOCOL.md for every run.

- **Never commit** `.env`, `.env.local`, `.claude/settings.local.json`, `target/`, or
  anything under `app/build/` or `app/macos/Flutter/ephemeral/`. Check
  `git diff --cached --name-only` before every commit.
- **Full suites** for what you touch, with the pass counts in the PR body:
  - Rust: `cargo fmt --check`, `cargo clippy --workspace --all-targets -- -D warnings`,
    `<runDir>/bin/suite-slot.sh cargo test --workspace`.
  - App: `cd app && flutter analyze && <runDir>/bin/suite-slot.sh flutter test`.
  - A PR touching both runs both.
  - Baseline on origin/main 6f09189 (2026-10-03): `cargo test --workspace` 133 passed,
    `flutter test` 25 passed, clippy 0 warnings, `flutter analyze` no issues. A full gate
    takes about 1 minute plus mutants.
  - **rustfmt ratchet:** main is not fmt-clean (98 hunks in about 12 files). New `.rs`
    files must be fmt-clean, and a changed file may not gain hunks. Don't reformat
    files you don't otherwise touch: that churns other WIs' diffs.
  - **AC map test names:** a Dart cell's test name is the literal string passed to
    `test(`/`testWidgets(` (not group-prefixed); a Rust cell's name is the `fn` name.
- **Schema (memex-core).** The schema is hand-written in
  `crates/memex-core/src/schema.rs` as layered `V1..Vn` constants with
  `APP_SCHEMA_VERSION`. Rules:
  - Exactly one Work Item owns each version bump; the ledger's migration order says
    which. Never bump the version in a WI that doesn't own it.
  - Add-only DDL: `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE … ADD COLUMN`, indexes.
    Never `DROP TABLE`, never drop or rename columns.
  - Every bump ships a migration test from a fixture of the previous version, following
    `crates/memex-core/tests/migration_v4.rs`.
  - Tell the orchestrator exactly which tables and columns change.
  - On `REGENERATE-MIGRATION`: merge `origin/main`, renumber your version to main's + 1,
    re-run the migration test and the full Rust suite.
- **The app reads SQLite directly** (`app/lib/src/db.dart`). A new column or table the
  app reads must exist in the schema WI it depends on; the app's SQL is checked only by
  the app's tests, so cover each new query with a test against a real schema.
- **The app writes through the CLI** (`app/lib/src/memex_cli.dart`). A new CLI
  subcommand used by the app gets a `MemexCli` wrapper and a fake in tests; never shell
  out to a real `memex` binary from a Flutter test.
- **Never touch Connor's real vault** (`~/memex`) or
  `~/.cargo/bin/memex`. Tests use temp dirs. Never run `cargo install`.
- **Signing.** Commits are signed with an SSH key (1Password agent).
  - If signing fails with `Permission denied (os error 13)`, retry the same commit with
    the Bash sandbox disabled.
  - If 1Password is locked (`Could not connect to socket`), keep the changes staged, tell
    Connor in the tab, and send `blocked: signing`.
  - Never use `--no-gpg-sign`.
- **Stash.** The stash stack is shared by every worktree. Use `git stash push -u -m <tag>`
  and `git stash apply <sha>`, never a bare `pop`.
- **Vocabulary.** `GLOSSARY.md` is canonical. Use its terms in code, tool names, prompts
  and docs. Edit only your own entries.
- **UI conventions.** Riverpod providers live in `app/lib/src/state/`. Add stable `Key`s
  for robot tests. Reuse `app/lib/src/theme/` tokens; no hard-coded colours.

## Tricky triggers

These add to the generic rubric:
- any change to `crates/memex-core/src/schema.rs`;
- block identity and matching (`blocks.rs`), transclusion parsing and rendering;
- `notes.rs` save path, versioning and optimistic concurrency;
- link extraction (`link_extractor.rs`, `links.rs`) and search fusion (`search.rs`);
- MCP tool contracts and server-side rule enforcement (pinning, marker, depth);
- the app's segmented editor, conflict merge and polling (editor logic, row editing and line
  geometry; a colour or style constant with no geometry change is routine, run 20261102-221 D2);
- anything that reads or writes the vault from both the app and the server.

## Review notes

### correctness
- `update_note_with_options` is the single write path; every server-side rule belongs in
  core so the CLI and MCP share it.
- Optimistic concurrency: every write carries `expected_version`; retries re-read.
- The app's SQLite reads run while the server writes (WAL); never hold a read
  transaction across awaits.
- Byte offsets vs char offsets in Rust strings: slicing on non-char boundaries panics.

### security
- MCP is the agent's channel; CLI is the person's. A rule that guards agent writes must
  be enforced in the MCP path, not only described in a prompt.
- No model calls, no API keys anywhere.

### seams
- One schema version bump per release, owned by one WI; check the ledger's order.
- Run `git merge-tree` against the other in-flight branches the orchestrator lists.
- `GLOSSARY.md` consistency.
- Axum routers nested under one prefix use the same path-parameter names (a mismatch panics at startup only on the merged tree).
- A test file several WIs edit needs one owner in the ledger's overlap table.

### tests
- Rust integration tests live in `crates/*/tests/`; CLI tests in
  `crates/memex-mcp/tests/` drive the built binary.
- Flutter tests override `memexCliProvider` and `vaultDbProvider` with fakes; time comes
  from an injected clock, never `DateTime.now()` in code under a pinned test.
- Robot journeys find widgets by `Key`.

### ui
- Compare copy, labels and states (loading, empty, error) with the Spec exactly.
- Check text scale and narrow window widths for overflow.

## Release

Connor's decision (2026-10-03): no CI, local builds only.

**Staging.** Once everything is merged, after the migration warning:
1. `n` = 1 + the highest existing `staging-<YYYYMMDD>.*` tag for today.
2. `git tag -a staging-<YYYYMMDD>.<n> -m "<run summary>" origin/main`, then
   `git push origin staging-<YYYYMMDD>.<n>`. Push the **tag only**.
3. Point `<repo>/worktrees/_staging` at the tag. If it already exists, reuse it: the last
   `flutter build macos` leaves `app/macos/Podfile`, `Runner.xcodeproj` and SwiftPM folders
   dirty, so `git worktree remove` refuses and auto mode blocks `--force`. Run
   `git -C worktrees/_staging restore app/macos && git -C worktrees/_staging clean -fdq app/macos`,
   then `git -C worktrees/_staging checkout --detach staging-<…>`. Otherwise
   `git worktree add --detach <repo>/worktrees/_staging staging-<…>`. Then in the background:
   `cargo build --release -p memex-mcp` and `cd app && flutter build macos --release`.
4. Hand Connor:
   - the app at `worktrees/_staging/app/build/macos/Build/Products/Release/`;
   - the binary at `worktrees/_staging/target/release/memex`;
   - the command to install the binary when he's ready, which **he runs**:
     `cargo install --path worktrees/_staging/crates/memex-mcp --locked`;
   - a warning that opening an existing vault with the new binary applies the schema
     migration to it, so test on a scratch vault first.

**Prod.** Only after Connor's explicit go: a version tag `v<ver>` on the merged main,
pushed by Connor himself (auto mode blocks it). No release pipeline or notes publishing.

## CI facts

- No CI. No GitHub Actions, no required checks, no coverage gate. The merge check is
  the only gate; the orchestrator merges on it. Run 20261003-1 has per-PR review off.
