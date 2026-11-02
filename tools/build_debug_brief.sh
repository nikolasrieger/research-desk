#!/bin/zsh
set -eu
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/research-desk-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/research-desk-swift-cache"
swift build --disable-sandbox
mkdir -p dist/ResearchDeskDebug.app/Contents/MacOS dist/ResearchDeskDebug.app/Contents/Resources
cp .build/debug/ResearchDesk dist/ResearchDeskDebug.app/Contents/MacOS/ResearchDesk
cp dist/ResearchDesk.app/Contents/Resources/ResearchDesk.icns dist/ResearchDeskDebug.app/Contents/Resources/ResearchDesk.icns
python3 - <<'PY'
import plistlib
from pathlib import Path
source = Path('dist/ResearchDesk.app/Contents/Info.plist')
info = plistlib.loads(source.read_bytes())
info['CFBundleIdentifier'] = 'com.nrieger.researchdesk.debug'
info['CFBundleName'] = 'Research Desk Debug'
info['CFBundleDisplayName'] = 'Research Desk Debug'
Path('dist/ResearchDeskDebug.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - dist/ResearchDeskDebug.app
codesign --verify dist/ResearchDeskDebug.app
printf '%s\n' 'Ready: dist/ResearchDeskDebug.app (the standard app was not modified)'
