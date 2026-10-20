#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/DocVision.app"
ICONSET="$ROOT/.build/DocVision.iconset"

cd "$ROOT"
mkdir -p "$ROOT/.build/SwiftModuleCache" "$ROOT/.build/ClangModuleCache"
BIN_DIR="$(SWIFT_MODULECACHE_PATH="$ROOT/.build/SwiftModuleCache" CLANG_MODULE_CACHE_PATH="$ROOT/.build/ClangModuleCache" swift build -c release --show-bin-path --disable-sandbox 2>/dev/null)"
BUILD_LOG="$ROOT/.build/DocVision-release-build.log"
if SWIFT_MODULECACHE_PATH="$ROOT/.build/SwiftModuleCache" \
     CLANG_MODULE_CACHE_PATH="$ROOT/.build/ClangModuleCache" \
     swift build -c release --disable-sandbox 2>&1 | tee "$BUILD_LOG"; then
    :
else
    if ! grep -q 'GenerateDSYMFile .* failed with a nonzero exit code' "$BUILD_LOG" || [[ ! -x "$BIN_DIR/DocVision" ]]; then
        exit 1
    fi
    printf 'SwiftPM linked the app, but local dSYM generation was blocked; packaging the new executable.\n'
fi
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for dimensions in "16 16" "32 32" "64 64" "128 128" "256 256" "512 512"; do
    read -r width height <<< "$dimensions"
    sips -z "$height" "$width" "$ROOT/Assets/DocVision.png" --out "$ICONSET/icon_${width}x${height}.png" >/dev/null
done
for dimensions in "16 32" "32 64" "128 256" "256 512" "512 1024"; do
    read -r base scale <<< "$dimensions"
    sips -z "$scale" "$scale" "$ROOT/Assets/DocVision.png" --out "$ICONSET/icon_${base}x${base}@2x.png" >/dev/null
done
python3 "$ROOT/Scripts/package-icns.py" "$ICONSET" "$ROOT/Assets/DocVision.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DocVision" "$APP/Contents/MacOS/DocVision"
cp "$ROOT/Assets/DocVision.icns" "$APP/Contents/Resources/DocVision.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DocVision</string>
    <key>CFBundleIdentifier</key><string>com.docvision.app</string>
    <key>CFBundleName</key><string>DocVision</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>DocVision</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'Application bundle created: %s\n' "$APP"
