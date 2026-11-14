#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="build/Star Command.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/StarCommand "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/Star Command.app" "/Applications/Berth.app" "/Applications/Wormhole.app" "/Applications/SSH Manager.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Star Command.app"
fi
