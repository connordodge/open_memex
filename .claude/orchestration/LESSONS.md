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
  (run 20261106-229-230) Every step, suite and mutant now runs under `run-guarded.sh`: a time
  ceiling plus a per-process memory ceiling (`GUARD_MEM_MB`, default a quarter of RAM), because a
  `tags.rs::code_spans` mutant looped at over 8 GB/s and panicked the Mac. `reset_gate` prints
  `GATE WARN` when `_gate` holds uncommitted changes, such as a mutant a crash left behind. It
  logs the size of `target/debug/deps` and prunes it past `DEPS_PRUNE_AT` (300k): at 1.2M entries
  every `rustc` spent about 65 s listing it, and suites timed out. All enforced.
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
  (run 20261106-229-230) Both hit again. `bridge_rereads_the_utc_offset…` failed #301's gate and
  still needs its event wait. `pending_saves_test.dart:1025` hit `Directory not empty` in #296's
  gate and #289's verify. #311 fixed that one by flushing before delete. Each new temp-vault test
  repeats the race, so a shared `tempVault` helper that flushes before deleting is still due.
- **`app/pubspec.lock` and `app/macos/Podfile.lock` are tracked** (since #379, run 20261110-356 D7, for locked
  release builds); a plugin or crate add commits its lockfile. `GeneratedPluginRegistrant.swift` stays gitignored.
  Plugins resolve through SwiftPM, so a local `flutter build macos` rewrites Runner.xcscheme/project.pbxproj and adds
  `xcshareddata/swiftpm/`: revert those, never commit them. `scripts/release/build.sh` builds in a copied tree, so the
  checkout stays clean.

Run 20261025-156 (#156 inline live preview: 1 ticket, 14 WIs across 3 leads, 16 PRs; review off,
mutation on, Flutter only) added the lessons below.

- **Flutter editor gates are cheap (2–8 min); MUTATION survivors in widget code are the cost.**
  Why: #181 #183 #184 #185 #186 #187 each failed their first gate with 5–8 of 16 survivors and
  needed a 15–45 min tests-only round. Repeat sites: `splitRows(..., atSegmentStart: true)` in four
  files (no test split rows away from a segment start), `shouldRepaint` `||` chains, key handlers'
  `return true`, and `_applying` guard initializers.
  How: before ready, the verify test author names a flipping test for each such site.
  (run 20261106-229-230) Same pattern: every MUTATION fail was tricky widget code (#296's 8 of 16,
  #302 and #309's 6), and the Rust core had none. #309's survivors were `||` chains over line
  kinds, a tag span's bounds and a `fenced` default.
- **Write max/min with `dart:math`, not a ternary.**
  Why: `a > b ? a : b` mutated to `>=` is always equivalent; #185's `composeEdits` needed five
  exemption write-ups (row_edits.dart:177–203) that `max(a, b)` would not have produced.
  How: new code uses `max`/`min`. Never rewrite existing code only to drop a mutant site (PROTOCOL §5).

Run 20261027-191 (#191 list indent + #192 tables: 10 WIs across 4 leads; review off, mutation on,
Flutter only) added the lessons below.

- **Pure-core WIs pass the first gate; seam stubs and render objects don't.**
  Why: #194 #202 #203 (pure Dart) passed first time. #212 (#204) had 7/16 survivors, 4 in the stub
  table_grid.dart that #205 replaced (`_active` flags, `p.attached && p.hasSize`, `forceHidden: true`);
  #215 and #217 failed on pointer `>`/`>=` bounds and `parentUsesSize: true` sites.
  How: a seam WI's verify test author pins the stub's frozen contract and both arms of each new
  predicate. `parentUsesSize: true` mutants are often equivalent (a later layout() or cached
  intrinsics decide it): prove it with a test that kills the sibling site, then exempt (#217).

Run 20261102-221 (#221 heading levels: 1 ticket, 2 WIs, 2 PRs; review on, mutation on, Flutter only)
added the lessons below.

- **Measure editor line metrics in a real TextField with the theme's even leading.**
  Why: Spec #222 R5a: an 11 px H4–H6 run with height 22.95/11 lays its line out about 1 px taller than
  the 22.95 strut under even leading. The old line-metrics test built spans with proportional leading
  and couldn't see it. #223 fixed it with the body ratio (22.95/13.5) and pumped-field tests.
  How to apply: any run smaller than the 13.5 body font keeps the body height ratio, and its test
  pumps a field with the controller strut and compares against plain body lines.
- **Reuse the staging worktree instead of removing it.** The last macOS build leaves `app/macos`
  dirty, and `git worktree remove` refuses (run 20261102-221). How to apply: adapter Release step 3.

Run 20261106-229-230 (#229 Tags, #230 back navigation, #231 review feedback: 3 Specs, 36 WIs, 39 PRs
across 9 leads; review off, mutation on, schema V6; one kernel panic and a night of host freezes)
added the lessons below.

- **A `Closes #N` line doesn't always close the WI.** #264, #266 and #267 stayed OPEN after #275,
  #278 and #279 merged into main with `Closes` in their bodies (cause not found).
  How: merge-pr checks the WI's state after merging and prints `ISSUE WARN` (enforced). It never
  closes the issue; the lead does it, or Connor.
- **OPEN, for Connor: the host froze system-wide from 16:27 on 2026-11-06 until a quiet morning.**
  Why: `flutter test` froze at random points in most gates, and `ps`, `lsof` and a 5 s probe each
  blocked for 15–30 min (U state). Earlier, a `dartaotruntime` in cmux's coalition had written
  2,199 GB in 3.5 h (diag `dartaotruntime_2026-11-06-152613`), and `~/.dartServer` is 14 GB. The
  same PRs passed in 2 min the next morning, after the orphaned testers were killed.
  How: on a freeze, stop the queue rather than re-gating. Check SSD wear and the analysis server.

## Staging 2026-11-09

- **An incremental release build can ship a stale signature.** Why: staging-20261109.1's
  `flutter build macos --release` rebuilt App.framework but kept the old ad-hoc signature.
  `codesign --verify --deep` said "nested code is modified or invalid", and the bad copy had already
  gone into /Applications. How: `staging-build.sh` verifies the signature and rebuilds from clean
  if it fails (enforced). Check the installed copy too.

Run 20261109-315 (#315 vault backups: 1 ticket split across 3 leads, 13 WIs, 16 PRs; review on, mutation on,
Rust + Flutter) added the lessons below.

- **The Flutter suite flakes on a google_fonts runtime fetch under load.**
  Why: #330's first gate failed `vault_open_hosted_contracts_test.dart :: switchToVault of a hosted ref ...` with
  `Failed to load font with url: https://fonts.gstatic.com/...`, though #330 changed no Dart production code.
  `app/test/support/font_fetch_hold.dart` exists for this, but that test file doesn't use it.
  How to apply: re-gate once. If it recurs, a small fix PR adds the hold to that file (or to every file that pumps themed widgets).
  Update (#382, run 20261110-356): fonts are now bundled and never fetched. `holdFontFetches()` also hands google_fonts an
  empty asset manifest, so tests keep the fallback font their widths were tuned to. Every new widget test that lays out
  text calls it at the top of `main()`; only `theme/font_setup_test.dart` uses the real bundle.
- **Widget MUTATION survivors recur on semantics flags and bool initializers.** (extends run 20261025-156)
  Why: #341 had 9 of 16 survivors (`button:`, `container:`, `excludeSemantics:`, `scrollable:`, `_nameError`/
  `_highlight = false`, a focus `&&`). #342 and #337 avoided it by naming those site classes before ready.
  How to apply: test-author.md verify step 6 now lists them. The orchestrator forwards the classes to sibling
  widget WIs as soon as one gate shows them.
  Still recurring (runs 20261110-347 #352, 20261110-355 #368 and #380): `excludeSemantics:` again, plus MouseRegion
  `onEnter`/`onExit` and `_hover && enabled`. #368 failed its gate 11/16. A "some changed test uses matchesSemantics"
  merge-check rule was tried in the retro and dropped, because every one of those PRs already had such a test. The
  pin has to be per site: a leaf-node assertion (`childrenCount == 0` plus label) for each `excludeSemantics:`, and a
  mouse-in and mouse-out `TestGesture` for each hover callback (test-author.md verify step 6).
- **Seam WIs with many frozen contracts escalate on the coding tier.**
  Why: A0 #321 (scale-only tricky, Sonnet) took 3 rounds and escalated to Opus. A1 and A2, which filled its stubs, passed in 1 round on Sonnet.
  How to apply: an interface-first seam WI that freezes models, Keys, a test harness and fakes for 3+ fillers is
  plain tricky, not scale-only.
- **Rust MUTATION in memex-mcp costs ~60 s per mutant, about 2× memex-core.**
  Why: #340's server mutants took 59–62 s each, against 21–23 s for memex-core in #332.
  How to apply: plan a ~10 min gate for a tricky server WI. Load from parallel verify suites stretches it further.

Run 20261110-347 (#347 delete a vault from the app: 3 WIs, one lead; review on, Flutter + a Swift
method channel) added the lessons below.

- **A press handler sees repeats before any rebuild: test held keys and same-frame double presses.**
  Why: #352 r1: a held Enter/Space fired once per key repeat (`KeyRepeatEvent`). #353 r1 (blocking):
  `if (_busy) return;` was called an equivalent mutant because `onPressed` is null while busy, but
  `setState` nulls it only on the next frame, so two presses in one frame started two moves.
  How: keyboard activation ignores `KeyRepeatEvent`; a busy guard is never exempt, and gets a
  "two presses in the same frame start one action" test (pump once, not pumpAndSettle).
- **Keep Swift method-channel handlers a thin pass-through; map errors in Dart.**
  Why: AC MAP takes no Swift test path and nothing here runs XCTest (#347 refine dropped one); #351
  put the NSError domain/code → result mapping in Dart, tested over a mock `MethodChannel`.
  How: Swift replies with `{domain, code}` and the message only; real native behavior is a MANUAL
  row, and the gate's NATIVE NOTE reminds that the app must be built by hand before release.

Runs 20261110-355 (#357 vault management: 4 WIs) and 20261110-356 (#367 public release prep: 9 WIs across 2 leads)
ran concurrently in one orchestrator session, with review and mutation on, and added the lessons below.

- **Scripts and workflows are gated code.** (enforced: merge-check counts `scripts/**` and `.github/workflows/**`
  in CODE_CHANGED)
  Why: #367's leak-check, history rewrite, release build and workflow PRs touched no app/lib or crates/src. Without the
  change they skipped AC MAP and RED ON MAIN.
  How: test scripts from `app/test/release/` via `Process.run`, with exact exit codes, fake tool binaries on PATH and
  an isolated git config. Mutation doesn't cover `.sh`, so name the key branches under `## Hand mutants`.
- **A test default that reads the real filesystem makes tests host-dependent.**
  Why: D8 (#378) made `SettingsController.load()` skip a missing picked path and autodiscover `~/.cargo/bin/memex`.
  24 existing tests, plus 4 new ones on #357 branches, seeded `fake-memex`. They passed on Connor's Mac and would get
  null elsewhere.
  How: tests that seed a binary load through `loadSettingsKeepingPickedBinary` (test/support/token_store_fakes.dart).
  A WI that adds a real-FS lookup ships its seam helper and switches every existing caller.
- **Real-filesystem widget tests can hang under load.**
  Why: #388's first gate timed out (10 min) on `vault_picker_modal_fixes_test` alias rows, which use real temp-dir
  symlinks. That suite took 713 s against ~200 s; the file passes in 8 s alone, and the re-gate passed.
  How: a TimeoutException in a real-FS widget test during a slow suite is contention; re-gate before routing a REVIEW.
