[CmdletBinding()]
param(
    [string]$ChangedDirectories,
    [string]$PackageId,
    [string]$PackageVersion
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$manifestDirectories = @(if ($ChangedDirectories) {
        $ChangedDirectories | ConvertFrom-Json | Sort-Object -Unique
    }
    else {
        $relativePath = "$($PackageId.Substring(0, 1).ToLowerInvariant())/$($PackageId.Replace('.', '/'))/$PackageVersion"
        if (Test-Path "fonts/$relativePath") { "fonts/$relativePath" } else { "manifests/$relativePath" }
    })

$entries = @(
    $manifestDirectories | Where-Object { Test-Path $_ } | ForEach-Object {
        Get-ChildItem $_ -Filter '*.installer.yaml' -File | ForEach-Object {
            $manifestPath = (Resolve-Path $_.FullName -Relative) -replace '^\.[\\/]', '' -replace '\\', '/'
            $manifest = yq --output-format=json --indent 0 '.' $_.FullName | ConvertFrom-Json

            $manifest.Installers | ForEach-Object {
                $scope = $_.Scope ?? $manifest.Scope
                $installerType = $_.InstallerType ?? $manifest.InstallerType
                [pscustomobject][ordered]@{
                    manifest = $manifestPath
                    arch     = $_.Architecture
                    scope    = $scope
                    type     = $installerType
                    artifact = (@($manifest.PackageIdentifier, $_.Architecture, $scope, $installerType) | Where-Object { $_ }) -join '-'
                }
            }
        }
    }
) | Sort-Object artifact -Unique

if ($entries.Count -eq 0) {
    $target = if ($ChangedDirectories) { 'the changed manifests' } else { "$PackageId $PackageVersion" }
    throw "No installers found for $target"
}

ConvertTo-Json -InputObject ([ordered]@{ include = @($entries) }) -Compress -Depth 4
