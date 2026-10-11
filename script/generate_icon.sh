#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT_DIR/Assets/AppIcon.png}"
DESTINATION="${2:-$ROOT_DIR/dist/CodeJump.app/Contents/Resources/AppIcon.icns}"

if [ ! -f "$SOURCE" ]; then
  echo "Missing application icon source: $SOURCE" >&2
  exit 1
fi

PROPERTIES="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$SOURCE")"
FORMAT="$(awk '/^  format:/ { print $2 }' <<< "$PROPERTIES")"
WIDTH="$(awk '/^  pixelWidth:/ { print $2 }' <<< "$PROPERTIES")"
HEIGHT="$(awk '/^  pixelHeight:/ { print $2 }' <<< "$PROPERTIES")"
if [ "$FORMAT" != "png" ] || ! [[ "$WIDTH" =~ ^[0-9]+$ && "$HEIGHT" =~ ^[0-9]+$ ]] ||
   [ "$WIDTH" != "$HEIGHT" ] || [ "$WIDTH" -lt 1024 ]; then
  echo "Application icon must be a square PNG at least 1024 × 1024 pixels: $SOURCE" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codejump-icon.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

# Resample the approved source only; design and transparency belong to the PNG.
for SIZE in 16 32 128 256 512; do
  /usr/bin/sips -z "$SIZE" "$SIZE" "$SOURCE" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  /usr/bin/sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$SOURCE" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

/usr/bin/iconutil -c icns "$ICONSET" -o "$WORK_DIR/AppIcon.icns"
mkdir -p "$(dirname "$DESTINATION")"
cp "$WORK_DIR/AppIcon.icns" "$DESTINATION"
echo "Generated $DESTINATION"
