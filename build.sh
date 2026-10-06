#!/bin/zsh
# Builds SysMeter.app next to this script.
set -e
cd "$(dirname "$0")"

APP="SysMeter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Universal binary: runs on Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 main.swift -o "/tmp/SysMeter-$arch" \
    -framework Cocoa -framework ServiceManagement
done
lipo -create /tmp/SysMeter-arm64 /tmp/SysMeter-x86_64 -output "$APP/Contents/MacOS/SysMeter"
rm /tmp/SysMeter-arm64 /tmp/SysMeter-x86_64

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SysMeter</string>
  <key>CFBundleDisplayName</key><string>SysMeter</string>
  <key>CFBundleIdentifier</key><string>local.sysmeter</string>
  <key>CFBundleExecutable</key><string>SysMeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
