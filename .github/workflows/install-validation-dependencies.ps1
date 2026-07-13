function Install-ValidationDependencies {
    param([string]$Token)

    $headers = @{ Accept = 'application/vnd.github+json' }
    if ($Token) { $headers.Authorization = "Bearer $Token" }

    if (-not (Test-Path 'C:\dotnet\dotnet.exe')) {
        $dotnetInstall = Join-Path $env:TEMP 'dotnet-install.ps1'
        Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetInstall
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $dotnetInstall `
            -Channel '8.0' -InstallDir 'C:\dotnet'
        if ($LASTEXITCODE) { throw ".NET installation failed with exit code $LASTEXITCODE" }
    }

    if (-not (Test-Path 'C:\PowerShell\pwsh.exe')) {
        $powerShellRelease = Invoke-RestMethod `
            'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers $headers
        $powerShellArchitecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        $powerShellAsset = $powerShellRelease.assets |
            Where-Object name -Like "PowerShell-*-win-$powerShellArchitecture.zip" | Select-Object -First 1
        if (-not $powerShellAsset) {
            throw "Latest PowerShell release has no win-$powerShellArchitecture archive"
        }
        $powerShellArchive = Join-Path $env:TEMP 'powershell.zip'
        Invoke-WebRequest $powerShellAsset.browser_download_url -OutFile $powerShellArchive
        Expand-Archive $powerShellArchive -DestinationPath 'C:\PowerShell' -Force
    }

    if (-not (Test-Path 'C:\tools\asa.exe')) {
        $packageDirectory = Join-Path $env:TEMP 'asa-pkg'
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
        if ($LASTEXITCODE) {
            throw "Attack Surface Analyzer installation failed with exit code $LASTEXITCODE"
        }
    }
}
