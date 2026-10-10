#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
  swift test "$@" -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$DEVELOPER_DIR/Library/Developer/usr/lib"
else
  swift test "$@"
fi
