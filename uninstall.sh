#!/bin/sh
# Remove Rick completely: the app, the launch agent, the log, his hooks in
# ~/.claude/settings.json (only his — everything else in there is preserved),
# and his saved preferences. Nothing else on the machine was ever touched.
set -u

DEST="$HOME/.rubin-buddy"
LABEL="co.desklify.rubinbuddy"

printf '\n  Removing Rick...\n'

# His Claude Code hooks, if wired (kept for last-run before we delete hooks.sh).
if grep -qs "rubin-buddy" "$HOME/.claude/settings.json" 2>/dev/null \
    && [ -x "$DEST/hooks.sh" ]; then
    sh "$DEST/hooks.sh" --remove >/dev/null 2>&1 \
        && printf '  Unwired his Claude Code hooks.\n' \
        || printf '  Could not unwire hooks automatically; see README.\n'
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x buddy 2>/dev/null
sleep 1
pkill -9 -x buddy 2>/dev/null

rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/Library/Logs/rubin-buddy.log"
rm -rf "$DEST"
defaults delete buddy >/dev/null 2>&1

printf '  Done. He was never precious about it.\n\n'
