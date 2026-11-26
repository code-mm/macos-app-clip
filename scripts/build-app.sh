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
mkdir -p "$PWD/build"
stage="$(mktemp -d "$PWD/build/app-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
staged_app="$stage/ClipRecord.app"
resource_bundle="$staged_app/Contents/Resources/ClipRecord_ClipRecord.bundle"
mkdir -p "$staged_app/Contents/MacOS" "$resource_bundle"
cp "$binary_dir/ClipRecord" "$staged_app/Contents/MacOS/ClipRecord"
cp Support/Info.plist "$staged_app/Contents/Info.plist"
# Allowlist the shipped SwiftPM resource; never copy stale audio from an older build.
source_bundle="$binary_dir/ClipRecord_ClipRecord.bundle"
if [[ -f "$source_bundle/Contents/Resources/BrandMark.png" ]]; then
  mkdir -p "$resource_bundle/Contents/Resources"
  cp "$source_bundle/Contents/Info.plist" "$resource_bundle/Contents/Info.plist"
  cp "$source_bundle/Contents/Resources/BrandMark.png" "$resource_bundle/Contents/Resources/BrandMark.png"
else
  cp "$source_bundle/BrandMark.png" "$resource_bundle/BrandMark.png"
fi
cp Support/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - --identifier com.codemm.cliprecord "$staged_app"
codesign --verify --deep --strict "$staged_app"
if [[ -e "$app" ]]; then mv "$app" "$stage/previous.app"; fi
if ! mv "$staged_app" "$app"; then
  if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$app"; fi
  exit 1
fi
echo "$app"
