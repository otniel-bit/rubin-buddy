#!/bin/sh
# Wire Rick to Claude Code, so he reacts to what it's doing.
#
#   ~/.rubin-buddy/hooks.sh          add the hooks
#   ~/.rubin-buddy/hooks.sh --remove take them out again
#
# Merges into ~/.claude/settings.json, preserving everything already in there.
# Idempotent — running it twice doesn't duplicate anything.

set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
MODE="${1:-add}"

command -v python3 >/dev/null 2>&1 || {
    echo "Needs python3 (it ships with the Xcode Command Line Tools)." >&2
    exit 1
}

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"

python3 - "$SETTINGS" "$SELF_DIR/state.sh" "$MODE" <<'PY'
import json, sys, os

settings_path, state_sh, mode = sys.argv[1], sys.argv[2], sys.argv[3]

# What Rick does for each Claude Code event.
MAPPING = {
    "SessionStart":     "idle",
    "UserPromptSubmit": "think",
    "PreToolUse":       "stroke",
    "Notification":     "glasses",
    "Stop":             "nod",
    "SessionEnd":       "idle",
}

try:
    with open(settings_path) as f:
        text = f.read().strip() or "{}"
    settings = json.loads(text)
except (OSError, ValueError) as exc:
    sys.exit(f"Could not read {settings_path}: {exc}")

if not isinstance(settings, dict):
    sys.exit(f"{settings_path} is not a JSON object; leaving it alone.")

hooks = settings.setdefault("hooks", {})
marker = "rubin-buddy"          # how we recognise our own entries later
changed = 0

def is_ours(group):
    return any(
        marker in str(h.get("command", "")) or h.get("_rubinBuddy")
        for h in group.get("hooks", [])
        if isinstance(h, dict)
    )

for event, state in MAPPING.items():
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        print(f"  skipped {event}: unexpected shape")
        continue
    # Drop any entry of ours from a previous run, keep everyone else's.
    kept = [g for g in groups if not (isinstance(g, dict) and is_ours(g))]
    if mode != "--remove":
        kept.append({
            "hooks": [{
                "type": "command",
                # async so Rick is never the reason a hook is slow, and the
                # script exits 0 unconditionally so he's never why one fails.
                "command": f'"{state_sh}" {state}  # {marker}',
                "async": True,
            }]
        })
    if kept != groups:
        changed += 1
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)

if not hooks:
    settings.pop("hooks", None)

tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_path)

verb = "Removed" if mode == "--remove" else "Wired"
print(f"  {verb} {changed} hook event(s) in {settings_path}")
PY

if [ "$MODE" = "--remove" ]; then
    printf '\n  Rick no longer follows Claude Code.\n\n'
else
    printf '\n  Rick now follows Claude Code. Open a new session to see it.\n\n'
fi
