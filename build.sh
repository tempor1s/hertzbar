#!/bin/zsh
# Builds HertzBar.app with just the Command Line Tools (no Xcode project needed).
set -euo pipefail
cd "${0:A:h}"

# Use the CLT toolchain so an un-accepted Xcode license doesn't block the build.
if [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

APP=build/HertzBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -target arm64-apple-macos13.0 \
  -framework AppKit -framework IOKit -framework CoreGraphics -framework ServiceManagement \
  Sources/main.swift -o "$APP/Contents/MacOS/HertzBar"

cp -R Resources/profiles "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.local.HertzBar</string>
  <key>CFBundleName</key><string>HertzBar</string>
  <key>CFBundleExecutable</key><string>HertzBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
echo "Install: cp -R $APP /Applications/"
