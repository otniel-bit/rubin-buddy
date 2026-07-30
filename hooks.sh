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

def is_ours(entry):
    """One hook entry (not a whole group) that we wrote. Matched by the exact
    trailing signature our writer produces — a plain substring test would also
    claim a user's own hook that merely mentions rubin-buddy."""
    if not isinstance(entry, dict):
        return False
    cmd = str(entry.get("command", "")).rstrip()
    return cmd.endswith(f"# {marker}") and "state.sh" in cmd

def without_ours(groups):
    """Strip OUR entries; preserve everyone else's, even if they share a group.
    Matching per-entry matters: a user's own hook that merely mentions
    rubin-buddy in a shared group must never be collateral damage."""
    kept_groups = []
    removed = 0
    for group in groups:
        if not isinstance(group, dict):
            kept_groups.append(group)
            continue
        entries = group.get("hooks", [])
        theirs = [e for e in entries if not is_ours(e)]
        removed += len(entries) - len(theirs)
        if theirs or not entries:
            kept = dict(group)
            kept["hooks"] = theirs
            kept_groups.append(kept)
    return kept_groups, removed

for event, state in MAPPING.items():
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        print(f"  skipped {event}: unexpected shape")
        continue
    kept, removed = without_ours(groups)
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

# One backup of the pre-Rick state, written only the first time we ever touch
# this file — the scariest thing a pet can do is rewrite your agent config.
backup = settings_path + ".rubin-bak"
if changed and not os.path.exists(backup):
    import shutil
    shutil.copy2(settings_path, backup)
    print(f"  (original backed up to {backup})")

tmp = settings_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_path)

verb = "Removed" if mode == "--remove" else "Wired"
print(f"  {verb} {changed} hook event(s) in {settings_path}")
PY

if [ "$MODE" = "--remove" ]; then
    # Removing by hand is also a "no" — future installers must not re-ask.
    touch "$SELF_DIR/.hooks-declined" 2>/dev/null || true
    printf '\n  Rick no longer follows Claude Code.\n\n'
else
    rm -f "$SELF_DIR/.hooks-declined" 2>/dev/null || true
    printf '\n  Rick now follows Claude Code. Open a new session to see it.\n\n'
fi
