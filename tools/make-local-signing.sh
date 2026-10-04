#!/bin/sh
# Creates a signing certificate that lives only on this Mac, so every build
# of Clippa gets the same signature and macOS keeps the Accessibility
# permission across updates. No Apple account needed.
#
# What it creates, all in one folder you can delete at any time:
#   ~/Library/Application Support/Clippa/Signing/
#     signing.keychain-db   a separate keychain with the certificate and its key
#     keychain-password     the random password of that keychain (readable only by you)
#
# It does not touch your login keychain, your keychain list or any trust
# setting: the certificate is self-signed and only used by build.sh, which
# picks it up automatically. Trade-off: a program running as you could use
# this key to sign itself as Clippa. The same is true of any developer
# certificate kept on a Mac.
#
# Run once:  sh tools/make-local-signing.sh
# Undo:      rm -rf ~/Library/Application\ Support/Clippa/Signing
set -eu

DIR="$HOME/Library/Application Support/Clippa/Signing"
KEYCHAIN="$DIR/signing.keychain-db"
NAME="Clippa Local Signing"

if [ -f "$KEYCHAIN" ]; then
  echo "Already set up: $KEYCHAIN"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A random password for the separate keychain, kept next to it.
PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
umask 077
printf '%s' "$PASSWORD" > "$DIR/keychain-password"

# Self-signed certificate valid for code signing, ten years.
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" \
  -passout "pass:$PASSWORD" 2>/dev/null

# `security create-keychain` adds the new keychain to your keychain list:
# put the list back exactly as it was.
LIST=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
echo "$LIST" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s
security set-keychain-settings "$KEYCHAIN"   # no automatic lock timeout
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo "Created \"$NAME\" in $KEYCHAIN"
echo "Next: sh build.sh --install, then allow Clippa in Accessibility one last time."
