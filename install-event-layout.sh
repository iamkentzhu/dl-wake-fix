#!/bin/bash
# Install one LaunchAgent for wake recovery and the signed window worker.
set -euo pipefail

FULLSCREEN=false
case "${1:-}" in
  "") ;;
  --restore-full-screen) FULLSCREEN=true ;;
  *) printf 'Usage: bash %s [--restore-full-screen]\n' "$0" >&2; exit 2 ;;
esac

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HOME/Library/Scripts/dl-wake-fix"
SUPPORT="$ROOT/event-layout"
WINDOW_APP="$SUPPORT/FlipGo Window Layout.app"
RECOVERY="$SUPPORT/.DisplayRecovery.app"
LABEL=com.kent.dl-wake-fix
DOMAIN="gui/$(/usr/bin/id -u)"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
BACKUP="$SUPPORT/previous-agent.plist"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dl-wake-layout.XXXXXXXX")"
trap '[[ ! -e "$BUILD/agent.plist" ]] || /bin/rm -f "$BUILD/agent.plist"' EXIT

/bin/mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$ROOT"
if [[ ! -d "$SUPPORT" ]]; then /bin/mkdir -m 700 "$SUPPORT"; fi
if [[ ! -e "$WINDOW_APP" ]]; then
  APP="$BUILD/FlipGo Window Layout.app"
  /bin/mkdir -p "$APP/Contents/MacOS"
  /usr/bin/install -m 644 "$SRC/launchd/LayoutEvents-Info.plist" "$APP/Contents/Info.plist"
  /usr/bin/xcrun swiftc -O -warnings-as-errors "$SRC/sources/layout-events.swift" -o "$APP/Contents/MacOS/layout-events"
  /usr/bin/codesign --sign - "$APP"
  /usr/bin/codesign --verify --strict "$APP"
  /usr/bin/ditto "$APP" "$WINDOW_APP"
fi
# Do not rebuild or re-sign an existing authorized binary on upgrades.
/usr/bin/codesign --verify --strict "$WINDOW_APP"
"$WINDOW_APP/Contents/MacOS/layout-events" --self-test

APP="$BUILD/DisplayRecovery.app"
/bin/mkdir -p "$APP/Contents/MacOS"
/usr/bin/install -m 644 "$SRC/launchd/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/xcrun swiftc -O -warnings-as-errors "$SRC/sources/main.swift" -o "$APP/Contents/MacOS/dl-wake-fix"

/usr/bin/install -m 644 "$SRC/launchd/EventLayoutLaunchAgent.plist" "$BUILD/agent.plist"
/usr/bin/plutil -replace ProgramArguments.0 -string "$RECOVERY/Contents/MacOS/dl-wake-fix" "$BUILD/agent.plist"
if $FULLSCREEN; then
  /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:2 string --restore-full-screen' "$BUILD/agent.plist"
fi
/usr/bin/plutil -lint "$BUILD/agent.plist"
if [[ -f "$AGENT" && ! -e "$BACKUP" ]]; then /usr/bin/install -m 600 "$AGENT" "$BACKUP"; fi
if /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootout "$DOMAIN/$LABEL"
fi
/usr/bin/ditto "$APP" "$RECOVERY"
/usr/bin/install -m 644 "$BUILD/agent.plist" "$AGENT"
if ! /bin/launchctl bootstrap "$DOMAIN" "$AGENT"; then
  printf 'Could not start the integrated service. Previous plist, if present: %s\n' "$BACKUP" >&2
  if [[ -f "$BACKUP" ]]; then
    /usr/bin/install -m 644 "$BACKUP" "$AGENT"
    /bin/launchctl bootstrap "$DOMAIN" "$AGENT"
  fi
  exit 1
fi
printf 'Service: %s\nAccessibility app: %s\n' "$LABEL" "$WINDOW_APP"
printf 'Recovery log: %s\nWindow log: %s\n' "$HOME/Library/Logs/dl-wake-fix.log" "$SUPPORT/layout-events.log"
