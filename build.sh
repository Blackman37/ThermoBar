#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="${1:-build/ThermoBar.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build
swift build -c release --arch arm64 -Xswiftc -warnings-as-errors
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN_DIR/ThermoBar" "$APP/Contents/MacOS/ThermoBar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ThermoBar</string>
<key>CFBundleIdentifier</key><string>cz.local.ThermoBar</string>
<key>CFBundleName</key><string>ThermoBar</string>
<key>CFBundleDisplayName</key><string>ThermoBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Sestaveno: $APP"
