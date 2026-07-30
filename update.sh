#!/bin/sh
# Pull the latest version and reinstall. The installer is idempotent and
# preserves an edited lines.txt, so updating is just installing again.
#
# Downloaded to a file first, never piped into sh: piping executes the script
# as it streams, so a dropped connection would run a truncated prefix of it.
# Fetching fresh each time also means installer fixes reach everyone.
set -eu
tmp="$(mktemp /tmp/rubin-buddy-install.XXXXXX)"
trap 'rm -f "$tmp"' EXIT INT TERM
curl -fsSL "https://raw.githubusercontent.com/otniel-bit/rubin-buddy/main/install.sh" -o "$tmp" \
    || { echo "  Download failed — check your connection and try again." >&2; exit 1; }
sh "$tmp"
