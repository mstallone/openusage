#!/bin/bash
# Sets the RSS channel title without touching release item titles or enclosure history.
set -euo pipefail

appcast_path="${1:?appcast path required}"
channel_title="${2:?channel title required}"

python3 - "$appcast_path" "$channel_title" << 'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
title = sys.argv[2]
contents = path.read_text()
updated, replacements = re.subn(
    r"(<channel>\s*<title>)[^<]*(</title>)",
    lambda match: f"{match.group(1)}{title}{match.group(2)}",
    contents,
    count=1,
)
if replacements != 1:
    raise SystemExit(f"{path}: expected exactly one RSS channel title")
path.write_text(updated)
PY
