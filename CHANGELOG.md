# Photobank — Changelog

All of this shipped on 2026-09-03 (25 commits, ~12.3k lines across 136 files).

## Server (FastAPI + SQLAlchemy)
- Core: multipart upload with SHA-256 dedup, EXIF (date/GPS/camera) + ffprobe metadata,
  WebP thumb/preview worker, month-bucketed timeline, albums, favorites, trash, multi-user
  auth (cookie JWT; first user is admin), admin user management.
- Mobile support: long-lived bearer tokens (`/api/auth/token`), bulk checksum check
  (`/api/assets/exists`), Live Photo video attach/serve, MIME guessing from extension.
- LAN discovery over mDNS (`_photobank._tcp`, IP carried in TXT; AsyncZeroconf).
- Color correctness: ICC→sRGB for stills (Display-P3 HEIC), HDR tone mapping for video frames.
- Hide/unhide, change-password, sort-by-size listing, reveal-in-Explorer.
- Perceptual (dHash) duplicate groups, Tesseract OCR with word boxes + text search, daily stats.
- **SQLite support**: dual-dialect models (portable UUID/TZ types, dialect-aware bucketing and
  upserts), WAL + foreign keys, schema bootstrap; `migrate_pg_to_sqlite.py` snapshot copier.
- Migrations 0001–0004 (Postgres path); ffmpeg/Tesseract auto-located; no-window subprocesses.

## Web app (React + Vite)
- Timeline (lazy month sections), lightbox (video, Live Photo playback, Explorer button),
  multi-select bar (favorite / album / hide / trash), albums, favorites, trash, admin.
- Sort by date or file size with size badges; Settings (profile, password) with Hidden photos
  at the bottom; Duplicates review page; OCR text Search with match highlighting; Dashboard
  (stat tiles, per-day media and storage charts, validated palette).
- `THEME.md` design tokens shared with the mobile app.

## iPhone app (Flutter, sideloaded via GitHub Actions IPA)
- Auto-discovers the server, tap-to-login; backup of the camera roll with per-file progress,
  iCloud-aware fetch with timeouts, hashing progress, newest/oldest-first order, screen wakelock.
- Free up space (server-verified deletion), Live Photo capture + Verify Live Photos repair,
  Library tab (browse by month or size, inline video/Live playback, save to Photos),
  Settings tab with Hidden photos, hide from viewer.
- Background backup (BGTaskScheduler slices), rolling N-month retention, backlog notification.

## Desktop app (Windows)
- `Photobank.exe` (PyInstaller): self-configuring SQLite instance in `%LOCALAPPDATA%\Photobank`,
  embedded server on the LAN, native WebView2 window, minimize-to-tray (server keeps running),
  file logging, port auto-fallback. Built by `scripts\build-desktop.ps1`.

## Ops
- PowerShell scripts: setup / dev / start / firewall (TCP 8000 + UDP 5353) / fix-db / build-desktop.
- CI: macOS runner builds an unsigned IPA on every `mobile/**` push.
