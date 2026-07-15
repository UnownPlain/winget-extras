$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$tempRoot = '/dev/shm'
$tempManifests = Join-Path $tempRoot 'manifests'
$tempDependencies = Join-Path $tempRoot 'winget-extras-dependencies'

Remove-Item $tempManifests, $tempDependencies -Recurse -Force -ErrorAction SilentlyContinue
New-Item $tempManifests, $tempDependencies -ItemType Directory -Force | Out-Null

# winget can't resolve dependencies across sources (microsoft/winget-cli#3271), so
# copy each declared winget-pkgs dependency in to be merged alongside our packages.
$installerFiles = @(git ls-files -- 'manifests/*.installer.yaml' 'fonts/*.installer.yaml')
$dependencies = @(
  & yq ea @'
[.]
| map((.Dependencies, .Installers[].Dependencies).PackageDependencies[].PackageIdentifier)
| flatten
| map(select(. != null))
| unique
| .[]
'@ @installerFiles
)

$missingDependencies = @(
  foreach ($dependency in $dependencies) {
    $first = $dependency.Substring(0, 1).ToLowerInvariant()
    $path = "manifests/$first/$($dependency.Replace('.', '/'))"
    $fontPath = $path -replace '^manifests', 'fonts'

    $existingManifest = Get-ChildItem $path, $fontPath -Filter "$dependency.yaml" -File -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
    if ($existingManifest) {
      continue
    }

    [pscustomobject]@{
      Dependency = $dependency
      Path       = $path
    }
  }
)

if ($missingDependencies) {
  $token = $env:GH_TOKEN
  if (-not $token) {
    $token = & gh auth token
    if ($LASTEXITCODE -ne 0) {
      throw 'GitHub authentication is required to resolve dependencies'
    }
  }

  $headers = @{
    Accept                 = 'application/vnd.github+json'
    Authorization          = "Bearer $token"
    'User-Agent'           = 'winget-extras'
    'X-GitHub-Api-Version' = '2026-03-10'
  }

  function Invoke-GitHubTreeQuery {
    param(
      [Parameter(Mandatory)] [object[]] $Items,
      [switch] $IncludeContent
    )

    $definitions = [Collections.Generic.List[string]]::new()
    $definitions.Add('$owner: String!')
    $definitions.Add('$repo: String!')
    $fields = [Collections.Generic.List[string]]::new()
    $variables = @{ owner = 'microsoft'; repo = 'winget-pkgs' }

    for ($index = 0; $index -lt $Items.Count; $index++) {
      $variable = "expression$index"
      $definitions.Add("`$$variable`: String!")
      $variables[$variable] = "master:$($Items[$index].Path)"
      $selection = if ($IncludeContent) {
        'entries { name type object { ... on Blob { text } } }'
      }
      else {
        'entries { name type }'
      }
      $fields.Add("dependency$index`: object(expression: `$$variable) { ... on Tree { $selection } }")
    }

    $query = "query($($definitions -join ', ')) { repository(owner: `$owner, name: `$repo) { $($fields -join ' ') } }"
    $body = @{ query = $query; variables = $variables } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Method Post -Headers $headers -Uri 'https://api.github.com/graphql' -Body $body -ContentType 'application/json'
    if ($response.errors) {
      throw "GitHub dependency query failed: $($response.errors.message -join '; ')"
    }
    $response.data.repository
  }

  $versionTrees = Invoke-GitHubTreeQuery -Items $missingDependencies
  for ($index = 0; $index -lt $missingDependencies.Count; $index++) {
    $item = $missingDependencies[$index]
    $version = $versionTrees."dependency$index".entries |
    Where-Object type -eq 'tree' |
    Select-Object -ExpandProperty name |
    & sort --version-sort |
    Select-Object -Last 1
    if (-not $version) {
      throw "No version found for dependency $($item.Dependency)"
    }
    $item.Path = "$($item.Path)/$version"
  }

  $manifestTrees = Invoke-GitHubTreeQuery -Items $missingDependencies -IncludeContent
  for ($index = 0; $index -lt $missingDependencies.Count; $index++) {
    $item = $missingDependencies[$index]
    $files = $manifestTrees."dependency$index".entries |
    Where-Object { $_.type -eq 'blob' -and $_.name -like '*.yaml' }
    $destination = Join-Path $tempDependencies $item.Path
    New-Item $destination -ItemType Directory -Force | Out-Null
    foreach ($file in $files) {
      [IO.File]::WriteAllText((Join-Path $destination $file.name), $file.object.text)
    }
  }
}

$yqExpression = @'
[.]
| group_by(.PackageIdentifier + "\u0000" + .PackageVersion)[]
| . as $docs
| ($docs | map(select(.ManifestType != "locale")) | .[] as $item ireduce ({}; . * $item))
| .Localization = ($docs | map(select(.ManifestType == "locale") | del(.PackageIdentifier, .PackageVersion, .ManifestType, .ManifestVersion)))
| del(.Localization | select(length == 0))
| .ManifestType = "merged"
| sort_keys(..)
| ... comments=""
'@

$normalizedTempManifests = $tempManifests.Replace('\', '/')
$env:TMP_MANIFESTS = $normalizedTempManifests
$splitExpression = 'strenv(TMP_MANIFESTS) + "/" + .PackageIdentifier + "-" + .PackageVersion + ".yaml"'
$packageGroups = @(
  Get-ChildItem manifests, fonts, $tempDependencies -Filter '*.yaml' -File -Recurse |
  Group-Object DirectoryName
)

$workerCount = [Math]::Min([Environment]::ProcessorCount, $packageGroups.Count)
$shards = [object[]]::new($workerCount)
for ($worker = 0; $worker -lt $workerCount; $worker++) {
  $shards[$worker] = [Collections.Generic.List[string]]::new()
}
for ($index = 0; $index -lt $packageGroups.Count; $index++) {
  $shards[$index % $workerCount].AddRange(
    [string[]]$packageGroups[$index].Group.FullName
  )
}

$shards | ForEach-Object -ThrottleLimit $workerCount -Parallel {
  $env:TMP_MANIFESTS = $using:normalizedTempManifests
  $files = @($_)
  & yq ea --split-exp $using:splitExpression $using:yqExpression @files
}
