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
# Per-process temp name: parallel Claude Code sessions all run these hooks, and
# a shared temp path let concurrent writers interleave and lose events.
tmp="$dir/state.tmp.$$"
printf '%s' "${1:-idle}" > "$tmp" 2>/dev/null || exit 0
mv -f "$tmp" "$dir/state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
exit 0
