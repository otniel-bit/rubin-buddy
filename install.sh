#!/bin/sh
# Install (or update) the Rick buddy.
#
#   curl -fsSL https://raw.githubusercontent.com/otniel-bit/rubin-buddy/main/install.sh | sh
#
# This same script is the updater — it's idempotent, preserves an edited
# lines.txt, respects a disabled Start-at-Login, and restarts him when done.
#
# It builds from source on your machine rather than shipping a binary. That's
# deliberate: a downloaded unsigned binary gets quarantined by Gatekeeper and
# needs a right-click-open dance, while something you compiled locally just
# runs. It also means you can read exactly what you're installing.
#
# Everything lives inside main(), invoked on the very last line. Under
# `curl | sh` the shell executes the script AS IT STREAMS — if the connection
# dropped halfway through a top-down script, the downloaded prefix would run
# and the rest never would. With the wrapper, a truncated download dies parsing
# an unterminated function instead of half-installing.

set -eu

main() {

REPO="otniel-bit/rubin-buddy"
BRANCH="main"
DEST="$HOME/.rubin-buddy"
LABEL="co.desklify.rubinbuddy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/rubin-buddy.log"
# Set by the in-app auto-updater: never prompt, never touch a terminal.
AUTO="${RUBIN_AUTO:-}"

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

# Was he installed before, and had the user turned Start at Login off?
WAS_INSTALLED=0
[ -f "$DEST/VERSION" ] && WAS_INSTALLED=1
LOGIN_ENABLED=1
if [ "$WAS_INSTALLED" = 1 ] && [ ! -f "$PLIST" ]; then
    # Updating an install whose LaunchAgent the user removed via the menu:
    # rewriting it here would silently revert their choice.
    LOGIN_ENABLED=0
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

# --- install ----------------------------------------------------------------
#
# Everything goes in by rename, never written over in place. Copying onto a
# *running* executable gets that process killed with SIGKILL "Code Signature
# Invalid": the kernel checks code pages against the binary's signature as it
# pages them in, and the bytes changed underneath it. rename() only swaps the
# directory entry, so a running copy keeps its original inode and stays valid.

mkdir -p "$DEST"

rm -rf "$DEST/.frames.new" "$DEST/.frames.old"
cp -R "$SRC/frames" "$DEST/.frames.new"
# Swap via two renames — the no-frames window is microseconds, not a full copy.
if [ -d "$DEST/frames" ]; then mv "$DEST/frames" "$DEST/.frames.old"; fi
mv "$DEST/.frames.new" "$DEST/frames"
rm -rf "$DEST/.frames.old"

for f in buddy state.sh update.sh hooks.sh uninstall.sh VERSION; do
    [ -e "$SRC/$f" ] || continue
    cp "$SRC/$f" "$DEST/.$f.new"
    case "$f" in *.sh|buddy) chmod +x "$DEST/.$f.new" ;; esac
    mv -f "$DEST/.$f.new" "$DEST/$f"
done

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

# --- start ------------------------------------------------------------------

DOMAIN="gui/$(id -u)"

# Stop the old copy now that the new files are safely in place, and actually
# wait for it to go — pkill returns as soon as the signal is sent.
pkill -x buddy 2>/dev/null || true
i=0
while pgrep -x buddy >/dev/null 2>&1 && [ "$i" -lt 25 ]; do
    sleep 0.2
    i=$((i + 1))
done
pkill -9 -x buddy 2>/dev/null || true

if [ "$LOGIN_ENABLED" = 1 ]; then
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
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
PLISTEOF

    launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        # bootout is asynchronous; bootstrapping too early fails with EINPROGRESS.
        j=0
        while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ "$j" -lt 25 ]; do
            sleep 0.2
            j=$((j + 1))
        done
    fi
    # Only start him ourselves if launchd declined the job — checking "is he
    # running yet?" after a fixed sleep raced launchd and started a second copy.
    if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
        k=0
        while ! pgrep -x buddy >/dev/null 2>&1 && [ "$k" -lt 40 ]; do
            sleep 0.2
            k=$((k + 1))
        done
    else
        # </dev/null matters: without it the background buddy inherits the
        # terminal's stdin and keeps the pty open after the installer exits.
        ( nohup "$DEST/buddy" </dev/null >/dev/null 2>&1 & )
        sleep 1
    fi
else
    say "Start at Login is off — leaving it off."
    ( nohup "$DEST/buddy" </dev/null >/dev/null 2>&1 & )
    sleep 1
fi

if pgrep -x buddy >/dev/null 2>&1; then
    printf '\n  Rick %s is on your screen, bottom-right.\n' "$VERSION"
else
    printf '\n  Installed %s, but he did not start. Try: %s/buddy\n' "$VERSION" "$DEST"
fi

# --- Claude Code ------------------------------------------------------------
# Offer the connection right here, once. This runs under `curl | sh`, where
# stdin is the script itself — so the answer must come from /dev/tty. Headless
# runs (RUBIN_AUTO from the in-app updater, or no controlling terminal) skip
# the prompt entirely; the "Follow Claude Code" menu toggle covers them later.
# Declining is remembered so updates never nag.
if [ -z "$AUTO" ] && [ -d "$HOME/.claude" ] && [ ! -f "$DEST/.hooks-declined" ] \
    && ! grep -qs "rubin-buddy" "$HOME/.claude/settings.json"; then
    if { : < /dev/tty; } 2>/dev/null; then
        printf '\n  Make Rick follow Claude Code — think, work, nod along with it? [Y/n] ' > /dev/tty
        IFS= read -r answer < /dev/tty || answer=""
        case "$answer" in
            [Nn]*)
                touch "$DEST/.hooks-declined"
                say 'Okay. Menu bar -> "Follow Claude Code" if you change your mind.'
                ;;
            *)
                # A hooks failure (unreadable settings.json) shouldn't scuttle
                # an otherwise complete install at the last step.
                sh "$DEST/hooks.sh" \
                    || say "Couldn't wire the hooks — run ~/.rubin-buddy/hooks.sh later."
                ;;
        esac
    fi
fi

cat <<'NEXTEOF'

  Settings live in the menu bar — the small bald silhouette. Size,
  chattiness, "Take a Breath", "Follow Claude Code", and "Bring Him
  Back" if you ever lose him.

  He updates himself when a new version lands (menu bar -> Auto-Update
  to turn that off). To remove him completely:

    ~/.rubin-buddy/uninstall.sh

NEXTEOF

}

main "$@"