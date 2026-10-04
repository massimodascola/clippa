#!/bin/sh
# Builds Clippa.app into build/.
# Usage:  sh build.sh            build only
#         sh build.sh --install  build, copy to /Applications and launch
#
# Signing: by default the app gets an ad hoc signature, enough to run on the
# Mac that built it. macOS then ties the Accessibility permission to that
# exact build, so after an update you allow Clippa again. To keep the
# permission across updates, sign with a stable identity:
#   CLIPPA_SIGN_IDENTITY="My Certificate" sh build.sh --install
# (see "Keeping permissions across updates" in the README).
set -eu
cd "$(dirname "$0")"

# CLIPPA_SWIFT_FLAGS passes extra options to SwiftPM (Homebrew uses
# --disable-sandbox, since it already builds inside its own sandbox).
FLAGS="${CLIPPA_SWIFT_FLAGS:-}"
# shellcheck disable=SC2086
swift build -c release $FLAGS --product Clippa
# shellcheck disable=SC2086
swift build -c release $FLAGS --product clippa-mcp
# shellcheck disable=SC2086
BIN=$(swift build -c release $FLAGS --show-bin-path)

APP=build/Clippa.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Clippa" "$APP/Contents/MacOS/Clippa"
cp "$BIN/clippa-mcp" "$APP/Contents/MacOS/clippa-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Clippa.icns "$APP/Contents/Resources/Clippa.icns"
cp -R Resources/en.lproj Resources/it.lproj "$APP/Contents/Resources/"

IDENTITY="${CLIPPA_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier com.massimodascola.clippa.mcp "$APP/Contents/MacOS/clippa-mcp"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built: $APP"

case "${1:-}" in
  --install)
    pkill -x Clippa 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Clippa.app
    cp -R "$APP" /Applications/
    open /Applications/Clippa.app
    echo "Installed in /Applications and launched."
    ;;
esac
