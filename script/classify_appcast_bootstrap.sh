#!/usr/bin/env bash
set -euo pipefail

# Classify whether a missing appcast can safely start fresh. Existing GitHub Release tag names are
# read one per line from stdin; the current release tag is the sole argument.
CURRENT_TAG="${1:?current release tag required}"
RELEASE_COUNT=0
ONLY_RELEASE_TAG=""

while IFS= read -r release_tag || [ -n "$release_tag" ]; do
  [ -n "$release_tag" ] || continue
  RELEASE_COUNT=$((RELEASE_COUNT + 1))
  if [ "$RELEASE_COUNT" -eq 1 ]; then
    ONLY_RELEASE_TAG="$release_tag"
  fi
done

if [ "$RELEASE_COUNT" -eq 0 ]; then
  echo "fresh"
elif [ "$RELEASE_COUNT" -eq 1 ] && [ "$ONLY_RELEASE_TAG" = "$CURRENT_TAG" ]; then
  echo "retry"
else
  echo "history"
fi
