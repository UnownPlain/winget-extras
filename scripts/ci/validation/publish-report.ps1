[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactName,
    [string]$ScreenshotUrl
)

function ConvertTo-MarkdownCell {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    if ($text.Length -eq 0) { return '<em>empty</em>' }

    [Net.WebUtility]::HtmlEncode($text).
    Replace('|', '&#124;').
    Replace("`r`n", '<br>').
    Replace("`n", '<br>')
}

function ConvertTo-RegistryValueMap {
    param([AllowNull()][object]$Registry)

    $values = @{}
    if ($null -eq $Registry -or $null -eq $Registry.Values) { return $values }

    if ($Registry.Values -is [Collections.IDictionary]) {
        foreach ($name in $Registry.Values.Keys) {
            $values[$name] = $Registry.Values[$name]
        }
        return $values
    }

    foreach ($property in @($Registry.Values.PSObject.Properties)) {
        $values[$property.Name] = $property.Value
    }
    $values
}

function Add-UninstallRegistrySummary {
    param(
        [Parameter(Mandatory)][string]$SarifPath,
        [Parameter(Mandatory)][string]$SummaryPath
    )

    if (-not (Test-Path $SarifPath)) { return }

    $sarif = Get-Content $SarifPath -Raw | ConvertFrom-Json -AsHashtable
    $entries = @(
        foreach ($artifact in @($sarif.runs.artifacts)) {
            $properties = $artifact.properties
            if ($properties.ResultType -ne 'REGISTRY' -or $properties.ChangeType -ne 'CREATED') { continue }

            $registry = $properties.Compare
            if ($registry.Key -notlike '*Microsoft\Windows\CurrentVersion\Uninstall*') { continue }

            [pscustomobject]@{
                Key    = $registry.Key
                Values = ConvertTo-RegistryValueMap $registry
            }
        }
    )

    @('## Added uninstall registry entries', '') | Add-Content $SummaryPath
    if ($entries.Count -eq 0) {
        '_No uninstall registry entries were added._', '' | Add-Content $SummaryPath
        return
    }

    $entryLabel = if ($entries.Count -eq 1) { 'entry' } else { 'entries' }
    "<details open><summary>$($entries.Count) added uninstall registry $entryLabel</summary>", '' |
        Add-Content $SummaryPath
    foreach ($entry in $entries | Sort-Object Key) {
        $key = [Net.WebUtility]::HtmlEncode($entry.Key)
        @(
            "### <code>$key</code>"
            ''
            '| Value | Data |'
            '| --- | --- |'
        ) | Add-Content $SummaryPath
        $entry.Values.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $name = ConvertTo-MarkdownCell $(if ($_.Name) { $_.Name } else { '(Default)' })
            $value = ConvertTo-MarkdownCell $_.Value
            "| $name | $value |"
        } | Add-Content $SummaryPath
        Add-Content $SummaryPath ''
    }
    '</details>', '' | Add-Content $SummaryPath
}

$summary = @(
    "## Validation logs: $ArtifactName"
    ''
)
if ($ScreenshotUrl) {
    $summary += "[Screenshot artifact]($ScreenshotUrl)", ''
}
$summary | Add-Content $env:GITHUB_STEP_SUMMARY

$sarifPath = Join-Path $env:RUNNER_TEMP "artifacts\$ArtifactName-asa.sarif"
Add-UninstallRegistrySummary -SarifPath $sarifPath -SummaryPath $env:GITHUB_STEP_SUMMARY

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
