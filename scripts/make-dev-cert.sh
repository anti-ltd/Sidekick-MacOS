#!/usr/bin/env bash
# Generate a stable "Sidekick Dev" code-signing identity in the user's
# login keychain so macOS keeps TCC grants (Accessibility, Screen
# Recording, Local Network) alive across rebuilds. Ad-hoc signing
# regenerates the cdhash every build and TCC re-prompts every time.
#
# Mirrors the cert previously scripted for "FileDen Dev" and "Clonk Dev".
# Idempotent — if the cert already exists, exits cleanly.
#
# Properties of the cert:
#   • RSA-2048 / SHA-256, self-signed
#   • basicConstraints critical CA:FALSE
#   • keyUsage critical digitalSignature
#   • extendedKeyUsage critical codeSigning
#   • Imported with -T /usr/bin/codesign so codesign can use the key
#     without a Keychain Access prompt
#
# `security find-identity -v -p codesigning` won't list it (untrusted
# self-signed → CSSMERR_TP_NOT_TRUSTED) but `codesign --sign "Sidekick
# Dev"` still works. That's expected.
set -euo pipefail

CN="Sidekick Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$CN" >/dev/null 2>&1; then
    echo "✓ '$CN' already exists in keychain. Nothing to do."
    exit 0
fi

CONF="$TMP/openssl.cnf"
cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3

[ dn ]
CN = $CN

[ v3 ]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
EOF

# 1) Self-signed cert + key.
openssl req \
    -x509 -newkey rsa:2048 -sha256 -nodes \
    -days 3650 \
    -keyout "$TMP/key.pem" \
    -out "$TMP/cert.pem" \
    -config "$CONF" >/dev/null 2>&1

# 2) Bundle into PKCS#12. macOS `security` rejects LibreSSL's empty-
#    password p12 ("MAC verification failed"), so set a real password
#    and use the legacy PBE algorithms.
PASS="sidekick"
openssl pkcs12 -export \
    -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" \
    -name "$CN" \
    -out "$TMP/cert.p12" \
    -passout "pass:$PASS" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES >/dev/null 2>&1

# 3) Import into the login keychain, authorising /usr/bin/codesign to use
#    the key with no further prompts.
security import "$TMP/cert.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" \
    -T /usr/bin/codesign

echo "✓ Created '$CN' in login keychain."
echo "  Next \`make run\` will sign with it; the first launch after the"
echo "  switch off ad-hoc will re-prompt for Accessibility / Screen"
echo "  Recording once, then sticks across rebuilds."
