#!/bin/zsh
# Builds build/RawViewer.app with only the Command Line Tools.
#
# SIGN_MODE=auto     Developer ID when one is in the keychain, otherwise ad-hoc (default)
# SIGN_MODE=adhoc    always ad-hoc (fine for running on this Mac)
# SIGN_MODE=release  Developer ID with hardened runtime and timestamp; fails without one
set -euo pipefail
cd "${0:A:h}/.."

APP="build/RawViewer.app"
SIGN_MODE="${SIGN_MODE:-auto}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/RawViewer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RawViewer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
if [[ "$SIGN_MODE" == "release" && -z "$IDENTITY" ]]; then
    echo "No 'Developer ID Application' certificate in the keychain. See README > Releasing." >&2
    exit 1
fi
if [[ "$SIGN_MODE" != "adhoc" && -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Signed with $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (runs on this Mac only)"
fi
codesign --verify --strict "$APP"
echo "Built $PWD/$APP"
