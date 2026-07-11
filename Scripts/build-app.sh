#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/OctoPilot"
APP="$ROOT/OctoPilot.app"
VERSION="${OCTOPILOT_VERSION:-$("$ROOT/Scripts/version.sh")}"
BUILD_NUMBER="${OCTOPILOT_BUILD_NUMBER:-$(git rev-list --count HEAD)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OctoPilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $APP (version $VERSION, build $BUILD_NUMBER)"
