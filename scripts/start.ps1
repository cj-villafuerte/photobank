# Production: build the web app if needed, run migrations, serve everything on 0.0.0.0.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

# rebuild web/dist when sources are newer than the last build
$dist = "$root\web\dist\index.html"
$needBuild = -not (Test-Path $dist)
if (-not $needBuild) {
    $distTime = (Get-Item $dist).LastWriteTime
    $newest = Get-ChildItem "$root\web\src" -Recurse -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest -and $newest.LastWriteTime -gt $distTime) { $needBuild = $true }
}
if ($needBuild) {
    Write-Host "Building web app..." -ForegroundColor Cyan
    Push-Location "$root\web"
    npm run build
    Pop-Location
}

Push-Location "$root\server"
& ".\.venv\Scripts\python.exe" -m alembic upgrade head

$port = 8000
$envFile = "$root\.env"
if (Test-Path $envFile) {
    $portLine = Select-String -Path $envFile -Pattern "^PORT=(\d+)" | Select-Object -First 1
    if ($portLine) { $port = [int]$portLine.Matches[0].Groups[1].Value }
}

Write-Host ""
Write-Host "Photobank is available on this machine at http://localhost:$port" -ForegroundColor Green
Write-Host "On your LAN, use one of these:" -ForegroundColor Green
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
    ForEach-Object { Write-Host "  http://$($_.IPAddress):$port" -ForegroundColor Green }
Write-Host ""

& ".\.venv\Scripts\python.exe" -m uvicorn app.main:app --host 0.0.0.0 --port $port
Pop-Location
