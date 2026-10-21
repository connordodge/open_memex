# Open Memex orchestration lessons

These are repo-specific. Read at kickoff and before every dispatch. Generic lessons are in
`~/.claude/skills/orchestrate/LESSONS.md`. `/orchestrate-retro` curates this file.

Seeded at adapter creation (2026-10-03). Run 20261003-1 (Spec #1: 29 WIs, 31 PRs, review off)
added the lessons marked (run 1).

- **There is no CI, so the merge check is the only safety net.**
  Why: nothing else runs the Rust or Flutter suites on a PR.
  How: never merge without a passing `merge-check.sh` run on the merged tree.
- **Schema migrations apply to Connor's real vault on first open.**
  Why: the app and `memex` open `~/memex` directly; there is no staging
  data.
  How: add-only DDL, a migration test from a previous-version fixture, and a migration
  warning before any staging build.
- **`UiStateStore` writes are unawaited; tests await `store.flush()`.** (run 1)
  Why: `tabs_state_test` deleted its temp dir mid-write and read state before the write
  landed; it failed three gates (#33, #43) until #45 added `flush()`.
  How: any test that reads back or deletes a vault dir after store writes awaits flush first.
- **Shared daily-note helpers exist once; check before writing SQL.** (run 1)
  Why: #50 and #54 re-implemented the "daily note for date" lookup and the transclusion
  span (rulings D27, D28).
  How: use `links::daily_note_id_for_title` / `daily::daily_note_for_date` /
  `daily::stored_blocks` and `transclusion::resolve_span`; expose a private helper as
  `pub(crate)` instead of copying it.
- **The gate times out hung suites and flags a full disk.** (run 1)
  Why: ENOSPC left `flutter test` hung for 20 min (#47).
  How: enforced: the Flutter suite has a 900 s timeout (`FLUTTER_SUITE_TIMEOUT`), an
  `INFRA: ENOSPC` line marks disk-full failures (re-run, don't fix code), `suite-slot.sh`
  kills a suite after 25 min, and `wi-setup.sh` warns under 20 GB free.
- **The mutation floor needs 2+ mutants.** (run 1)
  Why: a 1-mutant run passed with its only mutant surviving (#32).
  How: enforced in `merge-check.sh` and `mutation-spot.sh`.
- **Dart test names with apostrophes can trip the AC map.** (run 1)
  Why: #40 had to rename two tests (`today\'s`).
  How: avoid apostrophes and quotes in `test()` / `testWidgets()` descriptions.


Run 20261020-66 (#66 hosted vault: 1 ticket, 41 WIs, about 48 PRs; review off and mutation paused
mid-run) added the lessons below.

- **Merge through `scripts/merge-queue.sh`; don't run merge-pr loops by hand.** (run 20261020-66)
  Why: racing loops re-gated #110, and a stopped gate's stale index.lock made a queue drop 23 PRs.
  How: one file-driven queue (`<runDir>/merge-queue.txt`) that stops on infra failures. `reset_gate`
  now clears an orphaned `_gate` index.lock. merge-pr checks GitHub mergeable before gating.
  `MUTATION_OFF=1` pauses the MUTATION stage when Connor asks. All enforced.
- **Rust MUTATION dominates gate time: about 40–70 s per mutant, 13–35 min per tricky gate.**
  Why: #110's gate took 1,816 s and #108's 2,078 s. Without mutation, the same gates ran in 2–6 min.
  How: see the generic "merge phase is too slow" open item before the next run.
- **Axum routers nested under one prefix must share path-parameter names.**
  Why: V1–V5 nest under `/vaults/{name}/api/v1`; `{id}` vs `{note_id}` panics at startup, and
  only the merged tree shows it.
  How: the architect fixes the parameter names in the wire-contract ruling. Verify trial-merges
  sibling slices and starts the full `api::router()`.
- **A test that waits a fixed wall-clock time flakes under load.**
  Why: `serve_remote.rs :: bridge_rereads_the_utc_offset_for_every_request` ("no preflight after
  30s") failed #149's gate, which hadn't touched it. `sidebar_split_test` hit a temp-dir teardown
  race (`Directory not empty`).
  How: wait on an event or a FakeClock, not a fixed `Instant` budget; await every store's
  `flush()` before deleting a test dir.
- **`app/pubspec.lock` is gitignored in this repo,** so plugin adds change only pubspec.yaml.
  `GeneratedPluginRegistrant.swift` is gitignored too.
