#!/usr/bin/env bash
# Build "Runout Bar.app" into build/, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)/RunoutBar"

app="build/Runout Bar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/RunoutBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
fi
codesign --force --sign - --timestamp=none "$app"
echo "Built $app"
