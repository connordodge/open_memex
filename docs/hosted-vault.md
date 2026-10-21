# Hosted vault

A **hosted vault** is a vault that lives on another machine. That machine runs the **vault server** (`memex serve --root`), and the app, Claude Desktop, Raycast and Claude Code reach the vault over your network. A **local vault** is the opposite: a folder on this Mac's own disk, opened directly (see [`claude-desktop-setup.md`](claude-desktop-setup.md)).

This page takes you from nothing to a working hosted vault:

1. run the vault server on a NAS, on Linux or on an always-on Mac;
2. choose the address it listens on, and find its access token;
3. move an existing local vault onto it (optional);
4. connect the app, Claude Desktop, Raycast and Claude Code;
5. fix the usual problems.

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

On the always-on machine, once `memex` is installed (the next three sections show how for a NAS, Linux and a Mac):

```bash
memex init <root>/<name>
memex serve --root <root> --listen <ip>:7878
```

Then copy the access token from `<root>/.memex/access-token` and connect from the app: choose "connect to a vault server…" and paste the server URL (`http://<ip>:7878`) and the token. The in-app set-up sheet shows the same steps.

## Set up on a NAS (Synology or QNAP)

There are two routes: Docker (Container Manager on Synology, Container Station on QNAP) or SSH. There is no published `memex` image, so both routes start by building the `memex` binary yourself.

### Run it with Docker

Build `memex` inside a Rust container on the NAS itself, so the binary matches the NAS's processor, then run it in a plain Debian container. Turn SSH on in the NAS settings and run these in an SSH session. The example sets `TZ` (see [Time zone](#time-zone)) and publishes port 7878:

```bash
# 1. build memex (a recent stable Rust image; this takes a while on a NAS)
git clone https://github.com/connordodge/open_memex.git
cd open_memex
docker run --rm -v "$PWD":/src -w /src rust:1-bookworm cargo build --release -p memex-mcp
mkdir -p /volume1/memex /volume1/memex-bin
cp target/release/memex /volume1/memex-bin/memex

# 2. create the first vault inside the vault root
docker run --rm \
  -v /volume1/memex:/data \
  -v /volume1/memex-bin/memex:/usr/local/bin/memex:ro \
  debian:bookworm-slim \
  memex init /data/home

# 3. start the vault server
docker run -d --name memex-vault-server --restart unless-stopped \
  -e TZ=Europe/London \
  -p 7878:7878 \
  -v /volume1/memex:/data \
  -v /volume1/memex-bin/memex:/usr/local/bin/memex:ro \
  debian:bookworm-slim \
  memex serve --root /data --listen 0.0.0.0:7878
```

The paths are examples: `/volume1/memex` is a Synology volume path, so use the shared folder on your own NAS. Keep the vault root on one of the NAS's own disks (a normal shared folder is fine; a mounted network share is not, see [Network drive refusal](#network-drive-refusal)).

If the container stops at once with a message about a missing shared library, read the log with `docker logs memex-vault-server` and either install the named library in a derived image or run the binary in the same `rust:1-bookworm` image you built it in.

### Run it over SSH

Build `memex` the same way (or build it on any Linux machine of the same processor type and copy it over), then run it directly:

```bash
mkdir -p /volume1/memex
/volume1/memex-bin/memex init /volume1/memex/home
TZ=Europe/London /volume1/memex-bin/memex serve --root /volume1/memex --listen 0.0.0.0:7878
```

That stops when your SSH session ends. To keep it running, make it a Task Scheduler "boot-up" task (Synology) or an autorun script (QNAP) that runs the same `serve` command, or use the Docker route above.

The access token lands in `/volume1/memex/.memex/access-token`. The Docker route runs as root, so read it over SSH with `sudo cat`.

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

Install `memex` on the Mac that stays on:

```bash
git clone https://github.com/connordodge/open_memex.git
cd open_memex
cargo install --path crates/memex-mcp --locked
mkdir -p ~/memex-server
memex init ~/memex-server/home
```

`cargo install` puts the binary at `~/.cargo/bin/memex`. Keep the vault root on the Mac's internal disk or an external disk that is a local drive, not a network share.

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

## Move a local vault onto the server

To bring a vault you already use onto the vault server, copy it in whole. The server must never see a half-copied vault, so copy it somewhere it ignores, then rename it into place.

1. Quit the app and any agent that has the local vault open. SQLite writes some data into side files while a vault is open; quitting makes `memex.db` complete.
2. Choose the vault's name. The vault-name rule: letters, digits, `-` and `_`, 1 to 64 characters, compared case-insensitively. So `Work` and `work` are the same vault, and the server serves only one of them.
3. Copy the vault folder into `<root>/.incoming/`. The server ignores every folder that starts with a dot, so nothing is served while the copy runs. An SMB share of the vault root works well for this (mount it in Finder), as does `rsync` or `scp`. Create `.incoming` first if it does not exist.
4. When the copy is complete, rename the folder to `<root>/<name>` on the machine that runs the vault server (or in your file manager on the share, which is also a rename on the same volume). The vault appears at once, with no restart.

```bash
# on the machine that runs the vault server
mkdir -p /volume1/memex/.incoming

# on your Mac, with the share mounted at /Volumes/memex
cp -R ~/Documents/MyMemex /Volumes/memex/.incoming/notes

# on the machine that runs the vault server, once the copy has finished
mv /volume1/memex/.incoming/notes /volume1/memex/notes
```

Check the result with `curl`, using the token (see [Troubleshooting](#troubleshooting) for the expected answers):

```bash
curl -H "Authorization: Bearer $MEMEX_ACCESS_TOKEN" http://192.168.1.20:7878/api/v1/vaults
```

Notes:

- The server's `memex` must be the same version as the one that wrote the vault, or newer. A newer `memex` upgrades the vault when it first opens it, and an older one refuses it.
- Stop using the local vault once it is on the server. The two copies do not merge, so keep the old folder only as a backup.

## Connect the app and agents

Every client needs the server URL, the vault name and the access token. Replace `192.168.1.20` with your vault server's address, `home` with your vault's name, and the token with yours.

**The app.** Choose "connect to a vault server…", then paste the server URL (`http://192.168.1.20:7878`) and the access token. You can create a vault from the app after you connect, or pick one the server already has.

**Claude Desktop, Raycast and other stdio clients** run `memex serve --remote <server-url>/vaults/<name>/mcp` as a bridge, with `MEMEX_ACCESS_TOKEN` in the client's `env`. The bridge sends your machine's current UTC offset with every request. It exits, so the client shows an error, if the token is missing, the server cannot be reached, the server answers 401, or the vault does not exist.

### Claude Desktop

Add this to `~/Library/Application Support/Claude/claude_desktop_config.json` (merge it into the existing `mcpServers`), then restart Claude Desktop. Use the absolute path to `memex`; Claude Desktop does not expand `~`.

```json
{
  "mcpServers": {
    "memex-home": {
      "command": "/Users/YOUR_USERNAME/.cargo/bin/memex",
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
      "command": "/Users/YOUR_USERNAME/.cargo/bin/memex",
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

### Network drive refusal

Starting the server, `memex init` or opening a vault fails with the error code `network_filesystem` when the folder is on a network drive (an SMB, NFS or similar mount). SQLite in WAL mode is not safe there, so `memex` refuses. Put the vault root on a disk that belongs to the machine running the vault server. To test a folder, run:

```bash
memex vault check --vault /volume1/memex
```

It exits 0 when the folder is safe, and otherwise prints the refusal and exits non-zero. The folder does not have to exist yet; the nearest existing parent is checked. Mounting your NAS share on a Mac and pointing a local vault at it is the same mistake, and is refused for the same reason: the vault belongs on the vault server, not on a share.
