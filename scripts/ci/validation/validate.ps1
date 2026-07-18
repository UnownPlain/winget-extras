[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$ArtifactName,
    [Parameter(Mandatory)][string]$Architecture,
    [string]$Scope,
    [string]$InstallerType
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'arp.ps1')

function New-Screenshot {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $PSCmdlet.ShouldProcess($Path, 'Capture screenshot')) { return }

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = [System.Drawing.Bitmap]::new($screen.Width, $screen.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
        $bitmap.Save($Path)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Disable-InstallerPrompt {
    # Disable Defender SmartScreen and Mark of the Web prompts on the ephemeral runner.
    $systemPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    $explorerSettings = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'
    $attachmentPolicy = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments'

    New-Item -Path $systemPolicy -Force | Out-Null
    Set-ItemProperty -Path $systemPolicy -Name EnableSmartScreen -Type DWord -Value 0
    Set-ItemProperty -Path $explorerSettings -Name SmartScreenEnabled -Type String -Value Off -ErrorAction SilentlyContinue
    New-Item -Path $attachmentPolicy -Force | Out-Null
    Set-ItemProperty -Path $attachmentPolicy -Name SaveZoneInformation -Value 1
}

function Install-LatestWinGet {
    $wingetDirectory = Join-Path $env:RUNNER_TEMP 'winget'
    $bundle = Join-Path $wingetDirectory 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    $dependencyArchive = Join-Path $wingetDirectory 'DesktopAppInstaller_Dependencies.zip'
    $dependencyRoot = Join-Path $wingetDirectory 'dependencies'

    New-Item -Path $wingetDirectory -ItemType Directory -Force | Out-Null
    gh release download --repo microsoft/winget-cli `
        --pattern (Split-Path $bundle -Leaf) `
        --pattern (Split-Path $dependencyArchive -Leaf) `
        --dir $wingetDirectory

    Expand-Archive -Path $dependencyArchive -DestinationPath $dependencyRoot -Force
    $dependencyDirectory = Join-Path $dependencyRoot $env:RUNNER_ARCH
    $dependencies = @(Get-ChildItem -Path $dependencyDirectory -File | Select-Object -ExpandProperty FullName)
    if ($dependencies.Count -eq 0) {
        throw "WinGet release contains no dependencies for $env:RUNNER_ARCH"
    }

    Add-AppxPackage -Path $bundle `
        -DependencyPath $dependencies `
        -ForceApplicationShutdown `
        -ForceUpdateFromAnyVersion
    Write-Information "Installed latest WinGet: $(winget --version)" -InformationAction Continue
}

function Install-AttackSurfaceAnalyzer {
    $packageDirectory = Join-Path $env:RUNNER_TEMP 'asa-package'
    $toolDirectory = Join-Path $env:RUNNER_TEMP 'asa-tool'
    New-Item $packageDirectory, $toolDirectory -ItemType Directory -Force | Out-Null

    gh release download latest `
        --repo pl4nty/AttackSurfaceAnalyzer `
        --pattern '*.nupkg' `
        --dir $packageDirectory
    $package = Get-ChildItem $packageDirectory -Filter 'Microsoft.CST.AttackSurfaceAnalyzer.CLI.*.nupkg' |
        Select-Object -First 1
    if (-not $package) {
        throw 'Attack Surface Analyzer release does not contain the CLI package'
    }

    $version = $package.BaseName -replace '^Microsoft\.CST\.AttackSurfaceAnalyzer\.CLI\.', ''
    dotnet tool install `
        --tool-path $toolDirectory `
        --add-source $packageDirectory `
        Microsoft.CST.AttackSurfaceAnalyzer.CLI `
        --version $version
    $env:PATH = "$toolDirectory;$env:PATH"
}

function Set-WinGetPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Architecture,
        [string]$Scope,
        [string]$InstallerType
    )

    $settings = @{
        '$schema'            = 'https://aka.ms/winget-settings.schema.json'
        experimentalFeatures = @{
            fonts = $true
        }
        installBehavior      = @{
            preferences = @{
                architectures = @($Architecture)
            }
        }
    }
    if ($Scope) { $settings.installBehavior.preferences.scope = $Scope }
    if ($InstallerType) { $settings.installBehavior.preferences.installerTypes = @($InstallerType) }

    $settingsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
    if (-not $PSCmdlet.ShouldProcess($settingsPath, 'Configure WinGet preferences')) { return }

    $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $settingsPath -Encoding UTF8
    winget settings --enable LocalManifestFiles
    winget settings --enable LocalArchiveMalwareScanOverride
}

function Find-Installer {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Architecture,
        [string]$Scope,
        [string]$InstallerType
    )

    $installer = $Manifest.Installers | Where-Object {
        $effectiveScope = $_.Scope ?? $Manifest.Scope
        $effectiveType = $_.InstallerType ?? $Manifest.InstallerType
        $scopeMatches = if ($Scope) { $effectiveScope -eq $Scope } else { -not $effectiveScope }
        $typeMatches = if ($InstallerType) { $effectiveType -eq $InstallerType } else { -not $effectiveType }

        $_.Architecture -eq $Architecture -and $scopeMatches -and $typeMatches
    } | Select-Object -First 1

    if (-not $installer) {
        throw "No installer matches architecture '$Architecture', scope '$Scope', and type '$InstallerType'"
    }

    $installer
}

function Invoke-WinGetInstall {
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$TimeoutScreenshot
    )

    $process = Start-Process winget -ArgumentList $ArgumentList -PassThru -NoNewWindow
    # Large archives such as Cinebench need longer than two minutes to extract.
    if (-not $process.WaitForExit(5 * 60 * 1000)) {
        try {
            New-Screenshot -Path $TimeoutScreenshot
        }
        catch {
            Write-Warning "Could not capture timeout screenshot: $_"
        }
        finally {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        throw 'Install timed out after 5 minutes'
    }

    $process.ExitCode
}

function Copy-LatestWinGetLog {
    param([Parameter(Mandatory)][string]$Destination)

    $logDirectory = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
    $log = Get-ChildItem -Path $logDirectory -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($log) {
        Copy-Item -Path $log.FullName -Destination $Destination
    }
    else {
        Write-Warning 'WinGet did not create a diagnostic log'
    }
}

function Get-InstalledApplicationPath {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Installer,
        [string]$InstallerType
    )

    $nestedInstallerType = $Installer.NestedInstallerType ?? $Manifest.NestedInstallerType
    if ($nestedInstallerType -eq 'portable') {
        $nestedFiles = @($Installer.NestedInstallerFiles ?? $Manifest.NestedInstallerFiles)
        return $nestedFiles | ForEach-Object { Split-Path $_.RelativeFilePath -Leaf }
    }

    if ($InstallerType -eq 'portable') {
        return @($Installer.Commands) + @($Manifest.Commands) |
            Where-Object { $_ } |
            Select-Object -First 1
    }

    if ($InstallerType -eq 'msix') {
        $packageFamilyName = $Installer.PackageFamilyName ?? $Manifest.PackageFamilyName
        $package = Get-AppxPackage | Where-Object PackageFamilyName -EQ $packageFamilyName | Select-Object -First 1
        if (-not $package) {
            Write-Warning "Could not find installed MSIX package '$packageFamilyName'"
            return $null
        }

        $appxManifest = $package | Get-AppxPackageManifest
        $applicationId = $appxManifest.Package.Applications.Application.Id | Select-Object -First 1
        return "shell:AppsFolder\$packageFamilyName!$applicationId"
    }

    $shortcutDirectories = @(
        "$env:PUBLIC\Desktop"
        "$env:USERPROFILE\Desktop"
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    )
    Get-ChildItem -Path $shortcutDirectories -Recurse -File -Exclude 'Uninstall*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Save-ApplicationScreenshot {
    param(
        [Parameter(Mandatory)][string]$ApplicationPath,
        [Parameter(Mandatory)][string]$ScreenshotPath
    )

    $env:PATH = @(
        [Environment]::GetEnvironmentVariable('PATH', 'Machine')
        [Environment]::GetEnvironmentVariable('PATH', 'User')
    ) -join ';'

    # Arm64 runners can remain on an OOBE screen that covers the desktop.
    # https://github.com/actions/runner-images/issues/14069
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' `
        -Name PrivacyConsentStatus -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Stop-Process -Name WWAHost, FirstLogonAnim -Force -ErrorAction SilentlyContinue

    Write-Information "Starting $ApplicationPath" -InformationAction Continue
    $application = $null
    try {
        # Start-Process cannot use -ErrorAction with shell:AppsFolder paths.
        # https://github.com/PowerShell/PowerShell/issues/10996
        $application = Start-Process $ApplicationPath -PassThru
    }
    catch {
        Write-Warning "Could not track the application process: $_"
    }

    Start-Sleep 10

    # Close the post-OOBE Start menu, show the desktop, then restore only the app window.
    Add-Type 'using System;using System.Runtime.InteropServices;public static class Win{[DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int c);}' -ErrorAction SilentlyContinue
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    (New-Object -ComObject Shell.Application).MinimizeAll()
    if ($application) {
        $application.Refresh()
        [Win]::ShowWindow($application.MainWindowHandle, 9) | Out-Null
    }
    Start-Sleep 1

    New-Screenshot -Path $ScreenshotPath
    if (-not $application) { return }

    if ($application.HasExited) {
        Write-Information "App exited with code $($application.ExitCode) after $($application.ExitTime - $application.StartTime)" `
            -InformationAction Continue
    }
    else {
        Stop-Process -Id $application.Id -ErrorAction SilentlyContinue
    }
}

Install-Module powershell-yaml -Force

$artifactDirectory = Join-Path $env:RUNNER_TEMP 'artifacts'
$manifestDirectory = Split-Path $ManifestPath -Parent
$manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Yaml
$installer = Find-Installer `
    -Manifest $manifest `
    -Architecture $Architecture `
    -Scope $Scope `
    -InstallerType $InstallerType

$defaultLocale = Get-ChildItem -Path $manifestDirectory -Filter '*.locale.*.yaml' |
    ForEach-Object { Get-Content -Path $_.FullName -Raw | ConvertFrom-Yaml } |
    Where-Object ManifestType -EQ defaultLocale |
    Select-Object -First 1
if (-not $defaultLocale.Moniker) {
    throw "Default locale manifest is missing required field 'Moniker'"
}

$screenshotPath = Join-Path $artifactDirectory "$ArtifactName.png"

New-Item -Path $artifactDirectory -ItemType Directory -Force | Out-Null
Disable-InstallerPrompt
Install-LatestWinGet
Install-AttackSurfaceAnalyzer
Set-WinGetPreference -Architecture $Architecture -Scope $Scope -InstallerType $InstallerType

$programFilesBefore = @(Get-ChildItem $env:ProgramFiles -Directory | Select-Object -ExpandProperty FullName)
$programFilesX86Before = @(Get-ChildItem ${env:ProgramFiles(x86)} -Directory | Select-Object -ExpandProperty FullName)
$analyzerArgs = @(
    '--all', '--hives', 'CurrentUser, LocalMachine'
    '--skip-directories', "$env:LOCALAPPDATA\AzureFunctionsTools"
    '--directories', "$env:USERPROFILE\AppData"
)
$wingetArgs = @(
    'install', '--verbose'
    '--manifest', $manifestDirectory
    '--log', (Join-Path $artifactDirectory "$ArtifactName-installer.log")
    '--silent', '--ignore-local-archive-malware-scan'
    '--accept-package-agreements', '--accept-source-agreements'
)

if (-not (Test-Path asa.sqlite)) {
    Write-Information "asa collect --runid baseline $analyzerArgs" -InformationAction Continue
    asa collect --runid baseline $analyzerArgs
}

try {
    $exitCode = Invoke-WinGetInstall -ArgumentList $wingetArgs -TimeoutScreenshot $screenshotPath
    if ($exitCode -eq -1978334972) {
        # Resolve missing package dependencies from the winget-extras source.
        winget source add `
            --name winget-extras `
            --type Microsoft.PreIndexed.Package `
            --arg https://winget.tplant.com.au/cache `
            --accept-source-agreements
        winget source remove --name winget
        $exitCode = Invoke-WinGetInstall -ArgumentList $wingetArgs -TimeoutScreenshot $screenshotPath
    }
}
finally {
    Copy-LatestWinGetLog -Destination (Join-Path $artifactDirectory "$ArtifactName-winget.log")
}

if ($exitCode -ne 0) {
    throw "Install failed with exit code $exitCode"
}

$programFilesAdded = Get-ChildItem $env:ProgramFiles -Directory |
    Select-Object -ExpandProperty FullName |
    Where-Object { $_ -notin $programFilesBefore }
$programFilesX86Added = Get-ChildItem ${env:ProgramFiles(x86)} -Directory |
    Select-Object -ExpandProperty FullName |
    Where-Object { $_ -notin $programFilesX86Before }
$analyzedDirectories = @($analyzerArgs[-1]) + $programFilesAdded + $programFilesX86Added
$analyzerArgs[-1] = $analyzedDirectories -join ','

Write-Information "asa collect --overwrite --runid installed $analyzerArgs" -InformationAction Continue
asa collect --overwrite --runid installed $analyzerArgs
asa export-collect `
    --firstrunid baseline `
    --secondrunid installed `
    --outputsarif `
    --filename (Join-Path $PSScriptRoot 'analyses.json')
$sarifPath = Join-Path $artifactDirectory "$ArtifactName-asa.sarif"
Move-Item baseline_vs_installed_summary.sarif `
    $sarifPath `
    -Force

$applicationPaths = @(Get-InstalledApplicationPath `
        -Manifest $manifest `
        -Installer $installer `
        -InstallerType $InstallerType)
foreach ($applicationPath in $applicationPaths) {
    Save-ApplicationScreenshot `
        -ApplicationPath $applicationPath `
        -ScreenshotPath $screenshotPath
}

$null = Test-AppsAndFeaturesEntries `
    -Manifest $manifest `
    -Installer $installer `
    -DefaultLocale $defaultLocale `
    -SarifPath $sarifPath `
    -InstallerType $InstallerType
