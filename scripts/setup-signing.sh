#!/bin/sh
# One-time setup, run by the repository owner on their Mac: creates a code signing identity for
# ponyhub releases and hands it to GitHub Actions as two secrets.
#
# Why: without it, releases are ad-hoc signed, so to macOS every update is a different app. People
# then have to allow Calendars and Accessibility again after each update. With one identity for
# all releases, macOS keeps those permissions, and ponyhub's updater accepts only updates signed
# with it (a release built by anyone else is refused).
#
#   scripts/setup-signing.sh [owner/repo]
#
# Needs openssl (built into macOS) and the GitHub CLI, logged in with admin access to the repo
# (brew install gh && gh auth login). The private key goes only into the repository's secrets;
# pass KEEP=1 to also keep a copy (notchy-release-signing.p12 + its password) in this folder.
set -eu
REPO=${1:-samidun26/dynamic-island-mac}
NAME="ponyhub Release Signing"
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.cnf" <<CNF
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
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -config "$DIR/cert.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
PASSWORD=$(openssl rand -hex 24)
# 3DES/SHA1 packaging: the format macOS's keychain tools import everywhere.
LEGACY=""
openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY="-legacy"
# shellcheck disable=SC2086
openssl pkcs12 -export $LEGACY -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
  -out "$DIR/release.p12" -passout "pass:$PASSWORD"

base64 < "$DIR/release.p12" | tr -d '\n' | gh secret set SIGNING_CERT_P12 --repo "$REPO"
printf %s "$PASSWORD" | gh secret set SIGNING_CERT_PASSWORD --repo "$REPO"
if [ "${KEEP:-0}" = 1 ]; then
  cp "$DIR/release.p12" notchy-release-signing.p12
  printf '%s\n' "$PASSWORD" > notchy-release-signing.password
  echo "Kept notchy-release-signing.p12 and .password here: store them somewhere safe, never in git."
fi
echo "Done. The next release of $REPO is signed as \"$NAME\"."
echo "Copies installed before this keep updating; from then on only releases with this identity are accepted."
