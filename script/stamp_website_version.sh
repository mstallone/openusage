#!/usr/bin/env bash
# Stamps the landing page's dashboard mock with a release version.
#
# The mock's footer shows "Runway X.Y.Z". The source file carries whatever version was current
# when it was last edited; the site is only ever published by the update-feed workflows, so each
# of them stamps the real version at assemble time and the page never drifts.
#
# Usage: stamp_website_version.sh <index.html path> <MAJOR.MINOR.PATCH>
set -euo pipefail

html="$1"
version="$2"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "stamp_website_version: '$version' is not a plain MAJOR.MINOR.PATCH version" >&2
  exit 1
}
grep -qE 'Runway [0-9]+\.[0-9]+\.[0-9]+' "$html" || {
  echo "stamp_website_version: no 'Runway X.Y.Z' text found in $html — did the mock's footer change?" >&2
  exit 1
}

tmp="$html.tmp"
sed -E "s/Runway [0-9]+\.[0-9]+\.[0-9]+/Runway $version/g" "$html" > "$tmp"
mv "$tmp" "$html"

grep -q "Runway $version" "$html" || {
  echo "stamp_website_version: stamping $html with $version failed" >&2
  exit 1
}
echo "Stamped $html with Runway $version"
