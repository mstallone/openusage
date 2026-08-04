#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:?usage: decode_provisioning_profile.sh <profile> [output-plist]}"
OUTPUT="${2:-/dev/stdout}"

[ -f "$PROFILE" ] || { echo "provisioning profile does not exist: $PROFILE" >&2; exit 1; }

# Provisioning profiles are CMS-signed plists. Decode them with OpenSSL so repository tooling never
# delegates profile access to the Keychain-oriented security CLI. Verifying the CMS signature while
# skipping signer-chain trust matches the local-inspection purpose and also catches corrupt profiles.
exec /usr/bin/openssl cms -verify -inform DER -noverify -in "$PROFILE" -out "$OUTPUT"
