#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
options=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)
swift build "${options[@]}" -c "$configuration"
binary_dir="$(swift build "${options[@]}" -c "$configuration" --show-bin-path)"
app="$PWD/build/ClipRecord.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/ClipRecord" "$app/Contents/MacOS/ClipRecord"
cp Support/Info.plist "$app/Contents/Info.plist"
cp -R "$binary_dir/ClipRecord_ClipRecord.bundle" "$app/Contents/Resources/"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - --identifier com.codemm.cliprecord "$app"
codesign --verify --deep --strict "$app"
echo "$app"
