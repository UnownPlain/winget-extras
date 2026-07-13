$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$work = 'C:\winget-validation'
$shared = '\\host.lan\Data'
$artifacts = Join-Path $work 'artifacts'
$log = Join-Path $work 'bootstrap.log'
$exitCode = 1
New-Item $work, $artifacts -ItemType Directory -Force | Out-Null
Start-Transcript -Path $log -Force

try {
    $source = if (Test-Path (Join-Path $shared 'config.json')) { $shared } else { 'C:\OEM' }
    $config = Get-Content (Join-Path $source 'config.json') -Raw | ConvertFrom-Json
    . (Join-Path $source 'install-validation-dependencies.ps1')
    Install-ValidationDependencies -Token $config.token

    $env:PATH = "C:\tools;C:\dotnet;$env:PATH"
    $env:RUNNER_TEMP = $work
    $env:GITHUB_OUTPUT = Join-Path $work 'github-output.txt'
    $env:GITHUB_TOKEN = $config.token
    $manifest = Get-ChildItem (Join-Path $source 'manifest') -Filter '*.installer.yaml' |
        Select-Object -First 1 -ExpandProperty FullName

    $validationArguments = @(
        '-NoLogo', '-NoProfile', '-File', (Join-Path $source 'validate.ps1'),
        '-ManifestPath', $manifest, '-Arch', $config.arch
    )
    if ($config.scope) { $validationArguments += '-Scope', $config.scope }
    if ($config.installerType) {
        $validationArguments += '-InstallerType', $config.installerType
    }
    & 'C:\PowerShell\pwsh.exe' @validationArguments
    $exitCode = $LASTEXITCODE
}
catch {
    Write-Error $_ -ErrorAction Continue
    $exitCode = 1
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
    $shareDeadline = (Get-Date).AddMinutes(2)
    while (-not (Test-Path $shared) -and (Get-Date) -lt $shareDeadline) { Start-Sleep 5 }
    if (Test-Path $shared) {
        $sharedArtifacts = Join-Path $shared 'artifacts'
        New-Item $sharedArtifacts -ItemType Directory -Force | Out-Null
        Copy-Item "$artifacts\*" $sharedArtifacts -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item $log (Join-Path $sharedArtifacts 'bootstrap.log') -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $work 'github-output.txt') $shared -Force -ErrorAction SilentlyContinue
        Set-Content (Join-Path $shared 'exit-code.txt') -Value $exitCode -Encoding Ascii
    }
}
