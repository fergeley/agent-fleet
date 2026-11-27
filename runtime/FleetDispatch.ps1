function Get-FleetGitStatus([string]$Directory) {
    $empty = [pscustomobject]@{
        State = 'unavailable'
        Branch = $null
        Head = $null
        DirtyCount = $null
        Ahead = $null
        Behind = $null
    }
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $empty
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('-C', $Directory, 'status', '--porcelain=v2', '--branch')) {
        [void]$start.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(3000)) {
            $process.Kill($true)
            return $empty
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { return $empty }
    } catch {
        return $empty
    } finally {
        if ($started -and -not $process.HasExited) { try { $process.Kill($true) } catch { } }
        $process.Dispose()
    }
    $branch = $null
    $head = $null
    $ahead = $null
    $behind = $null
    $dirty = 0
    foreach ($rawLine in ($stdout -split "\r?\n")) {
        $line = $rawLine.TrimEnd()
        if (-not $line) { continue }
        if ($line.StartsWith('# branch.oid ', [StringComparison]::Ordinal)) {
            $oid = $line.Substring(13).Trim()
            if ($oid -and $oid -ne '(initial)') { $head = $oid }
        } elseif ($line.StartsWith('# branch.head ', [StringComparison]::Ordinal)) {
            $branch = $line.Substring(14).Trim()
        } elseif ($line.StartsWith('# branch.ab ', [StringComparison]::Ordinal)) {
            if ($line -match '^\# branch\.ab \+(\d+) -(\d+)$') {
                $ahead = [int]$Matches[1]
                $behind = [int]$Matches[2]
            }
        } elseif (-not $line.StartsWith('#', [StringComparison]::Ordinal)) {
            $dirty++
        }
    }
    [pscustomobject]@{
        State = 'observed'
        Branch = $branch
        Head = $head
        DirtyCount = $dirty
        Ahead = $ahead
        Behind = $behind
    }
}

function Get-FleetClaudeSessions([string]$ClaudeExecutable, [int]$TimeoutMilliseconds = 5000) {
    $empty = [pscustomobject]@{ State = 'unavailable'; Sessions = @() }
    if ([string]::IsNullOrWhiteSpace($ClaudeExecutable) -or -not (Test-Path -LiteralPath $ClaudeExecutable -PathType Leaf)) {
        return $empty
    }
    try {
        if ((Get-Item -LiteralPath $ClaudeExecutable).Length -eq 0) { return $empty }
    } catch {
        return $empty
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $ClaudeExecutable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('agents', '--json', '--all')) { [void]$start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            return $empty
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) { return $empty }
        $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        $sessions = if ($null -eq $parsed) { @() } else { @($parsed) }
        return [pscustomobject]@{ State = 'observed'; Sessions = $sessions }
    } catch {
        return $empty
    } finally {
        if ($started -and -not $process.HasExited) { try { $process.Kill($true) } catch { } }
        $process.Dispose()
    }
}

function Assert-FleetNoReparseAncestors([string]$Path, [string]$StopAt = '') {
    $cursor = [IO.Path]::GetFullPath($Path)
    $stopNorm = if ([string]::IsNullOrWhiteSpace($StopAt)) { '' } else { [IO.Path]::GetFullPath($StopAt).TrimEnd('\') }
    while ($cursor) {
        $probe = if ($cursor.Length -gt 3) { $cursor.TrimEnd('\') } else { $cursor }
        $item = Get-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Path contains a reparse point: $probe"
        }
        if ($stopNorm -and $probe.TrimEnd('\').Equals($stopNorm, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [IO.Path]::GetDirectoryName($probe)
        if (-not $parent -or $parent -eq $probe) { break }
        $cursor = $parent
    }
}

function Assert-FleetSafeRelativeCopyPath([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw 'Worktree copy path cannot be empty.' }
    $trimmed = $RelativePath.Trim()
    if ([IO.Path]::IsPathRooted($trimmed) -or $trimmed.StartsWith('\') -or $trimmed.StartsWith('/') -or $trimmed.Contains(':')) {
        throw "Worktree copy path must be relative to the repository root: $trimmed"
    }
    if ($trimmed.Contains('*') -or $trimmed.Contains('?')) {
        throw "Worktree copy path cannot contain wildcards: $trimmed"
    }
    $segments = $trimmed -split '[/\\]'
    foreach ($seg in $segments) {
        if ([string]::IsNullOrEmpty($seg) -or $seg -eq '.' -or $seg -eq '..' -or $seg.Equals('.git', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Worktree copy path contains a blocked segment: $trimmed"
        }
    }
    return ($segments -join [IO.Path]::DirectorySeparatorChar)
}

function Get-FleetRelativeCopyPaths([string]$RepoRoot, $Manifest = $null, [bool]$AllowIncludeFile = $false) {
    $raw = [Collections.Generic.List[string]]::new()
    if ($null -ne $Manifest -and (Test-FleetProperty $Manifest 'WorktreeCopyFiles') -and $null -ne $Manifest.WorktreeCopyFiles) {
        if ($Manifest.WorktreeCopyFiles -is [string] -or $Manifest.WorktreeCopyFiles -isnot [Array]) {
            throw 'The WorktreeCopyFiles manifest field must be an array of relative file paths.'
        }
        foreach ($entry in $Manifest.WorktreeCopyFiles) {
            if ($entry -isnot [string]) { throw 'The WorktreeCopyFiles entries must be strings.' }
            $raw.Add($entry)
        }
    }
    if ($AllowIncludeFile) {
        $includePath = Join-Path $RepoRoot '.worktreeinclude'
        if (Test-Path -LiteralPath $includePath) {
            $item = Get-Item -LiteralPath $includePath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'The .worktreeinclude file cannot be a reparse point.'
            }
            if ($item.PSIsContainer -or $item.Length -gt 65536) {
                throw 'The .worktreeinclude file is invalid or exceeds 64 KiB.'
            }
            foreach ($line in (Get-Content -LiteralPath $includePath)) {
                $clean = $line.Trim()
                if (-not $clean -or $clean.StartsWith('#', [StringComparison]::Ordinal)) { continue }
                $raw.Add($clean)
            }
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $normalized = [Collections.Generic.List[string]]::new()
    foreach ($item in $raw) {
        $rel = Assert-FleetSafeRelativeCopyPath $item
        if ($seen.Add($rel)) {
            $normalized.Add($rel)
        }
    }
    if ($normalized.Count -gt 64) {
        throw "Worktree copy list exceeds 64 files ($($normalized.Count))."
    }
    return $normalized.ToArray()
}

function Copy-FleetWorktreeFiles([string]$RepoRoot, [string]$TargetWorktree, [string[]]$RelativePaths) {
    $copied = [Collections.Generic.List[string]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    if ($RelativePaths.Count -eq 0) {
        return [pscustomobject]@{ Copied = @(); Skipped = @() }
    }
    $canonRepo = Get-FleetFinalDirectoryPath $RepoRoot
    $canonTarget = Get-FleetFinalDirectoryPath $TargetWorktree
    Assert-FleetNoReparseAncestors $canonTarget $canonTarget

    foreach ($rel in $RelativePaths) {
        $normRel = Assert-FleetSafeRelativeCopyPath $rel
        $src = Join-Path $canonRepo $normRel
        if (-not (Test-Path -LiteralPath $src)) {
            $skipped.Add([pscustomobject]@{ Path = $rel; Reason = 'missing' })
            continue
        }
        $srcItem = Get-Item -LiteralPath $src -Force
        if ($srcItem.PSIsContainer) {
            throw "Worktree copy entry must be a file, not a directory: $rel"
        }
        Assert-FleetNoReparseAncestors $src $canonRepo
        if ($srcItem.Length -gt 10485760) {
            throw "Worktree copy file exceeds the 10 MiB limit: $rel"
        }
        $srcParentCanon = Get-FleetFinalDirectoryPath ([IO.Path]::GetDirectoryName($src))
        if (-not ($srcParentCanon.Equals($canonRepo, [StringComparison]::OrdinalIgnoreCase) -or
            $srcParentCanon.StartsWith(($canonRepo + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase))) {
            throw "Worktree copy source escapes the repository root: $rel"
        }
        $dst = Join-Path $canonTarget $normRel
        $dstParent = [IO.Path]::GetDirectoryName($dst)
        Assert-FleetNoReparseAncestors $dst $canonTarget
        if (Test-Path -LiteralPath $dst) {
            $skipped.Add([pscustomobject]@{ Path = $rel; Reason = 'exists' })
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($dstParent)) {
            [void][IO.Directory]::CreateDirectory($dstParent)
        }
        [IO.File]::Copy($src, $dst, $false)
        $copied.Add($rel)
    }
    [pscustomobject]@{ Copied = $copied.ToArray(); Skipped = $skipped.ToArray() }
}

function New-FleetWorktree([string]$Repository, [string]$Path, [string]$BaseRef = 'main', [string]$Branch = '', [switch]$Lock,
    $Manifest = $null, [switch]$AllowWorktreeInclude) {
    Assert-FleetAbsolutePath $Repository
    Assert-FleetAbsolutePath $Path
    if ([string]::IsNullOrWhiteSpace($BaseRef) -or $BaseRef.Trim().StartsWith('-', [StringComparison]::Ordinal)) {
        throw "Invalid BaseRef: $BaseRef"
    }
    if (-not [string]::IsNullOrWhiteSpace($Branch) -and $Branch.Trim().StartsWith('-', [StringComparison]::Ordinal)) {
        throw "Invalid Branch: $Branch"
    }
    if (-not (Test-Path -LiteralPath $Repository -PathType Container)) {
        throw "The repository directory is unavailable: $Repository"
    }
    $fullTarget = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $fullTarget) {
        throw "The target worktree path already exists: $fullTarget"
    }
    Assert-FleetNoReparseAncestors $fullTarget
    $repoTop = (& git -C $Repository rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoTop)) {
        throw "The path is not a Git repository: $Repository"
    }
    $repoTopFull = [IO.Path]::GetFullPath($repoTop.Trim()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($fullTarget.StartsWith(($repoTopFull + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or
        $fullTarget.Equals($repoTopFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Worktree path must be outside the repository: $fullTarget"
    }
    $commonGitDirRaw = (& git -C $Repository rev-parse --git-common-dir 2>$null)
    $copyRoot = $repoTopFull
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commonGitDirRaw)) {
        $resolvedCommon = if ([IO.Path]::IsPathFullyQualified($commonGitDirRaw.Trim())) { $commonGitDirRaw.Trim() } else { [IO.Path]::GetFullPath((Join-Path $Repository $commonGitDirRaw.Trim())) }
        $commonParent = Split-Path -Parent $resolvedCommon.TrimEnd('\', '/')
        if ($commonParent -and (Test-Path -LiteralPath $commonParent -PathType Container)) {
            $copyRoot = $commonParent
        }
    }

    $useInclude = [bool]($AllowWorktreeInclude -or ($null -ne $Manifest -and (Test-FleetProperty $Manifest 'AllowWorktreeInclude') -and [bool]$Manifest.AllowWorktreeInclude))
    $copyPaths = @(Get-FleetRelativeCopyPaths $copyRoot $Manifest $useInclude)

    $worktreeList = @(& git -C $Repository worktree list --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Could not list existing Git worktrees.' }
    foreach ($line in $worktreeList) {
        if (-not ([string]$line).StartsWith('worktree ', [StringComparison]::Ordinal)) { continue }
        $existing = [IO.Path]::GetFullPath(([string]$line).Substring(9).Trim()).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ($fullTarget.Equals($existing, [StringComparison]::OrdinalIgnoreCase) -or
            $fullTarget.StartsWith(($existing + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Worktree path must be outside existing worktrees: $fullTarget"
        }
    }
    $parentDir = Split-Path -Parent $fullTarget
    if (-not [string]::IsNullOrWhiteSpace($parentDir)) {
        [void][IO.Directory]::CreateDirectory($parentDir)
    }
    $gitArgs = @('-C', $Repository, 'worktree', 'add')
    if ($Lock) { $gitArgs += '--lock' }
    if (-not [string]::IsNullOrWhiteSpace($Branch)) {
        $gitArgs += @('-b', $Branch, $fullTarget, $BaseRef)
    } else {
        $gitArgs += @('--detach', $fullTarget, $BaseRef)
    }
    $addOutput = & git @gitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git worktree add failed: $($addOutput | Out-String)"
    }
    $copyReport = Copy-FleetWorktreeFiles $copyRoot $fullTarget $copyPaths
    [pscustomobject]@{
        Result = 'created'
        Path = $fullTarget
        Branch = if ([string]::IsNullOrWhiteSpace($Branch)) { '(detached)' } else { $Branch }
        BaseRef = $BaseRef
        Locked = [bool]$Lock
        CopiedFiles = @($copyReport.Copied)
        SkippedFiles = @($copyReport.Skipped)
    }
}

function Get-FleetKnownWorktrees([string]$InstallRoot) {
    $dirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gitDirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($InstallRoot) -or -not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        return [pscustomobject]@{ Directories = $dirs; GitDirectories = $gitDirs }
    }
    $manifests = [Collections.Generic.List[string]]::new()
    $rootManifest = Join-Path $InstallRoot 'manifest.json'
    if (Test-Path -LiteralPath $rootManifest -PathType Leaf) { $manifests.Add($rootManifest) }
    $profilesDir = Join-Path $InstallRoot 'profiles'
    if (Test-Path -LiteralPath $profilesDir -PathType Container) {
        foreach ($p in @(Get-ChildItem -LiteralPath $profilesDir -Directory -ErrorAction SilentlyContinue)) {
            $pm = Join-Path $p.FullName 'manifest.json'
            if (Test-Path -LiteralPath $pm -PathType Leaf) { $manifests.Add($pm) }
        }
    }
    foreach ($mp in $manifests) {
        try {
            $m = Read-FleetSharedText $mp | ConvertFrom-Json -ErrorAction Stop
            foreach ($job in @($m.Jobs)) {
                if ($job.Directory -is [string] -and (Test-Path -LiteralPath $job.Directory -PathType Container)) {
                    [void]$dirs.Add((Get-FleetFinalDirectoryPath $job.Directory))
                    $gd = (& git -C $job.Directory rev-parse --absolute-git-dir 2>$null)
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gd)) {
                        [void]$gitDirs.Add((Get-FleetFinalDirectoryPath $gd.Trim()))
                    }
                }
            }
        } catch { }
    }
    $stateDirs = [Collections.Generic.List[string]]::new()
    $rootState = Join-Path $InstallRoot 'state'
    if (Test-Path -LiteralPath $rootState -PathType Container) { $stateDirs.Add($rootState) }
    if (Test-Path -LiteralPath $profilesDir -PathType Container) {
        foreach ($p in @(Get-ChildItem -LiteralPath $profilesDir -Directory -ErrorAction SilentlyContinue)) {
            $ps = Join-Path $p.FullName 'state'
            if (Test-Path -LiteralPath $ps -PathType Container) { $stateDirs.Add($ps) }
        }
    }
    foreach ($sd in $stateDirs) {
        foreach ($jf in @(Get-ChildItem -LiteralPath $sd -Filter 'job-*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $ev = Read-FleetSharedText $jf.FullName | ConvertFrom-Json -ErrorAction Stop
                if ($ev.Directory -is [string] -and (Test-Path -LiteralPath $ev.Directory -PathType Container)) {
                    [void]$dirs.Add((Get-FleetFinalDirectoryPath $ev.Directory))
                }
                if ($ev.GitDirectory -is [string] -and (Test-Path -LiteralPath $ev.GitDirectory)) {
                    [void]$gitDirs.Add((Get-FleetFinalDirectoryPath $ev.GitDirectory))
                }
            } catch { }
        }
    }
    [pscustomobject]@{ Directories = $dirs; GitDirectories = $gitDirs }
}

function Invoke-FleetOpenTab($Manifest, [string]$InstallRoot, [string]$Profile = '', [string]$Client,
    [string]$Directory = '', [string]$Repository = '', [string]$Branch = '', [string]$BaseRef = 'main',
    [string]$TabTitle = '', [string]$TabColor = '', [string[]]$ClientArgs = $null,
    [switch]$Lock, [switch]$AllowWorktreeInclude, [switch]$PlanOnly) {
    if ($Client -cnotin @('Codex', 'Claude', 'Antigravity', 'OpenCode')) {
        throw "OpenTab client is unsupported: $Client"
    }
    if (-not (Test-FleetProperty $Manifest $Client) -or [string]::IsNullOrWhiteSpace([string]$Manifest.$Client)) {
        throw "The selected client is not configured in manifest.json: $Client"
    }
    $executable = [string]$Manifest.$Client
    Assert-FleetAbsolutePath $executable
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "The selected client executable is unavailable: $Client"
    }
    if ($executable.Contains(';')) { throw "Client executable path cannot contain a semicolon: $executable" }
    if ($TabColor -and $TabColor -cnotmatch '^#[0-9A-Fa-f]{6}$') {
        throw "The -TabColor value must be a #RRGGBB hex color: $TabColor"
    }
    if ($TabTitle -and $TabTitle.Contains(';')) {
        throw 'The -TabTitle cannot contain a semicolon.'
    }
    if (-not [string]::IsNullOrWhiteSpace($Branch) -and $Branch.Trim().StartsWith('-', [StringComparison]::Ordinal)) {
        throw "Invalid Branch: $Branch"
    }
    if ([string]::IsNullOrWhiteSpace($BaseRef) -or $BaseRef.Trim().StartsWith('-', [StringComparison]::Ordinal)) {
        throw "Invalid BaseRef: $BaseRef"
    }
    # Get-FleetClientArguments returns its array as one object. Assign it as it is: @() would nest it, and the
    # nested array would reach Windows Terminal as one argument.
    $resolvedArgs = Get-FleetClientArguments $Client $ClientArgs
    foreach ($a in $resolvedArgs) {
        if ($a.Contains(';')) { throw 'Client arguments passed to -OpenTab cannot contain a semicolon.' }
    }

    $createdWorktree = $null
    $targetDir = $Directory
    $newWorktree = [string]::IsNullOrWhiteSpace($targetDir)
    if ($newWorktree) {
        if ([string]::IsNullOrWhiteSpace($Branch) -or [string]::IsNullOrWhiteSpace($Repository)) {
            throw '-OpenTab requires either -Directory or both -Repository and -Branch.'
        }
        Assert-FleetAbsolutePath $Repository
        $repoTop = (& git -C $Repository rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoTop)) {
            throw "The path is not a Git repository: $Repository"
        }
        $repoFull = [IO.Path]::GetFullPath($repoTop.Trim()).TrimEnd('\')
        $repoParent = Split-Path -Parent $repoFull
        $repoName = Split-Path -Leaf $repoFull
        $slug = ($Branch -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
        if ([string]::IsNullOrWhiteSpace($slug)) { throw "Could not derive worktree folder name from branch: $Branch" }
        $targetDir = Join-Path $repoParent "$repoName-$slug"
    } else {
        Assert-FleetAbsolutePath $targetDir
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            throw "The -OpenTab directory is unavailable: $targetDir"
        }
    }

    if ($targetDir.Contains(';')) {
        throw "The -OpenTab directory cannot contain a semicolon: $targetDir"
    }
    $stateDir = Get-FleetStateDirectory $InstallRoot $Profile
    $liveWindows = [ordered]@{}
    if (('FleetWindow' -as [type]) -and (Test-Path -LiteralPath $stateDir -PathType Container)) {
        foreach ($instFile in @(Get-ChildItem -LiteralPath $stateDir -Filter 'job-*.instance.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $ev = Read-FleetSharedText $instFile.FullName | ConvertFrom-Json -ErrorAction Stop
                if ((Test-FleetProperty $ev 'Layout') -and $ev.Layout -ceq 'SingleWindow' -and (Test-FleetProperty $ev 'WindowProperty')) {
                    $handles = @([FleetWindow]::Find($ev.WindowProperty))
                    foreach ($h in $handles) {
                        $liveWindows[[long]$h] = $ev.WindowName
                    }
                }
            } catch { }
        }
    }
    if ($liveWindows.Count -gt 1) {
        throw 'Multiple live SingleWindow Agent Fleet windows are open. Close extras before using -OpenTab.'
    }
    $windowTarget = if ($liveWindows.Count -eq 1) { 'existing' } else { 'new' }
    $windowName = if ($liveWindows.Count -eq 1) { @($liveWindows.Values)[0] } else { 'new' }
    $effectiveTitle = if (-not [string]::IsNullOrWhiteSpace($TabTitle)) {
        $TabTitle.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($Branch)) {
        "$Client | $Branch"
    } else {
        "$Client | $(Split-Path -Leaf $targetDir.TrimEnd('\'))"
    }
    # Refuse the tab before the worktree exists, so that a plan fails as the run would
    # and a refused tab leaves no worktree or branch behind.
    Assert-FleetTerminalArgument (@($windowName, $effectiveTitle, $targetDir) + $resolvedArgs)
    if ($newWorktree -and -not $PlanOnly) {
        $createdWorktree = New-FleetWorktree -Repository $repoFull -Path $targetDir -BaseRef $BaseRef -Branch $Branch -Lock:$Lock -Manifest $Manifest -AllowWorktreeInclude:$AllowWorktreeInclude
        $targetDir = $createdWorktree.Path
    }

    $targetGitDir = ''
    if (Test-Path -LiteralPath $targetDir -PathType Container) {
        $gdRaw = (& git -C $targetDir rev-parse --absolute-git-dir 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gdRaw)) {
            throw "The -OpenTab directory is not a Git worktree: $targetDir"
        }
        $targetGitDir = Get-FleetFinalDirectoryPath $gdRaw.Trim()
        $known = Get-FleetKnownWorktrees $InstallRoot
        if ($known.GitDirectories.Contains($targetGitDir)) {
            throw "The worktree is already owned by a configured or bound Agent Fleet job: $targetDir"
        }
    }

    $wtArgs = [Collections.Generic.List[string]]::new()
    $wtArgs.AddRange([string[]]@('-w', $windowName, 'new-tab'))
    if ($TabColor) { $wtArgs.AddRange([string[]]@('--tabColor', $TabColor)) }
    $wtArgs.AddRange([string[]]@('--title', $effectiveTitle, '--suppressApplicationTitle', '-d', $targetDir, $executable))
    foreach ($arg in $resolvedArgs) { $wtArgs.Add($arg) }

    if (-not $PlanOnly) {
        Start-FleetTerminal $Manifest.Terminal $wtArgs.ToArray()
    }
    [pscustomobject]@{
        Result = if ($PlanOnly) { 'planned' } else { 'opened' }
        WindowTarget = $windowTarget
        WindowName = $windowName
        Title = $effectiveTitle
        Client = $Client
        Directory = $targetDir
        Arguments = $wtArgs.ToArray()
        Worktree = $createdWorktree
    }
}

function Remove-FleetWorktree([string]$Path, [string]$BaseRef = '', [string]$InstallRoot = $PSScriptRoot, [switch]$DryRun, [switch]$Force) {
    Assert-FleetAbsolutePath $Path
    $fullTarget = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $fullTarget -PathType Container)) {
        throw "The worktree directory does not exist: $fullTarget"
    }
    $targetItem = Get-Item -LiteralPath $fullTarget -Force
    if ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to remove a reparse-point worktree path: $fullTarget"
    }
    $canonTarget = Get-FleetFinalDirectoryPath $fullTarget

    # Guard 2: linked worktree check (never remove main repository checkout).
    $gitDirRaw = (& git -C $canonTarget rev-parse --absolute-git-dir 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitDirRaw)) {
        throw "The path is not a Git worktree: $canonTarget"
    }
    $commonDirRaw = (& git -C $canonTarget rev-parse --git-common-dir 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDirRaw)) {
        throw "Could not resolve Git common directory: $canonTarget"
    }
    $resolvedCommon = if ([IO.Path]::IsPathFullyQualified($commonDirRaw.Trim())) { $commonDirRaw.Trim() } else { [IO.Path]::GetFullPath((Join-Path $canonTarget $commonDirRaw.Trim())) }
    $canonGitDir = Get-FleetFinalDirectoryPath $gitDirRaw.Trim()
    $canonCommonDir = Get-FleetFinalDirectoryPath $resolvedCommon
    if ($canonGitDir.Equals($canonCommonDir, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove the main Git repository checkout: $canonTarget"
    }

    $commonParent = Split-Path -Parent $canonCommonDir
    $wtList = @(& git -C $commonParent worktree list --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect repository worktree list.' }
    $foundEntry = $false
    $isLocked = $false
    $inMatchedEntry = $false
    foreach ($line in $wtList) {
        $text = [string]$line
        if ($text.StartsWith('worktree ', [StringComparison]::Ordinal)) {
            $wtPath = Get-FleetFinalDirectoryPath ([IO.Path]::GetFullPath($text.Substring(9).Trim()))
            $inMatchedEntry = $wtPath.Equals($canonTarget, [StringComparison]::OrdinalIgnoreCase)
            if ($inMatchedEntry) { $foundEntry = $true }
        } elseif ($inMatchedEntry -and ($text -eq 'locked' -or $text.StartsWith('locked ', [StringComparison]::Ordinal))) {
            $isLocked = $true
        }
    }
    if (-not $foundEntry) {
        throw "Directory is not registered as a linked worktree of ${commonParent}: $canonTarget"
    }

    # Guard 3: not bound in any root or profile manifest/state.
    $known = Get-FleetKnownWorktrees $InstallRoot
    if ($known.GitDirectories.Contains($canonGitDir) -or $known.Directories.Contains($canonTarget)) {
        throw "Refusing to remove a worktree owned by a configured or active Agent Fleet job: $canonTarget"
    }

    # Guard 4: not CWD or ancestor of CWD.
    $cwdCanon = Get-FleetFinalDirectoryPath ((Get-Location).Path)
    if ($cwdCanon.Equals($canonTarget, [StringComparison]::OrdinalIgnoreCase) -or
        $cwdCanon.StartsWith(($canonTarget + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove the current working directory or its ancestor: $canonTarget"
    }

    # Guard 5: clean working tree unless -Force.
    $porcelain = @(& git -C $canonTarget status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect Git status for $canonTarget" }
    $isDirty = $porcelain.Count -gt 0
    if ($isDirty -and -not $Force) {
        throw "Worktree has uncommitted changes ($($porcelain.Count) entries). Commit/discard them or pass -Force."
    }

    # Guard 6: no unpushed or unmerged commits unless -Force.
    $wtHead = (& git -C $canonTarget rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wtHead)) {
        throw "Could not resolve HEAD for $canonTarget"
    }
    $wtHead = $wtHead.Trim()
    $upstream = (& git -C $canonTarget rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $unpushedCount = 0
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($upstream)) {
        $cntRaw = (& git -C $canonTarget rev-list --count '@{u}..HEAD' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $cntRaw -match '^\d+$') { $unpushedCount = [int]$cntRaw }
        if ($unpushedCount -gt 0 -and -not $Force) {
            throw "Worktree has $unpushedCount unpushed commit(s) ahead of $($upstream.Trim()). Push or pass -Force."
        }
    }

    $mergeTarget = ''
    if (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
        if ($BaseRef.Trim().StartsWith('-', [StringComparison]::Ordinal)) { throw "Invalid BaseRef: $BaseRef" }
        $resolvedRef = (& git -C $commonParent rev-parse --verify "$($BaseRef.Trim())^{commit}" 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "BaseRef could not be resolved in repository: $BaseRef" }
        $mergeTarget = $BaseRef.Trim()
    } else {
        foreach ($candidate in @('origin/HEAD', 'refs/heads/main', 'refs/heads/master', 'refs/heads/develop', 'HEAD')) {
            $null = (& git -C $commonParent rev-parse --verify "$candidate^{commit}" 2>$null)
            if ($LASTEXITCODE -eq 0) { $mergeTarget = $candidate; break }
        }
    }
    $merged = $false
    if ($mergeTarget) {
        $null = (& git -C $commonParent merge-base --is-ancestor $wtHead $mergeTarget 2>$null)
        $merged = ($LASTEXITCODE -eq 0)
    }
    if (-not $merged -and -not $Force) {
        throw "Worktree HEAD ($($wtHead.Substring(0,8))) is not merged into $mergeTarget. Merge/push it or pass -Force."
    }

    $commands = [Collections.Generic.List[string]]::new()
    if ($isLocked) { $commands.Add("git -C `"$commonParent`" worktree unlock `"$canonTarget`"") }
    $rmCmd = if ($Force) { "git -C `"$commonParent`" worktree remove --force `"$canonTarget`"" } else { "git -C `"$commonParent`" worktree remove `"$canonTarget`"" }
    $commands.Add($rmCmd)

    if ($DryRun) {
        return [pscustomobject]@{
            Result = 'dry-run'
            Path = $canonTarget
            Locked = $isLocked
            Dirty = $isDirty
            UnpushedCommits = $unpushedCount
            MergedInto = if ($merged) { $mergeTarget } else { $null }
            Commands = $commands.ToArray()
        }
    }

    if ($isLocked) {
        $unlockOut = & git -C $commonParent worktree unlock $canonTarget 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git worktree unlock failed: $($unlockOut | Out-String)" }
    }
    $rmArgs = @('-C', $commonParent, 'worktree', 'remove')
    if ($Force) { $rmArgs += '--force' }
    $rmArgs += $canonTarget
    $rmOut = & git @rmArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git worktree remove failed: $($rmOut | Out-String)" }

    [pscustomobject]@{
        Result = 'removed'
        Path = $canonTarget
        WasLocked = $isLocked
        Forced = [bool]$Force
        MergedInto = if ($merged) { $mergeTarget } else { $null }
    }
}

function Invoke-FleetProcessSync([string]$Executable, [string]$WorkingDirectory, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in $Arguments) { [void]$start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout.GetAwaiter().GetResult()
            Stderr = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

# cmd.exe parses the command line of a .cmd or .bat file again, so text in a prompt such as & or %VAR% would run or
# expand there. Dispatch and Queue pass text from the caller, so they start only a program file.
function Assert-FleetDirectExecutable([string]$Executable, [string]$Client) {
    if ([IO.Path]::GetExtension($Executable) -notin @('.exe', '.com')) {
        throw "Dispatch and Queue need the $Client program file (.exe), not a script or shim such as a .cmd file: $Executable"
    }
}

function Invoke-FleetDispatch($Manifest, [string]$Client, [string]$Directory, [string]$Prompt,
    [string]$Model = '', [string]$Name = '', [string]$InstallRoot = $PSScriptRoot, [string]$Profile = '') {
    if ($Client -cnotin @('Claude', 'Codex')) {
        throw "Dispatch supports Claude or Codex only: $Client"
    }
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        throw 'Dispatch requires a non-empty -Prompt.'
    }
    Assert-FleetAbsolutePath $Directory
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "The dispatch directory is unavailable: $Directory"
    }
    $executable = [string]$Manifest.$Client
    Assert-FleetAbsolutePath $executable
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "The selected client is unavailable: $Client"
    }
    Assert-FleetDirectExecutable $executable $Client
    if ($Client -ceq 'Claude') {
        # Claude reads an argument that starts with - as an option, so such a prompt would not reach the session.
        if ($Prompt.TrimStart().StartsWith('-')) { throw 'A Claude dispatch prompt cannot start with -. Start it with a word.' }
        $argsList = [Collections.Generic.List[string]]::new()
        $argsList.Add('--bg')
        if (-not [string]::IsNullOrWhiteSpace($Model)) {
            $argsList.Add('--model')
            $argsList.Add($Model)
        }
        if (-not [string]::IsNullOrWhiteSpace($Name)) {
            $argsList.Add('--name')
            $argsList.Add($Name)
        }
        $argsList.Add($Prompt)
        $res = Invoke-FleetProcessSync $executable $Directory $argsList.ToArray()
        if ($res.ExitCode -ne 0) {
            throw "Claude background dispatch failed (exit $($res.ExitCode)): $($res.Stderr) $($res.Stdout)".Trim()
        }
        return [pscustomobject]@{
            Result = 'dispatched'
            Client = 'Claude'
            Directory = $Directory
            Output = $res.Stdout.Trim()
        }
    }
    $stateDir = Get-FleetStateDirectory $InstallRoot $Profile
    [void][IO.Directory]::CreateDirectory($stateDir)
    $logPath = Join-Path $stateDir ("dispatch-codex-" + [Guid]::NewGuid().ToString('n') + '.jsonl')
    $errPath = "$logPath.err"
    $codexArgs = [Collections.Generic.List[string]]::new()
    $codexArgs.AddRange([string[]]@('exec', '-C', $Directory, '--json'))
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $codexArgs.Add('-m')
        $codexArgs.Add($Model)
    }
    # codex exec reads its prompt from standard input when the prompt argument is -. A prompt there needs no quoting,
    # and cannot be read as an option or as a subcommand such as review.
    $codexArgs.Add('-')
    $promptPath = "$logPath.prompt.txt"
    [IO.File]::WriteAllText($promptPath, $Prompt, [Text.UTF8Encoding]::new($false))
    $proc = Start-Process -FilePath $executable -ArgumentList (ConvertTo-FleetCommandLine $codexArgs.ToArray()) -WorkingDirectory $Directory -WindowStyle Hidden -PassThru -RedirectStandardInput $promptPath -RedirectStandardOutput $logPath -RedirectStandardError $errPath
    [pscustomobject]@{
        Result = 'dispatched'
        Client = 'Codex'
        Directory = $Directory
        Pid = $proc.Id
        LogPath = $logPath
    }
}

function Invoke-FleetQueue($Manifest, [string]$Thread, [string]$Message, [switch]$Resume) {
    if ([string]::IsNullOrWhiteSpace($Thread)) { throw 'Queue requires -Thread (session UUID or exact name).' }
    if ([string]::IsNullOrWhiteSpace($Message)) { throw 'Queue requires -Message.' }
    $executable = [string]$Manifest.Codex
    Assert-FleetAbsolutePath $executable
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw 'The selected client is unavailable: Codex'
    }
    Assert-FleetDirectExecutable $executable 'Codex'
    $argsList = [Collections.Generic.List[string]]::new()
    $argsList.AddRange([string[]]@('queue', '--thread', $Thread, '--message', $Message))
    if ($Resume) { $argsList.Add('--resume') }
    $res = Invoke-FleetProcessSync $executable (Get-Location).Path $argsList.ToArray()
    if ($res.ExitCode -ne 0) {
        throw "Codex queue failed (exit $($res.ExitCode)): $($res.Stderr) $($res.Stdout)".Trim()
    }
    [pscustomobject]@{
        Result = 'queued'
        Client = 'Codex'
        Thread = $Thread
        Output = $res.Stdout.Trim()
    }
}
