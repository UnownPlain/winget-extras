[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Invoke-Process {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 900
    )

    Write-Host "> $FilePath $($ArgumentList -join ' ')"
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -NoNewWindow
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Write-Warning "$FilePath timed out after $TimeoutSeconds seconds"
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            return $false
        }
        if ($process.ExitCode -notin 0, 1605, 1614, 3010) {
            Write-Warning "$FilePath exited with code $($process.ExitCode)"
            return $false
        }
        return $true
    }
    catch {
        Write-Warning "Could not run ${FilePath}: $_"
        return $false
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

function Remove-InstalledProgram {
    param([Parameter(Mandatory)]$Program)

    # These are part of Windows rather than additions made by runner-images. App
    # Installer is also the WinGet client used by the validation that follows.
    if ($Program.DisplayName -match '^(Microsoft Edge|Microsoft Edge Update|Microsoft Edge WebView2 Runtime|App Installer)$') {
        Write-Host "Keeping Windows component: $($Program.DisplayName)"
        return
    }

    Write-Host "Uninstalling $($Program.DisplayName) $($Program.DisplayVersion)"
    $productCode = $Program.PSChildName
    if ($productCode -match '^\{[0-9A-Fa-f-]{36}\}$') {
        Invoke-Process msiexec.exe @('/x', $productCode, '/qn', '/norestart') | Out-Null
        return
    }

    # WinGet can remove applications that were not installed by WinGet and uses
    # the registered silent-uninstall metadata when it is available.
    $escapedName = $Program.DisplayName.Replace('"', '\"')
    Invoke-Process winget.exe @(
        'uninstall', '--name', "`"$escapedName`"", '--exact', '--silent',
        '--disable-interactivity', '--accept-source-agreements'
    ) | Out-Null
}

Write-Host 'Stopping services installed by runner-images'
@(
    'apache*', 'docker', 'mongodb*', 'mysql*', 'nginx*', 'postgresql*',
    'ServiceFabric*', 'ssh-agent', 'w3svc'
) | ForEach-Object {
    Get-Service -Name $_ -ErrorAction SilentlyContinue |
        Stop-Service -Force -ErrorAction SilentlyContinue
}

if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
    Write-Host 'Removing Chocolatey-managed packages'
    Invoke-Process choco.exe @(
        'uninstall', 'all', '--yes', '--remove-dependencies', '--no-progress',
        '--limit-output'
    ) 1800 | Out-Null
}

# Refresh after Chocolatey has removed its native packages so entries are not
# uninstalled twice.
Get-InstalledPrograms | ForEach-Object { Remove-InstalledProgram $_ }

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
    "$env:ProgramFiles\CMake",
    "$env:ProgramFiles\Git",
    "$env:ProgramFiles\GitHub CLI",
    "$env:ProgramFiles\Java",
    "$env:ProgramFiles\LLVM",
    "$env:ProgramFiles\Microsoft SDKs\Service Fabric",
    "$env:ProgramFiles\MongoDB",
    "$env:ProgramFiles\MySQL",
    "$env:ProgramFiles\nodejs",
    "$env:ProgramFiles\OpenSSL",
    "$env:ProgramFiles\PostgreSQL",
    "$env:ProgramFiles\PowerShell",
    "$env:ProgramFiles\R",
    "${env:ProgramFiles(x86)}\Android",
    "${env:ProgramFiles(x86)}\CMake",
    "${env:ProgramFiles(x86)}\Git",
    "${env:ProgramFiles(x86)}\GitHub CLI",
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio",
    "$env:ProgramFiles\Microsoft Visual Studio",
    "$env:USERPROFILE\.cargo",
    "$env:USERPROFILE\.ghcup",
    "$env:USERPROFILE\.rustup",
    "$env:USERPROFILE\.stack",
    'C:\Users\Default\.cargo',
    'C:\Users\Default\.dotnet\tools',
    'C:\Users\Default\.rustup'
) | Where-Object { $_ } | Select-Object -Unique

foreach ($path in $paths) {
    if (Test-Path -LiteralPath $path) {
        Write-Host "Removing $path"
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Continue
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
    Write-Host "Removing $dotnetRoot"
    Remove-Item -LiteralPath $dotnetRoot -Recurse -Force -ErrorAction Continue
}

Write-Host 'Runner image reset complete'
