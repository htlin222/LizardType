#!/bin/bash
# One-time: create a stable self-signed code-signing identity so macOS TCC
# (Accessibility / Input Monitoring) grants persist across rebuilds.
set -euo pipefail

CN="LizardType Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/opt/homebrew/bin/openssl

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CN"; then
  echo "✓ identity already present: $CN"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "▸ generating self-signed code-signing cert"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

echo "▸ bundling to PKCS#12 (legacy algos for Apple's importer)"
"$OPENSSL" pkcs12 -export -legacy -macalg sha1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:lizardtype

echo "▸ importing into login keychain (allow all tools to use it, no prompts)"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P lizardtype -A

echo "▸ done. identities for codesigning:"
security find-identity -p codesigning "$KEYCHAIN" | grep "$CN" || echo "  (not listed by -v; will test codesign next)"
