# Regenerates all app icons (Windows, macOS, tray, web, iOS, Android) from scripts\make_icons.py.
# Needs server\.venv (Pillow) - run scripts\setup.ps1 first. Downloads the Bricolage
# Grotesque font (SIL OFL) into assets\.fontcache on first use.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$py = "$root\server\.venv\Scripts\python.exe"
if (-not (Test-Path $py)) {
    Write-Host "server\.venv not found - run scripts\setup.ps1 first." -ForegroundColor Red
    exit 1
}
& $py "$root\scripts\make_icons.py"
