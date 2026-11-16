#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build a drag-to-install DMG and a ZIP from a clean staging directory.
# Set SIGNING_IDENTITY to a Developer ID certificate fingerprint for distribution.
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Support/Info.plist)"
identity="${SIGNING_IDENTITY:--}"
output="$PWD/build/release/v$version"
if [[ -e "$output" ]]; then
  echo "Release output already exists: $output" >&2
  exit 1
fi

./scripts/build-app.sh release
arch="$(lipo -archs build/ClipRecord.app/Contents/MacOS/ClipRecord)"
if [[ "$arch" != "arm64" ]]; then
  echo "This package is named for Apple Silicon; got architecture: $arch" >&2
  exit 1
fi
mkdir -p "$output"
stage="$(mktemp -d "$PWD/build/release-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr build/ClipRecord.app "$stage/ClipRecord.app"
# Debug symbols stay in the local build, outside the downloadable app.
strip -S "$stage/ClipRecord.app/Contents/MacOS/ClipRecord"
if [[ "$identity" == "-" ]]; then
  codesign --force --deep --sign - --identifier com.codemm.cliprecord "$stage/ClipRecord.app"
else
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$stage/ClipRecord.app"
fi
codesign --verify --deep --strict --verbose=2 "$stage/ClipRecord.app"
codesign --display --verbose=2 "$stage/ClipRecord.app" 2> "$output/signature.txt"

ln -s /Applications "$stage/Applications"
cat > "$stage/安装说明.txt" <<EOF
剪贴板 ClipRecord ${version}（build ${build_number}）
适用：macOS 14 或更新版本，Apple Silicon（M 系列）。

安装：将 ClipRecord.app 拖到 Applications（应用程序），然后从应用程序中打开。
升级：先退出旧版本，再替换应用；已有记录保存在用户资料库中。

双击 F1：显示 / 隐藏面板。
双击 F2：静默记录当前剪贴板，绿色闪烁和声音提示。
部分键盘需要配合 Fn 使用功能键。
打开后常驻菜单栏，没有 Dock 图标。

此包尚未经过 Apple 公证，首次打开可能被 macOS 拦截。
确认来自本项目且 SHA-256 与 Release 一致后，可参考 Apple 官方说明：
https://support.apple.com/zh-cn/102445
无需关闭系统安全机制，也不需要运行移除隔离属性的命令。

项目：https://github.com/code-mm/macos-app-clip
安装包不含任何个人剪贴板记录、测试数据或日志。
EOF

name="ClipRecord-$version-macOS-arm64"
ditto -c -k --sequesterRsrc --keepParent "$stage/ClipRecord.app" "$output/$name.zip"
hdiutil create -volname "ClipRecord $version" -srcfolder "$stage" -format UDZO -ov "$output/$name.dmg"
hdiutil verify "$output/$name.dmg"
(
  cd "$output"
  shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt
)
echo "Release packages: $output"
