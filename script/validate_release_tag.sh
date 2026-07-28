#!/usr/bin/env bash
set -euo pipefail

TAG="${1:?release tag required}"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Release tags must use the stable form v1.2.3." >&2
  exit 1
fi

printf '%s\n' "${TAG#v}"
