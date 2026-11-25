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

function Assert-FleetNoReparseAncestors([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Path contains a reparse point: $cursor"
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function New-FleetWorktree([string]$Repository, [string]$Path, [string]$BaseRef = 'main', [string]$Branch = '', [switch]$Lock) {
    Assert-FleetAbsolutePath $Repository
    Assert-FleetAbsolutePath $Path
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
    if (-not [string]::IsNullOrWhiteSpace($Branch)) {
        $gitArgs += @('-b', $Branch, $fullTarget, $BaseRef)
    } else {
        $gitArgs += @('--detach', $fullTarget, $BaseRef)
    }
    $addOutput = & git @gitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git worktree add failed: $($addOutput | Out-String)"
    }
    if ($Lock) {
        $lockOutput = & git -C $Repository worktree lock $fullTarget --reason 'Agent Fleet job slot' 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Worktree created at $fullTarget, but lock failed: $($lockOutput | Out-String)"
        }
    }
    [pscustomobject]@{
        Result = 'created'
        Path = $fullTarget
        Branch = if ([string]::IsNullOrWhiteSpace($Branch)) { '(detached)' } else { $Branch }
        BaseRef = $BaseRef
        Locked = [bool]$Lock
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

function Invoke-FleetDispatch($Manifest, [string]$Client, [string]$Directory, [string]$Prompt,
    [string]$Model = '', [string]$Name = '', [string]$InstallRoot = $PSScriptRoot) {
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
    if ($Client -ceq 'Claude') {
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
    $stateDir = Join-Path $InstallRoot 'state'
    [void][IO.Directory]::CreateDirectory($stateDir)
    $logPath = Join-Path $stateDir ("dispatch-codex-" + [Guid]::NewGuid().ToString('n') + '.jsonl')
    $errPath = "$logPath.err"
    $codexArgs = [Collections.Generic.List[string]]::new()
    $codexArgs.AddRange([string[]]@('exec', '-C', $Directory, '--json'))
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $codexArgs.Add('-m')
        $codexArgs.Add($Model)
    }
    $codexArgs.Add($Prompt)
    $proc = Start-Process -FilePath $executable -ArgumentList $codexArgs.ToArray() -WorkingDirectory $Directory -WindowStyle Hidden -PassThru -RedirectStandardOutput $logPath -RedirectStandardError $errPath
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
