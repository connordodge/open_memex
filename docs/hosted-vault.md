# Hosted vault

A **hosted vault** is a vault that lives on another machine. That machine runs the **vault server** (`memex serve --root`), and the app, Claude Desktop, Raycast and Claude Code reach the vault over your network. A **local vault** is the opposite: a folder on this Mac's own disk, opened directly (see [`claude-desktop-setup.md`](claude-desktop-setup.md)).

This page takes you from nothing to a working hosted vault:

1. run the vault server on a NAS, on Unraid, on Linux or on an always-on Mac;
2. choose the address it listens on, and find its access token;
3. move an existing local vault onto it (optional);
4. connect the app, Claude Desktop, Raycast and Claude Code;
5. fix the usual problems.

To back up the vaults on a vault server, and to restore one, see [`backups.md`](backups.md).

## What the vault server serves

- The **vault root** is the folder you pass to `--root`. Every immediate subfolder that is a vault is served under its folder name, so `<root>/home` is the vault `home` at `/vaults/home/`.
- A subfolder counts as a vault when it holds `manifest.json` and `memex.db` (`memex init` makes both). Folders that start with a dot are never served, and neither are folders whose names break the vault-name rule (see [Move a local vault onto the server](#move-a-local-vault-onto-the-server)). A vault you copy in by hand shows up without a restart.
- One access token protects the whole vault server (see [The access token and rotating it](#the-access-token-and-rotating-it)).
- It logs to `<root>/.memex/server.log` (rolled daily, so the files are named `server.log.<date>`). The access token is never written there.
- `--with-embeddings` on `memex serve --root` turns on real embeddings for every vault it serves; leave it off for keyword search only.
- The `memex` commands you run by hand (`memex add`, `memex ls`, and so on) stay local: they open a vault folder on the machine you run them on, never a URL.

## Trusted network only

A vault server is for a trusted LAN or tailnet only: your home network, or a Tailscale network of your own devices. It is never for the public internet. It speaks plain HTTP with no TLS, so anyone who can reach the port can read the access token off the wire.

Use your home network or Tailscale. Never expose the server to the internet. That means no port forwarding on your router, no public reverse proxy and no public cloud host.

## The short version

On the always-on machine, once `memex` is installed (the next four sections show how for a NAS, Unraid, Linux and a Mac):

```bash
memex init <root>/<name>
memex serve --root <root> --listen <ip>:7878
```

Then copy the access token from `<root>/.memex/access-token` and connect from the app: choose "connect to a vault server…" and paste the server URL (`http://<ip>:7878`) and the token. The in-app set-up sheet shows the same steps.

## Set up on a NAS (Synology or QNAP)

There are two routes: Docker (Container Manager on Synology, Container Station on QNAP) or SSH. The Docker route runs the published image `ghcr.io/connordodge/memex`, so you build nothing. The SSH route runs a `memex` binary you build from source.

### Run it with Docker

The vault server image, `ghcr.io/connordodge/memex`, is published for every release after v0.7.0, so `latest` exists once a release after v0.7.0 is out. Turn SSH on in the NAS settings and run these in an SSH session. They create the vault root, give it to user `1000:1000` (the user the image runs as), and start the vault server. The example sets `TZ` (see [Time zone](#time-zone)) and publishes port 7878:

```bash
sudo mkdir -p /volume1/memex
sudo chown 1000:1000 /volume1/memex

docker run -d --name memex-vault-server --restart unless-stopped \
  -e TZ=Europe/London \
  -p 7878:7878 \
  -v /volume1/memex:/vaults \
  ghcr.io/connordodge/memex:latest \
  memex serve --root /vaults --listen 0.0.0.0:7878
```

The paths are examples: `/volume1/memex` is a Synology volume path, so use the shared folder on your own NAS. Keep the vault root on one of the NAS's own disks (a normal shared folder is fine; a mounted network share is not, see [Network drive refusal](#network-drive-refusal)). The folder must belong to `1000:1000` before the first start: if Docker has to create it, it belongs to root and the server stops with "Permission denied" (see [Permission denied on first start](#permission-denied-on-first-start)).

Start on an empty folder. Connect from the app (see [Connect the app and agents](#connect-the-app-and-agents)) and create your first vault there. If you would rather make the first vault from the command line, that is optional; run it once, in the same folder:

```bash
docker run --rm -v /volume1/memex:/vaults ghcr.io/connordodge/memex:latest memex init /vaults/home
```

The server sets no `MEMEX_ACCESS_TOKEN`, so on its first start it makes its own access token. Run `docker logs memex-vault-server` and you will see one line, `memex serve: generated a new access token in /vaults/.memex/access-token`; the token itself is never printed. On the NAS that file is `/volume1/memex/.memex/access-token`: read it with `cat`, as the account that owns the folder, or run `docker exec memex-vault-server cat /vaults/.memex/access-token`.

To turn on embeddings for every vault, add `--with-embeddings` to the end of the `memex serve` line and start the container again (remove the old one first with `docker rm -f memex-vault-server`; your vaults stay in the folder):

```bash
docker run -d --name memex-vault-server --restart unless-stopped \
  -e TZ=Europe/London \
  -p 7878:7878 \
  -v /volume1/memex:/vaults \
  ghcr.io/connordodge/memex:latest \
  memex serve --root /vaults --listen 0.0.0.0:7878 --with-embeddings
```

The first start with embeddings needs internet access: the server downloads about 130 MB of model files into `<root>/.memex/models` (here `/volume1/memex/.memex/models`), and later starts reuse them.

### Run it over SSH

Build `memex` from source. You need a recent stable Rust toolchain, or a Rust container, and the build must match the NAS's processor: run it on the NAS itself in a `rust:1-trixie` container, or on any Linux machine of the same processor type and copy the binary over. The binary needs glibc 2.38 or later where it runs; if your NAS's Linux is older, use the Docker route above instead.

```bash
git clone https://github.com/connordodge/open_memex.git
cd open_memex
docker run --rm -v "$PWD":/src -w /src rust:1-trixie cargo build --release -p memex-mcp
mkdir -p /volume1/memex-bin
cp target/release/memex /volume1/memex-bin/memex
```

On a Linux machine, skip the container and run `cargo build --release -p memex-mcp` in the clone. Then run the binary directly on the NAS:

```bash
mkdir -p /volume1/memex
/volume1/memex-bin/memex init /volume1/memex/home
TZ=Europe/London /volume1/memex-bin/memex serve --root /volume1/memex --listen 0.0.0.0:7878
```

That stops when your SSH session ends. To keep it running, make it a Task Scheduler "boot-up" task (Synology) or an autorun script (QNAP) that runs the same `serve` command, or use the Docker route above.

The access token lands in `/volume1/memex/.memex/access-token`, owned by the account that ran `serve`, so read it over SSH as that account with `cat`.

## Set up on Unraid

Unraid runs the vault server as a Docker container from the published image `ghcr.io/connordodge/memex` (released after v0.7.0), started with the repository's compose file.

Keep the vault root in the `appdata` folder on a pool, such as `/mnt/cache/appdata/memex`. If your pool is not named `cache`, use your pool's name: `/mnt/<pool>/appdata/memex`. `/mnt/user/appdata/memex` works only when `appdata` is an Exclusive share (Unraid 6.12 and later). Otherwise `/mnt/user` is the `shfs` FUSE layer that merges shares across disks, and the vault server refuses it with the error code `network_filesystem` (see [Network drive refusal](#network-drive-refusal)). Never put the vault root on the array or on a user share.

Create the folder and give it to `99:100`, the `nobody:users` owner Unraid uses for container files:

```bash
mkdir -p /mnt/cache/appdata/memex && chown 99:100 /mnt/cache/appdata/memex
```

The compose file is [`deploy/compose.yaml`](https://raw.githubusercontent.com/connordodge/open_memex/main/deploy/compose.yaml) in the repository. This is the same file with two changes: an added `user: "99:100"` line, so the container runs as the folder's owner instead of the image's `1000:1000`, and your Unraid folder as the volume. Replace `Europe/London` with your own time zone (see [Time zone](#time-zone)). The comments are the file's own; on Unraid, read `./vaults` as the appdata folder and `1000:1000` as `99:100`.

```yaml
# The Open Memex vault server (memex serve) from the published image.
# Start it with `docker compose up -d` in the folder that holds this file.
# The image runs as user 1000:1000 and serves every vault in /vaults.
services:
  memex:
    image: ghcr.io/connordodge/memex:latest
    container_name: memex
    restart: unless-stopped
    user: "99:100"
    environment:
      # Set your own time zone here (a TZ name such as America/New_York).
      # Without it the container runs in UTC, and callers that send no UTC
      # offset get the wrong day.
      TZ: Europe/London
    ports:
      - "7878:7878"
    volumes:
      # The folder on this host that holds your vaults. Create ./vaults and
      # make 1000:1000 its owner (chown 1000:1000 ./vaults) before the first
      # start. If you do not, Docker creates it owned by root and the server
      # stops with "Permission denied". If the folder has another owner, add
      # a user: line to this service (user: "<uid>:<gid>") instead.
      - /mnt/cache/appdata/memex:/vaults
    # To turn on embeddings for every vault, add this line under the service
    # (it downloads about 130 MB on the first start):
    #   command: memex serve --root /vaults --listen 0.0.0.0:7878 --with-embeddings
```

Start it with the Compose Manager plugin (add a stack, paste the file, then choose Compose Up), or from the Unraid terminal in the folder that holds the file:

```bash
docker compose up -d
```

Start on an empty folder. Connect from the app (see [Connect the app and agents](#connect-the-app-and-agents)) and create your first vault there. If you would rather make it from the command line, that is optional; run it once, in the folder with the compose file:

```bash
docker compose run --rm memex memex init /vaults/home
```

The compose file sets no `MEMEX_ACCESS_TOKEN`, so the first start makes its own access token. `docker logs memex` shows one line, `memex serve: generated a new access token in /vaults/.memex/access-token`; the token itself is never printed. Read it on the host:

```bash
cat /mnt/cache/appdata/memex/.memex/access-token
```

To turn on embeddings for every vault, uncomment the `command:` line shown at the end of the file, under the `memex` service:

```yaml
    command: memex serve --root /vaults --listen 0.0.0.0:7878 --with-embeddings
```

Then run `docker compose up -d` again. The first start with embeddings needs internet access: the server downloads about 130 MB of model files into `<root>/.memex/models` (here `/mnt/cache/appdata/memex/.memex/models`).

## Set up on Linux (systemd)

Build and install `memex` (you need a recent stable Rust toolchain, installed with rustup):

```bash
git clone https://github.com/connordodge/open_memex.git
cd open_memex
cargo build --release -p memex-mcp
sudo install -m 0755 target/release/memex /usr/local/bin/memex
```

Make a user and a vault root, then create the first vault:

```bash
sudo useradd --system --create-home --home-dir /srv/memex memex
sudo -u memex memex init /srv/memex/home
```

Save this as `/etc/systemd/system/memex-vault-server.service`. Replace `192.168.1.20` with this machine's LAN or Tailscale address (see [Choose the listen address](#choose-the-listen-address)) and `Europe/London` with your time zone:

```ini
[Unit]
Description=Open Memex vault server
After=network-online.target
Wants=network-online.target

[Service]
User=memex
Environment=TZ=Europe/London
ExecStart=/usr/local/bin/memex serve --root /srv/memex --listen 192.168.1.20:7878
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Start it and read the access token:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now memex-vault-server
sudo cat /srv/memex/.memex/access-token
```

`journalctl -u memex-vault-server` shows what the server printed at start, including where it generated the token file. If you use Tailscale and the unit starts before Tailscale is up, `Restart=on-failure` brings it back once the address exists.

## Set up on an always-on Mac (launchd)

Build `memex` from source on the Mac that stays on (or use the standalone `memex-<ver>-macos-arm64.zip` from the [Releases page](https://github.com/connordodge/open_memex/releases), which holds only the `memex` binary):

```bash
git clone https://github.com/connordodge/open_memex.git
cd open_memex
cargo install --path crates/memex-mcp --locked
mkdir -p ~/memex-server
memex init ~/memex-server/home
```

Installing from source with `cargo install` puts the binary at `~/.cargo/bin/memex`. Keep the vault root on the Mac's internal disk or an external disk that is a local drive, not a network share.

Save this as `~/Library/LaunchAgents/com.openmemex.vault-server.plist`. launchd does not expand `~`, so write out your user name, and use your own time zone and address:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.openmemex.vault-server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOUR_USERNAME/.cargo/bin/memex</string>
    <string>serve</string>
    <string>--root</string>
    <string>/Users/YOUR_USERNAME/memex-server</string>
    <string>--listen</string>
    <string>192.168.1.20:7878</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TZ</key><string>Europe/London</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
```

Load it, and read the access token:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openmemex.vault-server.plist
cat ~/memex-server/.memex/access-token
```

Stop it with `launchctl bootout gui/$(id -u)/com.openmemex.vault-server`.

A LaunchAgent runs while that user is logged in. For a Mac that must serve after a restart with nobody logged in, turn on automatic login for a dedicated user, or install the same plist as a LaunchDaemon in `/Library/LaunchDaemons` (owned by root) and add a `UserName` key. Also stop the Mac from sleeping (System Settings, Energy), or the vault server goes away whenever it naps.

## Time zone

The app, `memex serve --remote` and Claude Code send their UTC offset with each request, and the vault server uses it to decide which day "today" is. The vault server's own time zone is only the fallback for a caller that sends no offset. That is why the Docker, systemd and launchd examples above set `TZ`: set it to the zone you live in, so those callers get the right day. Without it, a Docker container runs in UTC.

## Choose the listen address

`--listen` takes `<host:port>` and has no default: the vault server will not start without it, so it never listens on an address you did not choose.

- `0.0.0.0:7878` listens on every network interface of the machine, so the LAN and Tailscale both reach it. It is the simplest choice at home, and the only sensible one inside a Docker container.
- `<lan-ip>:7878`, for example `192.168.1.20:7878`, listens on the home-network address only. Give the machine a fixed address (a DHCP reservation in your router) so the URL does not change.
- `<tailnet-ip>:7878`, for example `100.101.102.103:7878`, listens on the Tailscale address only. Find it with `tailscale ip -4`. Your devices reach it from anywhere on your tailnet, with Tailscale's encryption, and the LAN does not reach it at all.
- `127.0.0.1:7878` listens on the machine itself only, which is handy for trying things out.

The port is yours to choose; 7878 is just the one these examples use. The server URL you give the app and the agents is `http://<ip>:7878`.

## The access token and rotating it

The vault server needs one access token, and every client sends it. The server reads it from the `MEMEX_ACCESS_TOKEN` environment variable, and if that is not set, from `<root>/.memex/access-token`.

- With neither, the first start generates a random token and writes it to `<root>/.memex/access-token` with mode `0600` (only its owner can read it). It prints that file's path once, on stderr, and nothing else. The token itself is never printed or logged, and it is never read from the command line.
- Read it with `cat <root>/.memex/access-token`, and paste it into the app or the client configs below. Leading and trailing whitespace is ignored.
- If you set `MEMEX_ACCESS_TOKEN` in the service definition instead, that value wins and the file is not used.
- If the token file is readable by group or others, the server still starts but logs a warning; run `chmod 600` on it.

To rotate the token, stop the vault server, delete `<root>/.memex/access-token`, and start it again. It generates a new one. Then update every client (the app, the Claude Desktop and Raycast configs, `$MEMEX_ACCESS_TOKEN` for Claude Code), because the old token stops working at once. If you set `MEMEX_ACCESS_TOKEN` yourself, change the value in the service definition and restart.

On a hosted vault one bearer token is shared by `/mcp` (the agents' endpoint) and `/api/v1` (the app's endpoint), so Agent read-only stops agents that connect over MCP, but not a holder of the server token who also has shell access and can call `/api/v1` to clear it. That includes an agent you connect from Claude Code (see [Claude Code](#claude-code)) or any other client that runs a shell: it holds the token, so Agent read-only does not bind it until a separate token for agents lands. Keep the token away from anything an agent can run a shell in. That separate token is tracked in #26.

## Move a local vault onto the server

To bring a vault you already use onto the vault server, copy it in whole. The server must never see a half-copied vault, so copy it somewhere it ignores, then rename it into place.

1. Quit the app and any agent that has the local vault open. SQLite writes some data into side files while a vault is open; quitting makes `memex.db` complete.
2. Choose the vault's name. The vault-name rule: letters, digits, `-` and `_`, 1 to 64 characters, compared case-insensitively. So `Work` and `work` are the same vault, and the server serves only one of them.
3. Copy the vault folder into `<root>/.incoming/`. The server ignores every folder that starts with a dot, so nothing is served while the copy runs. An SMB share of the vault root works well for this (mount it in Finder), as does `rsync` or `scp`. Create `.incoming` first if it does not exist.
4. When the copy is complete, give the copy to the user the vault server runs as, then rename the folder to `<root>/<name>` on the machine that runs the vault server. On the binary routes (SSH, systemd or launchd) you can instead rename it in your file manager on the share, which is also a rename on the same volume. On the Docker route the container runs as `1000:1000` (`99:100` on Unraid), and a copy you made belongs to the account that copied it, so without the `chown` the container cannot write the vault and does not open it (see [Permission denied on first start](#permission-denied-on-first-start)). After that `chown` the folder belongs to the container user, and your account on the share cannot move it, so on the Docker route the rename is the root `mv` on the server, not the file manager. The vault appears at once, with no restart.

```bash
# on the machine that runs the vault server: create .incoming for the account that copies
sudo mkdir -p /volume1/memex/.incoming
sudo chown "$(id -u):$(id -g)" /volume1/memex/.incoming

# on your Mac, with the share mounted at /Volumes/memex
cp -R ~/Documents/MyMemex /Volumes/memex/.incoming/notes

# on the machine that runs the vault server, once the copy has finished, in a root shell (sudo -i)
chown -R 1000:1000 /volume1/memex/.incoming/notes
mv /volume1/memex/.incoming/notes /volume1/memex/notes
```

If you run the vault server from a binary instead (the SSH route, systemd or launchd), skip the `chown` lines and the root shell: the copy only has to belong to the account that runs the vault server.

Check the result with `curl`, using the token (see [Troubleshooting](#troubleshooting) for the expected answers):

```bash
curl -H "Authorization: Bearer $MEMEX_ACCESS_TOKEN" http://192.168.1.20:7878/api/v1/vaults
```

Notes:

- The server's `memex` must be the same version as the one that wrote the vault, or newer. A newer `memex` upgrades the vault when it first opens it, and an older one refuses it.
- Stop using the local vault once it is on the server. The two copies do not merge, so keep the old folder only as a backup.

## Connect the app and agents

Every client needs the server URL, the vault name and the access token. Replace `192.168.1.20` with your vault server's address, `home` with your vault's name, and the token with yours.

The Agents sheet (⇧⌘A, also Window ▸ Agents…, or `OPEN ↗` in the sidebar) is the quickest way to get these setup snippets filled in for this vault.

**The app.** Choose "connect to a vault server…", then paste the server URL (`http://192.168.1.20:7878`) and the access token. You can create a vault from the app after you connect, or pick one the server already has.

**Claude Desktop, Raycast and other stdio clients** run `memex serve --remote <server-url>/vaults/<name>/mcp` as a bridge, with `MEMEX_ACCESS_TOKEN` in the client's `env`. The bridge sends your machine's current UTC offset with every request. It exits, so the client shows an error, if the token is missing, the server cannot be reached, the server answers 401, or the vault does not exist.

### Claude Desktop

Add this to `~/Library/Application Support/Claude/claude_desktop_config.json` (merge it into the existing `mcpServers`), then restart Claude Desktop. Use the absolute path to `memex` (here the Bundled memex inside the app, which the README's Install section describes; for a terminal, run the `ln -s` step in the [README](../README.md)); Claude Desktop does not expand `~`.

```json
{
  "mcpServers": {
    "memex-home": {
      "command": "/Applications/Open Memex.app/Contents/MacOS/memex",
      "args": ["serve", "--remote", "http://192.168.1.20:7878/vaults/home/mcp"],
      "env": { "MEMEX_ACCESS_TOKEN": "paste-the-access-token-here" }
    }
  }
}
```

### Raycast

Add a server in Raycast's MCP server settings (the menu names change between Raycast versions) with the same command, arguments and environment:

```json
{
  "mcpServers": {
    "memex-home": {
      "command": "/Applications/Open Memex.app/Contents/MacOS/memex",
      "args": ["serve", "--remote", "http://192.168.1.20:7878/vaults/home/mcp"],
      "env": { "MEMEX_ACCESS_TOKEN": "paste-the-access-token-here" }
    }
  }
}
```

### Claude Code

Claude Code speaks HTTP to the vault server directly, so it needs no bridge:

```bash
export MEMEX_ACCESS_TOKEN=paste-the-access-token-here
claude mcp add --transport http memex-home http://192.168.1.20:7878/vaults/home/mcp \
  --header "Authorization: Bearer $MEMEX_ACCESS_TOKEN" \
  --header "X-Memex-UTC-Offset: +01:00"
```

Set `X-Memex-UTC-Offset` to your own offset from UTC, as `+HH:MM` or `-HH:MM`. Claude Code sends this header exactly as written, so it is a fixed offset: when daylight saving time changes, update the header (run `claude mcp remove memex-home` and add it again). The bridge that Claude Desktop and Raycast use sends the current offset automatically, so they need no such update. Without the header the vault server falls back to its own time zone (see [Time zone](#time-zone)).

Claude Code runs a shell and holds the access token, so on a hosted vault Agent read-only does not bind it (see [The access token and rotating it](#the-access-token-and-rotating-it)).

## Troubleshooting

### 401 unauthorized

The access token is missing or wrong. Compare what the client sends with `cat <root>/.memex/access-token` on the vault server, and look for a token you rotated since (see [The access token and rotating it](#the-access-token-and-rotating-it)). Check by hand:

```bash
curl -i -H "Authorization: Bearer $MEMEX_ACCESS_TOKEN" http://192.168.1.20:7878/api/v1/vaults
```

A 200 answer with a list of vaults means the token and the address are fine. The bridge exits when the server answers 401, so fix the token in the client's `env` and restart the client.

### Cannot reach the server

The bridge exits with `server_unreachable` when nothing answers at the URL. Work through these in order:

- Is the vault server running? On the server machine, check `docker ps`, `systemctl status memex-vault-server` or `launchctl list | grep openmemex`, and read `<root>/.memex/server.log.<date>`.
- Is the URL right: the address you gave to `--listen`, the port, `http://` and not `https://`? A server listening on `127.0.0.1` answers only on its own machine.
- Is the client on the same LAN, or signed in to the same tailnet? Try `curl -i http://192.168.1.20:7878/api/v1/vaults` from the client machine: any answer, even 401, means the network path works.
- If the vault does not exist, the server answers 404 `vault_not_found`, and the bridge exits with it. The name in the URL must match a folder under the vault root, ignoring case.

### Firewall blocks the port

The server runs but only the machine itself can reach it. Open the port to your home network only:

- Synology: Control Panel, Security, Firewall, allow TCP 7878 from your LAN subnet.
- QNAP: Control Panel, Security, Security Level, allow the port for your LAN subnet.
- Linux with ufw: `sudo ufw allow from 192.168.1.0/24 to any port 7878 proto tcp`.
- Mac: System Settings, Network, Firewall; allow incoming connections for `memex` when macOS asks, or add it to the allowed apps.

Do not open the port to "any address", and do not forward it on your router.

### Permission denied on first start

The vault server stops at once with "Permission denied" when the container's user cannot write to the vault root. The same ownership problem shows later when you copy a vault in (see [Move a local vault onto the server](#move-a-local-vault-onto-the-server)): the vault does not open until its folder belongs to the container's user. The image runs as user `1000:1000`, so the folder you mount at `/vaults` needs that owner. If the folder did not exist, Docker created it owned by root. Check the folder's owner with `ls -ld <folder>`, then do one of these:

- Give the folder to the container's user: `chown 1000:1000 <folder>` (on Unraid, `chown 99:100 <folder>` together with the `user: "99:100"` line from the compose file above), then start the container again.
- Or keep the folder's owner and run the container as it: add `user: "<uid>:<gid>"` to the compose service, or `--user <uid>:<gid>` to `docker run`, using the owner's numbers from `ls -n`.

### Network drive refusal

Starting the server, `memex init` or opening a vault fails with the error code `network_filesystem` when the folder is on a network drive (an SMB, NFS or similar mount). SQLite in WAL mode is not safe there, so `memex` refuses. Put the vault root on a disk that belongs to the machine running the vault server. To test a folder, run:

```bash
memex vault check --vault /volume1/memex
```

It exits 0 when the folder is safe, and otherwise prints the refusal and exits non-zero. The folder does not have to exist yet; the nearest existing parent is checked. On Unraid the same refusal appears when the vault root is under `/mnt/user`, which is the `shfs` FUSE layer: use `/mnt/<pool>/appdata/memex` instead (or an Exclusive share), as in [Set up on Unraid](#set-up-on-unraid). Mounting your NAS share on a Mac and pointing a local vault at it is the same mistake, and is refused for the same reason: the vault belongs on the vault server, not on a share.
