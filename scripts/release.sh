#!/bin/zsh
# Signs with Developer ID, notarizes, staples and zips RawViewer for a GitHub release.
# One-time setup is described in README > Releasing.
set -euo pipefail
cd "${0:A:h}/.."

PROFILE="${NOTARY_PROFILE:-RawViewerNotary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP="build/RawViewer.app"
ZIP="dist/RawViewer-$VERSION.zip"

SIGN_MODE=release ./scripts/build-app.sh

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting $ZIP for notarization (usually a few minutes)…"
RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)"
STATUS="$(plutil -extract status raw -o - - <<< "$RESULT")"
if [[ "$STATUS" != "Accepted" ]]; then
    ID="$(plutil -extract id raw -o - - <<< "$RESULT" || true)"
    echo "Notarization status: $STATUS" >&2
    echo "Details: xcrun notarytool log $ID --keychain-profile $PROFILE" >&2
    exit 1
fi

xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

codesign --verify --strict --verbose=2 "$APP"
spctl --assess --verbose=4 --type execute "$APP"
shasum -a 256 "$ZIP"
echo "Release ready: $PWD/$ZIP"
