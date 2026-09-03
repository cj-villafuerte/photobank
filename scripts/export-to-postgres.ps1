# Redundancy: mirror the desktop app's SQLite database into PostgreSQL.
# Double-click (or run) any time; Postgres ends up an exact copy of SQLite.
# Media files are shared on disk, so only the database rows are copied.
$root = Split-Path -Parent $PSScriptRoot
$py = "$root\server\.venv\Scripts\python.exe"

Write-Host "This REPLACES the Postgres 'photobank' database with the desktop app's current data." -ForegroundColor Yellow
$answer = Read-Host "Continue? (y/N)"
if ($answer -ne "y") { Write-Host "Cancelled."; exit 0 }

Push-Location "$root\server"
& $py dbsync.py --from desktop --to pg --replace
$code = $LASTEXITCODE
Pop-Location

if ($code -eq 0) {
    Write-Host "`nPostgres mirror is up to date. To go back to it later, point .env / the desktop" -ForegroundColor Green
    Write-Host "config at Postgres, or run:  python dbsync.py --from pg --to desktop --replace" -ForegroundColor Green
} else {
    Write-Host "`nExport failed (exit $code)." -ForegroundColor Red
}
Read-Host "Press Enter to close"
