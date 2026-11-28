#!/usr/bin/env bash
# eddsa_sign.sh: prints the Sparkle EdDSA (Ed25519) signature of a file
# (Spec #31, requirements 5-7).
#
# Usage:
#   SPARKLE_ED_KEY_PATH=<key file> scripts/release/eddsa_sign.sh <file>
#
#   SPARKLE_ED_KEY_PATH  the private key file: base64 of the 32-byte Ed25519
#                        seed, the format `generate_keys -x` exports
#   <file>               the file to sign (the release DMG)
#
# It runs Sparkle's `sign_update -p -f <key file> <file>`, with the
# sign_update found on PATH, and prints only the base64 signature on stdout
# (one line), so it is safe in a command substitution. Diagnostics go to
# stderr.
#
# It never runs sign_update without a key file: without -f the real tool
# reads the signing key from the login Keychain.
#
# Exit status: 0 signed, 1 sign_update failed or printed no signature,
# 2 usage error (no file, no key file).

set -u

die() {
  printf 'eddsa_sign: %s\n' "$2" >&2
  exit "$1"
}

[ $# -eq 1 ] || die 2 "usage: eddsa_sign.sh <file>"
file=$1
[ -n "$file" ] && [ -f "$file" ] || die 2 "the file to sign does not exist"

key=${SPARKLE_ED_KEY_PATH:-}
[ -n "$key" ] || die 2 "SPARKLE_ED_KEY_PATH is not set (sign_update would read the Keychain)"
[ -f "$key" ] && [ -r "$key" ] || die 2 "SPARKLE_ED_KEY_PATH is not a readable file"

command -v sign_update >/dev/null 2>&1 || die 1 "sign_update is required on PATH"

sig=$(sign_update -p -f "$key" "$file") || die 1 "sign_update failed"
case "$sig" in
  '' | *[!A-Za-z0-9+/=]*) die 1 "sign_update printed no base64 signature" ;;
esac
printf '%s\n' "$sig"
