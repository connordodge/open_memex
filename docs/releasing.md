# Releasing Open Memex

This is the runbook for the person who owns the repo. It has three parts: the one-time cutover that creates the public repo, the steps for every release, and recovery when a release goes wrong. Only the repo owner pushes `v*` tags and approves the `release` environment.

Every release is a **Release** on the public repo's GitHub Releases: the DMG, the standalone `memex` zip, their SHA-256 sums and the release notes, all for one `v<version>` tag. The release workflow (`.github/workflows/release.yml`) builds, signs, notarizes and publishes it after you approve.

## One-time cutover

The public repo starts from a rewritten copy of the history, never from the private repo itself. Do these steps once, in order.

1. Preconditions. Check that every PR is merged and none is open, then pull `main` in the repo you are cutting over from, so that it matches `origin/main`. Its working tree must be clean, and it must hold the `v0.1.0` tag.

2. Write the private deny-list at `~/.claude/orchestration/open_memex/leak-patterns.txt`, outside any repo. It lists everything that must never go public, one per line:

   - every personal email address you have committed with (an entry with `@` is an email, matched without regard to case);
   - every home path that appears in files or messages, such as `/Users/<your-account>` (any other entry is a path, matched exactly).

   Do not list the bare GitHub login. It is public already: it is in every repo URL and in the noreply address, so listing it would only break the rewrite. If the deny-list is empty, the scripts refuse to run (exit 2) rather than check against nothing. Keep this file private; it is the only place the real values live.

3. Run the history rewrite. It reads the source repo, never writes to it and pushes nothing:

   ```bash
   scripts/public-cutover/rewrite-history.sh \
     --source <path-to-your-current-clone> \
     --out <new-empty-dir> \
     --noreply ID+YOUR_USERNAME@users.noreply.github.com \
     --patterns ~/.claude/orchestration/open_memex/leak-patterns.txt
   ```

   `--noreply` is your GitHub noreply address (GitHub shows it under Settings → Emails). The script keeps only `main` and `v0.1.0`, replaces the deny-list entries and your home path, adds one final commit that removes the dev files, and runs `scripts/leak-check.sh --history` on the result. If it reports a leak, fix the deny-list or the cause and run it again with a new, empty `--out`; never push that output.

4. Review its summary: the commit count, the kept refs, `main`'s SHA and `leaks: 0`. Then look at the `design/` folder: the exported PNG files and the `.sketch` files are binary, so the rewrite cannot clean them and no tool can check them. The `--out` directory is a bare mirror with no work tree, so list the files with `git --git-dir <out> ls-tree -r --name-only main -- design`, and extract them to a scratch folder with `git --git-dir <out> archive main design | tar -x -C <scratch-dir>`. Open every PNG file and every `.sketch` file yourself and look for real note content. A scan is only an extra check and never replaces looking: it finds only the deny-list entries, it cannot read text drawn into an image, and it unpacks only files named `.zip` or `.dmg`, so each `.sketch` file must be passed as its own path, for example `scripts/leak-check.sh --artifact <scratch-dir>/design/<name>.sketch --patterns ~/.claude/orchestration/open_memex/leak-patterns.txt`. If you find anything private, stop and do not push: the rewrite has no option to drop a path from history, so the history itself has to be fixed before you go on.

5. Rename the old repo with `gh repo rename open_memex-archive`, keep it private, then create the new empty public repo named `open_memex` with no README, licence or `.gitignore` of its own (an empty repo, so the push below is the whole history).

6. Push `main` and `v0.1.0` from the `--out` directory to the new public repo. The script printed the exact push commands; run them yourself.

7. Set up the public repo's settings:

   - turn on private vulnerability reporting (the Security page links to it from `SECURITY.md`);
   - add a tag ruleset for `v*` that only you (the repo owner) can create, so nobody else can start a release;
   - create the `release` environment, with you as the required reviewer, deployment limited to `v*` tags only, and these environment secrets and variable (the full list the workflow reads is in [The release environment](#the-release-environment));
   - under your account settings, turn on email privacy (Keep my email addresses private, and Block command line pushes that expose my email), so a push cannot leak a personal address.

8. Work only in fresh clones from now on. Clone the new public repo into a new folder, then set `user.email` to the noreply address in that clone (`git config user.email ID+YOUR_USERNAME@users.noreply.github.com`). The dev files (`.claude/orchestration`, `.act`, `ai_specs`, `CLAUDE.md`, `AGENTS.md`) now live in the private companion dir `~/.claude/orchestration/open_memex/`; link them into the fresh clone from there, and keep them out of commits.

Old clones and worktrees hold pre-rewrite branches, with the old history and the old email addresses in them. Never run `git remote set-url` on an old clone or worktree to point it at the public repo, and never push from one: that would publish exactly what the rewrite removed. Delete them, or keep them pointed at the archive.

## The release environment

The `release` job runs in the `release` environment and reads these environment secrets and one environment variable. Set them on the environment (Settings → Environments → release), not as repository-wide secrets, so only an approved `v*` tag run can read them.

| Name | Kind | What it holds |
|---|---|---|
| `MACOS_CERT_P12_BASE64` | environment secret | your Developer ID Application certificate and key, exported as a `.p12` file and base64-encoded |
| `MACOS_CERT_PASSWORD` | environment secret | the password you set when exporting that `.p12` |
| `NOTARY_KEY_P8_BASE64` | environment secret | the App Store Connect API key (`.p8`) used for notarization, base64-encoded |
| `NOTARY_KEY_ID` | environment secret | that API key's ID |
| `NOTARY_ISSUER_ID` | environment secret | the issuer ID shown with the API keys |
| `LEAK_PATTERNS` | environment secret | the contents of the private deny-list file from cutover step 2, so the build's Leak check can run |
| `MACOS_SIGN_IDENTITY` | environment variable | the signing identity name, for example `Developer ID Application: Your Name (TEAMID)` |

The manual dry-run job reads none of these.

## Every release

1. Bump the versions: `version: <ver>+<build>` in `app/pubspec.yaml` (raise the build number too), `version = "<ver>"` under `[workspace.package]` in `Cargo.toml`, and regenerate `Cargo.lock` with `cargo update -w --offline`, so that only the two workspace crates change.
2. Write `release-notes/v<ver>.md` from the template in `release-notes/README.md`: Highlights, Upgrade and Requirements. If the release migrates vaults to a new schema, the Upgrade section says so with the template's schema line.
3. Check the pair locally with `scripts/release/check-version.sh v<ver>` (it must exit 0), then open a PR with the bump and the notes and merge it into `main`.
4. In a fresh clone, pull `main`, tag it and push the tag: `git tag v<ver>` and `git push origin v<ver>`. The tag starts the release workflow.
5. Approve the run: open the workflow run on the repo's Actions tab and approve the deployment to the `release` environment. Nothing is signed or published until you do.
6. Check the Release when the run ends. It must be published (not a draft) with four assets: `Open-Memex-<ver>-arm64.dmg`, `memex-<ver>-macos-arm64.zip`, `THIRD_PARTY_NOTICES.txt` and `SHA256SUMS.txt`. Download the DMG, verify it against `SHA256SUMS.txt` (`shasum -a 256 -c --ignore-missing SHA256SUMS.txt`, because the sums file also lists the files you did not download), install it on a Mac and open it; run `scripts/leak-check.sh --artifact` on the files if you want a second look.

To try a build without publishing, run the Release workflow by hand (Actions → Release → Run workflow) with a version. That dry run reads no secrets, and it does not sign, notarize or publish.

## Recovery

If a run fails or the Release is wrong, the tag has already been used, so undo it before you try again:

1. Delete the draft Release (or the published one) on the Releases page, or with `gh release delete v<ver> --cleanup-tag`, which also deletes the tag on the remote.
2. Make sure the tag is gone from the remote and from your clone (`git push origin --delete v<ver>`, then `git tag -d v<ver>`).
3. Fix the cause on `main` through a PR: a version that did not match, missing notes, a wrong secret, a failed build. Fix the secret or variable in the environment settings if that was it.
4. Run the every-release steps again from the tag: pull `main`, then re-tag with `git tag v<ver>` and push it. If you changed the version number, start again from step 1.

If the Release was already published, say so in the next release's notes, and remove any bad asset from the Release page.
