# Photobank

Self-hosted, Immich-like photo & video library for Windows. FastAPI + PostgreSQL on the server,
a React web app for browsing — usable from any phone/laptop on your home network.

## Features

- Upload photos & videos from any browser (JPEG, PNG, HEIC, WebP, GIF, MP4, MOV, …)
- Automatic EXIF extraction (date taken, GPS, camera), video metadata via ffprobe
- Thumbnails + previews (WebP), generated in the background
- Timeline grouped by month, lazy-loaded; lightbox with video playback
- Duplicate detection (SHA-256 per user)
- Albums, favorites, trash with restore
- Multi-user with per-user libraries; first registered user becomes admin

## Requirements

- Windows 10/11, Python 3.12+ (`py`), Node 18+, PostgreSQL (any recent version, running locally)
- ffmpeg (for video support): `winget install Gyan.FFmpeg`, then open a new terminal

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

- **HTTP only**: sessions use cookies without the `Secure` flag because the LAN runs plain HTTP.
  Don't expose the port to the internet as-is; use a VPN (e.g. Tailscale/WireGuard) for remote access.
- Registration is open by default; set `ALLOW_REGISTRATION=false` in `.env` after your household
  has accounts (admins can still create users from the Admin page).
- Video playback streams the original file — H.264 MP4/MOV plays everywhere; exotic codecs may not.
- Trash keeps files on disk until you empty it or delete items permanently.

## Mobile app (iPhone/Android)

`mobile/` is a Flutter "sync companion": it logs into your server, backs up the
camera roll (skipping anything the server already has, verified by SHA-256), and
its **Free up space** button deletes photos from the phone — but only ones the
server just confirmed it still holds.

**iOS install (sideloading, no Mac needed):** every push touching `mobile/`
builds an unsigned IPA via GitHub Actions (macOS runner). Download the
`photobank-ipa` artifact from the Actions run, then install it with
[Sideloadly](https://sideloadly.io/): plug in the iPhone, drag the IPA in,
sign in with your Apple ID. With a free Apple ID the app expires after 7 days —
re-sideload to renew. On the phone: Settings → General → VPN & Device
Management → trust your developer certificate.

First launch: enter your server's LAN URL (e.g. `http://192.168.1.23:8000`),
log in, grant photo access ("All Photos"). Backups run while the app is open.

**Android:** `flutter build apk` in `mobile/` produces an installable APK directly.

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
server/   FastAPI app (SQLAlchemy models, ingest pipeline, REST API, serves web/dist)
web/      React SPA (Vite + TypeScript + React Query)
mobile/   Flutter sync-companion app (camera-roll backup + free-up-space)
scripts/  PowerShell: setup / dev / start / firewall
```
