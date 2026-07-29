#!/bin/sh
# Tell the buddy what to play. Called by the Claude Code hooks in settings.json.
#   state.sh think
#
# Writes to a temp file and renames, so the buddy never reads a half-written
# state. Silent and exit-0 no matter what — a desktop pet must never be the
# reason a hook fails.
set -u
dir="${RUBIN_STATE_DIR:-$HOME/.rubin-buddy}"
mkdir -p "$dir" 2>/dev/null || exit 0
printf '%s' "${1:-idle}" > "$dir/state.tmp" 2>/dev/null || exit 0
mv -f "$dir/state.tmp" "$dir/state" 2>/dev/null || exit 0
exit 0
