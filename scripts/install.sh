#!/bin/bash

set -euo pipefail

APP_DISPLAY_NAME="Book Sender"
APP_BUNDLE_NAME="BookSender.app"
BUNDLE_IDENTIFIER="com.rckbrcls.BookSender"
SIGNING_CERTIFICATE_SHA1="51F0C83093408095C09F3CF5359EB7C83B7F6B38"
PINNED_DESIGNATED_REQUIREMENT='certificate root = H"51f0c83093408095c09f3cf5359eb7c83b7f6b38" and identifier "com.rckbrcls.BookSender"'
ASSET_PREFIX="BookSender-macos-universal-v"
REPO="rckbrcls/book-sender"
GITHUB_API="https://api.github.com/repos/${REPO}/releases"
SIGNING_CERTIFICATE_URL="https://rckbrcls.github.io/book-sender/book-sender/BookSenderReleaseSigning.cer"

ARCHIVE_OVERRIDE="${BOOKSENDER_INSTALLER_ARCHIVE_PATH:-}"
CERTIFICATE_OVERRIDE="${BOOKSENDER_INSTALLER_CERTIFICATE_PATH:-}"
KEYCHAIN_OVERRIDE="${BOOKSENDER_INSTALLER_KEYCHAIN_PATH:-}"
TARGET_DIRECTORY_OVERRIDE="${BOOKSENDER_INSTALLER_TARGET_DIRECTORY:-}"
CERTIFICATE_REGISTRATION_ACCEPTED="${BOOKSENDER_INSTALLER_ACCEPT_CERTIFICATE_REGISTRATION:-0}"

usage() {
  cat << EOF
Usage: install.sh [--version <version>]

Options:
  --version <version>  Install a specific version (for example: 0.2.0)
  -h, --help           Show this help
EOF
}

VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --version."
        exit 1
      fi
      VERSION="${2#v}"
      shift 2
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

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer only supports macOS."
  exit 1
fi

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ -n "$ARCHIVE_OVERRIDE" ]; then
  if [[ "$ARCHIVE_OVERRIDE" != /* ]] || [ ! -f "$ARCHIVE_OVERRIDE" ]; then
    echo "The archive override must reference an absolute existing ZIP."
    exit 1
  fi
  ZIP_PATH="$ARCHIVE_OVERRIDE"
  ASSET_NAME=$(basename "$ZIP_PATH")
else
  if [ -n "$VERSION" ]; then
    RELEASE_URL="${GITHUB_API}/tags/v${VERSION}"
  else
    RELEASE_URL="${GITHUB_API}/latest"
  fi

  RELEASE_JSON=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$RELEASE_URL")

  ASSET_JSON=$(printf "%s" "$RELEASE_JSON" | python3 -c '
import json
import sys

prefix = sys.argv[1]
data = json.load(sys.stdin)
matches = [
    asset
    for asset in data.get("assets", [])
    if asset.get("name", "").startswith(prefix)
    and asset.get("name", "").endswith(".zip")
]

if len(matches) != 1:
    print(
        f"ERROR: Expected one Book Sender universal ZIP, found {len(matches)}.",
        file=sys.stderr,
    )
    sys.exit(1)

asset = matches[0]
digest = asset.get("digest", "")
if not digest.startswith("sha256:"):
    print("ERROR: Release asset is missing its SHA-256 digest.", file=sys.stderr)
    sys.exit(1)

print(json.dumps({
    "name": asset["name"],
    "url": asset["browser_download_url"],
    "size": asset["size"],
    "digest": digest,
}))
' "$ASSET_PREFIX")

  ASSET_NAME=$(printf "%s" "$ASSET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
  ASSET_URL=$(printf "%s" "$ASSET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
  ASSET_SIZE=$(printf "%s" "$ASSET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["size"])')
  ASSET_DIGEST=$(printf "%s" "$ASSET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')
  ZIP_PATH="$TMP_DIR/$ASSET_NAME"

  echo "Downloading $ASSET_NAME..."
  curl -fL "$ASSET_URL" -o "$ZIP_PATH"

  DOWNLOADED_SIZE=$(stat -f%z "$ZIP_PATH")
  if [ "$DOWNLOADED_SIZE" -ne "$ASSET_SIZE" ]; then
    echo "Downloaded file size mismatch (expected $ASSET_SIZE, got $DOWNLOADED_SIZE)."
    exit 1
  fi

  EXPECTED_SHA256="${ASSET_DIGEST#sha256:}"
  DOWNLOADED_SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
  if [ "$DOWNLOADED_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "Downloaded file digest does not match the GitHub Release asset."
    exit 1
  fi
fi

if [ -n "$CERTIFICATE_OVERRIDE" ]; then
  if [[ "$CERTIFICATE_OVERRIDE" != /* ]] || [ ! -f "$CERTIFICATE_OVERRIDE" ]; then
    echo "The certificate override must reference an absolute existing DER certificate."
    exit 1
  fi
  PINNED_CERTIFICATE_PATH="$CERTIFICATE_OVERRIDE"
else
  PINNED_CERTIFICATE_PATH="$TMP_DIR/BookSenderReleaseSigning.cer"
  echo "Downloading the pinned Book Sender public signing certificate..."
  curl -fsSL "$SIGNING_CERTIFICATE_URL" -o "$PINNED_CERTIFICATE_PATH"
fi

ACTUAL_CERTIFICATE_SHA1=$(openssl x509 \
  -inform DER \
  -in "$PINNED_CERTIFICATE_PATH" \
  -noout \
  -fingerprint \
  -sha1 \
  | cut -d= -f2 \
  | tr -d ':')
if [ "$ACTUAL_CERTIFICATE_SHA1" != "$SIGNING_CERTIFICATE_SHA1" ]; then
  echo "The public signing certificate does not match the pinned fingerprint."
  exit 1
fi
if ! openssl x509 -inform DER -in "$PINNED_CERTIFICATE_PATH" -noout -text \
  | grep -Fq "Code Signing"; then
  echo "The pinned certificate is not restricted to code signing."
  exit 1
fi

EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"

APP_PATH="$EXTRACT_DIR/$APP_BUNDLE_NAME"
if [ ! -d "$APP_PATH" ]; then
  echo "$APP_BUNDLE_NAME was not found in the release archive."
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
ACTUAL_BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")
if [ "$ACTUAL_BUNDLE_IDENTIFIER" != "$BUNDLE_IDENTIFIER" ]; then
  echo "Unexpected bundle identifier: $ACTUAL_BUNDLE_IDENTIFIER"
  exit 1
fi

if [ -n "$VERSION" ]; then
  ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
  if [ "$ACTUAL_VERSION" != "$VERSION" ]; then
    echo "Unexpected app version: $ACTUAL_VERSION"
    exit 1
  fi
fi

if [ -n "$KEYCHAIN_OVERRIDE" ]; then
  if [[ "$KEYCHAIN_OVERRIDE" != /* ]] || [ ! -f "$KEYCHAIN_OVERRIDE" ]; then
    echo "The Keychain override must reference an absolute existing Keychain."
    exit 1
  fi
  USER_KEYCHAIN="$KEYCHAIN_OVERRIDE"
else
  USER_KEYCHAIN=$(security default-keychain -d user \
    | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
  if [[ "$USER_KEYCHAIN" != /* ]] || [ ! -f "$USER_KEYCHAIN" ]; then
    echo "The default user Keychain could not be resolved."
    exit 1
  fi
fi

certificate_is_registered() {
  security find-certificate -a -Z "$USER_KEYCHAIN" 2>/dev/null \
    | grep -F "SHA-1 hash: $SIGNING_CERTIFICATE_SHA1" >/dev/null
}

if ! certificate_is_registered; then
  if [ "$CERTIFICATE_REGISTRATION_ACCEPTED" != "1" ]; then
    if [ ! -r /dev/tty ]; then
      echo "Certificate registration requires an interactive terminal."
      exit 1
    fi
    printf "%s" \
      "Register the pinned Book Sender public code-signing certificate in your user Keychain? [y/N] " \
      >/dev/tty
    IFS= read -r registration_response </dev/tty
    case "$registration_response" in
      y|Y|yes|YES)
        ;;
      *)
        echo "Certificate registration was cancelled."
        exit 1
        ;;
    esac
  fi
  echo "Registering the pinned Book Sender public certificate in your user Keychain..."
  echo "Only the public code-signing certificate is stored; no private key or email password is added."
  security import "$PINNED_CERTIFICATE_PATH" \
    -k "$USER_KEYCHAIN" \
    -t cert >/dev/null
  if ! certificate_is_registered; then
    echo "The public signing certificate could not be registered."
    exit 1
  fi
fi

DESIGNATED_REQUIREMENT="anchor H\"$SIGNING_CERTIFICATE_SHA1\" and identifier \"$BUNDLE_IDENTIFIER\""
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify -R="$DESIGNATED_REQUIREMENT" "$APP_PATH"

if codesign -dvvv "$APP_PATH" 2>&1 | grep -Fq "Signature=adhoc"; then
  echo "The downloaded app uses a forbidden ad-hoc signature."
  exit 1
fi

ACTUAL_REQUIREMENT=$(codesign -d -r- "$APP_PATH" 2>&1 \
  | sed -n 's/^designated => //p')
if [ "$ACTUAL_REQUIREMENT" != "$PINNED_DESIGNATED_REQUIREMENT" ]; then
  echo "The downloaded app has an unexpected designated requirement."
  exit 1
fi

SIGNING_DETAILS=$(codesign -dvvv "$APP_PATH" 2>&1)
if ! printf "%s\n" "$SIGNING_DETAILS" \
  | grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)'; then
  echo "The downloaded app does not use the required hardened runtime."
  exit 1
fi
if ! printf "%s\n" "$SIGNING_DETAILS" \
  | grep -Fqx "TeamIdentifier=not set"; then
  echo "The downloaded app has an unexpected Team ID contract."
  exit 1
fi

SIGNED_ENTITLEMENTS="$TMP_DIR/signed-entitlements.plist"
codesign -d --entitlements - --xml "$APP_PATH" > "$SIGNED_ENTITLEMENTS"
if [ "$(/usr/libexec/PlistBuddy \
  -c "Print :com.apple.security.cs.disable-library-validation" \
  "$SIGNED_ENTITLEMENTS")" != "true" ]; then
  echo "The downloaded app is missing its required library validation exception."
  exit 1
fi

SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
verify_pinned_component() {
  local component="$1"
  if [ -e "$component" ]; then
    codesign --verify --strict --verbose=2 "$component"
    codesign \
      --verify \
      -R="anchor H\"$SIGNING_CERTIFICATE_SHA1\"" \
      "$component"
    if codesign -dvvv "$component" 2>&1 | grep -Fq "Signature=adhoc"; then
      echo "A nested app component uses a forbidden ad-hoc signature."
      exit 1
    fi
    if codesign -d --entitlements - --xml "$component" 2>/dev/null \
      | grep -Fq "com.apple.security.cs.disable-library-validation"; then
      echo "A nested app component has a forbidden library validation exception."
      exit 1
    fi
  fi
}

verify_pinned_component "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
verify_pinned_component "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
verify_pinned_component "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
verify_pinned_component "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
verify_pinned_component "$SPARKLE_FRAMEWORK"

if [ -n "$TARGET_DIRECTORY_OVERRIDE" ]; then
  if [[ "$TARGET_DIRECTORY_OVERRIDE" != /* ]]; then
    echo "The target directory override must be absolute."
    exit 1
  fi
  TARGET_DIR="$TARGET_DIRECTORY_OVERRIDE"
  mkdir -p "$TARGET_DIR"
else
  TARGET_DIR="/Applications"
  if [ ! -w "$TARGET_DIR" ]; then
    TARGET_DIR="$HOME/Applications"
    mkdir -p "$TARGET_DIR"
  fi
fi

TARGET_PATH="$TARGET_DIR/$APP_BUNDLE_NAME"
if [ -d "$TARGET_PATH" ]; then
  echo "Removing existing $TARGET_PATH"
  rm -rf "$TARGET_PATH"
fi

echo "Installing to $TARGET_DIR"
ditto "$APP_PATH" "$TARGET_PATH"

if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$TARGET_PATH" 2>/dev/null || true
fi

echo "$APP_DISPLAY_NAME installed at $TARGET_PATH"
if [ "$TARGET_DIR" != "/Applications" ]; then
  echo "Installed to $TARGET_DIR because /Applications is not writable."
fi

echo "Open with: open \"$TARGET_PATH\""
