[CmdletBinding()]
param(
    [string]$ManifestPath = '',
    [string]$ImportManifest = '',
    [switch]$EnableStartup,
    [switch]$Init,
    [string[]]$WorktreeDirectories = @(),
    [switch]$AddToPath,
    [switch]$DisableAutoUpdate,
    [ValidateSet('SingleWindow','JobWindows')][string]$JobsLayout = 'SingleWindow',
    [string]$UpdateRepo = '',
    [string]$DesktopDirectory = [Environment]::GetFolderPath('Desktop'),
    [string]$StartupDirectory = [Environment]::GetFolderPath('Startup')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwshCommand) { throw 'Agent Fleet requires Windows, PowerShell 7, and Windows Terminal.' }
    $forwardArguments = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath)
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) { $forwardArguments += "-$($entry.Key)" }
        } elseif ($entry.Value -is [array]) {
            if ($entry.Value.Count -gt 0) {
                $forwardArguments += "-$($entry.Key)"
                $forwardArguments += ($entry.Value -join ';')
            }
        } else {
            $forwardArguments += "-$($entry.Key)"
            $forwardArguments += [string]$entry.Value
        }
    }
    & $pwshCommand.Source @forwardArguments
    exit $LASTEXITCODE
}
if (-not $IsWindows) { throw 'Agent Fleet requires Windows, PowerShell 7, and Windows Terminal.' }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $env:LOCALAPPDATA 'AgentFleet/manifest.json'
}
if ($WorktreeDirectories.Count -gt 0) {
    $WorktreeDirectories = @($WorktreeDirectories | ForEach-Object { $_.Split(';', [StringSplitOptions]::RemoveEmptyEntries) })
}

function Resolve-FleetClientExecutable([string]$Client) {
    $candidates = [Collections.Generic.List[string]]::new()
    switch ($Client) {
        'PowerShell' {
            $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
            $candidates.Add((Join-Path $PSHOME 'pwsh.exe'))
        }
        'Terminal' {
            $cmd = Get-Command wt.exe -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
            $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wt.exe'))
        }
        'Codex' {
            $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
            $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs/OpenAI/Codex/bin/codex.exe'))
        }
        'Claude' {
            $cmd = Get-Command claude.exe -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
            $candidates.Add((Join-Path $env:USERPROFILE '.local/bin/claude.exe'))
        }
        'Antigravity' {
            $cmd = Get-Command agy.exe -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
            $candidates.Add((Join-Path $env:LOCALAPPDATA 'agy/bin/agy.exe'))
        }
        'OpenCode' {
            $cmd = Get-Command opencode.exe -ErrorAction SilentlyContinue
            if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source) }
            $candidates.Add((Join-Path $env:APPDATA 'npm/node_modules/@opencode/cli/bin/opencode.exe'))
            $candidates.Add((Join-Path $env:APPDATA 'npm/node_modules/opencode-ai/bin/opencode.exe'))
            $shim = Get-Command opencode.ps1 -ErrorAction SilentlyContinue
            if ($shim -and $shim.Source) {
                $shimDir = Split-Path -Parent $shim.Source
                $candidates.Add((Join-Path $shimDir 'node_modules/@opencode/cli/bin/opencode.exe'))
                $candidates.Add((Join-Path $shimDir 'node_modules/opencode-ai/bin/opencode.exe'))
            }
        }
    }
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-FleetInitWorktrees([string[]]$Explicit) {
    if ($Explicit.Count -gt 0) {
        return @($Explicit | ForEach-Object { [IO.Path]::GetFullPath($_.Trim()) })
    }
    $discovered = [Collections.Generic.List[string]]::new()
    $porcelain = & git -C $PSScriptRoot worktree list --porcelain 2>$null
    if ($LASTEXITCODE -eq 0 -and $porcelain) {
        foreach ($line in @($porcelain)) {
            if ($line -match '^worktree\s+(.+)$') {
                $path = [IO.Path]::GetFullPath($Matches[1].Trim())
                if (Test-Path -LiteralPath $path -PathType Container) { $discovered.Add($path) }
            }
        }
    }
    if ($discovered.Count -gt 1) {
        return @($discovered | Select-Object -Skip 1 -First 4)
    }
    if ($discovered.Count -eq 1) {
        return @($discovered[0])
    }
    $entered = Read-Host 'Enter 1 to 4 Git worktree paths (comma-separated)'
    if ([string]::IsNullOrWhiteSpace($entered)) { return @() }
    return @($entered.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_) })
}

$sourceRoot = Join-Path $PSScriptRoot 'runtime'
. (Join-Path $sourceRoot 'FleetSources.ps1')
. (Join-Path $sourceRoot 'FleetUpdate.ps1')
$release = Read-FleetRelease (Join-Path $PSScriptRoot 'release.json')
$installRoot = Join-Path $env:LOCALAPPDATA 'AgentFleet'
$lockHash = Get-FleetLaunchLockHash $installRoot
$mutex = [Threading.Mutex]::new($false, "Local\AgentFleet.$lockHash.Launch")
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(45000) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Another Fleet launch or installation is still running. Wait before trying again.' }
$commandDirectory = Join-Path $env:USERPROFILE '.local/bin'
$commandPath = Join-Path $commandDirectory 'agent-fleet.cmd'
$aliasPath = Join-Path $commandDirectory 'fleet.cmd'
$receiptPath = Join-Path $installRoot 'installation.json'
$desktopPath = Join-Path $DesktopDirectory 'Agent Fleet.lnk'
$startupPath = Join-Path $StartupDirectory 'Agent Fleet.lnk'
$ownedInstall = Test-Path -LiteralPath $receiptPath
$foundEntries = if (Test-Path -LiteralPath $installRoot) { @(Get-ChildItem -LiteralPath $installRoot -Force) } else { @() }
$onlyManifest = $foundEntries.Count -eq 1 -and $foundEntries[0].FullName -eq (Get-Item -LiteralPath $ManifestPath -ErrorAction SilentlyContinue).FullName
if ($foundEntries.Count -gt 0 -and -not $ownedInstall -and -not $onlyManifest) { throw 'The installation directory already exists without an Agent Fleet receipt.' }
$previous = if ($ownedInstall) { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json } else { $null }
if ($previous -and $previous.InstallRoot -ne $installRoot) { throw 'The installation receipt identifies another directory.' }
if ($previous -and $previous.ReleaseVersion -and ([Version]$release.Version -lt [Version]$previous.ReleaseVersion)) {
    throw 'This checkout release is older than the selected runtime. Use a newer checkout, or use agent-fleet -Rollback explicitly.'
}
if ($Init -and $ImportManifest) { throw 'Specify either -Init or -ImportManifest, not both.' }
if ($Init) {
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
        throw "The manifest already exists: $ManifestPath. Edit it directly or pass another -ManifestPath."
    }
    $detectedPowerShell = Resolve-FleetClientExecutable 'PowerShell'
    if (-not $detectedPowerShell) { throw 'Could not locate pwsh.exe for -Init. Install PowerShell 7 or create manifest.json manually.' }
    $detectedTerminal = Resolve-FleetClientExecutable 'Terminal'
    if (-not $detectedTerminal) { throw 'Could not locate wt.exe for -Init. Install Windows Terminal or create manifest.json manually.' }
    $detectedClients = [ordered]@{}
    foreach ($clientName in @('Codex', 'Claude', 'Antigravity', 'OpenCode')) {
        $resolved = Resolve-FleetClientExecutable $clientName
        if ($resolved) { $detectedClients[$clientName] = $resolved }
    }
    if ($detectedClients.Count -eq 0) {
        throw 'No supported agent CLI (Codex, Claude, Antigravity, OpenCode) was found for -Init.'
    }
    $initWorktrees = @(Get-FleetInitWorktrees $WorktreeDirectories)
    if ($initWorktrees.Count -lt 1 -or $initWorktrees.Count -gt 4) {
        throw 'Configure one to four distinct Git worktree directories for -Init.'
    }
    Assert-FleetDistinctWorktrees $initWorktrees $initWorktrees.Count
    $clientNames = @($detectedClients.Keys)
    $initJobs = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $initWorktrees.Count; $index++) {
        $initJobs.Add([ordered]@{
            Id = "job-$($index + 1)"
            Client = $clientNames[$index % $clientNames.Count]
            Directory = $initWorktrees[$index]
        })
    }
    $generated = [ordered]@{
        DefaultMode = 'Jobs'
        JobsLayout = $JobsLayout
        UpdateRepo = if ([string]::IsNullOrWhiteSpace($UpdateRepo)) { 'fergeley/agent-fleet' } else { $UpdateRepo.Trim() }
        PowerShell = $detectedPowerShell
        Terminal = $detectedTerminal
    }
    foreach ($clientName in $clientNames) {
        $generated[$clientName] = $detectedClients[$clientName]
    }
    $generated['Jobs'] = $initJobs.ToArray()
    $manifestText = $generated | ConvertTo-Json -Depth 6
} elseif ($ImportManifest) {
    $imported = Get-Content -LiteralPath $ImportManifest -Raw | ConvertFrom-Json
    $clean = [ordered]@{
        DefaultMode = 'Jobs'
        JobsLayout = if ($imported.PSObject.Properties.Match('JobsLayout').Count -gt 0 -and $imported.JobsLayout) { [string]$imported.JobsLayout } else { 'SingleWindow' }
        UpdateRepo = if (-not [string]::IsNullOrWhiteSpace($UpdateRepo)) { $UpdateRepo.Trim() } else { 'fergeley/agent-fleet' }
        PowerShell = [string]$imported.PowerShell
        Terminal = [string]$imported.Terminal
    }
    foreach ($clientName in @('Codex', 'Claude', 'Antigravity', 'OpenCode')) {
        if ($imported.PSObject.Properties.Match($clientName).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$imported.$clientName)) {
            $clean[$clientName] = [string]$imported.$clientName
        }
    }
    $clean['Jobs'] = @($imported.Jobs)
    $manifestText = $clean | ConvertTo-Json -Depth 7
} else {
    $manifestText = Get-Content -LiteralPath $ManifestPath -Raw
}
$manifest = $manifestText | ConvertFrom-Json
foreach ($field in @('PowerShell','Terminal')) {
    if ($manifest.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($manifest.$field) -or $manifest.$field.Contains('"')) {
        throw "The manifest field is missing or invalid: $field"
    }
    Assert-FleetAbsolutePath $manifest.$field
}
if ($manifest.PSObject.Properties.Match('DefaultMode').Count -gt 0 -and $manifest.DefaultMode -cne 'Jobs') {
    throw 'Agent Fleet 2.0 supports DefaultMode "Jobs" only.'
}
[void](Get-FleetJobsLayout $manifest)
$jobs = @(Get-FleetJobDefinitions $manifest)
if ($manifest.PowerShell -cmatch '[^\x00-\x7F]') { throw 'The PowerShell path must use ASCII characters only, because the command files are ASCII.' }
if ($manifest.PowerShell.Contains('%')) { throw 'The PowerShell path must not contain a percent sign, because cmd expands it in the command files.' }
$selectedClients = @('PowerShell','Terminal') + @($jobs | ForEach-Object Client | Select-Object -Unique)
$selectedClients = @($selectedClients | Select-Object -Unique)
foreach ($field in $selectedClients) {
    if ($manifest.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($manifest.$field) -or $manifest.$field.Contains('"')) { throw "The manifest field is missing or invalid: $field" }
    Assert-FleetAbsolutePath $manifest.$field
    if (-not (Test-Path -LiteralPath $manifest.$field -PathType Leaf)) { throw "The configured executable is unavailable: $field" }
}
$commandText = @('@echo off', ('"' + $manifest.PowerShell + '" -NoLogo -NoProfile -File "%LOCALAPPDATA%\AgentFleet\Start-Fleet.ps1" %*'), 'exit /b %ERRORLEVEL%') -join "`r`n"
$ownCommand = '^@echo off\r\n"[^"]+" -NoLogo -NoProfile -File "%LOCALAPPDATA%\\AgentFleet\\Start-Fleet\.ps1" %\*\r\nexit /b %ERRORLEVEL%$'
foreach ($target in @($commandPath,$aliasPath)) {
    if ((Test-Path -LiteralPath $target) -and [IO.File]::ReadAllText($target).TrimEnd() -notmatch $ownCommand) {
        throw "An unrelated command already exists: $target"
    }
}
$shell = New-Object -ComObject WScript.Shell
$shortcutArguments = '-NoLogo -NoProfile -WindowStyle Hidden -File "' + (Join-Path $installRoot 'Start-Fleet.ps1') + '" -Quiet'
$startupAlreadyExists = Test-Path -LiteralPath $startupPath
$startupEnabled = [bool]($EnableStartup -or $startupAlreadyExists)
$shortcutTargets = @($desktopPath)
if ($startupEnabled) { $shortcutTargets += $startupPath }
foreach ($target in $shortcutTargets) {
    if (Test-Path -LiteralPath $target) {
        $existing = $shell.CreateShortcut($target)
        if (-not $ownedInstall -or $existing.Arguments -ne $shortcutArguments) {
            throw "An unrelated shortcut already exists: $target"
        }
    }
}
$receipt = [ordered]@{
    InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
    InstallRoot = $installRoot
    Command = $commandPath
    CompatibilityCommand = $aliasPath
    DesktopShortcut = $desktopPath
    StartupShortcut = if ($startupEnabled) { $startupPath } else { $null }
    StartupEnabled = $startupEnabled
    DefaultMode = 'Jobs'
    NoAutomaticTaskPrompt = $true
    UpdateProtocol = [int]$release.Protocol
    ReleaseVersion = $release.Version
    SourceCommit = ''
    AutoUpdateEnabled = if ($DisableAutoUpdate) { $false } elseif ($previous -and $previous.PSObject.Properties.Name -contains 'AutoUpdateEnabled') { [bool]$previous.AutoUpdateEnabled } else { $true }
}
if ($previous -and $previous.UpdateProtocol -eq 2 -and $previous.RuntimeDirectory) {
    if ([Version]$release.Version -gt [Version]$previous.ReleaseVersion) {
        $receipt.PreviousRuntime = [ordered]@{
            UpdateProtocol = $previous.UpdateProtocol
            RuntimeDirectory = $previous.RuntimeDirectory
            ReleaseVersion = $previous.ReleaseVersion
            SourceCommit = $previous.SourceCommit
        }
    } elseif ($previous.PSObject.Properties.Match('PreviousRuntime').Count -gt 0) {
        $receipt.PreviousRuntime = $previous.PreviousRuntime
    }
}
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
if (-not $ownedInstall) { Write-FleetUpdateJson $receiptPath $receipt }
New-Item -ItemType Directory -Path (Join-Path $installRoot 'state') -Force | Out-Null
New-Item -ItemType Directory -Path $commandDirectory -Force | Out-Null
$receipt.RuntimeDirectory = Publish-FleetGeneration -InstallRoot $installRoot -SourceRoot $sourceRoot -Release $release
foreach ($file in @('FleetUpdate.ps1','Start-Fleet.ps1')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $installRoot $file) -Force
}
if ($Init -or $ImportManifest) {
    $manifestDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ManifestPath))
    if (-not [string]::IsNullOrWhiteSpace($manifestDirectory)) {
        New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    }
    [IO.File]::WriteAllText($ManifestPath, $manifestText, [Text.UTF8Encoding]::new($false))
}
[IO.File]::WriteAllText((Join-Path $installRoot 'manifest.json'), $manifestText, [Text.UTF8Encoding]::new($false))
Write-FleetUpdateJson $receiptPath $receipt
foreach ($target in @($commandPath,$aliasPath)) { [IO.File]::WriteAllText($target, ($commandText + "`r`n"), [Text.ASCIIEncoding]::new()) }
if ($AddToPath) {
    $normalizedCmdDir = [IO.Path]::GetFullPath($commandDirectory).TrimEnd('\', '/')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userSegments = if ([string]::IsNullOrWhiteSpace($userPath)) { @() } else { @($userPath.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    $alreadyPresent = $false
    foreach ($segment in $userSegments) {
        try {
            if ([IO.Path]::GetFullPath($segment).TrimEnd('\', '/') -ieq $normalizedCmdDir) { $alreadyPresent = $true; break }
        } catch {
            if ($segment.Trim().TrimEnd('\', '/') -ieq $normalizedCmdDir) { $alreadyPresent = $true; break }
        }
    }
    if (-not $alreadyPresent) {
        $newUserPath = (@($userSegments) + $commandDirectory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    }
    $envSegments = if ([string]::IsNullOrWhiteSpace($env:PATH)) { @() } else { @($env:PATH.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    $inProcess = $false
    foreach ($segment in $envSegments) {
        if ($segment.Trim().TrimEnd('\', '/') -ieq $normalizedCmdDir) { $inProcess = $true; break }
    }
    if (-not $inProcess) {
        $env:PATH = (@($envSegments) + $commandDirectory) -join ';'
    }
}
foreach ($target in $shortcutTargets) {
    $shortcut = $shell.CreateShortcut($target)
    $shortcut.TargetPath = $manifest.PowerShell
    $shortcut.Arguments = $shortcutArguments
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.IconLocation = (Join-Path $env:WINDIR 'System32/cmd.exe') + ',0'
    $shortcut.Description = 'Open or focus Agent Fleet'
    $shortcut.Save()
}
$receipt | ConvertTo-Json
} finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
