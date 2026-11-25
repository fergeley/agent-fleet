[CmdletBinding()]
param([Parameter(Mandatory)][string]$Version)

$ErrorActionPreference = 'Stop'
if ($Version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'The Fleet release version is invalid.' }
. (Join-Path $PSScriptRoot 'runtime/FleetUpdate.ps1')
$files = [ordered]@{}
foreach ($name in Get-FleetUpdateFiles 2) {
    $path = Join-Path $PSScriptRoot "runtime/$name"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The Fleet release file is missing: $name" }
    $files[$name] = Get-FleetReleaseHash $path
}
$release = [ordered]@{ Protocol = 2; Version = $Version; Files = $files }
Write-FleetUpdateJson (Join-Path $PSScriptRoot 'release.json') $release
Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release.json') -Raw
