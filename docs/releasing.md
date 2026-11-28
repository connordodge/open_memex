# Releasing Open Memex

This is the runbook for the person who owns the repo. It has five parts: the one-time cutover that creates the public repo, the steps for every release, the Docker image that follows each release, recovery when a release goes wrong, and the Self-update signing key and Appcast. Only the repo owner pushes `v*` tags and approves the `release` environment.

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
| `SPARKLE_ED_PRIVATE_KEY_BASE64` | environment secret | the Self-update EdDSA private key, exported with `generate_keys -x` and base64-encoded (see [Self-update one-time setup](#self-update-one-time-setup)) |
| `MACOS_SIGN_IDENTITY` | environment variable | the signing identity name, for example `Developer ID Application: Your Name (TEAMID)` |

The manual dry-run job reads none of these.

## Every release

1. Bump the versions: `version: <ver>+<build>` in `app/pubspec.yaml` (raise the build number too), `version = "<ver>"` under `[workspace.package]` in `Cargo.toml`, and regenerate `Cargo.lock` with `cargo update -w --offline`, so that only the two workspace crates change.
2. Write `release-notes/v<ver>.md` from the template in `release-notes/README.md`: Highlights, Upgrade and Requirements. If the release migrates vaults to a new schema, the Upgrade section says so with the template's schema line.
3. Check the pair locally with `scripts/release/check-version.sh v<ver>` (it must exit 0), then open a PR with the bump and the notes and merge it into `main`.
4. In a fresh clone, pull `main`, tag it and push the tag: `git tag v<ver>` and `git push origin v<ver>`. The tag starts the release workflow.
5. Approve the run: open the workflow run on the repo's Actions tab and approve the deployment to the `release` environment. Nothing is signed or published until you do. When the Release succeeds, `docker.yml` starts on its own and publishes the vault server image (see [Docker image](#docker-image)).
6. Check the Release when the run ends. It must be published (not a draft) with four assets: `Open-Memex-<ver>-arm64.dmg`, `memex-<ver>-macos-arm64.zip`, `THIRD_PARTY_NOTICES.txt` and `SHA256SUMS.txt`. Download the DMG, verify it against `SHA256SUMS.txt` (`shasum -a 256 -c --ignore-missing SHA256SUMS.txt`, because the sums file also lists the files you did not download), install it on a Mac and open it; run `scripts/leak-check.sh --artifact` on the files if you want a second look.
7. For the first two Self-update Releases, run the manual check in [`docs/self-update-acceptance.md`](self-update-acceptance.md) against the Release you just published.

To try a build without publishing, run the Release workflow by hand (Actions → Release → Run workflow) with a version. That dry run reads no secrets, and it does not sign, notarize or publish.

## Docker image

The vault server image is `ghcr.io/connordodge/memex`. A successful Release triggers `.github/workflows/docker.yml`, which builds the image for `linux/amd64` and `linux/arm64`, smoke-tests both and publishes `ghcr.io/connordodge/memex:<x.y.z>`, `:<x.y>` and `:latest`. It moves `<x.y>` and `latest` only forward: publishing an older version, such as a patch for an earlier minor, never moves either of them backwards. Nothing is published from a pull request or a manual dry run of the Release workflow.

If a publish fails, open the `docker.yml` run on the Actions tab and use **Re-run jobs** on that run. Never fix it by re-running the Release: the tag and the Release already exist, and re-running the Release would try to create them again.

Do this once, after the first image is published. GitHub makes a new package private, so the Docker route in [`hosted-vault.md`](hosted-vault.md) cannot pull it:

1. Open the `memex` package under your account's Packages, then Package settings, and set its visibility to Public.
2. Check that the package is linked to the `open_memex` repo (the repo's page shows it under Packages). If it is not, connect it from the package page.
3. From a machine that is not signed in to ghcr.io, run `docker pull ghcr.io/connordodge/memex:latest` to check that it is public.

The first image comes from the first Release after v0.7.0; earlier Releases are not published retroactively.

## Recovery

If a run fails or the Release is wrong, the tag has already been used, so undo it before you try again:

1. Delete the draft Release (or the published one) on the Releases page, or with `gh release delete v<ver> --cleanup-tag`, which also deletes the tag on the remote.
2. Make sure the tag is gone from the remote and from your clone (`git push origin --delete v<ver>`, then `git tag -d v<ver>`).
3. Fix the cause on `main` through a PR: a version that did not match, missing notes, a wrong secret, a failed build. Fix the secret or variable in the environment settings if that was it.
4. Run the every-release steps again from the tag: pull `main`, then re-tag with `git tag v<ver>` and push it. If you changed the version number, start again from step 1.

If the Release was already published, say so in the next release's notes, and remove any bad asset from the Release page.

## Self-update

Open Memex checks the **Appcast**, `https://connordodge.github.io/open_memex/appcast.xml`, for a newer Release. GitHub Pages serves it from `appcast.xml` on the `gh-pages` branch. Each item names one Release's DMG and carries its EdDSA (Ed25519) signature; the app installs a DMG only when that signature verifies against the public key built into it. That URL is built into every Self-update build, so it never changes.

### Self-update one-time setup

Do these steps once, before the first signed Release. A signed `build.sh` refuses to start (exit 2) without `SPARKLE_ED_KEY_PATH`, which the `release` job sets from the secret below, so every Release fails until steps 1 and 2 are done.

1. Mint the keypair with Sparkle's `generate_keys` (in `bin/` of the Sparkle 2 release tarball). `generate_keys --account open-memex` creates the key in your login Keychain and prints the public key. Then export the private key with `generate_keys --account open-memex -x <file>`. Keep a backup of the private key outside the repo. It is Open Memex's own keypair, never one another app uses.
2. Store the base64 of the exported file as the `release`-environment secret `SPARKLE_ED_PRIVATE_KEY_BASE64` (for example `base64 -i <file> | pbcopy`, then paste it under Settings → Environments → release). Then delete the exported file.
3. Commit the public key: set `_committed` in `app/lib/src/updater/sparkle_ed_public_key.dart` to the base64 public key `generate_keys` printed, through a PR. The app reads it as `sparkleEdPublicKey`, and a test checks that it decodes to 32 bytes. An empty key refuses every install.
4. Create the `gh-pages` branch as an orphan holding `.nojekyll` and an `appcast.xml` with one empty channel, and push it:

   ```bash
   git switch --orphan gh-pages
   touch .nojekyll
   cat > appcast.xml <<'XML'
   <?xml version="1.0" encoding="utf-8"?>
   <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
     <channel>
       <title>Open Memex</title>
     </channel>
   </rss>
   XML
   git add .nojekyll appcast.xml
   git commit -m "Empty Appcast"
   git push origin gh-pages
   ```

   Then turn on GitHub Pages from `gh-pages` (root) under Settings → Pages, and check that `https://connordodge.github.io/open_memex/appcast.xml` serves the file.

### The `appcast` job

Every Release publishes its own Appcast item; there is no manual step. The `release` job decodes the private key to `$RUNNER_TEMP/sparkle-ed-key` (deleted at the end of the job), `build.sh` signs the stapled DMG with it, and right after **Build, sign and notarize** the job uploads the DMG's signature and byte length (`dist/Open-Memex-<ver>-arm64.dmg.edsig` and `.length`) as the workflow artifact `appcast-input`. **Publish the Release** is still its last step.

The `appcast` job runs only after the `release` job succeeds. It has no environment and reads no secret: it pushes with the run's `github.token`. It checks out the tag, downloads `appcast-input`, checks that `gh-pages` exists, checks out `gh-pages`, runs the generator from the tag's checkout and pushes one commit to `gh-pages`:

```bash
scripts/release/generate_appcast.sh --version <ver> --input <appcast-input dir> --appcast <gh-pages checkout>/appcast.xml
```

The generator takes the build number from `app/pubspec.yaml`, the notes from `release-notes/v<ver>.md` and the minimum macOS version from the app's deployment target. It keys each item on the version (`sparkle:shortVersionString`): running it again for a version replaces that version's item, and every other Release's item is kept. Only one `appcast` job runs at a time, and GitHub keeps only one waiting behind it: if you push a third tag while one `appcast` job runs and another waits, GitHub cancels the waiting one. Its Release then has no Appcast item; recover it as in [If the appcast job fails](#if-the-appcast-job-fails).

GitHub Pages caches the file for about 10 minutes, so a new item can take that long to reach the app.

### If the appcast job fails

The Release is already published, so do not delete it or its tag. Fix the cause (for example, create `gh-pages` as in step 4 of the one-time setup if the job says it is missing), then open the workflow run on the Actions tab and use **Re-run failed jobs**. That runs only the `appcast` job again, with the same `appcast-input` signature and length, while the run's artifacts are kept (90 days by default). Never use Re-run all jobs: the `release` job would fail at creating the Release, and a rebuilt DMG would not match the published asset's signature.

### Rotating the key

To replace the EdDSA keypair, mint a new one (one-time setup step 1, with a new export file), put its public key in `sparkleEdPublicKey` (step 3) and ship that build **signed with the old key**: leave `SPARKLE_ED_PRIVATE_KEY_BASE64` holding the old key for that Release, so installed apps, which trust only the old key, accept it. After that Release is published, replace the secret with the new private key (step 2). Every later Release is signed with the new key, which the rotated build trusts.
