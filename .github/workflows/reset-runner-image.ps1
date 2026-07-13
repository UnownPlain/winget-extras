[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$quarantineSuffix = [Guid]::NewGuid().ToString('N')

function Move-ToQuarantine {
    param([Parameter(Mandatory)][string]$Path)

    Write-Host "Quarantining $Path"
    try {
        $leaf = (Get-Item -LiteralPath $Path -ErrorAction Stop).Name
        $newName = ".$leaf.runner-image-removed-$quarantineSuffix"
        Rename-Item -LiteralPath $Path -NewName $newName -Force -ErrorAction Stop
    }
    catch {
        Write-Host "Taking ownership of protected path $Path"
        & takeown.exe /f $Path /a /r /d Y | Out-Null
        & icacls.exe $Path /grant '*S-1-5-32-544:(OI)(CI)F' /t /c /q | Out-Null
        try {
            Rename-Item -LiteralPath $Path -NewName $newName -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not quarantine ${Path}: $_"
        }
    }
}

function Get-InstalledPrograms {
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty $registryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and
            $_.SystemComponent -ne 1 -and
            -not $_.ParentKeyName -and
            $_.ReleaseType -notin 'Hotfix', 'Security Update', 'Update Rollup', 'Update'
        } |
        Sort-Object PSChildName -Unique
}

Write-Host 'Stopping services installed by runner-images'
@(
    'apache*', 'docker', 'mongodb*', 'mysql*', 'nginx*', 'postgresql*',
    'ServiceFabric*', 'ssh-agent', 'w3svc'
) | ForEach-Object {
    Get-Service -Name $_ -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $_.Name | Out-Null
    }
}

# Native uninstallers take 15-20 minutes on hosted images. These runners are
# disposable, so remove registrations and quarantine payloads at their source.
$programs = @(Get-InstalledPrograms)
$installLocations = $programs | ForEach-Object {
    # Keep Windows components and the WinGet client used by validation.
    if ($_.DisplayName -match '^(Microsoft Edge|Microsoft Edge Update|Microsoft Edge WebView2 Runtime|App Installer)$') {
        Write-Host "Keeping Windows component: $($_.DisplayName)"
        return
    }

    Write-Host "Removing registration: $($_.DisplayName) $($_.DisplayVersion)"
    if ($_.InstallLocation) {
        [Environment]::ExpandEnvironmentVariables($_.InstallLocation).TrimEnd('\')
    }
    Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Removing portable tools and language caches installed by runner-images'
$paths = @(
    $env:AGENT_TOOLSDIRECTORY,
    'C:\actionarchivecache',
    'C:\aliyun-cli',
    'C:\Android',
    'C:\apache24',
    'C:\azureCli',
    'C:\azureDevOpsCli',
    'C:\cabal',
    'C:\cobertura-2.1.1',
    'C:\ghcup',
    'C:\image',
    'C:\mingw64',
    'C:\Miniconda',
    'C:\Modules',
    'C:\msys64',
    'C:\mysql',
    'C:\nginx',
    'C:\npm',
    'C:\post-generation',
    'C:\ProgramData\chocolatey',
    'C:\ProgramData\docker',
    'C:\ProgramData\kind',
    'C:\ProgramData\m2',
    'C:\PostgreSQL',
    'C:\selenium',
    'C:\SeleniumWebDrivers',
    'C:\tools',
    'C:\vcpkg',
    "$env:ProgramFiles\Android",
    "$env:ProgramFiles\Amazon",
    "$env:ProgramFiles\CMake",
    "$env:ProgramFiles\Docker",
    "$env:ProgramFiles\Eclipse Adoptium",
    "$env:ProgramFiles\GitHub CLI",
    "$env:ProgramFiles\Java",
    "$env:ProgramFiles\LLVM",
    "$env:ProgramFiles\Microsoft SDKs\Service Fabric",
    "$env:ProgramFiles\Microsoft SQL Server",
    "$env:ProgramFiles\MongoDB",
    "$env:ProgramFiles\MySQL",
    "$env:ProgramFiles\nodejs",
    "$env:ProgramFiles\OpenSSL",
    "$env:ProgramFiles\PostgreSQL",
    "$env:ProgramFiles\PowerShell",
    "$env:ProgramFiles\R",
    "${env:ProgramFiles(x86)}\Android",
    "${env:ProgramFiles(x86)}\CMake",
    "${env:ProgramFiles(x86)}\GitHub CLI",
    "${env:ProgramFiles(x86)}\Microsoft SDKs",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio",
    "${env:ProgramFiles(x86)}\Windows Kits",
    "$env:ProgramFiles\Microsoft Visual Studio",
    "$env:USERPROFILE\.cargo",
    "$env:USERPROFILE\.ghcup",
    "$env:USERPROFILE\.rustup",
    "$env:USERPROFILE\.stack",
    'C:\Users\Default\.cargo',
    'C:\Users\Default\.dotnet\tools',
    'C:\Users\Default\.rustup'
)

$protectedPaths = @(
    'C:\',
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    $env:CommonProgramFiles,
    ${env:CommonProgramFiles(x86)},
    $env:SystemRoot,
    $env:USERPROFILE,
    $env:RUNNER_TEMP,
    $env:GITHUB_WORKSPACE
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

# actions/checkout resolves this path again during its post-job cleanup.
$protectedPaths += @(
    "$env:ProgramFiles\Git",
    "${env:ProgramFiles(x86)}\Git"
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

$protectedPrefixes = @(
    $env:SystemRoot,
    $env:USERPROFILE,
    $env:RUNNER_TEMP,
    $env:GITHUB_WORKSPACE
) | Where-Object { $_ } | ForEach-Object { "$($_.TrimEnd('\'))\" }

$safeInstallLocations = $installLocations | Where-Object {
    $candidate = $_.TrimEnd('\')
    $candidate -notin $protectedPaths -and
    -not ($protectedPrefixes | Where-Object { $candidate.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
}
$paths = (@($paths) + @($safeInstallLocations)) | Where-Object { $_ } | Select-Object -Unique

foreach ($path in $paths) {
    $path = $path.TrimEnd('\')
    if ($path -notin $protectedPaths -and $path.Length -gt 3 -and (Test-Path -LiteralPath $path)) {
        Move-ToQuarantine $path
    }
}

@(
    "$env:SystemRoot\System32\docker-credential-wincred.exe",
    "$env:SystemRoot\System32\docker.exe"
) | Remove-Item -Force -ErrorAction SilentlyContinue

# The validation uses a private runtime under RUNNER_TEMP. The image-wide SDKs
# and frameworks can therefore be removed with the rest of the developer image.
$dotnetRoot = Join-Path $env:ProgramFiles 'dotnet'
if (Test-Path -LiteralPath $dotnetRoot) {
    Move-ToQuarantine $dotnetRoot
}

Write-Host 'Runner image reset complete'
