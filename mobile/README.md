# Photobank for iPhone / Android

Flutter companion app for a [Photobank](../README.md) server: finds the server on the
local network (Bonjour), backs up the camera roll (SHA-256 verified, Live Photos included),
browses the whole library, and can free up space on the phone once the server confirms it
holds each item.

## Develop

```bash
flutter pub get
flutter run                      # device or simulator; enter the server URL on first launch
flutter build apk                # Android APK
flutter build ios --no-codesign  # iOS app bundle (CI packages it as an unsigned IPA)
```

- `lib/main.dart` — setup/discovery, login sheet, backup screen, tab shell
- `lib/sync_service.dart` — backup + free-up-space logic (server-verified deletion)
- `lib/api.dart` — REST client; `DemoInfo` adapts the UI to the public demo server
- `lib/theme.dart` — design tokens, kept in sync with `../THEME.md`
- `assets/icon/` — launcher icon sources (regenerate everything with `../scripts/make-icons.ps1`)

## Ship

`TESTFLIGHT.md` covers TestFlight and the App Store: the signed build workflow, the
`fastlane/` lanes that push the listing / review info / privacy details and distribute
builds to testers, and what App Review needs.
