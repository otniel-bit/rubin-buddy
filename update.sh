#!/bin/sh
# Pull the latest version and reinstall. The installer is idempotent and
# preserves an edited lines.txt, so updating is just installing again.
#
# Fetching install.sh fresh each time means the update mechanism itself stays
# current — a fix to the installer reaches everyone on the next update.
set -eu
exec curl -fsSL "https://raw.githubusercontent.com/otniel-bit/rubin-buddy/main/install.sh" | sh
