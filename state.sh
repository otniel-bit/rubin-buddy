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
word="${1:-idle}"
# "say" borrows his voice: `state.sh say Deploy is green.` puts the rest of the
# arguments in his speech bubble, once. The buddy caps the length.
if [ "$word" = "say" ] && [ "$#" -gt 1 ]; then
    shift
    word="say $*"
fi
# Per-process temp name: parallel Claude Code sessions all run these hooks, and
# a shared temp path let concurrent writers interleave and lose events.
tmp="$dir/state.tmp.$$"
printf '%s' "$word" > "$tmp" 2>/dev/null || exit 0
mv -f "$tmp" "$dir/state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
exit 0
