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
    $config = Get-Content 'C:\OEM\config.json' -Raw | ConvertFrom-Json
    $headers = @{ Accept = 'application/vnd.github+json' }
    if ($config.token) { $headers.Authorization = "Bearer $($config.token)" }

    $dotnetInstall = Join-Path $work 'dotnet-install.ps1'
    Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetInstall
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $dotnetInstall `
        -Channel '8.0' -InstallDir 'C:\dotnet'
    if ($LASTEXITCODE) { throw ".NET installation failed with exit code $LASTEXITCODE" }

    $powerShellRelease = Invoke-RestMethod `
        'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers $headers
    $powerShellArchitecture = if ($config.arch -eq 'arm64') { 'arm64' } else { 'x64' }
    $powerShellAsset = $powerShellRelease.assets |
        Where-Object name -Like "PowerShell-*-win-$powerShellArchitecture.zip" | Select-Object -First 1
    if (-not $powerShellAsset) {
        throw "Latest PowerShell release has no win-$powerShellArchitecture archive"
    }
    $powerShellArchive = Join-Path $work 'powershell.zip'
    Invoke-WebRequest $powerShellAsset.browser_download_url -OutFile $powerShellArchive
    Expand-Archive $powerShellArchive -DestinationPath 'C:\PowerShell' -Force

    $packageDirectory = Join-Path $work 'asa-pkg'
    New-Item $packageDirectory -ItemType Directory -Force | Out-Null
    $asaRelease = Invoke-RestMethod `
        'https://api.github.com/repos/pl4nty/AttackSurfaceAnalyzer/releases/tags/latest' -Headers $headers
    $asaRelease.assets | Where-Object name -Like '*.nupkg' | ForEach-Object {
        Invoke-WebRequest $_.browser_download_url -OutFile (Join-Path $packageDirectory $_.name)
    }
    $cli = Get-ChildItem "$packageDirectory\Microsoft.CST.AttackSurfaceAnalyzer.CLI.*.nupkg" |
        Select-Object -First 1
    if (-not $cli) { throw 'Attack Surface Analyzer release has no CLI NuGet package' }
    $version = $cli.BaseName -replace '^Microsoft\.CST\.AttackSurfaceAnalyzer\.CLI\.', ''
    & 'C:\dotnet\dotnet.exe' tool install --tool-path C:\tools `
        --add-source $packageDirectory Microsoft.CST.AttackSurfaceAnalyzer.CLI --version $version
    if ($LASTEXITCODE) { throw "Attack Surface Analyzer installation failed with exit code $LASTEXITCODE" }

    $env:PATH = "C:\tools;C:\dotnet;$env:PATH"
    $env:RUNNER_TEMP = $work
    $env:GITHUB_OUTPUT = Join-Path $work 'github-output.txt'
    $env:GITHUB_TOKEN = $config.token
    $manifest = Get-ChildItem 'C:\OEM\manifest' -Filter '*.installer.yaml' |
        Select-Object -First 1 -ExpandProperty FullName

    & 'C:\PowerShell\pwsh.exe' -NoLogo -NoProfile -File 'C:\OEM\validate.ps1' `
        -ManifestPath $manifest -Arch $config.arch -Scope $config.scope `
        -InstallerType $config.installerType
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
        Copy-Item (Join-Path $work 'github-output.txt') $shared -Force -ErrorAction SilentlyContinue
        Copy-Item $log $shared -Force -ErrorAction SilentlyContinue
        Set-Content (Join-Path $shared 'exit-code.txt') -Value $exitCode -Encoding Ascii
    }
}
