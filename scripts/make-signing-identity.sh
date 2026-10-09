#!/usr/bin/env bash
# Creates a self-signed code-signing identity in a project-local keychain
# (.signing/junction.keychain-db, gitignored). Signing every build with the same
# identity means macOS keeps Junction's Accessibility permission across rebuilds;
# with ad-hoc signing, each rebuild looks like a new app.
#
# The keychain is separate from the login keychain and is not added to the
# keychain search list. Its password is not a secret: it only guards this
# throwaway signing key.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
dir="$repo/.signing"
keychain="$dir/junction.keychain-db"
password="junction"
name="Junction Local Signing"

if [[ -f "$keychain" ]]; then
  echo "Signing keychain already exists: $keychain"
  exit 0
fi

mkdir -p "$dir"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -out "$tmp/id.p12" -passout "pass:$password" -name "$name"

security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"   # no auto-lock timeout
security unlock-keychain -p "$password" "$keychain"
security import "$tmp/id.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign
# Let codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null

echo "Created $keychain"
