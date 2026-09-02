# Opens the Photobank port for LAN devices. Run ONCE in an elevated (admin) PowerShell.
# Private profile only - the port stays closed on public networks.
$existing = Get-NetFirewallRule -DisplayName "Photobank" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Firewall rule 'Photobank' already exists."
} else {
    New-NetFirewallRule -DisplayName "Photobank" -Direction Inbound -Protocol TCP `
        -LocalPort 8000 -Action Allow -Profile Private | Out-Null
    Write-Host "Firewall rule created: TCP 8000 inbound, Private networks only."
}
