$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$shared = '\\host.lan\Data'
$log = 'C:\validation-baseline.log'
Start-Transcript -Path $log -Force

try {
    . 'C:\OEM\install-validation-dependencies.ps1'
    Install-ValidationDependencies
    & 'C:\PowerShell\pwsh.exe' -NoLogo -NoProfile -Command `
        'Install-Module powershell-yaml -Scope CurrentUser -Force'
    if ($LASTEXITCODE) { throw "powershell-yaml installation failed with exit code $LASTEXITCODE" }

    $startup = [Environment]::GetFolderPath('CommonStartup')
    Set-Content (Join-Path $startup 'winget-validation.cmd') -Encoding Ascii -Value @(
        '@echo off',
        'start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\OEM\validation-startup.ps1'
    )

    $deadline = (Get-Date).AddMinutes(5)
    while (-not (Test-Path $shared) -and (Get-Date) -lt $deadline) { Start-Sleep 5 }
    if (-not (Test-Path $shared)) { throw 'Host shared folder did not become available' }
    Copy-Item $log (Join-Path $shared 'baseline.log') -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $shared 'baseline-ready.txt') -Value 'ready' -Encoding Ascii
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
    shutdown.exe /s /t 5 /f
}
