#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Build the app and DMG without installing or modifying the host.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
MODE="${1:-build}"
if [[ "$MODE" == test ]]; then
    exec bash tests/run-host-tests.sh
fi
if [[ "$MODE" != build ]]; then
    printf 'Usage: bash build.sh [build|test]\n' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
    printf '%s\n' 'SKIP: RogControl needs macOS with the Swift toolchain. No app was built or installed.' >&2
    exit 77
fi

APP="$ROOT/build/MyASUS.app"
DMG="$ROOT/build/MyASUS-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist).dmg"
WORK="$(mktemp -d)"
STAGING=""
trap 'rm -rf -- "$WORK" "${STAGING:-}"' EXIT
mkdir -p "$ROOT/build"
rm -rf -- "$APP"
rm -f -- "$DMG"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
/usr/bin/python3 -I - "$WORK/main.swift" <<'PY'
from pathlib import Path
import sys
files = ['ControlConfiguration.swift', 'SMCTelemetry.swift', 'RogControl.swift']
Path(sys.argv[1]).write_text('\n'.join(Path(name).read_text() for name in files))
PY
swiftc -O -target x86_64-apple-macos13.0 "$WORK/main.swift" -o "$APP/Contents/MacOS/RogControl" \
    -framework IOKit -framework SwiftUI -framework UserNotifications -framework ApplicationServices
codesign --force --sign - "$APP" >/dev/null
plutil -lint "$APP/Contents/Info.plist"
STAGING="$(mktemp -d)"
ln -s /Applications "$STAGING/Applications"
cp -R "$APP" "$STAGING/MyASUS.app"
hdiutil create -volname MyASUS -srcfolder "$STAGING" -format UDZO -ov -o "$DMG" >/dev/null
shasum -a 256 "$DMG" > "$ROOT/build/SHA256SUMS.txt"
printf 'Built %s and %s. No installation or hardware writes were performed.\n' "$APP" "$DMG"
