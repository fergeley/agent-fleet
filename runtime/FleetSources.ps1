function Assert-FleetAbsolutePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "The Fleet path must be absolute: $Path"
    }
    $trimmed = $Path.Trim()
    if ($trimmed.StartsWith('\\?\') -or $trimmed.StartsWith('\\.\')) { throw "The Fleet path cannot use a device prefix: $Path" }
    $root = [IO.Path]::GetPathRoot($trimmed)
    if ($root -eq '\' -or ($root.Length -eq 2 -and $root[1] -eq ':')) {
        throw "The Fleet path cannot depend on a current directory or drive root: $Path"
    }
}

function Assert-FleetProfileName([string]$Profile) {
    if ([string]::IsNullOrWhiteSpace($Profile)) { return }
    if ($Profile -cnotmatch '^[a-z][a-z0-9-]{0,31}$') {
        throw "The Fleet profile name is invalid (use 1-32 lowercase letters, digits, or hyphens): $Profile"
    }
}

function Get-FleetManifestPath([string]$InstallRoot, [string]$Profile = '') {
    Assert-FleetProfileName $Profile
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        return (Join-Path $InstallRoot 'manifest.json')
    }
    return (Join-Path (Join-Path (Join-Path $InstallRoot 'profiles') $Profile) 'manifest.json')
}

function Get-FleetStateDirectory([string]$InstallRoot, [string]$Profile = '') {
    Assert-FleetProfileName $Profile
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        return (Join-Path $InstallRoot 'state')
    }
    return (Join-Path (Join-Path (Join-Path $InstallRoot 'profiles') $Profile) 'state')
}

function Get-FleetFinalDirectoryPath([string]$Path) {
    Assert-FleetAbsolutePath $Path
    if (-not ('FleetPath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class FleetPath
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern uint GetFinalPathNameByHandleW(IntPtr file, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    public static string FinalPath(string folder)
    {
        IntPtr handle = CreateFileW(folder, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var path = new StringBuilder(2048);
            uint length = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
            if (length == 0 || length >= path.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
            string text = path.ToString();
            if (text.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + text.Substring(8);
            if (text.StartsWith(@"\\?\", StringComparison.Ordinal)) return text.Substring(4);
            return text;
        } finally { CloseHandle(handle); }
    }
}
'@
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (Test-Path -LiteralPath $full) {
        return [FleetPath]::FinalPath($full).TrimEnd('\')
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    $leaf = [IO.Path]::GetFileName($full)
    if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
        return (Join-Path ([FleetPath]::FinalPath($parent).TrimEnd('\')) $leaf).TrimEnd('\')
    }
    return $full
}

function Get-FleetLaunchLockHash([string]$InstallRoot, [string]$Profile = '') {
    Assert-FleetProfileName $Profile
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $installKey = $identity + '|' + (Get-FleetFinalDirectoryPath $InstallRoot).ToUpperInvariant()
    if (-not [string]::IsNullOrWhiteSpace($Profile)) { $installKey += '|' + $Profile }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($installKey))).Substring(0, 16)
}

function Read-FleetSharedText([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true))
        try { $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Move-FleetFileReplacing([string]$Source, [string]$Destination) {
    for ($attempt = 1; ; $attempt++) {
        try { [IO.File]::Move($Source, $Destination, $true); return }
        catch [UnauthorizedAccessException], [IO.IOException] {
            if ($attempt -ge 40) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Assert-FleetDistinctWorktrees([string[]]$Worktrees, [int]$ExpectedCount) {
    foreach ($name in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
        if (Test-Path "Env:$name") {
            throw "Remove the inherited Git source override before launching: $name"
        }
    }
    $resolved = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $heads = [Collections.Generic.List[string]]::new()
    foreach ($worktree in $Worktrees) {
        Assert-FleetAbsolutePath $worktree
        $trimmed = [IO.Path]::TrimEndingDirectorySeparator($worktree)
        if (-not (Test-Path -LiteralPath $trimmed -PathType Container)) {
            throw "The configured directory is unavailable: $worktree"
        }
        $gitDirectory = (& git -C $trimmed rev-parse --absolute-git-dir)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitDirectory)) {
            throw "The configured worker is not a Git worktree: $worktree"
        }
        $canonicalGit = Get-FleetFinalDirectoryPath $gitDirectory.Trim()
        if (-not $seen.Add($canonicalGit)) {
            throw 'Workers must identify distinct Git worktrees.'
        }
        $head = (& git -C $trimmed rev-parse HEAD)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
            throw "The worker Git HEAD is unavailable: $worktree"
        }
        $resolved.Add($trimmed)
        $heads.Add($head.Trim())
    }
    if ($resolved.Count -ne $ExpectedCount) {
        throw "Configure $ExpectedCount distinct worker worktrees."
    }
    [pscustomobject]@{ Worktrees = $resolved.ToArray(); GitDirectories = @($seen); Heads = $heads.ToArray() }
}

function Test-FleetProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    $Object.PSObject.Properties.Match($Name).Count -gt 0
}

function Get-FleetTabColors($Manifest) {
    $colors = [ordered]@{}
    if (-not (Test-FleetProperty $Manifest 'TabColors') -or $null -eq $Manifest.TabColors) {
        return $colors
    }
    $raw = $Manifest.TabColors
    if ($raw -is [string] -or $raw -is [Array]) {
        throw 'The TabColors manifest field must be an object mapping tab names to #RRGGBB hex colors.'
    }
    $pairs = if ($raw -is [Collections.IDictionary]) {
        $raw.GetEnumerator()
    } else {
        @($raw.PSObject.Properties | ForEach-Object { [Collections.DictionaryEntry]::new($_.Name, $_.Value) })
    }
    foreach ($pair in $pairs) {
        $tab = [string]$pair.Key
        $val = $pair.Value
        if ($tab -cnotmatch '^[a-z0-9][a-z0-9 _-]{0,31}$') {
            throw "The TabColors tab name is invalid: $tab"
        }
        if ($val -isnot [string] -or $val -cnotmatch '^#[0-9A-Fa-f]{6}$') {
            throw "The TabColors value must be a #RRGGBB hex color for tab $tab."
        }
        $colors[$tab] = $val
    }
    return $colors
}

function Get-FleetJobIds($Manifest) {
    if ($null -eq $Manifest.Jobs) { throw 'Configure 1 to 16 Jobs entries in the manifest.' }
    $entries = @($Manifest.Jobs)
    if ($entries.Count -lt 1 -or $entries.Count -gt 16) { throw 'Configure 1 to 16 Jobs entries.' }
    $ids = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        if ($entry -is [string] -or ($entry -isnot [psobject] -and $entry -isnot [Collections.IDictionary]) -or $entry -is [Array]) { throw 'Each Jobs entry must be an object.' }
        if ($entry.Id -isnot [string] -or $entry.Id -cnotmatch '^[a-z][a-z0-9-]{0,31}$') {
            throw 'Every Jobs entry needs an explicit lowercase ASCII ID of 1 to 32 filename-safe characters.'
        }
        if (-not $seen.Add($entry.Id)) { throw "The Jobs ID is duplicated: $($entry.Id)" }
        $ids.Add($entry.Id)
    }
    return $ids.ToArray()
}

function Get-FleetClientArguments([string]$Client, [string[]]$CustomArgs = $null) {
    if ($null -ne $CustomArgs) { return ,$CustomArgs }
    switch ($Client) {
        'Codex' { ,@('agents') }
        'Claude' { ,@('agents') }
        'Antigravity' { ,@() }
        'OpenCode' { ,@() }
        default { throw "The Jobs client is unsupported: $Client" }
    }
}

function Parse-FleetJobArgs($Entry, [string]$Id) {
    if (-not (Test-FleetProperty $Entry 'Args')) { return $null }
    if ($null -eq $Entry.Args -or $Entry.Args -is [string] -or $Entry.Args -isnot [Array]) {
        throw "The Jobs Args field must be a string array for $Id."
    }
    $parsed = [Collections.Generic.List[string]]::new()
    foreach ($item in $Entry.Args) {
        if ($item -isnot [string]) { throw "The Jobs Args entries must be strings for $Id." }
        $parsed.Add($item)
    }
    return ,$parsed.ToArray()
}

function Parse-FleetJobEnv($Entry, [string]$Id) {
    if (-not (Test-FleetProperty $Entry 'Env')) { return $null }
    $raw = $Entry.Env
    if ($null -eq $raw -or $raw -is [string] -or $raw -is [Array]) {
        throw "The Jobs Env field must be an object for $Id."
    }
    $blocked = @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')
    $parsed = [ordered]@{}
    $pairs = if ($raw -is [Collections.IDictionary]) {
        $raw.GetEnumerator()
    } else {
        @($raw.PSObject.Properties | ForEach-Object { [Collections.DictionaryEntry]::new($_.Name, $_.Value) })
    }
    foreach ($pair in $pairs) {
        $k = [string]$pair.Key
        $v = $pair.Value
        if ([string]::IsNullOrWhiteSpace($k) -or $v -isnot [string]) {
            throw "The Jobs Env entries must map non-empty keys to strings for $Id."
        }
        if ($blocked -contains $k.ToUpperInvariant()) {
            throw "The Jobs Env cannot override Git source variables: $k"
        }
        $parsed[$k] = $v
    }
    return $parsed
}

function Parse-FleetJobTab($Entry, [string]$Id) {
    if (-not (Test-FleetProperty $Entry 'Tab') -or $null -eq $Entry.Tab) { return 'fleet' }
    if ($Entry.Tab -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry.Tab)) {
        throw "The Jobs Tab field must be a non-empty string for $Id."
    }
    $tab = $Entry.Tab.Trim()
    if ($tab -cnotmatch '^[a-z0-9][a-z0-9 _-]{0,31}$') {
        throw "The Jobs Tab name is invalid for $Id (use 1-32 letters, digits, spaces, _ or -): $tab"
    }
    return $tab
}

function Get-FleetJobDefinitions($Manifest, [string]$JobId = '') {
    $ids = @(Get-FleetJobIds $Manifest)
    $entries = @($Manifest.Jobs)
    if ($JobId -and $JobId -cnotin $ids) { throw "The Jobs ID is not configured: $JobId" }
    [void](Get-FleetJobsLayout $Manifest)
    [void](Get-FleetTabColors $Manifest)

    # Validate full-manifest tab limits even when a single -Job filter is active.
    $tabCounts = [ordered]@{}
    foreach ($entry in $entries) {
        $tabName = Parse-FleetJobTab $entry $entry.Id
        if (-not $tabCounts.Contains($tabName)) { $tabCounts[$tabName] = 0 }
        $tabCounts[$tabName]++
        if ($tabCounts[$tabName] -gt 4) {
            throw "Tab '$tabName' exceeds the limit of 4 panes per tab."
        }
    }
    if ($tabCounts.Count -gt 4) {
        throw "Configure at most 4 distinct tabs in SingleWindow (found $($tabCounts.Count))."
    }

    $selected = [Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        if ($JobId -and $entry.Id -cne $JobId) { continue }
        if ($entry.Client -isnot [string] -or $entry.Client -cnotin @('Codex','Claude','Antigravity','OpenCode')) {
            throw "The Jobs client is unsupported: $($entry.Client)"
        }
        if ($entry.Directory -isnot [string]) { throw "The Jobs directory is missing for $($entry.Id)." }
        # Both layouts pass the directory to Windows Terminal, which reads a semicolon as a command separator.
        if ($entry.Directory.Contains(';')) {
            throw "The Jobs directory for $($entry.Id) cannot contain a semicolon: $($entry.Directory)"
        }
        $tabName = Parse-FleetJobTab $entry $entry.Id
        $customArgs = Parse-FleetJobArgs $entry $entry.Id
        $customEnv = Parse-FleetJobEnv $entry $entry.Id
        $selected.Add([pscustomobject]@{
            Id = $entry.Id
            Client = $entry.Client
            Tab = $tabName
            Directory = [IO.Path]::TrimEndingDirectorySeparator($entry.Directory)
            NativeArguments = Get-FleetClientArguments $entry.Client $customArgs
            NativeEnv = $customEnv
        })
    }
    if ($selected.Count -eq 0) { throw "The Jobs ID is not configured: $JobId" }
    $verified = Assert-FleetDistinctWorktrees @($selected | ForEach-Object Directory) $selected.Count
    $gitDirs = [Collections.Generic.List[string]]::new()
    foreach ($dir in $verified.Worktrees) {
        $gitDirs.Add((Get-FleetFinalDirectoryPath ((& git -C $dir rev-parse --absolute-git-dir).Trim())))
    }
    $resolved = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $selected.Count; $index++) {
        $entry = $selected[$index]
        $resolved.Add([pscustomobject]@{
            Id = $entry.Id
            Client = $entry.Client
            Tab = $entry.Tab
            Directory = $verified.Worktrees[$index]
            GitDirectory = $gitDirs[$index]
            ObservedHead = $verified.Heads[$index]
            NativeArguments = $entry.NativeArguments
            NativeEnv = $entry.NativeEnv
        })
    }
    return $resolved.ToArray()
}

function Get-FleetJobsLayout($Manifest) {
    if (-not (Test-FleetProperty $Manifest 'JobsLayout') -or $null -eq $Manifest.JobsLayout) {
        return 'SingleWindow'
    }
    if ($Manifest.JobsLayout -isnot [string] -or $Manifest.JobsLayout -cnotin @('JobWindows', 'SingleWindow')) {
        throw 'The Jobs layout is invalid.'
    }
    $Manifest.JobsLayout
}

function Get-FleetWindowProperty([string]$LockHash, [string]$WindowNonce) {
    "AgentFleet.$LockHash.Window.$WindowNonce"
}

function Get-FleetEvidenceNonce($Evidence) {
    if ((Test-FleetProperty $Evidence 'LaunchNonce') -and $Evidence.LaunchNonce -is [string] -and $Evidence.LaunchNonce -cmatch '^[a-f0-9]{32}$') {
        return $Evidence.LaunchNonce
    }
    if ((Test-FleetProperty $Evidence 'WindowName') -and $Evidence.WindowName -is [string] -and $Evidence.WindowName -cmatch '^AgentFleetJob-[a-f0-9]+-[a-z][a-z0-9-]{0,31}-(?<nonce>[a-f0-9]{32})$') {
        return $Matches.nonce
    }
    if ((Test-FleetProperty $Evidence 'ContextPath') -and $Evidence.ContextPath -is [string] -and $Evidence.ContextPath -cmatch 'launch-context-(?<nonce>[a-f0-9]{32})\.json$') {
        return $Matches.nonce
    }
    $null
}

function Get-FleetJobArguments([string]$PowerShellExecutable, [string]$OpenFleetPath, [string]$InstallRoot, $Job, [string]$ContextPath, [string]$Profile = '') {
    $argsList = [Collections.Generic.List[string]]::new()
    $argsList.AddRange([string[]]@(
        '-NoLogo', '-NoExit', '-File', $OpenFleetPath,
        '-Job', $Job.Id, '-Pane', $Job.Client,
        '-Directory', $Job.Directory, '-LaunchContext', $ContextPath,
        '-InstallRoot', $InstallRoot
    ))
    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $argsList.AddRange([string[]]@('-Profile', $Profile))
    }
    return $argsList.ToArray()
}

# Callers check their arguments with this before they change anything, so that a refused launch leaves nothing behind.
function Assert-FleetTerminalArgument([string[]]$Arguments) {
    foreach ($argument in $Arguments) {
        if ($argument.Contains('"')) { throw 'A Windows Terminal argument cannot contain a double quote.' }
        if ($argument -cne ';' -and $argument.Contains(';')) { throw 'A Windows Terminal argument cannot contain a semicolon, because Windows Terminal reads it as a command separator.' }
    }
}

function Start-FleetTerminal([string]$Terminal, [string[]]$Arguments) {
    Assert-FleetTerminalArgument $Arguments
    if (-not ('FleetWindow' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'FleetWindow.cs') }
    # ArgumentList quotes each argument. A tab that wt.exe opens takes the environment of wt.exe,
    # so give it the sign-in environment instead of the environment of the shell that ran Fleet.
    $start = [Diagnostics.ProcessStartInfo]::new($Terminal)
    $start.UseShellExecute = $false
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment.Clear()
    foreach ($variable in [FleetWindow]::GetSignInEnvironment().GetEnumerator()) { $start.Environment[$variable.Key] = $variable.Value }
    [Diagnostics.Process]::Start($start).Dispose()
}

# The Windows command line for these arguments, by the rules that CommandLineToArgvW and the C runtime use to split it.
function ConvertTo-FleetCommandLine([string[]]$Arguments) {
    $parts = foreach ($argument in $Arguments) {
        if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') { $argument; continue }
        $builder = [Text.StringBuilder]::new('"')
        $backslashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq [char]'\') { $backslashes++; continue }
            if ($character -eq [char]'"') { [void]$builder.Append([char]'\', 2 * $backslashes + 1) }
            elseif ($backslashes -gt 0) { [void]$builder.Append([char]'\', $backslashes) }
            [void]$builder.Append($character)
            $backslashes = 0
        }
        [void]$builder.Append([char]'\', 2 * $backslashes).Append([char]'"')
        $builder.ToString()
    }
    $parts -join ' '
}

# The boot counter of Windows, or 'unknown'. It changes at every restart, so it tells a marker of an earlier boot from one of this boot.
function Get-FleetBootId {
    $bootId = try {
        [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -Name BootId -ErrorAction Stop)
    } catch { 'unknown' }
    if ([string]::IsNullOrWhiteSpace($bootId)) { 'unknown' } else { $bootId }
}

function Get-FleetResetHint([string]$JobId, [string]$Profile = '') {
    $profileArgument = if ($Profile) { " -Profile $Profile" } else { '' }
    " When no window or client of that launch is still running, run: agent-fleet -Job $JobId -ResetPending$profileArgument"
}

function New-FleetJobPaneArguments([string]$PowerShellExecutable, [string]$OpenFleetPath, [string]$InstallRoot, $Job, [string]$ContextPath, [string]$Title, [string]$Profile = '', [bool]$UseApplicationTitle = $true) {
    $titleFlag = if ($UseApplicationTitle) { '--useApplicationTitle' } else { '--suppressApplicationTitle' }
    @('--title', $Title, $titleFlag, '-d', $Job.Directory, $PowerShellExecutable) +
        (Get-FleetJobArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $Job $ContextPath $Profile)
}

function New-FleetSingleWindowPlan([string]$PowerShellExecutable, [string]$OpenFleetPath, [string]$InstallRoot, [string]$LockHash, [string]$WindowNonce, [object[]]$JobPlans, $TabColors = @{}, [string]$Profile = '') {
    if ($JobPlans.Count -lt 1 -or $JobPlans.Count -gt 16) { throw 'Configure 1 to 16 Jobs entries for SingleWindow.' }
    $windowName = "AgentFleetJobs-$LockHash-$WindowNonce"
    $title = "Agent Fleet Jobs | $LockHash/$WindowNonce"
    $windowProperty = Get-FleetWindowProperty $LockHash $WindowNonce

    $tabGroups = [ordered]@{}
    foreach ($jp in $JobPlans) {
        $tName = if ((Test-FleetProperty $jp 'Tab') -and -not [string]::IsNullOrWhiteSpace([string]$jp.Tab)) { [string]$jp.Tab } else { 'fleet' }
        if (-not $tabGroups.Contains($tName)) { $tabGroups[$tName] = [Collections.Generic.List[object]]::new() }
        $tabGroups[$tName].Add($jp)
    }
    if ($tabGroups.Count -gt 4) { throw 'Configure at most 4 tabs for SingleWindow.' }

    $terminalArgs = [Collections.Generic.List[string]]::new()
    $tabSummaries = [Collections.Generic.List[object]]::new()
    $tabIndex = 0
    foreach ($entry in $tabGroups.GetEnumerator()) {
        $tabName = [string]$entry.Key
        $tabJobs = @($entry.Value.ToArray())
        if ($tabJobs.Count -lt 1 -or $tabJobs.Count -gt 4) {
            throw "Tab '$tabName' must contain 1 to 4 panes."
        }
        $tabColor = ''
        if ($TabColors -is [Collections.IDictionary] -and $TabColors.Contains($tabName)) {
            $tabColor = [string]$TabColors[$tabName]
        } elseif ($null -ne $TabColors -and (Test-FleetProperty $TabColors $tabName)) {
            $tabColor = [string]$TabColors.$tabName
        }

        if ($tabIndex -eq 0) {
            # No --maximized: Windows Terminal 1.25 often hung when its window changed size while it was still
            # creating the panes of this command line. The launcher maximizes the window after every pane started.
            $terminalArgs.AddRange([string[]]@('-w', $windowName, 'new-tab'))
        } else {
            $terminalArgs.Add(';')
            $terminalArgs.Add('new-tab')
        }
        if ($tabColor) {
            $terminalArgs.AddRange([string[]]@('--tabColor', $tabColor))
        }
        $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $tabJobs[0] $tabJobs[0].ContextPath $title $Profile $true))

        if ($tabJobs.Count -eq 2) {
            $terminalArgs.Add(';')
            $terminalArgs.AddRange([string[]]@('split-pane', '-V'))
            $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $tabJobs[1] $tabJobs[1].ContextPath $title $Profile $true))
        } elseif ($tabJobs.Count -eq 3) {
            $terminalArgs.Add(';')
            $terminalArgs.AddRange([string[]]@('split-pane', '-V'))
            $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $tabJobs[1] $tabJobs[1].ContextPath $title $Profile $true))
            $terminalArgs.AddRange([string[]]@(';', 'move-focus', 'left', ';', 'split-pane', '-H'))
            $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $tabJobs[2] $tabJobs[2].ContextPath $title $Profile $true))
        } elseif ($tabJobs.Count -eq 4) {
            $terminalArgs.Add(';')
            $terminalArgs.AddRange([string[]]@('split-pane', '-V'))
            $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $tabJobs[1] $tabJobs[1].ContextPath $title $Profile $true))
            $terminalArgs.Add(';')
            $terminalArgs.AddRange([string[]]@('split-pane', '-H'))
            $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $tabJobs[3] $tabJobs[3].ContextPath $title $Profile $true))
            $terminalArgs.AddRange([string[]]@(';', 'move-focus', 'left', ';', 'split-pane', '-H'))
            $terminalArgs.AddRange([string[]](New-FleetJobPaneArguments $PowerShellExecutable $OpenFleetPath $InstallRoot $tabJobs[2] $tabJobs[2].ContextPath $title $Profile $true))
        }

        $tabSummaries.Add([pscustomobject]@{
            Tab = $tabName
            Color = if ($tabColor) { $tabColor } else { $null }
            JobIds = @($tabJobs | ForEach-Object Id)
        })
        $tabIndex++
    }

    [pscustomobject]@{
        Layout = 'SingleWindow'
        WindowName = $windowName
        Title = $title
        WindowProperty = $windowProperty
        WindowNonce = $WindowNonce
        Tabs = $tabSummaries.ToArray()
        Arguments = $terminalArgs.ToArray()
        Jobs = @($JobPlans)
    }
}

function Get-FleetJobs($Manifest, [string]$InstallRoot = $PSScriptRoot, [string]$OpenFleetPath = (Join-Path $PSScriptRoot 'Open-Fleet.ps1'), [string]$JobId = '', [string]$Profile = '') {
    $definitions = @(Get-FleetJobDefinitions $Manifest $JobId)
    $layout = Get-FleetJobsLayout $Manifest
    $lockHash = Get-FleetLaunchLockHash $InstallRoot $Profile
    $stateDirectory = Get-FleetStateDirectory $InstallRoot $Profile
    $singleWindowNonce = if ($layout -ceq 'SingleWindow') { [Guid]::NewGuid().ToString('n') } else { '' }
    $windowName = if ($layout -ceq 'SingleWindow') { "AgentFleetJobs-$lockHash-$singleWindowNonce" } else { '' }
    $windowTitle = if ($layout -ceq 'SingleWindow') { "Agent Fleet Jobs | $lockHash/$singleWindowNonce" } else { '' }
    $windowProperty = if ($layout -ceq 'SingleWindow') { Get-FleetWindowProperty $lockHash $singleWindowNonce } else { '' }
    $jobs = [Collections.Generic.List[object]]::new()
    foreach ($entry in $definitions) {
        $executable = [string]$Manifest.($entry.Client)
        Assert-FleetAbsolutePath $executable
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "The selected client is unavailable: $($entry.Client)"
        }
        $nonce = [Guid]::NewGuid().ToString('n')
        $contextPath = Join-Path $stateDirectory "launch-context-$nonce.json"
        if ($layout -ceq 'SingleWindow') {
            $jobWindowName = $windowName
            $jobTitle = $windowTitle
        } else {
            $jobWindowName = "AgentFleetJob-$lockHash-$($entry.Id)-$nonce"
            $jobTitle = "Agent Fleet Job [$($entry.Id)] | $($entry.Client) | $lockHash/$nonce"
        }
        $item = [ordered]@{
            Id = $entry.Id
            Client = $entry.Client
            Tab = $entry.Tab
            Directory = $entry.Directory
            GitDirectory = $entry.GitDirectory
            ObservedHead = $entry.ObservedHead
            NativeExecutable = $executable
            NativeArguments = @($entry.NativeArguments)
            NativeEnv = $entry.NativeEnv
            Nonce = $nonce
            InstallationTag = $lockHash
            Property = "AgentFleet.$lockHash.Job.$($entry.Id)"
            InstanceProperty = "AgentFleet.$lockHash.Instance.$nonce"
            WindowName = $jobWindowName
            Title = $jobTitle
            TitleMode = 'Native'
            ContextPath = $contextPath
            StatePath = Join-Path $stateDirectory "job-$($entry.Id).pending.json"
            InstancePath = Join-Path $stateDirectory "job-$($entry.Id).instance.json"
            Layout = $layout
        }
        if ($Profile) { $item.Profile = $Profile }
        if ($layout -ceq 'SingleWindow') {
            $item.WindowNonce = $singleWindowNonce
            $item.WindowProperty = $windowProperty
        }
        $jobs.Add([pscustomobject]$item)
    }
    return $jobs.ToArray()
}

function Read-FleetLaunchContext([string]$Path, [bool]$AllowCustomArgsAndEnv = $false, [string]$InstallRoot = $PSScriptRoot, [string]$Profile = '') {
    Assert-FleetAbsolutePath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The launch context is missing: $Path" }
    $expectedDir = [IO.Path]::GetFullPath((Get-FleetStateDirectory $InstallRoot $Profile)).TrimEnd('\')
    $actualDir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    if ($actualDir -ine $expectedDir) { throw "The launch context is outside the install state directory: $Path" }
    $context = Read-FleetSharedText $Path | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('Nonce','InstallationTag','Id','Client','Directory','GitDirectory','ObservedHead','NativeExecutable','WindowName','Title')) {
        if (-not (Test-FleetProperty $context $field) -or $context.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($context.$field)) {
            throw "The launch context field is invalid: $field"
        }
    }
    if ($context.Nonce -cnotmatch '^[a-f0-9]{32}$') { throw 'The launch context nonce is invalid.' }
    if ($context.Id -cnotmatch '^[a-z][a-z0-9-]{0,31}$') { throw 'The launch context job ID is invalid.' }
    if ($context.Client -cnotin @('Codex','Claude','Antigravity','OpenCode')) { throw 'The launch context client is unsupported.' }
    Assert-FleetAbsolutePath $context.Directory
    Assert-FleetAbsolutePath $context.GitDirectory
    Assert-FleetAbsolutePath $context.NativeExecutable
    if (Test-FleetProperty $context 'Tab' -and $null -ne $context.Tab) {
        if ($context.Tab -isnot [string] -or $context.Tab -cnotmatch '^[a-z0-9][a-z0-9 _-]{0,31}$') {
            throw 'The launch context Tab field is invalid.'
        }
    }
    if (Test-FleetProperty $context 'NativeArguments') {
        if ($null -eq $context.NativeArguments -or $context.NativeArguments -is [string] -or $context.NativeArguments -isnot [Array]) {
            throw 'The launch context NativeArguments field is invalid.'
        }
        foreach ($arg in $context.NativeArguments) {
            if ($arg -isnot [string]) { throw 'The launch context NativeArguments entries must be strings.' }
        }
    }
    if (Test-FleetProperty $context 'NativeEnv' -and $null -ne $context.NativeEnv) {
        if ($context.NativeEnv -is [string] -or $context.NativeEnv -is [Array]) {
            throw 'The launch context NativeEnv field is invalid.'
        }
        $blocked = @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')
        foreach ($prop in $context.NativeEnv.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace($prop.Name) -or $prop.Value -isnot [string]) {
                throw 'The launch context NativeEnv entries must map non-empty keys to strings.'
            }
            if ($blocked -contains $prop.Name.ToUpperInvariant()) {
                throw "The launch context NativeEnv cannot override Git source variables: $($prop.Name)"
            }
        }
    }
    if (Test-FleetProperty $context 'Layout') {
        if ($context.Layout -isnot [string] -or $context.Layout -cnotin @('JobWindows', 'SingleWindow')) {
            throw 'The launch context layout is invalid.'
        }
        if ($context.Layout -ceq 'SingleWindow' -and (-not (Test-FleetProperty $context 'WindowNonce') -or $context.WindowNonce -isnot [string] -or $context.WindowNonce -cnotmatch '^[a-f0-9]{32}$')) {
            throw 'The launch context window nonce is invalid.'
        }
    }
    $context
}

function Wait-FleetJobRegistration($Context, [string]$ContextPath, [string]$InstallRoot, [int]$TimeoutMilliseconds = 60000, [string]$Profile = '') {
    $stateDirectory = Get-FleetStateDirectory $InstallRoot $Profile
    $pendingPath = Join-Path $stateDirectory "job-$($Context.Id).pending.json"
    $instancePath = Join-Path $stateDirectory "job-$($Context.Id).instance.json"
    $isSingleWindow = (Test-FleetProperty $Context 'Layout') -and $Context.Layout -ceq 'SingleWindow'
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) {
            if (Test-Path -LiteralPath $instancePath -PathType Leaf) {
                $instance = Read-FleetSharedText $instancePath | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($null -ne $instance -and (Get-FleetEvidenceNonce $instance) -ceq $Context.Nonce) {
                    $live = @([FleetWindow]::Find($instance.InstanceProperty))
                    if ($live.Count -eq 1) { return [long]$live[0] }
                }
            }
            throw 'The launch pending state disappeared before this pane registered.'
        }
        $windows = @([FleetWindow]::Find($Context.InstanceProperty))
        if ($windows.Count -eq 1 -and (-not $isSingleWindow -or @([FleetWindow]::Find($Context.WindowProperty)).Count -eq 1)) {
            return [long]$windows[0]
        }
        Start-Sleep -Milliseconds 150
    }
    try {
        [IO.File]::WriteAllText((Join-Path $stateDirectory "registration-timeout-$($Context.Nonce).json"),
            ([ordered]@{ Nonce = $Context.Nonce; JobId = $Context.Id; AtUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress))
    } catch { }
    throw "The Jobs window was not confirmed within $TimeoutMilliseconds ms. Registration does not prove the client started. Inspect its pending state before retrying."
}

function New-FleetInvocationRecord($Context, [string]$ContextPath, [string]$RuntimeDirectory) {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $shellStartedAtUtc = $process.StartTime.ToUniversalTime().ToString('o')
        $sessionId = [int]$process.SessionId
    } finally { $process.Dispose() }
    $bootId = Get-FleetBootId
    $runtimeVersion = $null
    $releasePath = Join-Path $RuntimeDirectory 'release.json'
    if ([IO.File]::Exists($releasePath)) {
        $release = [IO.File]::ReadAllText($releasePath) | ConvertFrom-Json -ErrorAction Stop
        if ($release.Version -isnot [string] -or $release.Version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
            throw 'The Fleet runtime version metadata is invalid.'
        }
        $runtimeVersion = $release.Version
    }
    [ordered]@{
        SchemaVersion = 1
        InvocationId = [Guid]::NewGuid().ToString('n')
        LaunchNonce = $Context.Nonce
        InstallationTag = $Context.InstallationTag
        JobId = $Context.Id
        Client = $Context.Client
        ContextPath = $ContextPath
        ShellPid = [int]$PID
        ShellStartedAtUtc = $shellStartedAtUtc
        SessionId = $sessionId
        BootId = $bootId
        RuntimeVersion = $runtimeVersion
        RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
        EnteredAtUtc = [DateTime]::UtcNow.ToString('o')
        ReturnedAtUtc = $null
        ExitCode = $null
    }
}

function Write-FleetInvocationRecord([string]$Path, $Record, [bool]$Replace = $false) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 4 -Compress -ErrorAction Stop))
    if ($bytes.Length -gt 8192) { throw 'The Fleet invocation record exceeds its size limit.' }
    $directory = [IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('n') + '.tmp')
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ($Replace) { Move-FleetFileReplacing $temporary $Path } else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
