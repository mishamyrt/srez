#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?Usage: package-release.sh vX.Y.Z}"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Release tag must have the form vX.Y.Z." >&2
    exit 1
fi
: "${BUILD_CERTIFICATE_BASE64:?BUILD_CERTIFICATE_BASE64 is not set}"
: "${P12_PASSWORD:?P12_PASSWORD is not set}"
: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"

app="$PWD/.build/Srez.app"
test -x "$app/Contents/MacOS/Srez"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
if [[ "$version" != "${tag#v}" ]]; then
    echo "App version $version does not match release tag $tag. Rebuild with VERSION=${tag#v}." >&2
    exit 1
fi
work=$(mktemp -d "$RUNNER_TEMP/srez-signing.XXXXXX")
keychain="$work/signing.keychain-db"
cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

printf '%s' "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$work/certificate.p12"
keychain_password=$(openssl rand -hex 32)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/certificate.p12" -P "$P12_PASSWORD" -k "$keychain" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null

# find-identity -v omits self-signed certificates that aren't trusted by macOS.
identity=$(security find-identity -p codesigning "$keychain" |
    awk '/^[[:space:]]*[0-9]+\)/ { print $2 }' | sort -u)
if [[ ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "Certificate must contain exactly one code-signing identity with a private key." >&2
    exit 1
fi
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$app/Contents/MacOS/ffmpeg"
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$app"
codesign --verify --deep --strict "$app"

rm -rf .build/release
mkdir -p .build/release
archive="Srez-${tag}-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" ".build/release/$archive"
cd .build/release
shasum -a 256 "$archive" > sha256sums.txt
