#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
./scripts/build-app.sh release
bin_dir="$(swift build --configuration release --show-bin-path)"
module_dir="$bin_dir"
if [[ -d "$bin_dir/Modules" ]]; then module_dir="$bin_dir/Modules"; fi
core_objects=("$bin_dir/ClipCore.o")
if [[ ! -f "${core_objects[0]}" ]]; then
  shopt -s nullglob
  core_objects=("$bin_dir"/ClipCore.build/*.o)
fi
if [[ ${#core_objects[@]} -eq 0 ]]; then
  echo "Cannot locate compiled ClipCore objects" >&2
  exit 1
fi
cat > build/readme-resource-bundle.swift <<'SWIFT'
import Foundation
extension Bundle {
    static let module = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("ClipRecord_ClipRecord.bundle"))!
}
SWIFT
swiftc -parse-as-library -swift-version 5 -I "$module_dir" \
  Sources/ClipRecord/AppModel.swift Sources/ClipRecord/Views.swift \
  Sources/ClipRecord/HotkeyService.swift Sources/ClipRecord/ClipboardImport.swift \
  Sources/ClipRecord/PasteCaptureView.swift Sources/ClipRecord/ImagePreview.swift \
  Sources/ClipRecord/TextPreview.swift scripts/render-readme-assets.swift \
  build/readme-resource-bundle.swift \
  "${core_objects[@]}" -o build/render-readme-assets
rsync -a --delete "$bin_dir/ClipRecord_ClipRecord.bundle/" build/ClipRecord_ClipRecord.bundle/
./build/render-readme-assets
# Remove optional metadata chunks without changing PNG pixels.
python3 - <<'PY'
from pathlib import Path
import struct

for path in Path('docs/media').glob('*.png'):
    source = path.read_bytes()
    assert source[:8] == b'\x89PNG\r\n\x1a\n'
    output = bytearray(source[:8])
    offset = 8
    while offset < len(source):
        length = struct.unpack('>I', source[offset:offset + 4])[0]
        kind = source[offset + 4:offset + 8]
        end = offset + length + 12
        if kind not in {b'eXIf', b'tEXt', b'iTXt', b'zTXt'}:
            output.extend(source[offset:end])
        offset = end
    path.write_bytes(output)
PY
