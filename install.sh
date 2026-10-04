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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Clippa..."
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$TMP"

echo "Building and installing (this takes a minute)..."
sh "$TMP/clippa-$BRANCH/build.sh" --install
