# Public demo server

A Photobank that anyone can log into - App Review, people deciding whether to install,
you showing it off. Same code as every other server, switched into **demo mode** with
`DEMO_MODE=true`, and small enough for a 0.5 GB RAM / 1 GB disk container.

## What demo mode does

| Area | Behaviour |
|---|---|
| Account | One shared, non-admin account (`DEMO_EMAIL` / `DEMO_PASSWORD`). Registration and password changes are off, so nobody can lock the next visitor out. The web login and the iPhone login sheet prefill it. |
| Library | Generated sample photos (`DEMO_SEED_COUNT`, default 36) with real EXIF dates over the last 14 months, in a few albums. **Read-only**: they can be browsed, favorited, searched, put in albums - not trashed, hidden or deleted (403 with an explanation). |
| Uploads | Images only. Per file `DEMO_MAX_UPLOAD_MB` (12), at most `DEMO_MAX_UPLOADS` (100) live at once and `DEMO_MAX_TOTAL_UPLOAD_MB` (300) across all users. Each upload is deleted `DEMO_UPLOAD_TTL_SECONDS` (60) after it lands; the web grid refreshes itself when that happens. |
| Phone safety | `/api/assets/exists` and `/api/assets/match` never report anything, so a phone can never be told "the server holds this" and free up space by deleting its own copy. The app also hides *Free up space*, retention and background backup on a demo server, and sends only the newest 25 photos per backup run. |
| Hidden | Admin console, redundancy backup, import/export, reveal-in-Explorer, Live Photo videos: all 403. The web Settings page shows profile + a demo note only. mDNS is off. |
| Reset | Every `DEMO_RESET_MINUTES` (60) and at startup: remaining uploads are removed, favorites/hidden/albums on the sample library go back to pristine. |

## Deploy on Railway

1. **New Project → Deploy from GitHub repo** → pick this repository. Railway finds the
   `Dockerfile` and `railway.json` at the root.
2. **Volume**: service → *Settings → Volumes → Add Volume*, mount path `/data`. Without it
   the photos and the SQLite database vanish on every deploy.
3. **Variables** (service → *Variables*):

   | Variable | Value |
   |---|---|
   | `DEMO_MODE` | `true` |
   | `STORAGE_ROOT` | `/data/storage` |
   | `DATABASE_URL` | `sqlite+aiosqlite:////data/photobank.db` |
   | `DATABASE_URL_SYNC` | `sqlite:////data/photobank.db` |
   | `SECRET_KEY` | any long random string (`openssl rand -hex 32`) |
   | `DEMO_PASSWORD` | the demo account's password (shown on the login page - pick something you don't use elsewhere) |
   | `DEMO_EMAIL` | optional, default `demo@photobank.app` |
   | `DEMO_UPLOAD_TTL_SECONDS` | optional, default `60` - long enough to open what you just uploaded, short enough that nothing accumulates |

4. **Domain**: *Settings → Networking → Generate Domain*. The image listens on whatever `PORT`
   is; Railway injects one at runtime (8080 on a fresh service). If the domain dialog asks for
   a target port, either leave it as the injected value or set a `PORT=8000` variable and target
   8000 - a mismatch shows up as a 502 with a healthy-looking deploy log. The URL is HTTPS out
   of the box - required, since the iPhone app only allows plain HTTP on the local network.

   CLI equivalent of steps 1-4 (`npm i -g @railway/cli`, `railway login`):
   `railway init --name photobank-demo` → `railway add --service photobank-demo -v DEMO_MODE=true -v … -v PORT=8000`
   → `railway volume add --mount-path /data` → `railway up --detach` → `railway domain --port 8000`.
5. First boot generates the sample library (a few seconds) - `/api/health` answers once it's
   done and shows `"demo": {...}`.

Resource notes for the small plan: one uvicorn worker, no ffmpeg/tesseract in the image
(videos are refused, text search is empty), seed photos are ~150 KB each. Peak memory is a
thumbnail of a 12 MB image (~150 MB); idle is ~120 MB. Disk: ~15 MB seeds + at most 300 MB
of live uploads, and uploads live for seconds.

## Run it locally

```powershell
$env:DEMO_MODE = "true"
$env:DATABASE_URL = "sqlite+aiosqlite:///C:/tmp/pb-demo/photobank.db"
$env:DATABASE_URL_SYNC = "sqlite:///C:/tmp/pb-demo/photobank.db"
$env:STORAGE_ROOT = "C:/tmp/pb-demo/storage"
Set-Location server; .\.venv\Scripts\python.exe -m uvicorn app.main:app --port 8000
```

## In the App Store review notes

> Demo server: https://<your-railway-domain>  -  the login form is prefilled
> (demo@photobank.app / <DEMO_PASSWORD>). It runs in demo mode: the sample library is
> read-only, uploads are removed automatically after a minute, and "Free up space"
> is disabled against it, so nothing can be deleted from the reviewer's device.
