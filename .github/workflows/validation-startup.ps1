$shared = '\\host.lan\Data'
$deadline = (Get-Date).AddMinutes(5)
while (-not (Test-Path (Join-Path $shared 'config.json')) -and (Get-Date) -lt $deadline) {
    Start-Sleep 5
}
if (Test-Path (Join-Path $shared 'config.json')) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $shared 'validate-bootstrap.ps1')
}
