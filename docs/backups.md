# Backups

A **backup** is one finished `.memex.zip` file that holds a copy of a vault. Open Memex writes it into a **backup destination**, a folder you choose. If the vault is lost, damaged or upgraded to a schema you cannot undo, you **restore** the backup into a new vault folder.

This page covers:

1. what a backup holds, and what it leaves out;
2. choosing a backup destination in the app: iCloud Drive, Google Drive, OneDrive or any folder;
3. running `memex backup` yourself, on a schedule, for a local vault the app does not have open;
4. backing up every vault on a vault server, on a NAS, in Docker or on an always-on Mac, and copying those backups on to the cloud;
5. restoring from a backup;
6. the error codes.

The commands on this page are the same ones the app and the vault server run for you, so what you read here matches what you see in the app.

## What a backup holds

A backup is a single file named `<label>-<YYYYMMDDTHHMMSSZ>-<vault_id>.memex.zip`, for example `Notes-20261109T140300Z-01J8Z6K3Q4W9X2V5B7N1M0C8DA.memex.zip`. The label is the vault folder's name, with every character other than letters, digits, `_` and `-` replaced by `-`. The timestamp is in UTC, and the vault id is the vault's own id, which is the same in every backup of that vault.

- It holds `memex.db`, taken as a consistent copy while the vault is in use (so your notes, block ids, review state, Smart Folders, canvases, tags and feedback are all in it), `manifest.json`, everything under `objects/` (attachments), and a small `backup.json` that says when and from what the backup was made.
- A backup leaves out the vault's `.memex/` folder, which holds the app's UI state and logs. Neither is needed to get your notes back.
- A backup also leaves out `backup-state.json` and `backup.lock`, the files in the vault folder that record the backup history and stop two backups of one vault running at once. They describe the backups, so they are never part of one.

Making a backup never writes to your vault, never runs a migration and never waits for you to close the app: you can keep typing while it runs. The file is written under a hidden name (`.<name>.partial`) and renamed only when it is complete, so a folder never holds a half-written backup under a real name.

## Choose where backups go

The app shows its button labels in lower case (for example "back up now"); this page writes them with a capital letter. In the app, press the **backups** row in the sidebar (under the vault pills) to open the Backups sheet, then choose **Turn on backups…**. The sheet lists the folders it finds on this Mac, and a **Choose folder…** row for any folder.

| Choice | Notes |
|---|---|
| iCloud Drive | Open Memex creates an `Open Memex Backups` folder in iCloud Drive and writes each backup there. |
| Google Drive | The same, inside the Google Drive folder (My Drive) of the account you pick. |
| OneDrive | The same, inside the OneDrive folder of the account you pick. |
| Any folder | A NAS share, an external disk or a plain folder on this Mac. |

**The provider's app uploads it.** Open Memex only writes the file into the folder. It does not talk to iCloud, Google or Microsoft, and it cannot see when an upload finishes. The provider's own app does the upload, so that app must be installed and signed in on this Mac. If the sheet finds no provider folder, install the provider's app, sign in, and reopen the sheet.

With **Optimize Mac Storage** turned on in iCloud settings, macOS may keep only a placeholder for an older backup on this Mac. The backup is still in iCloud. Open it in Finder to download it before you restore from it.

In the sheet you also choose how many backups to keep (1 to 365), and whether to back up automatically. Automatic backups run once a day, only when the vault has changed, and only while the vault is open in the app; the first one runs within the hour. **Back up now** makes one straight away. Turning backups off deletes no backup files.

A vault that is not open in the app is not backed up by the app. Back it up with a scheduled `memex backup` (see [Back up from the command line](#back-up-from-the-command-line)).

### The macOS Files and Folders prompt

The first time Open Memex writes into a folder in iCloud Drive, Documents, Desktop or on an external disk, macOS may ask whether Open Memex can use files and folders there. Choose Allow.

If you refused, or the prompt never showed, the backup fails and the sheet says it cannot write to the folder. To allow it afterwards, open System Settings, go to Privacy & Security, then Files and Folders, find Open Memex in the list and turn on the folder it was refused. Then press **Back up now** in the sheet. Choosing another folder also works.

### Never put a live vault in a provider folder

A backup destination in iCloud Drive, Google Drive or OneDrive is safe because it only receives finished files. Never put a live vault, the vault folder you open and edit, in any of those folders, and never point a provider's app at it. These apps copy files one at a time, at different moments, so they can upload `memex.db` and its side files from different instants, or overwrite the vault from another machine while it is open. The result is a damaged vault. Keep every live vault on a disk that belongs to your Mac (or on a vault server), and let the provider's app see only the backups.

## Back up from the command line

`memex backup` makes one backup of a local vault:

```bash
memex backup --vault ~/memex --dest "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Open Memex Backups"

# keep the newest 60, and write nothing when the vault has not changed
memex backup --vault ~/memex --dest /Volumes/Disk/memex-backups --keep 60 --if-changed
```

- `--vault <path>` is the vault folder.
- `--dest <folder>` is the backup destination. It must already exist, and it cannot be the vault folder or inside it.
- `--keep <n>` is how many backups of this vault the destination keeps: 30 unless you say otherwise, from 1 to 365. After a new backup is written, the oldest backups of this vault beyond the newest `<n>` are deleted. Files of other vaults and any other file in the folder are never touched.
- `--if-changed` skips writing a backup when the vault is unchanged since the last backup to this destination.

It prints one line of JSON when it is done. A new backup:

```json
{"result":"created","vault_id":"01J8Z6K3Q4W9X2V5B7N1M0C8DA","file":"/Users/me/Backups/Notes-20261109T140300Z-01J8Z6K3Q4W9X2V5B7N1M0C8DA.memex.zip","bytes":4218870,"fingerprint":"9f2c0a41d7b6e8530c1a2b3d4e5f60718293a4b5c6d7e8f9011223344556677a","removed":[]}
```

- `"result"` is `"created"` when a file was written.
- `"vault_id"` is the vault's id.
- `"file"` is the full path of the backup file.
- `"bytes"` is its size.
- `"fingerprint"` identifies the vault's content at that moment. `--if-changed` compares it with the last backup's.
- `"removed"` lists the older backups that retention deleted (often an empty list).

With `--if-changed`, a vault that has not changed prints `"result":"unchanged"` and writes nothing:

```json
{"result":"unchanged","vault_id":"01J8Z6K3Q4W9X2V5B7N1M0C8DA","fingerprint":"9f2c0a41d7b6e8530c1a2b3d4e5f60718293a4b5c6d7e8f9011223344556677a","last_file":"/Users/me/Backups/Notes-20261109T140300Z-01J8Z6K3Q4W9X2V5B7N1M0C8DA.memex.zip"}
```

`"last_file"` is the file the last backup to this destination wrote, or `null` when there is none. A failure prints one line of JSON on stderr, with the error code (see [Error codes](#error-codes)), and exits with a non-zero status.

### Schedule it with launchd

The app backs up only the vaults it has open, and only while it runs. For a Mac where the app is not always running, or for a vault you open with an agent only, schedule `memex backup` with launchd. Save this as `~/Library/LaunchAgents/com.openmemex.backup.plist`. launchd does not expand `~`, so write out your user name and use your own paths:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.openmemex.backup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOUR_USERNAME/.cargo/bin/memex</string>
    <string>backup</string>
    <string>--vault</string>
    <string>/Users/YOUR_USERNAME/memex</string>
    <string>--dest</string>
    <string>/Users/YOUR_USERNAME/Library/Mobile Documents/com~apple~CloudDocs/Open Memex Backups</string>
    <string>--if-changed</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>3</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
</dict>
</plist>
```

Load it with:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openmemex.backup.plist
```

Stop it with `launchctl bootout gui/$(id -u)/com.openmemex.backup`. If the Mac is asleep at 03:00, launchd runs the job when it wakes. With `--if-changed`, a day with no edits writes nothing. If a scheduled run fails with an unavailable destination for a folder you can write to by hand, macOS may be refusing the program launchd starts: allow it under Privacy & Security, or use a destination folder outside iCloud Drive, Documents and Desktop.

## Back up a vault server

A vault server (`memex serve --root`, see [`hosted-vault.md`](hosted-vault.md)) can back up every hosted vault it serves with two more options:

```bash
memex serve --root /srv/memex --listen 192.168.1.20:7878 --backup-dir /srv/memex/.backups --backup-keep 30
```

- `--backup-dir <dir>` turns on backups. It needs `--root`, and it does not work with `--vault` or `--remote`. Every vault in the vault root gets its own folder, `<dir>/<vault folder name>/`, and the server creates that folder, but never `<dir>` itself: create `<dir>` first, or each backup fails with an unavailable destination.
- `--backup-keep <n>` is how many backups of each vault the vault server keeps: 30 unless you say otherwise, from 1 to 365. It needs `--backup-dir`.
- The backup directory can be outside the vault root, or inside it only as a top-level dot folder such as `<root>/.backups`. The vault server never serves a folder that starts with a dot, so the backups are not served as a vault. It refuses `<root>/.memex` and `<root>/.incoming`, and any other place inside the root, and exits before it starts listening.

The vault server backs up every vault it serves, one at a time. It checks when it starts and then every hour, and it makes a backup of a vault once a day, when that vault has changed since its last backup (a vault with no edits is skipped). It does not need the app open, and it does not block reads or writes while it works. A vault copied into the root later is picked up on the next hourly check. Each vault's backups are in `<dir>/<vault folder name>/`, named as in [What a backup holds](#what-a-backup-holds).

The app shows a hosted vault's backup status in the Backups sheet, and **Back up now** asks the vault server to make one at once. The sheet reads `GET /vaults/<name>/api/v1/backup` and sends `POST` to the same path, with the access token like every other request. The answer has `enabled`, `keep`, `in_progress`, `last_attempt_at`, `last_success_at`, `last_result`, `last_error`, `last_file`, `last_file_created_at` and `last_bytes`. A failed automatic backup shows in `last_result` and `last_error`.

### On a NAS, in Docker

With the Docker route from [`hosted-vault.md`](hosted-vault.md), `<root>` is the folder you mounted at `/data`, so `<root>/.backups` is `/data/.backups` inside the container and `/volume1/memex/.backups` on the NAS. Create it, then add the two options to the `docker run` that starts the vault server:

```bash
mkdir -p /volume1/memex/.backups

docker run -d --name memex-vault-server --restart unless-stopped \
  -e TZ=Europe/London \
  -p 7878:7878 \
  -v /volume1/memex:/data \
  -v /volume1/memex-bin/memex:/usr/local/bin/memex:ro \
  debian:bookworm-slim \
  memex serve --root /data --listen 0.0.0.0:7878 --backup-dir /data/.backups --backup-keep 30
```

To keep the backups on a different disk from the vaults, mount that disk's folder as a second volume (for example `-v /volume2/memex-backups:/backups`) and pass `--backup-dir /backups`. A backup destination on a different disk survives the loss of the first one. On an always-on Mac, add `--backup-dir` and its folder to the vault server's `ProgramArguments`.

### Copy the backups on to the cloud

A vault server writes to its own disk. To get a copy off that disk, point a NAS tool at the backup directory (and only at it, never at a live vault):

- Synology: Hyper Backup can copy the backup directory to another disk, another NAS or a cloud provider. Synology's package that mirrors a folder to a cloud provider also works for this folder.
- QNAP: HBS 3 can do the same: copy the backup directory to another disk, another NAS or a cloud provider.
- Other tools (rclone, a provider's own app on a Mac that mounts the folder) work the same way: they only need to copy finished `.memex.zip` files. Skip names that start with a dot and end in `.partial`; those are backups still being written.

The cloud copy is made by that tool, not by Open Memex. Check its schedule and its own errors in its own screens.

## Restore a backup

A restore makes a new vault folder from a backup file. It never changes a vault that already exists.

### With the command line

```bash
memex restore --from "$HOME/Backups/Notes-20261109T140300Z-01J8Z6K3Q4W9X2V5B7N1M0C8DA.memex.zip" --to ~/memex-restored
```

- `--from <file>` is the `.memex.zip` backup.
- `--to <folder>` is the new vault folder. It must not exist, or must be an empty folder; anything else is refused and nothing is changed. A restore into a folder on a network drive is refused too.

It prints one line of JSON: `"vault_id"` (the restored vault's id), `"path"` (the new vault folder) and `"created_at"` (when the backup was made, in milliseconds since 1970).

```json
{"vault_id":"01J8Z6K3Q4W9X2V5B7N1M0C8DA","path":"/Users/me/memex-restored","created_at":1794232980000}
```

A restore does not migrate the vault. A backup of an older vault restores as an older vault, and the first normal open upgrades it, as in the README's upgrade steps. A backup that holds a newer schema than your `memex` supports is refused, so update `memex` first.

### In the app

On the vault picker, choose **Restore from backup…**, pick the `.memex.zip` file, choose a name and a parent folder for the new vault, and press restore. The dialog shows the backup's size and when it was made. If a folder with that name already exists and is not empty, it asks for another name.

### Onto a vault server

A vault server serves a vault only once its folder is in the vault root. So restore anywhere you like (on the NAS over SSH, or on your Mac), then move the new folder onto the vault server the way [`hosted-vault.md`](hosted-vault.md#move-a-local-vault-onto-the-server) describes: copy it into `<root>/.incoming/`, then rename it into `<root>/<name>` on the machine that runs the vault server, with a name the vault server does not already use. The restored vault appears at once, with no restart.

### A restored copy and its original

A restored copy keeps the original's vault id, because a backup carries the vault id and a restore does not change it. Backups are counted per vault id, so if the restored copy and the original back up into the same folder, they share one keep-last-N: with a keep of 30, the 30 newest files of that vault id are kept across both, and older files from either are deleted. If you want the two counted apart, give the restored copy its own backup destination folder.

## Error codes

The failures specific to backups and restores carry one of these eight codes. Other failures come out as the codes `memex` uses everywhere: `network_filesystem` (the vault, or a restore's `--to` folder, is on a network drive, which is refused) and `internal` (for example the vault folder or its `manifest.json` is missing, or the `--from` file does not exist). A script that switches on the codes should treat any code not listed here as a failure too. The command line prints them in one line of JSON on stderr and exits non-zero. A vault server's automatic backup records its code and message in the status the app reads, and answers a request with an HTTP status only in the two cases marked here.

| Code | HTTP status | What it means |
|---|---|---|
| `backup_destination_unavailable` | none | The backup destination is missing, is not a folder, cannot be written to, or macOS refused access to it. Create the folder or allow access, then try again. |
| `backup_destination_inside_vault` | none | The backup destination is the vault folder or a folder inside it, so a backup would contain the next one. Choose a folder outside the vault. |
| `backup_in_progress` | 409 | Another backup of this vault is already running. A vault server answers a second Back up now with this; wait for the first to end. |
| `backup_failed` | none | Reading the vault or writing the file failed part way, or the copy of the database did not pass its integrity check. No backup file is left and older backups are not touched. |
| `backup_invalid` | none | A restore was given a file that is not a backup memex can restore: it is not a zip, or it is missing or has damaged parts. |
| `backup_too_new` | none | A restore was given a backup of a newer schema than this memex supports. The error carries `schema_version` (the backup's schema) and `supported_schema_version` (the newest this memex supports). Update memex and try again. |
| `restore_target_not_empty` | none | The folder given to `--to` exists and is not empty. Choose a new folder or an empty one. |
| `backups_not_configured` | 409 | Only a vault server sends this: it was started without `--backup-dir`, so it was asked for a backup it cannot make. Restart it with `--backup-dir`. |
