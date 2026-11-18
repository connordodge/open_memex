# Acceptance test: Self-update

Manual end-to-end check of Self-update: the app finds a newer Release, downloads and verifies it, and replaces itself when you choose relaunch. Run it once on each of the first two Self-update Releases, with a real Release pair for sections 1 to 8 and a local build for section 9. Background: [`docs/releasing.md`](releasing.md).

Every path here is a placeholder: the app is at `/Applications/Open Memex.app` and any vault is a scratch vault such as `/vaults/My Vault`. Never use your real vault. Quote marks around a message in a code span mean the app shows that text word for word.

Self-update is on only in a release build. `flutter run` and other debug builds show the Off state (section 3).

## 1. Install the older Release

1. Download the older Release's DMG (`Open-Memex-<older>-arm64.dmg`) from the Releases page.
2. Open the DMG, drag Open Memex to Applications and eject the disk image. Open the app from `/Applications/Open Memex.app` and create a scratch vault.
3. Quit the app.

**Expected**: the app opens from `/Applications/Open Memex.app` and shows `v<older>` under the app name in the sidebar and on the vault picker. Nothing offers an update yet, because the older Release is the newest one published.

## 2. Publish the newer Release and wait out the cache

1. Tag and publish the newer Release as in [`docs/releasing.md`](releasing.md), and approve the run.
2. When the `appcast` job ends, open the Appcast at `https://connordodge.github.io/open_memex/appcast.xml` in a browser.
3. Wait about 10 minutes. GitHub Pages caches the file, so the new item can take that long to reach the app.

**Expected**: the Appcast shows an item for the newer version, first in the channel, with a `sparkle:edSignature` on its enclosure. A checklist run that opens the app before the Pages cache expires may still say it is up to date; wait and try again before you call it a bug.

## 3. Every modal state

Open the older Release from `/Applications/Open Memex.app`, then choose Open Memex → Check for Updates… once per state below. The title is the dialog's heading, and every body is quoted verbatim. Once the update has reached Update ready, Check for Updates… only reopens that modal, so quit and reopen the app before any step that needs a fresh check (steps 7 to 15), or run them before steps 4 to 6. Steps 11 to 15 need the local setup of section 9.

1. **Checking for updates**: the modal opens at once with a spinner and a close action.
2. **You're up to date**: with no newer Release published yet (or after installing the newer one in section 4), the body is `Open Memex <current> is the newest version.` with a close action.
3. **Update available**: the body starts `Version <new> is available.` and shows the Release's notes as plain text in a scroll area. The actions are later and install.
4. **Downloading update**: choose install. A progress bar and a percentage show, with a later action.
5. **Verifying update**: when the bytes arrive the body reads `Checking the update's signature.` with a spinner.
6. **Update ready**: the body reads `Version <new> is downloaded. Relaunch to apply it.` with later and relaunch actions. Sections 5 and 6 start from this state.
7. **Update check failed**, offline: turn Wi-Fi off, choose Check for Updates…. The body is `Open Memex couldn't reach the update feed. Check your connection and try again.` with close and try again. Turn Wi-Fi back on and choose try again: the modal returns to Checking.
8. **Update check failed**, no Appcast (404): run a local build (section 9) with `--dart-define=SELF_UPDATE_APPCAST_URL=http://localhost:8000/missing.xml` against a local server that answers 404. The body is `No updates have been published yet.` with close and try again.
9. **Update failed**, folder not writable: copy `/Applications/Open Memex.app` into a scratch folder, remove write permission from that folder (`chmod a-w <folder>`), open the copy, let the update reach Update ready and choose relaunch. The body starts `Open Memex can't replace itself in` and names that folder, with close and download from GitHub. Choosing download from GitHub opens the Release's page in the browser. Restore the folder's permission afterwards.
10. **Updates are off**: run a debug build with `cd app && flutter run -d macos` and choose Check for Updates…. The title is Updates are off and the body is `Updates are off in development builds.` This is the debug build case; no network request is made.

11. **Update check failed**, feed unreadable: serve a truncated `appcast.xml` (cut it off mid-tag) or a server that answers 500 from the local setup of section 9, and choose Check for Updates… in a build pointed at it. The body is `The update feed couldn't be read. Try again later.` with close and try again.
12. **Update failed**, signature does not verify (the security check): in the section 9 setup, sign the DMG with a second throwaway key that is not the one built into the app, and choose install. The body is `The update isn't signed by the Open Memex release key, so it wasn't installed.` with close and try again, and nothing is staged for relaunch: the label never reads `· update ready`.
13. **Update failed**, no signature: remove the `sparkle:edSignature` attribute from the Appcast item and choose install. The body is `The update has no signature, so it wasn't installed.` with close and try again.
14. **Update failed**, no public key built in: build with an empty `--dart-define=SPARKLE_ED_PUBLIC_KEY=` and choose install. The body is `This build can't verify updates. Download the update from GitHub instead.` with close and download from GitHub, and no try again.
15. **Update failed**, download did not finish: from Update available, stop the local server, then choose install. The body is `The download didn't finish. Check your connection and try again.` with close and try again. Start the server and choose try again: the modal returns to Downloading.

**Expected**: each state shows the title, body and actions above, never two modals at once (choose Check for Updates… twice in a row and see one modal), and no state leaves a stray file: after a failed install, the temporary download folder for the update is gone.

## 4. Later during the download, then the update-ready label

1. From Update available, choose install.
2. While the modal says Downloading update, choose later.
3. Keep using the app until the download finishes.

**Expected**: the modal closes and the app stays usable. It does not reopen on its own. When the download and verification finish, the version label in the sidebar and on the vault picker reads `v<older> · update ready`. Clicking the label reopens the modal at Update ready, and so does Open Memex → Check for Updates….

## 5. Relaunch with unsent hosted text

1. Connect a scratch hosted vault (see [`docs/hosted-vault.md`](hosted-vault.md)) and type text into a field without sending it.
2. With the update at Update ready, open the modal and choose relaunch.

**Expected**: the leave confirm asks about the unsent text exactly one time. Choosing cancel closes the modal and the update stays Update ready, with the label still reading `· update ready`. Choose relaunch again and then leave: the app quits without asking a second time, and the newer Release opens from `/Applications/Open Memex.app` showing `v<newer>`.

## 6. Relaunch with a connected Claude Desktop agent

1. Connect Claude Desktop to the scratch vault with the Bundled memex path (see [`docs/claude-desktop-setup.md`](claude-desktop-setup.md)) and keep a conversation open that reads the vault.
2. With the update at Update ready, open the modal.
3. Choose relaunch and let the app restart. Then ask the agent for a note again.
4. Quit Claude Desktop and reopen it, then ask again.

**Expected**: with the agent live, the Update ready body adds `Connected agents keep using the current memex until they restart.` and relaunch is not blocked. The agent keeps working through the update, because the update never overwrites the running Bundled memex in place. After you restart Claude Desktop, its `memex serve` runs the new Bundled memex from `/Applications/Open Memex.app/Contents/MacOS/memex`.

## 7. Running from the mounted disk image

1. Open the older Release's DMG and, without dragging anything, double-click Open Memex inside the mounted volume.
2. Let the update reach Update ready and choose relaunch.

**Expected**: nothing quits. The modal shows Update failed with `Open Memex is running from a disk image or a temporary location, so it can't replace itself. Move Open Memex to your Applications folder, open it from there and try again.` and a close action only. Eject the disk image afterwards.

## 8. macOS 15 without App Management

1. On a Mac running macOS 15, make sure Open Memex is not listed under System Settings → Privacy & Security → App Management. Do not grant it, or remove it if it is there.
2. Install the older Release in `/Applications` as in section 1 and update to the newer one as in sections 2 to 4, then choose relaunch.

**Expected**: the update installs and the newer Release opens. If macOS stops the replace anyway, the app relaunches on the older Release and the next launch shows Update failed once, with the reason, and the modal's try again goes back to Checking. Record which of the two happened for this macOS version. Either way the app never leaves a half-installed `Open Memex.app` in `/Applications`.

## 9. Local rehearsal before the v0.5.0 tag

Rehearse the install path against a local Appcast, before the v0.5.0 tag, so that the first Self-update Release is not the first time the helper runs for real.

1. Mint a throwaway EdDSA keypair on its own Keychain account, never the release key's account `open-memex` from the one-time setup in [`docs/releasing.md`](releasing.md): run `generate_keys --account open-memex-rehearsal`, which prints the public key, then `generate_keys --account open-memex-rehearsal -x <scratch key file>`. Build the older version with that key's public half and the local Appcast address (the version comes from `version:` in `app/pubspec.yaml`; build the newer version from a copy of the checkout with a higher `version:` and a `release-notes/v<newer>.md`, the same way):

   ```bash
   cd app
   flutter build macos --release \
     --dart-define=SELF_UPDATE_APPCAST_URL=http://localhost:8000/appcast.xml \
     --dart-define=SPARKLE_ED_PUBLIC_KEY=<base64 rehearsal public key>
   ```

2. Package the newer build as a DMG, sign it with the throwaway private key (`SPARKLE_ED_KEY_PATH=<scratch key file> scripts/release/eddsa_sign.sh <dmg>`, with Sparkle's `sign_update` on your `PATH`) and write its signature and byte length next to it as `Open-Memex-<newer>-arm64.dmg.edsig` and `.length` files. Make an `appcast.xml` with one empty channel (as in step 4 of the one-time setup) and, from the newer copy's checkout root, add its item with `scripts/release/generate_appcast.sh --version <newer> --input <folder holding the .edsig and .length> --appcast <appcast.xml>`. The generator always writes the GitHub Releases address as the item's enclosure `url` and `link`, and the app downloads exactly that address, so edit the item's enclosure `url` to `http://localhost:8000/Open-Memex-<newer>-arm64.dmg` before serving. Serve the folder holding `appcast.xml` and the DMG on `localhost:8000` (for example `python3 -m http.server 8000`).
3. Copy the older build to `/Applications/Open Memex.app`, open it and choose Open Memex → Check for Updates….
4. Go through install and relaunch.

**Expected**: the modal walks Update available, Downloading update, Verifying update and Update ready, then relaunch replaces the app in `/Applications` and opens the newer build, showing `v<newer>`. The DMG volume is detached afterwards. The local Appcast stands in for the real Appcast: `build.sh` and the release workflow never set `SELF_UPDATE_APPCAST_URL`, so a Release build always reads the permanent GitHub Pages address. When done, delete the scratch key file and the rehearsal builds, and delete only the `open-memex-rehearsal` item from the login Keychain: the release key's `open-memex` item must stay.
