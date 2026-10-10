#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="CodeJump"
BUNDLE_ID="com.xiay8874.CodeJump"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CONFIGURATION="${CODEJUMP_CONFIGURATION:-release}"
swift build -c "$CONFIGURATION"
BUILD_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_PATH/CodeJump" "$APP_BUNDLE/Contents/MacOS/CodeJump"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CodeJump</string>
  <key>CFBundleIdentifier</key><string>com.xiay8874.CodeJump</string>
  <key>CFBundleName</key><string>CodeJump</string>
  <key>CFBundleDisplayName</key><string>CodeJump</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAccessibilityUsageDescription</key><string>在你按下快捷键时读取鼠标指向的代码引用，以便在编辑器中打开。</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>CodeJump location</string>
    <key>CFBundleURLSchemes</key><array><string>codejump</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
if [ "$MODE" = "--build-only" ]; then
  echo "Built $APP_BUNDLE"
  exit 0
fi
# Only this application's exact process is restarted.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
if [ "$MODE" = "--install" ]; then
  DESTINATION="/Applications/CodeJump.app"
  if [ -d "$DESTINATION" ]; then
    INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")"
    if [ "$INSTALLED_ID" != "$BUNDLE_ID" ]; then
      echo "Another application owns $DESTINATION; refusing to replace it." >&2
      exit 1
    fi
    mkdir -p "$ROOT_DIR/output/backups"
    ditto "$DESTINATION" "$ROOT_DIR/output/backups/CodeJump-$(date +%Y%m%d-%H%M%S).app"
  fi
  ditto "$APP_BUNDLE" "$DESTINATION"
  APP_BUNDLE="$DESTINATION"
fi
case "$MODE" in
  run|--install) /usr/bin/open "$APP_BUNDLE" ;;
  --verify) /usr/bin/open "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/CodeJump" ;;
  --logs|--telemetry)
    /usr/bin/open "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.xiay8874.CodeJump"'
    ;;
  *) echo "usage: $0 [run|--build-only|--install|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
