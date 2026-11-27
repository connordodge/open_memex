#!/usr/bin/env bash
# smoke-test.sh <image-ref> <expected-version>
#
# Checks a freshly built memex image's startup contract (Spec #189
# requirement 19). docker.yml runs it on every arch job before anything is
# pushed. It needs Docker, curl and passwordless sudo (a GitHub-hosted
# runner): the vault folders it bind-mounts belong to the container's users,
# not the runner's.
#
# The server runs without embeddings, so no embedding model is downloaded.
# Waits poll `docker logs`; there is no fixed sleep.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: scripts/docker/smoke-test.sh <image-ref> <expected-version>" >&2
  exit 2
fi
IMAGE=$1
VERSION=$2

LISTENING='memex serve: vault server listening on http://0.0.0.0:7878'
GENERATED='memex serve: generated a new access token in /vaults/.memex/access-token'
START_TIMEOUT_SECS=60
STOP_TIMEOUT_SECS=10
INFO_URL='http://127.0.0.1:7878/api/v1/info'

containers=""
dirs=""

fail() {
  echo "smoke-test: FAIL: $*" >&2
  exit 1
}

ok() {
  echo "smoke-test: ok: $*"
}

cleanup() {
  local status=$? c d
  for c in $containers; do
    if [ "$status" -ne 0 ]; then
      echo "--- docker logs $c" >&2
      docker logs "$c" >&2 2>&1 || true
    fi
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  for d in $dirs; do
    sudo rm -rf "$d" || true
  done
  exit "$status"
}
trap cleanup EXIT

# Polls the container's log until it prints $2, for up to
# START_TIMEOUT_SECS (60) seconds; fails at once if the container exits.
wait_for_line() {
  local c=$1 line=$2 waited=0
  while [ "$waited" -lt "$START_TIMEOUT_SECS" ]; do
    if docker logs "$c" 2>&1 | grep -qF "$line"; then
      return 0
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$c")" != "true" ]; then
      fail "container $c exited before printing '$line'"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  fail "container $c did not print '$line' within ${START_TIMEOUT_SECS}s"
}

# A fresh vault folder owned by $1 (uid:gid), as a host bind mount.
vault_dir() {
  local d
  d=$(mktemp -d)
  sudo chown "$1" "$d"
  echo "$d"
}

http_code() {
  curl -sS -o /dev/null -w '%{http_code}' "$@" "$INFO_URL"
}

# 1. The binary and its version.
out=$(docker run --rm "$IMAGE" memex --version)
[ "$out" = "memex $VERSION" ] || fail "memex --version printed '$out', expected 'memex $VERSION'"
ok "memex --version prints memex $VERSION"

# 2. Image config: the memex user, no health check, the version label.
user=$(docker inspect -f '{{.Config.User}}' "$IMAGE")
[ "$user" = "1000:1000" ] || fail "Config.User is '$user', expected 1000:1000"
healthcheck=$(docker inspect -f '{{json .Config.Healthcheck}}' "$IMAGE")
[ "$healthcheck" = "null" ] || fail "the image has a Healthcheck: $healthcheck"
label=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")
[ "$label" = "$VERSION" ] || fail "org.opencontainers.image.version is '$label', expected '$VERSION'"
ok "Config.User 1000:1000, no Healthcheck, version label $VERSION"

# 3. First start on an empty /vaults owned by 1000:1000, in Asia/Tokyo.
dir=$(vault_dir 1000:1000)
dirs="$dirs $dir"
c=$(docker run -d -e TZ=Asia/Tokyo -p 127.0.0.1:7878:7878 -v "$dir:/vaults" "$IMAGE")
containers="$containers $c"
wait_for_line "$c" "$LISTENING"
ok "the server is listening"
docker logs "$c" 2>&1 | grep -qF "$GENERATED" || fail "no '$GENERATED' line"
ok "it generated a new access token"

token_file="$dir/.memex/access-token"
mode_owner=$(sudo stat -c '%a %u:%g' "$token_file")
[ "$mode_owner" = "600 1000:1000" ] || fail "the token file is '$mode_owner', expected '600 1000:1000'"
ok "the token file is mode 600, owned by 1000:1000"
token=$(sudo cat "$token_file")
[ -n "$token" ] || fail "the token file is empty"

# 4. The API: 401 without the token, 200 with it, and the server version.
code=$(http_code)
[ "$code" = "401" ] || fail "GET /api/v1/info without a token answered $code, expected 401"
code=$(http_code -H "Authorization: Bearer $token")
[ "$code" = "200" ] || fail "GET /api/v1/info with the token answered $code, expected 200"
body=$(curl -sS -H "Authorization: Bearer $token" "$INFO_URL")
printf '%s' "$body" | grep -qF "\"server_version\":\"$VERSION\"" \
  || fail "GET /api/v1/info answered '$body', expected server_version $VERSION"
ok "GET /api/v1/info: 401 without the token, 200 with it, server_version $VERSION"

# 5. docker stop: a graceful SIGTERM shutdown, exit code 0, within 10 s.
started=$(date +%s)
docker stop -t "$STOP_TIMEOUT_SECS" "$c" >/dev/null
elapsed=$(($(date +%s) - started))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$c")
[ "$exit_code" = "0" ] || fail "after docker stop the container exited $exit_code, expected 0"
[ "$elapsed" -le "$STOP_TIMEOUT_SECS" ] || fail "docker stop took ${elapsed}s"
ok "docker stop: exit code 0 after ${elapsed}s"

# 6. server.log.<date> (flushed at shutdown): the startup line records the
# container's UTC offset, and the server ran without embeddings (no model).
started_line=$(sudo sh -c 'cat "$1"/.memex/server.log.*' sh "$dir" | grep -F 'vault server started' || true)
[ -n "$started_line" ] || fail "server.log.<date> has no 'vault server started' line"
printf '%s' "$started_line" | grep -qF 'utc_offset=+09:00' \
  || fail "the startup line does not record utc_offset=+09:00: $started_line"
printf '%s' "$started_line" | grep -qF 'with_embeddings=false' \
  || fail "the server started with embeddings: $started_line"
ok "server.log records utc_offset=+09:00 and with_embeddings=false"

# 7. --user 99:100 (Unraid's nobody:users) on a 99:100 folder starts and
# writes a 99:100 token file.
dir2=$(vault_dir 99:100)
dirs="$dirs $dir2"
c2=$(docker run -d --user 99:100 -v "$dir2:/vaults" "$IMAGE")
containers="$containers $c2"
wait_for_line "$c2" "$LISTENING"
owner=$(sudo stat -c '%u:%g' "$dir2/.memex/access-token")
[ "$owner" = "99:100" ] || fail "with --user 99:100 the token file is owned by '$owner', expected 99:100"
ok "--user 99:100 starts and writes a 99:100 token file"

echo "smoke-test: all checks passed for $IMAGE ($VERSION)"
