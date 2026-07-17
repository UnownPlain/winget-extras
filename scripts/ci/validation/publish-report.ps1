[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactName,
    [string]$ScreenshotUrl
)

$summary = @(
    "## Validation logs: $ArtifactName"
    ''
)
if ($ScreenshotUrl) {
    $summary += "[Screenshot artifact]($ScreenshotUrl)", ''
}
$summary | Add-Content $env:GITHUB_STEP_SUMMARY

$logPattern = Join-Path $env:RUNNER_TEMP "artifacts\$ArtifactName-*.log"
$logs = Get-ChildItem $logPattern -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName
foreach ($log in $logs) {
    Write-Output "::group::$($log.Name)"
    Get-Content $log
    Write-Output '::endgroup::'

    @(
        "<details><summary>$($log.Name)</summary>"
        ''
        '```text'
    ) | Add-Content $env:GITHUB_STEP_SUMMARY
    Get-Content $log | Add-Content $env:GITHUB_STEP_SUMMARY
    @(
        '```'
        ''
        '</details>'
        ''
    ) | Add-Content $env:GITHUB_STEP_SUMMARY
}
