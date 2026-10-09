#!/bin/bash

set -euo pipefail

IDENTITY_NAME="Book Sender Release Signing"
PASSWORD_SERVICE="Book Sender Release Signing PKCS12 Password"
REPOSITORY="rckbrcls/book-sender"
CERTIFICATE_OUTPUT="scripts/signing/BookSenderReleaseSigning.cer"
BACKUP_DIRECTORY=""
REPLACE_INCOMPLETE=false

usage() {
  cat << EOF
Usage: bootstrap_release_identity.sh --backup-directory <absolute-path> [--replace-incomplete]

Creates the stable self-signed Book Sender code-signing identity, imports it
into the login Keychain, stores an encrypted PKCS#12 backup outside the
repository, exports the public DER certificate, and configures the required
GitHub Actions secrets.

Options:
  --replace-incomplete  Replace files from an interrupted run only when the
                        signing identity is not present in any local Keychain.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-directory)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --backup-directory."
        exit 1
      fi
      BACKUP_DIRECTORY="$2"
      shift 2
      ;;
    --replace-incomplete)
      REPLACE_INCOMPLETE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ "$BACKUP_DIRECTORY" != /* ]]; then
  echo "The backup directory must be an absolute path."
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This bootstrap script only supports macOS."
  exit 1
fi

if security find-identity -v -p codesigning 2>/dev/null \
  | grep -Fq "\"$IDENTITY_NAME\""; then
  echo "The release signing identity already exists in a local Keychain."
  exit 1
fi

BACKUP_PATH="$BACKUP_DIRECTORY/BookSenderReleaseSigning.p12"
if [ -e "$CERTIFICATE_OUTPUT" ] || [ -e "$BACKUP_PATH" ]; then
  if [ "$REPLACE_INCOMPLETE" != true ]; then
    echo "Signing files already exist without an imported identity."
    echo "Review them, then rerun with --replace-incomplete if appropriate."
    exit 1
  fi
  rm -f "$CERTIFICATE_OUTPUT" "$BACKUP_PATH"
fi

for command_name in gh openssl security; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name"
    exit 1
  fi
done

gh auth status >/dev/null
mkdir -p "$BACKUP_DIRECTORY"
chmod 700 "$BACKUP_DIRECTORY"
mkdir -p "$(dirname "$CERTIFICATE_OUTPUT")"

TEMP_DIRECTORY=$(mktemp -d)
cleanup() {
  rm -f \
    "$TEMP_DIRECTORY/private-key.pem" \
    "$TEMP_DIRECTORY/certificate.pem" \
    "$TEMP_DIRECTORY/release-identity.p12"
  rmdir "$TEMP_DIRECTORY" 2>/dev/null || true
}
trap cleanup EXIT

P12_PASSWORD=$(openssl rand -base64 48 | tr -d '\n')
PRIVATE_KEY="$TEMP_DIRECTORY/private-key.pem"
CERTIFICATE_PEM="$TEMP_DIRECTORY/certificate.pem"
TEMP_P12="$TEMP_DIRECTORY/release-identity.p12"

umask 077
openssl req \
  -x509 \
  -newkey rsa:3072 \
  -sha256 \
  -days 3650 \
  -nodes \
  -subj "/CN=$IDENTITY_NAME/O=Book Sender/OU=Release Signing" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "subjectKeyIdentifier=hash" \
  -keyout "$PRIVATE_KEY" \
  -out "$CERTIFICATE_PEM"

openssl pkcs12 \
  -export \
  -legacy \
  -name "$IDENTITY_NAME" \
  -inkey "$PRIVATE_KEY" \
  -in "$CERTIFICATE_PEM" \
  -passout "pass:$P12_PASSWORD" \
  -out "$TEMP_P12"

openssl x509 \
  -in "$CERTIFICATE_PEM" \
  -outform DER \
  -out "$CERTIFICATE_OUTPUT"
chmod 644 "$CERTIFICATE_OUTPUT"

cp "$TEMP_P12" "$BACKUP_PATH"
chmod 600 "$BACKUP_PATH"

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security add-generic-password \
  -U \
  -a "$USER" \
  -s "$PASSWORD_SERVICE" \
  -w "$P12_PASSWORD" \
  "$LOGIN_KEYCHAIN"

security import "$TEMP_P12" \
  -k "$LOGIN_KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

base64 < "$TEMP_P12" \
  | tr -d '\n' \
  | gh secret set BOOKSENDER_CODESIGN_P12_BASE64 --repo "$REPOSITORY"
printf "%s" "$P12_PASSWORD" \
  | gh secret set BOOKSENDER_CODESIGN_P12_PASSWORD --repo "$REPOSITORY"

CERTIFICATE_SHA1=$(openssl x509 \
  -inform DER \
  -in "$CERTIFICATE_OUTPUT" \
  -noout \
  -fingerprint \
  -sha1 \
  | cut -d= -f2 \
  | tr -d ':')

echo "Release signing identity created."
echo "Public certificate: $CERTIFICATE_OUTPUT"
echo "Encrypted backup: $BACKUP_PATH"
echo "Certificate SHA-1: $CERTIFICATE_SHA1"
