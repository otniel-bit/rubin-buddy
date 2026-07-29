#!/bin/sh
# Install (or update) the Rick buddy.
#
#   curl -fsSL https://raw.githubusercontent.com/otniel-bit/rubin-buddy/main/install.sh | sh
#
# This same script is the updater — it's idempotent, preserves an edited
# lines.txt, and restarts him when it's done.
#
# It builds from source on your machine rather than shipping a binary. That's
# deliberate: a downloaded unsigned binary gets quarantined by Gatekeeper and
# needs a right-click-open dance, while something you compiled locally just
# runs. It also means you can read exactly what you're installing.

set -eu

REPO="otniel-bit/rubin-buddy"
BRANCH="main"
DEST="$HOME/.rubin-buddy"
LABEL="co.desklify.rubinbuddy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/rubin-buddy.log"

say() { printf '  %s\n' "$*"; }
die() { printf '\n  %s\n\n' "$*" >&2; exit 1; }

printf '\n  Rick buddy\n\n'

# --- requirements -----------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "macOS only."

if ! command -v swiftc >/dev/null 2>&1; then
    die "Needs the Xcode Command Line Tools. Install them with:

    xcode-select --install

  then run this again."
fi

# --- fetch ------------------------------------------------------------------

TMP="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$TMP'" EXIT INT TERM

say "Downloading $REPO..."
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" \
    | tar xz -C "$TMP" || die "Download failed. Is the repo public and the branch '$BRANCH' correct?"

SRC="$TMP/$(ls "$TMP" | head -1)"
for required in Buddy.swift lines.txt VERSION frames/manifest.json; do
    [ -e "$SRC/$required" ] || die "Download looks incomplete — no $required."
done

VERSION="$(tr -d ' \n' < "$SRC/VERSION")"

# --- build ------------------------------------------------------------------

say "Building $VERSION (this takes a few seconds)..."
( cd "$SRC" && swiftc -O Buddy.swift -o buddy ) || die "Build failed."

# Only stop the running copy once we know we have a working replacement.
pkill -x buddy 2>/dev/null || true

# --- install ----------------------------------------------------------------

mkdir -p "$DEST"
rm -rf "$DEST/frames"
cp -R "$SRC/frames" "$DEST/frames"
for f in buddy state.sh update.sh hooks.sh VERSION; do
    [ -e "$SRC/$f" ] && cp "$SRC/$f" "$DEST/$f"
done
chmod +x "$DEST/buddy" "$DEST"/*.sh 2>/dev/null || true

# lines.txt is meant to be edited, so don't clobber a customised one. We can
# tell the difference by remembering the hash of whatever we shipped last time.
new_sha="$(shasum -a 256 "$SRC/lines.txt" | cut -d' ' -f1)"
if [ ! -f "$DEST/lines.txt" ]; then
    cp "$SRC/lines.txt" "$DEST/lines.txt"
elif [ -f "$DEST/.shipped-lines.sha" ] &&
     [ "$(shasum -a 256 "$DEST/lines.txt" | cut -d' ' -f1)" = "$(cat "$DEST/.shipped-lines.sha")" ]; then
    cp "$SRC/lines.txt" "$DEST/lines.txt"   # untouched since last install
elif [ "$(shasum -a 256 "$DEST/lines.txt" | cut -d' ' -f1)" != "$new_sha" ]; then
    cp "$SRC/lines.txt" "$DEST/lines.txt.new"
    say "Kept your edited lines.txt — the new default is in lines.txt.new"
fi
printf '%s' "$new_sha" > "$DEST/.shipped-lines.sha"

# --- start at login ---------------------------------------------------------

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/buddy</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
PLISTEOF

DOMAIN="gui/$(id -u)"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
fi
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null ||
    ( nohup "$DEST/buddy" >/dev/null 2>&1 & )

sleep 1
if pgrep -x buddy >/dev/null 2>&1; then
    printf '\n  Rick %s is on your screen, bottom-right.\n' "$VERSION"
else
    printf '\n  Installed %s, but he did not start. Try: %s/buddy\n' "$VERSION" "$DEST"
fi

cat <<'NEXTEOF'

  Look for the bald silhouette in your menu bar for settings —
  size, chattiness, "Bring Him Back" if you ever lose him.

  To make him react to Claude Code (thinking, working, nodding):

    ~/.rubin-buddy/hooks.sh

  He updates himself when a new version lands. Turn that off in the
  menu bar under Auto-Update.

NEXTEOF
