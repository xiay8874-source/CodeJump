#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="CodeJump"
BUNDLE_ID="com.xiay8874.CodeJump"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CONFIGURATION="${CODEJUMP_CONFIGURATION:-release}"
# Avoid embedding the maintainer's local checkout/home paths in distributed binaries.
swift build -c "$CONFIGURATION" \
  -Xswiftc -gnone \
  -Xswiftc -no-toolchain-stdlib-rpath \
  -Xswiftc -Xfrontend -Xswiftc -no-serialize-debugging-options \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=CodeJump" \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=CodeJump" \
  -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/Users/developer" \
  -Xswiftc -file-compilation-dir -Xswiftc .
BUILD_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
# An interrupted codesign can leave a sealed reference to a missing *.cstemp file.
# Always package into a fresh bundle so a stale signature can never fail verification.
case "$APP_BUNDLE" in
  "$ROOT_DIR"/dist/*.app) rm -rf -- "$APP_BUNDLE" ;;
  *) echo "Unexpected bundle path; refusing to clean it." >&2; exit 1 ;;
esac
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_PATH/CodeJump" "$APP_BUNDLE/Contents/MacOS/CodeJump"
# SwiftPM may append its toolchain rpath after user compiler flags. A distributed
# app must use system Swift libraries, never the build machine's SDK directory.
python3 - "$APP_BUNDLE/Contents/MacOS/CodeJump" <<'PY'
import re, subprocess, sys
binary = sys.argv[1]
commands = subprocess.check_output(['otool', '-l', binary], text=True)
for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands):
    if '/Library/Developer/' in path or '.xctoolchain/' in path:
        subprocess.run(['install_name_tool', '-delete_rpath', path, binary], check=True)
PY
cp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
"$ROOT_DIR/script/generate_icon.sh" "$ROOT_DIR/Assets/AppIcon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CodeJump</string>
  <key>CFBundleIdentifier</key><string>com.xiay8874.CodeJump</string>
  <key>CFBundleName</key><string>CodeJump</string>
  <key>CFBundleDisplayName</key><string>CodeJump</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.3.5</string>
  <key>CFBundleVersion</key><string>12</string>
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
if [ "$MODE" = "--build-only" ]; then
  python3 "$ROOT_DIR/script/local_signing.py" --sign "$APP_BUNDLE" --allow-adhoc
else
  python3 "$ROOT_DIR/script/local_signing.py" --sign "$APP_BUNDLE"
fi
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
  # Build and backup copies share the bundle identifier. Keep only the installed app registered,
  # so System Settings grants Accessibility to /Applications/CodeJump.app and not a stale copy.
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  for copy in "$APP_BUNDLE" "$ROOT_DIR"/output/backups/*.app; do
    [ -d "$copy" ] && "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true
  done
  "$LSREGISTER" -f "$DESTINATION" >/dev/null 2>&1 || true
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
