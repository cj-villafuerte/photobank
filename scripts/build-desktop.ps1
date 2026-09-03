# Builds the Photobank desktop app: web UI -> PyInstaller bundle with a native window.
# Output: server\dist\Photobank\Photobank.exe
# "Continue": native tools (npm, pip, pyinstaller) write progress to stderr, which
# PowerShell would otherwise treat as a terminating error. Exit codes are checked instead.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot

Write-Host "== Building web app ==" -ForegroundColor Cyan
Push-Location "$root\web"
npm run build
$webExit = $LASTEXITCODE
Pop-Location
if ($webExit -ne 0) { Write-Host "Web build failed." -ForegroundColor Red; exit 1 }

Write-Host "== Installing build tools ==" -ForegroundColor Cyan
& "$root\server\.venv\Scripts\python.exe" -m pip install --quiet --disable-pip-version-check pyinstaller pywebview pystray 2>$null

Write-Host "== Freezing Photobank.exe ==" -ForegroundColor Cyan
Push-Location "$root\server"
& ".\.venv\Scripts\pyinstaller.exe" --noconfirm --clean --onedir --windowed `
    --name Photobank `
    --add-data "$root\web\dist;web_dist" `
    --collect-all pillow_heif `
    --hidden-import aiosqlite `
    --hidden-import pystray._win32 `
    desktop.py 2>&1 | Where-Object { $_ -match "ERROR|WARNING: .*not found|Building" }
$pyiExit = $LASTEXITCODE
Pop-Location
if ($pyiExit -ne 0) { Write-Host "PyInstaller failed (exit $pyiExit)." -ForegroundColor Red; exit 1 }

$exe = "$root\server\dist\Photobank\Photobank.exe"
if (Test-Path $exe) {
    $size = [math]::Round((Get-ChildItem "$root\server\dist\Photobank" -Recurse | Measure-Object Length -Sum).Sum / 1MB)
    Write-Host ""
    Write-Host "Built: $exe ($size MB total)" -ForegroundColor Green
    Write-Host "Data lives in %LOCALAPPDATA%\Photobank; photos in %USERPROFILE%\Pictures\Photobank."
    Write-Host "ffmpeg (video) and Tesseract (text search) are found automatically if installed."
} else {
    Write-Host "Build failed - no exe produced." -ForegroundColor Red
    exit 1
}
