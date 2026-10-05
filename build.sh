#!/bin/sh
# Builds Clippa.app into build/.
# Usage:  sh build.sh            build only
#         sh build.sh --install  build, copy to /Applications and launch
#
# Signing: by default the app gets an ad hoc signature, enough to run on the
# Mac that built it. macOS then ties the Accessibility permission to that
# exact build, so after an update you allow Clippa again. To keep the
# permission across updates, give every build the same signature:
#   sh tools/make-local-signing.sh      once, no Apple account needed
# or sign with a certificate of your own:
#   CLIPPA_SIGN_IDENTITY="Apple Development" sh build.sh --install
# (see "Keeping permissions across updates" in the README).
set -eu
cd "$(dirname "$0")"

# The Swift compiler is called directly, module by module, without Swift
# Package Manager: it builds the same code as Package.swift (which stays for
# development and `swift test`), and works even where SwiftPM's own files are
# broken, e.g. after a half-finished Command Line Tools update.
OBJ=build/obj
APP=build/Clippa.app
rm -rf "$OBJ" "$APP"
mkdir -p "$OBJ" "$APP/Contents/MacOS" "$APP/Contents/Resources"

TARGET="$(uname -m)-apple-macos14.0"

# Pick an SDK this toolchain can really build SwiftUI code with. In the
# macOS 27 SDK @State is a macro, and Apple's Command Line Tools (without
# Xcode) lack its plugin; they also ship the previous SDK, which works, and
# Clippa needs nothing newer.
cat > "$OBJ/probe.swift" <<'SWIFT'
import SwiftUI
struct Probe: View {
    @State private var value = 0
    var body: some View { Text("\(value)") }
}
SWIFT
usable() {
  xcrun swiftc -typecheck -target "$TARGET" -sdk "$1" -module-cache-path "$OBJ/module-cache" \
    "$OBJ/probe.swift" >/dev/null 2>&1
}
SDK=$(xcrun --show-sdk-path)
if ! usable "$SDK"; then
  FOUND=""
  for candidate in $(ls -d "$(dirname "$SDK")"/MacOSX[0-9]*.sdk 2>/dev/null | sort -r); do
    if [ "$candidate" != "$SDK" ] && usable "$candidate"; then
      FOUND="$candidate"
      break
    fi
  done
  if [ -z "$FOUND" ]; then
    echo "These developer tools cannot build SwiftUI apps with $(basename "$SDK")." >&2
    echo "Install Xcode (free, from the App Store), or update the Command Line Tools in" >&2
    echo "System Settings > General > Software Update, then run this again." >&2
    exit 1
  fi
  echo "Using $(basename "$FOUND"): $(basename "$SDK") needs Xcode to build SwiftUI apps."
  SDK="$FOUND"
fi
swiftc() {
  xcrun swiftc -O -wmo -swift-version 5 -target "$TARGET" -sdk "$SDK" \
    -module-cache-path "$OBJ/module-cache" -I "$OBJ" -L "$OBJ" "$@"
}
# A static library and its module interface, for each library target.
library() {
  name=$1
  shift
  swiftc -parse-as-library -emit-library -static -module-name "$name" \
    -emit-module -emit-module-path "$OBJ/$name.swiftmodule" -o "$OBJ/lib$name.a" "$@"
}

echo "Compiling with $(xcrun swiftc --version 2>/dev/null | head -n 1)"
library ClippaCore Sources/ClippaCore/*.swift
library ClippaPasteboard Sources/ClippaPasteboard/*.swift
library ClippaMCP Sources/ClippaMCP/*.swift
swiftc -module-name Clippa -lClippaPasteboard -lClippaCore \
  Sources/Clippa/*.swift -o "$APP/Contents/MacOS/Clippa"
swiftc -module-name clippa_mcp -lClippaMCP -lClippaPasteboard -lClippaCore \
  Sources/clippa-mcp/main.swift -o "$APP/Contents/MacOS/clippa-mcp"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Clippa.icns "$APP/Contents/Resources/Clippa.icns"
cp -R Resources/en.lproj Resources/it.lproj "$APP/Contents/Resources/"

IDENTITY="${CLIPPA_SIGN_IDENTITY:--}"
KEYCHAIN_ARGS=""
SIGNING="$HOME/Library/Application Support/Clippa/Signing"
if [ -z "${CLIPPA_SIGN_IDENTITY:-}" ] && [ -f "$SIGNING/signing.keychain-db" ]; then
  # The certificate made by tools/make-local-signing.sh.
  security unlock-keychain -p "$(cat "$SIGNING/keychain-password")" "$SIGNING/signing.keychain-db"
  IDENTITY="Clippa Local Signing"
  KEYCHAIN_ARGS="yes"
fi
sign() {
  if [ -n "$KEYCHAIN_ARGS" ]; then
    codesign --force --keychain "$SIGNING/signing.keychain-db" --sign "$IDENTITY" "$@"
  else
    codesign --force --sign "$IDENTITY" "$@"
  fi
}
sign --identifier com.massimodascola.clippa.mcp "$APP/Contents/MacOS/clippa-mcp"
sign "$APP"
echo "Built: $APP (signed: $([ "$IDENTITY" = "-" ] && echo "ad hoc" || echo "$IDENTITY"))"

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
