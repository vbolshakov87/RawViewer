#!/bin/zsh
# Builds RawViewer and installs it into /Applications (or ~/Applications if that isn't writable).
set -euo pipefail
cd "${0:A:h}/.."

./scripts/build-app.sh

DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

# Quit a running copy so it can be replaced.
if pgrep -xq RawViewer; then
    osascript -e 'tell application id "com.vbolshakov.RawViewer" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -x RawViewer 2>/dev/null || true
fi

rm -rf "$DEST/RawViewer.app"
ditto "build/RawViewer.app" "$DEST/RawViewer.app"

# Refresh Launch Services so Spotlight and Finder's Open With see the new copy.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$DEST/RawViewer.app"
    # Keep Open With to one entry: forget the copy left in build/.
    "$LSREGISTER" -u "$PWD/build/RawViewer.app" 2>/dev/null || true
fi

echo "Installed $DEST/RawViewer.app"
