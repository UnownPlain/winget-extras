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

function Get-AddedUninstallRegistryEntry {
    param([Parameter(Mandatory)][string]$SarifPath)

    $sarif = Get-Content $SarifPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($artifact in @($sarif.runs.artifacts)) {
        $properties = $artifact.properties
        if ($properties.ResultType -ne 'REGISTRY' -or $properties.ChangeType -ne 'CREATED') { continue }

        $registry = $properties.Compare
        if ($registry.Key -notmatch '\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\') { continue }

        [pscustomobject]@{
            Key         = $registry.Key
            ProductCode = $registry.Key -replace '^.*\\', ''
            Values      = ConvertTo-RegistryValueMap $registry
        }
    }
}

function Get-WinGetLegalEntitySuffix {
    @(
        'AB', 'AD', 'AG', 'APS', 'AS', 'ASA', 'BV', 'CO', 'COMPANY', 'CORP', 'CORPORATION',
        'CV', 'DOO', 'EV', 'GES', 'GESMBH', 'GMBH', 'HOLDING', 'HOLDINGS', 'INC', 'INCORPORATED',
        'KG', 'KS', 'LIMITED', 'LLC', 'LP', 'LTD', 'LTDA', 'MBH', 'NV', 'PLC', 'PS', 'PTY', 'PVT',
        'SA', 'SARL', 'SC', 'SCA', 'SL', 'SP', 'SPA', 'SRL', 'SRO', 'SUBSIDIARY'
    )
}

function ConvertTo-WinGetNormalizedName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }

    # Match WinGet's display-name normalization closely enough for ARP comparisons.
    # https://github.com/microsoft/winget-cli/blob/b042bf9d06f001657d5857c87327d2114f8811ec/src/AppInstallerCommonCore/NameNormalization.cpp
    $value = $Name.Normalize([Text.NormalizationForm]::FormKC).Trim().ToUpperInvariant()
    if ($value.Length -gt 3) {
        $atPosition = $value.IndexOf('@@', 3, [StringComparison]::Ordinal)
        if ($atPosition -ge 0) { $value = $value.Substring(0, $atPosition) }
    }

    while ($value.Length -ge 2 -and (
            ($value[0] -eq '"' -and $value[-1] -eq '"') -or
            ($value[0] -eq '(' -and $value[-1] -eq ')'))) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    $options = [Text.RegularExpressions.RegexOptions]::IgnoreCase
    $options = $options -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
    $architecturePatterns = @(
        '(^|[^\p{L}\p{Nd}])(?:64[\\/]32|32[\\/]64)[\p{Pd}\p{Pc}\p{Z}]?BITS?(?:\sEDITION)?(?=\P{Nd}|$)'
        '(^|[^\p{L}\p{Nd}])(?:X64|AMD64|X86[\p{Pd}\p{Pc}]64)(?:\sEDITION)?(?=\P{Nd}|$)'
        '(^|[^\p{L}\p{Nd}])(?:X32|X86)(?:\sEDITION)?(?=\P{Nd}|$)'
        '(^|[^\p{L}\p{Nd}])(?:32|64)[\p{Pd}\p{Pc}\p{Z}]?BITS?(?:\sEDITION)?(?=\P{Nd}|$)'
    )
    foreach ($pattern in $architecturePatterns) {
        $value = [regex]::Replace($value, $pattern, '$1', $options)
    }

    $localeEvaluator = [Text.RegularExpressions.MatchEvaluator] {
        param($match)

        try {
            [Globalization.CultureInfo]::GetCultureInfo($match.Value) | Out-Null
            ''
        }
        catch {
            $match.Value
        }
    }
    $localePattern = '(?<![A-Z])(?:[A-Z]{2,3}(?:-(?:CANS|CYRL|LATN|MONG))?-[A-Z]{2})(?![A-Z])(?:-VALENCIA)?'
    $value = [regex]::Replace($value, $localePattern, $localeEvaluator, $options)
    $value = [regex]::Replace($value, '\((KB\d+)\)', '$1', $options)

    $versionPrefix = '(?:V|VER|VERSI(?:O|Ó)N|VERSÃO|VERSIE|WERSJA|BUILD|RELEASE|RC|SP)'
    $cleanupPatterns = @(
        '^\(.*?\)'
        '(\(\s*\)|\[\s*\]|"\s*")'
        '\([CDEF]:\\(?:.+?\\)*[^\s]*\\?\)'
        '"[CDEF]:\\(?:.+?\\)*[^\s]*\\?"'
        '(?:(?:INSTALLED\sAT|IN)\s)?[CDEF]:\\(?:.+?\\)*[^\s]*\\?'
        "(?<!\p{L})(?:$versionPrefix\P{L})?\p{Lu}\p{Nd}+(?:[\p{Po}\p{Pd}\p{Pc}]\p{Nd}+)+"
        "((?<!\p{L})$versionPrefix\P{L}?)?\p{Nd}+([\p{Po}\p{Pd}\p{Pc}]\p{Nd}?(?:RC|B|A|R|SP|K)?\p{Nd}+)+([\p{Po}\p{Pd}\p{Pc}]?[\p{L}\p{Nd}]+)*"
        "(?:FOR\s)?(?<!\p{L})(?:P|R|$versionPrefix)(?:\P{L}|\P{L}\p{L})?(?:\p{Nd}|\.\p{Nd})+(?:RC|B|A|R|V|SP)?\p{Nd}?"
        '\sEN\s*$'
        '\([^()]*\)|\[[^\[\]]*\]'
        '(?:\p{Ps}.*\p{Pe}|".*")'
        '(?<!\p{L})(?:HTTPS?|FTP)://'
        '^[^\p{L}\p{Nd}]+'
        '[^\p{L}\p{Nd}]+$'
    )
    do {
        $previousValue = $value
        foreach ($pattern in $cleanupPatterns) {
            $value = [regex]::Replace($value, $pattern, '', $options)
        }
    } while ($value -ne $previousValue)

    $legalEntitySuffixes = @(Get-WinGetLegalEntitySuffix)
    $tokens = @([regex]::Split($value, '[^\p{L}\p{Nd}+&]+') | Where-Object { $_ })
    $nameTokens = for ($index = 0; $index -lt $tokens.Count; $index++) {
        if ($index -eq 0 -or $tokens[$index] -notin $legalEntitySuffixes) { $tokens[$index] }
    }

    (-join $nameTokens) -replace '[^\p{L}\p{Nd}]', ''
}

function ConvertTo-WinGetNormalizedPublisher {
    param([AllowEmptyString()][string]$Publisher)

    if ([string]::IsNullOrWhiteSpace($Publisher)) { return '' }

    $value = $Publisher.Normalize([Text.NormalizationForm]::FormKC).Trim().ToUpperInvariant()
    $tokens = @([regex]::Split($value, '[^\p{L}\p{Nd}]+') | Where-Object { $_ })
    $legalEntitySuffixes = @(Get-WinGetLegalEntitySuffix)
    $publisherTokens = for ($index = 0; $index -lt $tokens.Count; $index++) {
        if ($index -gt 0 -and $tokens[$index] -in $legalEntitySuffixes) { break }
        $tokens[$index]
    }

    -join $publisherTokens
}

function Format-AppsAndFeaturesEntry {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DisplayName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Publisher,
        [AllowEmptyString()][string]$DisplayVersion,
        [AllowEmptyString()][string]$ProductCode
    )

    $fields = @("DisplayName='$DisplayName'", "Publisher='$Publisher'")
    if ($DisplayVersion) { $fields += "DisplayVersion='$DisplayVersion'" }
    if ($ProductCode) { $fields += "ProductCode='$ProductCode'" }
    $fields -join ', '
}

function Test-AppsAndFeaturesEntries {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Installer,
        [Parameter(Mandatory)]$DefaultLocale,
        [Parameter(Mandatory)][string]$SarifPath,
        [string]$InstallerType
    )

    $effectiveInstallerType = @(
        $Installer.NestedInstallerType
        $Manifest.NestedInstallerType
        $Installer.InstallerType
        $Manifest.InstallerType
        $InstallerType
    ) | Where-Object { $_ } | Select-Object -First 1
    # Keep this aligned with DoesInstallerTypeWriteAppsAndFeaturesEntry in WinGet.
    # https://github.com/microsoft/winget-cli/blob/b042bf9d06f001657d5857c87327d2114f8811ec/src/AppInstallerCommonCore/Manifest/ManifestCommon.cpp
    if ($effectiveInstallerType -notin @('exe', 'inno', 'msi', 'nullsoft', 'wix', 'burn', 'portable')) {
        return $true
    }

    $actualEntries = @(Get-AddedUninstallRegistryEntry -SarifPath $SarifPath)
    $manifestEntries = @($Installer.AppsAndFeaturesEntries ?? $Manifest.AppsAndFeaturesEntries)
    if ($manifestEntries.Count -eq 0) { $manifestEntries = @([pscustomobject]@{}) }

    $unmatchedActualEntries = [Collections.Generic.List[object]]::new()
    $unmatchedActualEntries.AddRange($actualEntries)
    $missingEntries = [Collections.Generic.List[string]]::new()

    foreach ($manifestEntry in $manifestEntries) {
        # WinGet also uses the default locale name and publisher during ARP correlation.
        # https://github.com/microsoft/winget-cli/blob/b042bf9d06f001657d5857c87327d2114f8811ec/src/AppInstallerRepositoryCore/ARPCorrelation.cpp
        $displayName = $manifestEntry.DisplayName ?? $DefaultLocale.PackageName
        $publisher = $manifestEntry.Publisher ?? $DefaultLocale.Publisher
        $displayVersion = $manifestEntry.DisplayVersion
        $productCode = $manifestEntry.ProductCode ?? $Installer.ProductCode ?? $Manifest.ProductCode
        $normalizedName = ConvertTo-WinGetNormalizedName $displayName
        $normalizedPublisher = ConvertTo-WinGetNormalizedPublisher $publisher

        $match = $unmatchedActualEntries | Where-Object {
            $actualName = ConvertTo-WinGetNormalizedName ([string]$_.Values['DisplayName'])
            $actualPublisher = ConvertTo-WinGetNormalizedPublisher ([string]$_.Values['Publisher'])

            $actualName -ceq $normalizedName -and
            $actualPublisher -ceq $normalizedPublisher -and
            (-not $displayVersion -or [string]$_.Values['DisplayVersion'] -ieq $displayVersion) -and
            (-not $productCode -or $_.ProductCode -ieq $productCode)
        } | Select-Object -First 1

        if ($match) {
            $unmatchedActualEntries.Remove($match) | Out-Null
            continue
        }

        $expectedFields = @{
            DisplayName    = $displayName
            Publisher      = $publisher
            DisplayVersion = $displayVersion
            ProductCode    = $productCode
        }
        $missingEntries.Add((Format-AppsAndFeaturesEntry @expectedFields))
    }

    if ($missingEntries.Count -eq 0) {
        Write-Information 'ARP metadata matches the added uninstall registry entries' `
            -InformationAction Continue
        return $true
    }

    $actualDescriptions = @($actualEntries | ForEach-Object {
            $actualFields = @{
                DisplayName    = [string]$_.Values['DisplayName']
                Publisher      = [string]$_.Values['Publisher']
                DisplayVersion = [string]$_.Values['DisplayVersion']
                ProductCode    = $_.ProductCode
            }
            Format-AppsAndFeaturesEntry @actualFields
        })
    if ($actualDescriptions.Count -eq 0) { $actualDescriptions = @('<none>') }

    throw @"
AppsAndFeaturesEntries do not match the added uninstall registry entries.
Expected:
  $($missingEntries -join "`n  ")
Added:
  $($actualDescriptions -join "`n  ")
"@
}
