# Photobank one-time setup: venv, dependencies, database, .env, migrations.
# Run from anywhere:  .\scripts\setup.ps1
# Prompts once for the postgres superuser password to create the app role/database.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$psql = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
if (-not (Test-Path $psql)) {
    $psql = (Get-ChildItem "C:\Program Files\PostgreSQL\*\bin\psql.exe" | Select-Object -First 1).FullName
}

Write-Host "== Python venv + dependencies ==" -ForegroundColor Cyan
if (-not (Test-Path "$root\server\.venv")) {
    py -m venv "$root\server\.venv"
}
& "$root\server\.venv\Scripts\python.exe" -m pip install --quiet -r "$root\server\requirements.txt"

Write-Host "== Web dependencies ==" -ForegroundColor Cyan
Push-Location "$root\web"
npm install --no-audit --no-fund
Pop-Location

Write-Host "== Database ==" -ForegroundColor Cyan
$appPassword = $null
if (Test-Path "$root\.env") {
    $envLine = Select-String -Path "$root\.env" -Pattern "^DATABASE_URL=.*://photobank:([^@]+)@" | Select-Object -First 1
    if ($envLine) { $appPassword = $envLine.Matches[0].Groups[1].Value }
}
if (-not $appPassword) {
    $appPassword = -join ((48..57) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
}

$pgCred = Read-Host "Password for the 'postgres' superuser" -AsSecureString
$env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pgCred))
try {
    $roleExists = & $psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_roles WHERE rolname='photobank'"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not connect as 'postgres' - wrong password? Aborting." -ForegroundColor Red
        Write-Host "If you don't know the postgres password, run scripts\fix-db.ps1 as admin instead." -ForegroundColor Yellow
        exit 1
    }
    if ($roleExists -ne "1") {
        & $psql -U postgres -h localhost -v ON_ERROR_STOP=1 -c "CREATE ROLE photobank LOGIN PASSWORD '$appPassword'"
        if ($LASTEXITCODE -ne 0) { exit 1 }
        Write-Host "Created role 'photobank'."
    } else {
        & $psql -U postgres -h localhost -v ON_ERROR_STOP=1 -c "ALTER ROLE photobank LOGIN PASSWORD '$appPassword'"
        if ($LASTEXITCODE -ne 0) { exit 1 }
        Write-Host "Role 'photobank' already exists - password updated."
    }
    $dbExists = & $psql -U postgres -h localhost -tAc "SELECT 1 FROM pg_database WHERE datname='photobank'"
    if ($dbExists -ne "1") {
        & $psql -U postgres -h localhost -v ON_ERROR_STOP=1 -c "CREATE DATABASE photobank OWNER photobank"
        if ($LASTEXITCODE -ne 0) { exit 1 }
        Write-Host "Created database 'photobank'."
    } else {
        Write-Host "Database 'photobank' already exists."
    }
} finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}

Write-Host "== .env ==" -ForegroundColor Cyan
if (-not (Test-Path "$root\.env")) {
    $secretBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($secretBytes)
    $secret = ($secretBytes | ForEach-Object { $_.ToString("x2") }) -join ""
    $storage = "$env:USERPROFILE\photobank-data"
    @(
        "DATABASE_URL=postgresql+asyncpg://photobank:$appPassword@localhost:5432/photobank"
        "DATABASE_URL_SYNC=postgresql+psycopg://photobank:$appPassword@localhost:5432/photobank"
        "STORAGE_ROOT=$storage"
        "SECRET_KEY=$secret"
        "HOST=0.0.0.0"
        "PORT=8000"
        "ALLOW_REGISTRATION=true"
        "SESSION_DAYS=14"
    ) | Out-File -FilePath "$root\.env" -Encoding utf8
    Write-Host "Wrote .env (storage at $storage)."
} else {
    Write-Host ".env already exists - left untouched."
}

Write-Host "== Migrations ==" -ForegroundColor Cyan
Push-Location "$root\server"
& ".\.venv\Scripts\python.exe" -m alembic upgrade head
Pop-Location

Write-Host ""
Write-Host "Setup complete. Next steps:" -ForegroundColor Green
Write-Host "  Development :  .\scripts\dev.ps1   (http://localhost:5173)"
Write-Host "  Production  :  .\scripts\start.ps1 (http://<your-LAN-IP>:8000)"
Write-Host "  Firewall    :  .\scripts\firewall.ps1  (run once, as admin, for LAN access)"
