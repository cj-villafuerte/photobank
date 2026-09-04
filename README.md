# Photobank

**Your photos, on your computer, backed up from your phone — no cloud, no Docker, no setup.**

Photobank is a self-hosted photo & video library in the spirit of Immich, built for people
who want to double-click an app instead of running containers. A desktop app (Windows / macOS)
runs the server; the web UI works from any device on your network; the iPhone app finds the
server automatically, backs up your camera roll, and can free space on the phone safely.

Free and open source (MIT), made by **CJ Villafuerte**. No telemetry — see [PRIVACY.md](PRIVACY.md).

**Website:** https://cj-villafuerte.github.io/photobank/ — downloads, how it works, features (source in [`site/`](site/)).

## Try it

**Live demo:** https://photobank-demo-production.up.railway.app — the login is prefilled.
The sample library is read-only and anything you upload is removed after a minute.
The iPhone app can point at it too (enter the address manually on the first screen).

## Download

Grab the latest build from **[Releases](https://github.com/cj-villafuerte/photobank/releases)**:

| Platform | File | Notes |
|---|---|---|
| Windows 10/11 | `Photobank-Windows.zip` | unzip, run `Photobank.exe` (SmartScreen: More info → Run anyway) |
| macOS 13+ | `Photobank-macOS.zip` | unzip, drag to Applications, right-click → Open the first time |
| iPhone | TestFlight / App Store (coming) | meanwhile: `Photobank-iOS-unsigned.ipa`, sideloaded with [Sideloadly](https://sideloadly.io) |

Optional helpers for video thumbnails and text search: `winget install Gyan.FFmpeg` +
`winget install UB-Mannheim.TesseractOCR` (Windows) or `brew install ffmpeg tesseract` (macOS).

## Features

- Upload from any browser or from the phone: JPEG, PNG, HEIC, WebP, GIF, MP4, MOV, Live Photos
- EXIF (date, GPS, camera) and video metadata; WebP thumbnails with correct colors (ICC → sRGB, HDR-aware)
- Timeline by month, favorites, albums, trash with restore, hidden photos
- Search text inside photos (Tesseract OCR), find visually similar duplicates, storage dashboard
- Multi-user with private libraries; on the desktop app the computer's user is the passwordless administrator
- Redundancy backup to a second disk/NAS with a portable JSON export; SQLite ⇄ PostgreSQL mirroring
- Public **demo mode** for showing it off or App Review (see [DEMO.md](DEMO.md))

---

The sections below cover running the server from source (FastAPI + PostgreSQL or SQLite)
and developing the apps.

## Requirements

- Windows 10/11 or macOS, Python 3.12+ (`py`), Node 18+
- PostgreSQL (any recent version) for the from-source setup below; the desktop app uses SQLite
- ffmpeg for video support: `winget install Gyan.FFmpeg`, then open a new terminal

## Setup (once)

```powershell
.\scripts\setup.ps1
```

Prompts for your `postgres` superuser password, then creates the `photobank` role + database,
installs Python/npm dependencies, writes `.env` with a generated secret, and runs migrations.

Photos are stored under `%USERPROFILE%\photobank-data` by default — change `STORAGE_ROOT`
in `.env` to use another drive (do this before uploading anything).

## Run

```powershell
.\scripts\start.ps1     # production: builds web app, serves everything on port 8000
```

The script prints the LAN URLs (e.g. `http://192.168.1.23:8000`) to open from other devices.
For LAN access, allow the port through the firewall once, from an **admin** PowerShell:

```powershell
.\scripts\firewall.ps1
```

For development with hot reload:

```powershell
.\scripts\dev.ps1       # Vite on http://localhost:5173, API proxied to :8000
```

### Start automatically at logon (optional)

```powershell
Register-ScheduledTask -TaskName "Photobank" -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
  -Action (New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PWD\scripts\start.ps1`"")
```

## Notes & limitations

- **HTTP only on the LAN**: sessions use cookies without the `Secure` flag because the home
  network runs plain HTTP. Don't expose the port to the internet as-is; use a VPN (e.g.
  Tailscale/WireGuard) for remote access. Behind HTTPS (as the demo is) everything works too.
- Registration is open by default; set `ALLOW_REGISTRATION=false` in `.env` after your household
  has accounts (administrators can still create members from the Console).
- Video playback streams the original file — H.264 MP4/MOV plays everywhere; exotic codecs may not.
- Trash keeps files on disk until you empty it or delete items permanently.

## Mobile app (iPhone/Android)

`mobile/` is a Flutter "sync companion": it logs into your server, backs up the
camera roll (skipping anything the server already has, verified by SHA-256), and
its **Free up space** button deletes photos from the phone — but only ones the
server just confirmed it still holds. See [mobile/README.md](mobile/README.md).

**iOS install (sideloading, no Mac needed):** every push touching `mobile/`
builds an unsigned IPA via GitHub Actions (macOS runner). Download the
`photobank-ipa` artifact from the Actions run, then install it with
[Sideloadly](https://sideloadly.io/): plug in the iPhone, drag the IPA in,
sign in with your Apple ID. With a free Apple ID the app expires after 7 days —
re-sideload to renew. On the phone: Settings → General → VPN & Device
Management → trust your developer certificate.

First launch: pick the server the app found, or enter its address (e.g. `http://192.168.1.23:8000`),
log in, grant photo access ("All Photos"). Backups run while the app is open.

**Android:** `flutter build apk` in `mobile/` produces an installable APK directly.

**TestFlight / App Store:** see [mobile/TESTFLIGHT.md](mobile/TESTFLIGHT.md) — a signed build
workflow plus fastlane lanes for the listing, review info, privacy details and tester distribution.

## Desktop app

`Photobank.exe` / `Photobank.app` runs the server (SQLite) with a native window and a
tray / menu-bar icon; closing the window keeps the server running for phone syncs. The
computer's user is the administrator (no password) and sees only the Console (server,
accounts, redundancy backup); members sign in with theirs, and "View as member…" shows a
member's library inside the same window, exactly as that member sees it (no administrator
controls) - "Sign out" brings the administrator straight back to the Console.

- **Windows:** `.\scripts\build-desktop.ps1` → `server\dist\Photobank\Photobank.exe`
- **macOS:** built by GitHub Actions (`Build macOS desktop app` workflow) → download
  `photobank-macos` artifact → unzip → drag `Photobank.app` to Applications. First launch:
  right-click → Open (unsigned app). Install helpers with `brew install ffmpeg tesseract`.
  Data lives in `~/Library/Application Support/Photobank`, photos in `~/Pictures/Photobank`.
- Or locally on a Mac: `bash scripts/build-desktop.sh`.
- **Signed & notarized macOS builds** (no right-click → Open): add two repository secrets and
  every macOS build is signed with the hardened runtime and notarized by Apple, then stapled.
  `MAC_DEV_ID_P12_BASE64` — a *Developer ID Application* certificate exported from Xcode
  (Settings → Accounts → Manage Certificates → `+` → Developer ID Application, then
  right-click → Export as `.p12`; `base64 -i cert.p12 | pbcopy`) and `MAC_DEV_ID_P12_PASSWORD`.
  Notarization reuses the App Store Connect API key secrets from `mobile/TESTFLIGHT.md`.
  Locally: `MAC_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/build-desktop.sh`.
- **Icons:** `.\scripts\make-icons.ps1` regenerates every app icon (exe/.icns/tray, web favicon +
  home-screen icons, iOS/Android launcher PNGs) from the one design in `scripts/make_icons.py`.

## Database redundancy (SQLite ⇄ PostgreSQL)

The desktop app runs on SQLite; PostgreSQL can be kept as a mirror in case the
SQLite file ever has problems. Media files are shared on disk, so only rows move.

```powershell
.\scripts\export-to-postgres.ps1        # mirror desktop SQLite -> Postgres (replace)
```

Under the hood: `server\dbsync.py --from <src> --to <dst> (--replace | --merge)`
where `<src>/<dst>` are `desktop`, `pg`, a `.db` path, or a SQLAlchemy URL.
`--merge` only adds rows missing in the target (safe for reconciling two
databases that both received uploads); `--replace` makes an exact copy.
Recover from Postgres with `--from pg --to desktop --replace`.

## Layout

```
server/     FastAPI app (models, ingest pipeline, REST API, demo mode, desktop entry point; serves web/dist)
web/        React SPA (Vite + TypeScript + React Query)
mobile/     Flutter app (camera-roll backup + free-up-space + library) and fastlane/ release lanes
assets/     app icon sources and generated .ico / .icns
scripts/    PowerShell: setup / dev / start / firewall / build-desktop / make-icons
Dockerfile  server image (used by the public demo on Railway)
```

See [CHANGELOG.md](CHANGELOG.md) for what changed when, and [THEME.md](THEME.md) for the design language.
