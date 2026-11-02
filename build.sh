#!/bin/zsh
# Compile ScanMenu.app. Usage : ./build.sh [--install]
#   --install : copie l'app dans /Applications et la lance.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ScanMenu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>ScanMenu</string>
    <key>CFBundleDisplayName</key>        <string>ScanMenu</string>
    <key>CFBundleIdentifier</key>         <string>local.scanmenu</string>
    <key>CFBundleExecutable</key>         <string>ScanMenu</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

cp logo/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -o "$APP/Contents/MacOS/ScanMenu" Sources/main.swift \
    -framework AppKit -framework ImageCaptureCore \
    -framework ServiceManagement -framework UserNotifications

codesign --force --sign - "$APP"
echo "✅ Construit : $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ScanMenu 2>/dev/null || true
    rm -rf /Applications/ScanMenu.app
    cp -R "$APP" /Applications/
    open /Applications/ScanMenu.app
    echo "✅ Installé dans /Applications et lancé"
fi
