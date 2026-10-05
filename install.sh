#!/bin/sh
# Installs (or updates) Clippa with a single command:
#
#   curl -fsSL https://raw.githubusercontent.com/massimodascola/clippa/main/install.sh | sh
#
# Downloads the source from GitHub, builds it on this Mac with Apple's
# developer tools and copies the app to /Applications. Built locally, the app
# carries no quarantine flag, so Gatekeeper shows no warning.
set -eu

REPO="massimodascola/clippa"
BRANCH="${CLIPPA_BRANCH:-main}"

fail() {
  printf '%s\n' "$@" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "Clippa runs on macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "Clippa needs macOS 14 Sonoma or later."

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  fail "Apple's developer tools are missing. Install them with:" \
       "" \
       "  xcode-select --install" \
       "" \
       "then run this command again."
fi

# Swift 5.9 (Xcode 15 or its Command Line Tools) or later is needed.
SWIFT_VERSION=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
SWIFT_MAJOR=$(echo "${SWIFT_VERSION:-0.0}" | cut -d. -f1)
SWIFT_MINOR=$(echo "${SWIFT_VERSION:-0.0}" | cut -d. -f2)
if [ "$SWIFT_MAJOR" -lt 5 ] || { [ "$SWIFT_MAJOR" -eq 5 ] && [ "$SWIFT_MINOR" -lt 9 ]; }; then
  fail "Clippa needs Swift 5.9 or later; this Mac has Swift ${SWIFT_VERSION:-unknown}." \
       "Update Apple's developer tools in System Settings > General > Software Update" \
       "(look for Command Line Tools), then run this command again."
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Clippa..."
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$TMP"

echo "Building and installing with Swift $SWIFT_VERSION (this takes a minute)..."
if ! sh "$TMP/clippa-$BRANCH/build.sh" --install; then
  fail "" "The build failed (Swift $SWIFT_VERSION, macOS $(sw_vers -productVersion))." \
       "Updating Apple's developer tools often fixes it: System Settings > General >" \
       "Software Update, look for Command Line Tools, then run this command again." \
       "If it still fails, please open an issue with the messages above:" \
       "https://github.com/$REPO/issues"
fi
