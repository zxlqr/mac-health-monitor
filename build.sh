#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/build/Нагрузка Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
  Sources/Metrics.swift Sources/AppUsage.swift Sources/MonitorStore.swift Sources/MonitorView.swift Sources/App.swift \
  -framework AppKit -framework SwiftUI -o "$APP/Contents/MacOS/MacHealthMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Finder may tag the generated bundle in a synced Documents directory.
if /usr/bin/xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.FinderInfo "$APP"
fi
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
print -r -- "$APP"
