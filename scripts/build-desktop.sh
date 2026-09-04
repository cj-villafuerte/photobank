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
# macOS signing: MAC_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" signs with the
# hardened runtime so the app can be notarized; unset = ad-hoc signature (right-click > Open).
# Notarization runs when NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER_ID (an App Store
# Connect API key) are set as well. See README "Desktop app".
IDENTITY="${MAC_SIGN_IDENTITY:-}"
ENTITLEMENTS="$ROOT/scripts/macos-entitlements.plist"
EXTRA=()
if [[ "$(uname)" == "Darwin" ]]; then
  EXTRA+=(--osx-bundle-identifier com.cjvillafuerte.photobank.desktop --icon "$ROOT/assets/icon/photobank.icns")
  if [[ -n "$IDENTITY" ]]; then
    # PyInstaller signs every nested binary with the identity + entitlements as it collects them
    EXTRA+=(--codesign-identity "$IDENTITY" --osx-entitlements-file "$ENTITLEMENTS")
  fi
fi
pyinstaller --noconfirm --clean --onedir --windowed \
  --name Photobank \
  --add-data "$ROOT/web/dist:web_dist" \
  --add-data "$ROOT/assets/icon/photobank-256.png:assets" \
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
  # editing Info.plist invalidates the signature, and macOS reports an invalid
  # signature as "damaged" - re-sign the whole bundle
  APP="$ROOT/server/dist/Photobank.app"
  if [[ -n "$IDENTITY" ]]; then
    codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
  else
    codesign --force --deep --sign - "$APP"
  fi
  codesign --verify --deep --strict "$APP" && echo "signature OK ($( [[ -n "$IDENTITY" ]] && echo "$IDENTITY" || echo ad-hoc ))"

  if [[ -n "$IDENTITY" && -n "${NOTARY_KEY_PATH:-}" ]]; then
    echo "== Notarizing with Apple =="
    ZIP="$(mktemp -d)/Photobank-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m
    xcrun stapler staple "$APP"           # ticket travels with the app: works offline, no warning
    spctl --assess --type execute --verbose=2 "$APP" && echo "Gatekeeper: accepted"
  fi
  echo "Built: $APP"
else
  echo "Built: $ROOT/server/dist/Photobank/Photobank"
fi
