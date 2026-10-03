# Open Memex orchestration lessons

These are repo-specific. Read at kickoff and before every dispatch. Generic lessons are in
`~/.claude/skills/orchestrate/LESSONS.md`. `/orchestrate-retro` curates this file.

Seeded at adapter creation (2026-10-03), before run 20261003-1.

- **There is no CI, so the merge check is the only safety net.**
  Why: nothing else runs the Rust or Flutter suites on a PR.
  How: never merge without a passing `merge-check.sh` run on the merged tree.
- **Schema migrations apply to Connor's real vault on first open.**
  Why: the app and `memex` open `~/memex` directly; there is no staging
  data.
  How: add-only DDL, a migration test from a previous-version fixture, and a migration
  warning before any staging build.
