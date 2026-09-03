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
  echo "Built: $ROOT/server/dist/Photobank.app"
else
  echo "Built: $ROOT/server/dist/Photobank/Photobank"
fi
