#!/bin/bash
# One-time release-signing setup (free, no Apple Developer account).
#
# Generates ONE stable self-signed code-signing certificate, imports it into your
# login keychain (so local `make build` uses it too), and prints the GitHub
# Actions secrets to add. Because every official release is then signed with the
# SAME identity, macOS keeps users' Accessibility (TCC) grant working across
# updates — no re-granting on every new version.
#
#   bash scripts/release-signing-setup.sh
#
# Then add the two printed secrets to the repo. Re-running is safe: it reuses the
# existing cert if present and just re-exports the .p12 for the secret.
set -euo pipefail
cd "$(dirname "$0")/.."

CN="LizardType Self-Signed"
P12_PASS="${RELEASE_CERT_PASSWORD:-lizardtype}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OUT="build/release-cert.p12"
OPENSSL="$(command -v openssl || echo /opt/homebrew/bin/openssl)"
mkdir -p build

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "▸ generating self-signed code-signing cert ($CN)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

echo "▸ bundling to PKCS#12 (legacy algos for Apple's importer)"
"$OPENSSL" pkcs12 -export -legacy -macalg sha1 \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -out "$OUT" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$P12_PASS"

echo "▸ importing into login keychain (for local builds)"
security import "$OUT" -k "$KEYCHAIN" -P "$P12_PASS" -A || true
security find-identity -p codesigning "$KEYCHAIN" | grep "$CN" || \
  echo "  (not listed by find-identity yet; codesign will still find it)"

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Add these GitHub Actions secrets (repo → Settings → Secrets → Actions):"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "  RELEASE_CERT_PASSWORD = $P12_PASS"
echo
echo "  RELEASE_CERT_P12_BASE64 = (the base64 below, or pipe straight to gh):"
echo
if command -v gh >/dev/null 2>&1; then
  echo "  # one-liner with the GitHub CLI:"
  echo "  base64 < $OUT | gh secret set RELEASE_CERT_P12_BASE64"
  echo "  gh secret set RELEASE_CERT_PASSWORD --body '$P12_PASS'"
  echo
fi
echo "  --- base64 begin ---"
base64 < "$OUT"
echo "  --- base64 end ---"
echo
echo "⚠ Keep $OUT private (it's the signing key). It's under build/ which is"
echo "  git-ignored. Delete it once the secret is set: rip $OUT"
