#!/usr/bin/env bash
# Builds the Photobank desktop app on macOS/Linux (PyInstaller bundle with a native window).
# macOS output: server/dist/Photobank.app   Linux output: server/dist/Photobank/Photobank
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Building web app =="
(cd "$ROOT/web" && npm ci --no-audit --no-fund && npm run build)

echo "== Python environment =="
cd "$ROOT/server"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --quiet --disable-pip-version-check -r requirements.txt pyinstaller pywebview pystray

echo "== Freezing Photobank =="
EXTRA=()
if [[ "$(uname)" == "Darwin" ]]; then
  EXTRA+=(--osx-bundle-identifier com.photobank.desktop)
fi
pyinstaller --noconfirm --clean --onedir --windowed \
  --name Photobank \
  --add-data "$ROOT/web/dist:web_dist" \
  --collect-all pillow_heif \
  --hidden-import aiosqlite \
  "${EXTRA[@]}" \
  desktop.py

if [[ "$(uname)" == "Darwin" ]]; then
  # macOS (Sequoia+) blocks multicast/Bonjour unless the app declares local
  # network use; without these keys mDNS discovery silently fails.
  PLIST="$ROOT/server/dist/Photobank.app/Contents/Info.plist"
  PB=/usr/libexec/PlistBuddy
  $PB -c "Add :NSLocalNetworkUsageDescription string 'Photobank announces itself on your home network so the Photobank phone app can find it.'" "$PLIST" || true
  $PB -c "Add :NSBonjourServices array" "$PLIST" || true
  $PB -c "Add :NSBonjourServices:0 string '_photobank._tcp'" "$PLIST" || true
  $PB -c "Add :LSUIElement bool false" "$PLIST" || true
  $PB -c "Add :NSHighResolutionCapable bool true" "$PLIST" || true
  # editing Info.plist invalidates PyInstaller's ad-hoc signature, and macOS
  # reports an invalid signature as "damaged" - re-sign the whole bundle
  codesign --force --deep --sign - "$ROOT/server/dist/Photobank.app"
  codesign --verify --deep --strict "$ROOT/server/dist/Photobank.app" && echo "signature OK"
  echo "Built: $ROOT/server/dist/Photobank.app"
else
  echo "Built: $ROOT/server/dist/Photobank/Photobank"
fi
