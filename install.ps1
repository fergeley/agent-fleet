[CmdletBinding()]
param(
    [string]$Repo = 'fergeley/agent-fleet',
    [string]$Branch = 'main',
    [string]$Profile = '',
    [string]$ImportManifest = '',
    [string[]]$WorktreeDirectories = @(),
    [switch]$Init,
    [switch]$AddToPath,
    [switch]$EnableStartup,
    [switch]$DisableAutoUpdate,
    [switch]$ForceTakeover,
    [switch]$StageOnly,
    [string]$StageDirectory = ''
)

$ErrorActionPreference = 'Stop'

function Invoke-FleetBootstrapFetch([string]$Uri, [string]$Accept) {
    $headers = @{ 'User-Agent' = 'AgentFleet-Bootstrap/2.1' }
    if ($Accept) { $headers['Accept'] = $Accept }
    $resp = Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 20
    return $resp.Content
}

function Get-FleetBootstrapTextHash([string]$Text) {
    $norm = $Text.Replace("`r`n", "`n")
    if ($norm.Length -gt 0 -and [int]$norm[0] -eq 0xFEFF) { $norm = $norm.Substring(1) }
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($norm)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Invoke-FleetRemoteBootstrap {
    param(
        [string]$Repo,
        [string]$Branch,
        [string]$StageRoot,
        [bool]$RunInstaller = $true,
        [hashtable]$InstallerArgs = @{}
    )
    if ($Repo -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository slug: $Repo" }
    if ($Branch -cnotmatch '^[A-Za-z0-9._/-]+$') { throw "Invalid branch name: $Branch" }

    $commitRaw = Invoke-FleetBootstrapFetch "https://api.github.com/repos/$Repo/commits/$Branch" 'application/vnd.github+json'
    $commitObj = $commitRaw | ConvertFrom-Json
    $sha = ([string]$commitObj.sha).Trim()
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw "Resolved commit SHA is invalid: $sha" }

    $relText = Invoke-FleetBootstrapFetch "https://api.github.com/repos/$Repo/contents/release.json?ref=$sha" 'application/vnd.github.raw+json'
    $rel = $relText | ConvertFrom-Json
    if ([int]$rel.Protocol -ne 2) { throw "Unsupported release protocol: $($rel.Protocol)" }
    if ([string]$rel.Version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
        throw "Invalid release version: $($rel.Version)"
    }

    $runtimeDir = Join-Path $StageRoot 'runtime'
    [void][IO.Directory]::CreateDirectory($runtimeDir)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $StageRoot 'release.json'), $relText, $utf8NoBom)

    $installerText = Invoke-FleetBootstrapFetch "https://api.github.com/repos/$Repo/contents/Install-AgentFleet.ps1?ref=$sha" 'application/vnd.github.raw+json'
    [IO.File]::WriteAllText((Join-Path $StageRoot 'Install-AgentFleet.ps1'), $installerText, $utf8NoBom)

    foreach ($topFile in @('Start-Fleet.ps1', 'FleetUpdate.ps1')) {
        $txt = Invoke-FleetBootstrapFetch "https://api.github.com/repos/$Repo/contents/runtime/$topFile`?ref=$sha" 'application/vnd.github.raw+json'
        [IO.File]::WriteAllText((Join-Path $runtimeDir $topFile), $txt, $utf8NoBom)
    }

    $expectedFiles = @('Fleet.ps1', 'FleetJobs.ps1', 'FleetDispatch.ps1', 'FleetWindow.cs', 'FleetSources.ps1', 'Open-Fleet.ps1', 'README.md')
    foreach ($fileName in $expectedFiles) {
        $prop = $rel.Files.PSObject.Properties.Match($fileName)
        if ($prop.Count -eq 0) { throw "Missing digest in release.json for $fileName" }
        $expectedHash = [string]$rel.Files.$fileName
        if ($expectedHash -cnotmatch '^[A-F0-9]{64}$') { throw "Invalid digest format for $fileName" }
        $content = Invoke-FleetBootstrapFetch "https://api.github.com/repos/$Repo/contents/runtime/$fileName`?ref=$sha" 'application/vnd.github.raw+json'
        $actualHash = Get-FleetBootstrapTextHash $content
        if ($actualHash -cne $expectedHash) {
            throw "SHA-256 verification failed for $fileName (expected $expectedHash, got $actualHash)."
        }
        [IO.File]::WriteAllText((Join-Path $runtimeDir $fileName), $content, $utf8NoBom)
    }

    # Parse every PowerShell file before invoking anything.
    $psFiles = @((Join-Path $StageRoot 'Install-AgentFleet.ps1'))
    foreach ($pf in (Get-ChildItem -LiteralPath $runtimeDir -Filter '*.ps1' -File)) {
        $psFiles += $pf.FullName
    }
    foreach ($pf in $psFiles) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($pf, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            throw "PowerShell syntax check failed for $($pf): $($errors[0].Message)"
        }
    }

    if ($RunInstaller) {
        $instScript = Join-Path $StageRoot 'Install-AgentFleet.ps1'
        & $instScript @InstallerArgs
        if ($LASTEXITCODE -ne 0) { throw "Install-AgentFleet.ps1 exited with code $LASTEXITCODE." }
    }
    return [pscustomobject]@{
        Result = if ($RunInstaller) { 'installed' } else { 'staged' }
        Version = [string]$rel.Version
        Commit = $sha
        StageDirectory = $StageRoot
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ownedTemp = [string]::IsNullOrWhiteSpace($StageDirectory)
    $stage = if ($ownedTemp) { Join-Path ([IO.Path]::GetTempPath()) ('agent-fleet-bootstrap-' + [Guid]::NewGuid().ToString('n')) } else { $StageDirectory }
    [void][IO.Directory]::CreateDirectory($stage)
    $forward = @{}
    if ($Profile) { $forward['Profile'] = $Profile }
    if ($ImportManifest) { $forward['ImportManifest'] = $ImportManifest }
    if ($WorktreeDirectories.Count -gt 0) { $forward['WorktreeDirectories'] = $WorktreeDirectories }
    if ($Init -or (-not $ImportManifest -and $WorktreeDirectories.Count -gt 0)) { $forward['Init'] = $true }
    if ($AddToPath) { $forward['AddToPath'] = $true }
    if ($EnableStartup) { $forward['EnableStartup'] = $true }
    if ($DisableAutoUpdate) { $forward['DisableAutoUpdate'] = $true }
    if ($ForceTakeover) { $forward['ForceTakeover'] = $true }
    try {
        Invoke-FleetRemoteBootstrap -Repo $Repo -Branch $Branch -StageRoot $stage -RunInstaller:(-not $StageOnly) -InstallerArgs $forward
    } finally {
        if ($ownedTemp -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
