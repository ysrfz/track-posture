#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=build/TrackPosture.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" ~/Applications
swiftc -O main.swift -o "$APP/Contents/MacOS/TrackPosture"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

pkill -x TrackPosture || true
rm -rf ~/Applications/TrackPosture.app && cp -R "$APP" ~/Applications/
open ~/Applications/TrackPosture.app
