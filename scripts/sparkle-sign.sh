#!/bin/bash
# Signs an update archive for Sparkle, then checks the signature against the public key the app carries, the same
# check an installed copy of DropUp makes before it installs anything.
#
#   SPARKLE_PRIVATE_KEY=<key> scripts/sparkle-sign.sh <path to sign_update> <public key> <archive>
#
# Prints "<signature> <length>". The private key comes from the environment and goes to sign_update on its standard
# input: never on a command line, in a file or in the log. The signature and the length are public, they go in the
# appcast. Needs OpenSSL 3 (macOS's own is LibreSSL, which can't verify Ed25519).
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: SPARKLE_PRIVATE_KEY=<key> $0 <sign_update> <public key> <archive>" >&2
  exit 2
fi
sign_update="$1"
public_key="$2"
archive="$3"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"

output="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sign_update" --ed-key-file - "$archive")"
signature="$(printf '%s' "$output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
length="$(printf '%s' "$output" | sed -n 's/.* length="\([0-9]*\)".*/\1/p')"
if [ -z "$signature" ] || [ -z "$length" ]; then
  echo "sign_update printed something unexpected, so there is no signature to use." >&2
  exit 1
fi

openssl=""
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" version 2>/dev/null | grep -q '^OpenSSL 3'; then
    openssl="$candidate"
    break
  fi
done
if [ -z "$openssl" ]; then
  echo "OpenSSL 3 is needed to check the signature (brew install openssl@3)." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s' "$public_key" | base64 --decode > "$work/public-key.raw"
if [ "$(wc -c < "$work/public-key.raw" | tr -d ' ')" != 32 ]; then
  echo "The public key is not a 32 byte Ed25519 key. Check SUPublicEDKey in project.yml." >&2
  exit 1
fi
printf '%s' "$signature" | base64 --decode > "$work/signature"
# The raw key wrapped as an X.509 public key (RFC 8410), which is the form OpenSSL reads.
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; cat "$work/public-key.raw"; } > "$work/public-key.der"
if ! "$openssl" pkeyutl -verify -pubin -inkey "$work/public-key.der" -keyform DER -rawin \
     -in "$archive" -sigfile "$work/signature" > /dev/null 2>&1; then
  echo "The signature does not match the public key in the app. SPARKLE_PRIVATE_KEY and SUPublicEDKey in project.yml must be the two halves of one key." >&2
  exit 1
fi

echo "$signature $length"
