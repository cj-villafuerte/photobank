# Development: FastAPI with reload on :8000 + Vite dev server on :5173 (proxies /api).
$root = Split-Path -Parent $PSScriptRoot

$server = Start-Process -PassThru -WorkingDirectory "$root\server" `
    -FilePath "$root\server\.venv\Scripts\python.exe" `
    -ArgumentList "-m", "uvicorn", "app.main:app", "--reload", "--port", "8000"

try {
    Push-Location "$root\web"
    npm run dev
} finally {
    Pop-Location
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
}
