function Get-FleetJobProperty([string]$LockHash, [string]$Id) {
    "AgentFleet.$LockHash.Job.$Id"
}

function Get-FleetJobStatePath([string]$StateDirectory, [string]$Id, [string]$Kind) {
    Join-Path $StateDirectory "job-$Id.$Kind.json"
}

function Get-FleetStatusFileStamp([string[]]$Paths) {
    $stamps = [Collections.Generic.List[string]]::new()
    foreach ($path in @($Paths | Sort-Object -Unique)) {
        if ($path.StartsWith('@count|', [StringComparison]::Ordinal)) { $stamps.Add($path); continue }
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $length = $stream.Length
                if ([IO.Path]::GetFileName($path) -like 'invocation-*' -and $length -gt 8192) {
                    $buffer = [byte[]]::new(8192)
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    $digestBytes = if ($read -eq $buffer.Length) { $buffer } else { [byte[]]$buffer[0..($read - 1)] }
                    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$digestBytes))
                } else {
                    $hasher = [Security.Cryptography.SHA256]::Create()
                    try { $digest = [Convert]::ToHexString($hasher.ComputeHash($stream)) } finally { $hasher.Dispose() }
                }
                $stamps.Add("$path|$length|$digest")
            } finally { $stream.Dispose() }
        } catch {
            $stamps.Add("$path|unreadable|$($_.Exception.GetType().Name)")
        }
    }
    $stamps.ToArray()
}

function Get-FleetStatusFileSet([string]$InstallRoot) {
    $state = Join-Path $InstallRoot 'state'
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add((Join-Path $InstallRoot 'manifest.json'))
    $paths.Add((Join-Path $InstallRoot 'installation.json'))
    $bindings = @(Get-ChildItem -LiteralPath $state -Filter 'job-*.json' -File -ErrorAction Stop | Sort-Object Name)
    $paths.Add("@count|bindings|$($bindings.Count)")
    foreach ($file in @($bindings | Select-Object -First 128)) {
        $paths.Add($file.FullName)
        if ($file.Name -cnotmatch '^job-[a-z][a-z0-9-]{0,31}\.(?:pending|instance)\.json$') { continue }
        try {
            $binding = Read-FleetSharedText $file.FullName | ConvertFrom-Json -ErrorAction Stop
            $nonce = Get-FleetEvidenceNonce $binding
            if (-not $nonce) { continue }
            $paths.Add((Join-Path $state "launch-context-$nonce.json"))
            $invocations = @(Get-ChildItem -LiteralPath $state -Filter "invocation-$nonce-*.json" -File | Sort-Object Name)
            $paths.Add("@count|invocations|$nonce|$($invocations.Count)")
            foreach ($invocation in @($invocations | Select-Object -First 64)) {
                $paths.Add($invocation.FullName)
            }
        } catch { }
    }
    $paths.ToArray() | Sort-Object -Unique
}

function Add-FleetStatusDiagnostic($Diagnostics, [string]$Code, [string]$Message, [string]$Path = '', [string]$JobId = '') {
    $diagnostic = [pscustomobject]@{ Code = $Code; Message = $Message; Path = $Path }
    if ($JobId) { $diagnostic | Add-Member -NotePropertyName JobId -NotePropertyValue $JobId }
    $Diagnostics.Add($diagnostic)
}

function Get-FleetStatusShell($Invocation, $Diagnostics, [string]$Path, [bool]$WindowAbsent) {
    $observedAt = [DateTime]::UtcNow.ToString('o')
    $shell = [ordered]@{ State = 'unknown'; ObservedAtUtc = $observedAt; Pid = $Invocation.ShellPid; StartedAtUtc = $null; SessionId = $null }
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$Invocation.ShellPid)
        try {
            $shell.StartedAtUtc = $process.StartTime.ToUniversalTime().ToString('o')
            $shell.SessionId = $process.SessionId
            $expected = [DateTimeOffset]::Parse([string]$Invocation.ShellStartedAtUtc).UtcDateTime
            $actual = [DateTimeOffset]::Parse($shell.StartedAtUtc).UtcDateTime
            $bootMismatch = $false
            if ($Invocation.BootId -ne 'unknown') {
                $currentBoot = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -Name BootId -ErrorAction Stop)
                $bootMismatch = $currentBoot -cne $Invocation.BootId
            }
            if ($actual -ne $expected -or "$($shell.SessionId)" -cne "$($Invocation.SessionId)" -or $bootMismatch) {
                $shell.State = 'identity-mismatch'
                if (-not $WindowAbsent) { Add-FleetStatusDiagnostic $Diagnostics 'shell-identity-mismatch' 'The recorded shell PID now identifies another process or session.' $Path }
            } else { $shell.State = 'observed' }
        } finally { $process.Dispose() }
    } catch [ArgumentException] { $shell.State = 'absent' }
    catch {
        $shell.State = 'unknown'
        if (-not $WindowAbsent) { Add-FleetStatusDiagnostic $Diagnostics 'shell-query-failed' 'The recorded shell identity could not be queried.' $Path }
    }
    [pscustomobject]$shell
}

function Get-FleetStatusInvocations($Evidence, [string]$Nonce, [string]$InstallRoot, $Diagnostics, [bool]$WindowAbsent) {
    $state = Join-Path $InstallRoot 'state'
    $files = @(Get-ChildItem -LiteralPath $state -Filter "invocation-$Nonce-*.json" -File | Sort-Object Name)
    if ($files.Count -gt 64) {
        Add-FleetStatusDiagnostic $Diagnostics 'invocations-truncated' 'More than 64 invocation records belong to this launch; the first 64 are shown.' $state
        $files = @($files | Select-Object -First 64)
    }
    $calls = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        try {
            if ($file.Name -cnotmatch "^invocation-$Nonce-(?<id>[a-f0-9]{32})\.json$") { throw 'Invocation filename is invalid.' }
            $id = $Matches.id
            if ($file.Length -gt 8192) { throw 'Invocation record exceeds 8 KiB.' }
            $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                if ($stream.Length -gt 8192) { throw 'Invocation record exceeds 8 KiB.' }
                $bytes = [byte[]]::new([int]$stream.Length)
                $read = $stream.Read($bytes, 0, $bytes.Length)
                if ($read -ne $bytes.Length) { throw 'Invocation record changed during read.' }
            } finally { $stream.Dispose() }
            $jsonOptions = @{ ErrorAction = 'Stop' }
            if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
            $call = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json @jsonOptions
            foreach ($timeField in @('ShellStartedAtUtc','EnteredAtUtc','ReturnedAtUtc')) {
                if ($call.$timeField -is [DateTime]) { $call.$timeField = $call.$timeField.ToUniversalTime().ToString('o') }
            }
            if ($call.SchemaVersion -ne 1 -or $call.InvocationId -cne $id -or $call.LaunchNonce -cne $Nonce -or
                $call.InstallationTag -cne $Evidence.InstallationTag -or $call.JobId -cne $Evidence.Id -or
                $call.Client -cne $Evidence.Client -or $call.ContextPath -cne $Evidence.ContextPath -or
                ($call.ShellPid -isnot [long] -and $call.ShellPid -isnot [int]) -or $call.ShellPid -le 0 -or $call.ShellPid -gt [int]::MaxValue -or
                $call.ShellStartedAtUtc -isnot [string] -or ($call.SessionId -isnot [long] -and $call.SessionId -isnot [int]) -or
                $call.BootId -isnot [string] -or
                ($null -ne $call.RuntimeVersion -and $call.RuntimeVersion -isnot [string]) -or
                $call.RuntimeDirectory -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($call.RuntimeDirectory) -or
                $call.EnteredAtUtc -isnot [string] -or
                ($null -eq $call.ReturnedAtUtc -and $null -ne $call.ExitCode) -or
                ($null -ne $call.ReturnedAtUtc -and $call.ReturnedAtUtc -isnot [string]) -or
                ($null -ne $call.ExitCode -and ($call.ExitCode -isnot [int] -and $call.ExitCode -isnot [long] -or $call.ExitCode -lt [int]::MinValue -or $call.ExitCode -gt [int]::MaxValue))) {
                throw 'Invocation record is incomplete or conflicts with its launch binding.'
            }
            [void][DateTimeOffset]::Parse($call.EnteredAtUtc)
            [void][DateTimeOffset]::Parse($call.ShellStartedAtUtc)
            if ($null -ne $call.ReturnedAtUtc) { [void][DateTimeOffset]::Parse($call.ReturnedAtUtc) }
            $shell = Get-FleetStatusShell $call $Diagnostics $file.FullName $WindowAbsent
            $calls.Add([pscustomobject]@{
                InvocationId = $id; State = if ($null -eq $call.ReturnedAtUtc) { 'entry-recorded' } else { 'return-recorded' }
                EnteredAtUtc = $call.EnteredAtUtc; ReturnedAtUtc = $call.ReturnedAtUtc; ExitCode = $call.ExitCode
                RuntimeVersion = $call.RuntimeVersion; RuntimeDirectory = $call.RuntimeDirectory
                BootId = $call.BootId; Shell = $shell
            })
        } catch {
            Add-FleetStatusDiagnostic $Diagnostics 'invocation-invalid' $_.Exception.Message $file.FullName
        }
    }
    $calls.ToArray()
}

function Get-FleetStatusWindow($Evidence, $Diagnostics, [string]$Path) {
    $time = [DateTime]::UtcNow.ToString('o')
    $isSingleWindow = (Test-FleetProperty $Evidence 'Layout') -and $Evidence.Layout -ceq 'SingleWindow'
    try {
        $found = if ($isSingleWindow) {
            @([FleetWindow]::Observe($Evidence.Title, $Evidence.InstanceProperty, $Evidence.WindowProperty))
        } else {
            @([FleetWindow]::Observe($Evidence.Title, $Evidence.InstanceProperty))
        }
        $owned = @($found | Where-Object PropertyMatch)
        $candidates = @($found | Where-Object { $_.TitleMatch -or ($isSingleWindow -and $_.WindowPropertyMatch) })
        $state = if ($owned.Count -gt 1 -or ($owned.Count -eq 0 -and $candidates.Count -gt 1)) { 'ambiguous' }
            elseif ($owned.Count -eq 1) { 'observed' }
            elseif ($candidates.Count -eq 1) { 'pending-candidate' }
            else { 'absent' }
        if ($state -eq 'ambiguous') { Add-FleetStatusDiagnostic $Diagnostics 'window-ambiguous' 'Multiple windows match this binding.' $Path }
        if ($owned.Count -eq 1 -and @($candidates | Where-Object Handle -ne $owned[0].Handle).Count -gt 0) {
            $state = 'ambiguous'
            Add-FleetStatusDiagnostic $Diagnostics 'window-ambiguous' 'A registered window and a different candidate window both match this binding.' $Path
        }
        if (@($found | Where-Object CloakQuery -ne 'ok').Count) {
            Add-FleetStatusDiagnostic $Diagnostics 'window-cloak-query-failed' 'A matching window cloak state could not be queried.' $Path
        }
        $primary = if ($owned.Count -eq 1) { $owned[0] } elseif ($candidates.Count -eq 1) { $candidates[0] } else { $null }
        [pscustomobject]@{
            State = $state; ObservedAtUtc = $time
            Layout = if ($isSingleWindow) { 'SingleWindow' } else { 'JobWindows' }
            Handle = if ($primary) { [long]$primary.Handle } else { $null }
            Visibility = if (-not $primary) { 'absent' } elseif ($primary.Cloaked -eq $true) { 'hidden' } elseif ($primary.CloakQuery -ne 'ok') { 'unknown' } elseif (-not $primary.Visible) { 'hidden' } elseif ($primary.Minimized) { 'minimized' } else { 'visible' }
            Foreground = if ($primary) { [bool]$primary.Foreground } else { $null }
            TitleMatch = if ($primary) { [bool]$primary.TitleMatch } else { $null }
        }
    } catch {
        Add-FleetStatusDiagnostic $Diagnostics 'window-query-failed' $_.Exception.Message $Path
        [pscustomobject]@{
            State = 'unknown'; ObservedAtUtc = $time
            Layout = if ($isSingleWindow) { 'SingleWindow' } else { 'JobWindows' }
            Handle = $null; Visibility = 'unknown'; Foreground = $null; TitleMatch = $null
        }
    }
}

function Get-FleetStatusBinding($File, [string]$LockHash, [string]$InstallRoot, $Diagnostics) {
    try {
        $evidence = Read-FleetJobEvidence $File.FullName $LockHash $InstallRoot
        $nonce = Get-FleetEvidenceNonce $evidence
        $window = Get-FleetStatusWindow $evidence $Diagnostics $File.FullName
        $timeoutPath = Join-Path (Join-Path $InstallRoot 'state') "registration-timeout-$nonce.json"
        [pscustomobject]@{
            Id = $evidence.Id; Valid = $true; Path = $File.FullName; Client = $evidence.Client
            Directory = $evidence.Directory; GitDirectory = $evidence.GitDirectory
            ObservedHead = $evidence.ObservedHead; Layout = if (Test-FleetProperty $evidence 'Layout') { $evidence.Layout } else { 'JobWindows' }
            WindowNonce = if (Test-FleetProperty $evidence 'WindowNonce') { $evidence.WindowNonce } else { $null }
            LaunchNonce = $nonce; Window = $window
            RegistrationTimedOut = (Test-Path -LiteralPath $timeoutPath -PathType Leaf)
            Invocations = @(Get-FleetStatusInvocations $evidence $nonce $InstallRoot $Diagnostics ($window.State -ceq 'absent'))
        }
    } catch {
        Add-FleetStatusDiagnostic $Diagnostics 'binding-invalid' $_.Exception.Message $File.FullName
        $null
    }
}

function Get-FleetStatusCollection([string]$InstallRoot, [string]$LockHash, [string]$JobId = '') {
    $manifestPath = Join-Path $InstallRoot 'manifest.json'
    $state = Join-Path $InstallRoot 'state'
    $diagnostics = [Collections.Generic.List[object]]::new()
    $manifest = Read-FleetSharedText $manifestPath | ConvertFrom-Json -ErrorAction Stop
    $ids = @(Get-FleetJobIds $manifest)
    if ($JobId -and $JobId -cnotin $ids) { throw "The Jobs ID is not configured: $JobId" }
    $selectedIds = if ($JobId) { @($JobId) } else { $ids }
    $configuredById = @{}
    foreach ($entry in @($manifest.Jobs)) { $configuredById[$entry.Id] = $entry }

    $files = @(Get-ChildItem -LiteralPath $state -Filter 'job-*.json' -File -ErrorAction Stop | Sort-Object Name)
    if ($files.Count -gt 128) {
        Add-FleetStatusDiagnostic $Diagnostics 'bindings-truncated' 'More than 128 job state files exist; the first 128 are shown.' $state
        $files = @($files | Select-Object -First 128)
    }
    $pendingById = @{}
    $instanceById = @{}
    $extras = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        if ($file.Name -cnotmatch '^job-(?<id>[a-z][a-z0-9-]{0,31})\.(?<kind>pending|instance)\.json$') {
            Add-FleetStatusDiagnostic $Diagnostics 'binding-unexpected-filename' 'Unexpected job state file name in Fleet state directory.' $file.FullName
            continue
        }
        $fid = $Matches.id
        $kind = $Matches.kind
        $binding = Get-FleetStatusBinding $file $LockHash $InstallRoot $diagnostics
        if ($null -eq $binding) { continue }
        if ($binding.Id -cne $fid) {
            Add-FleetStatusDiagnostic $Diagnostics 'binding-id-mismatch' 'The Jobs state file ID differs from its binding.' $file.FullName $fid
            continue
        }
        if ($fid -cnotin $ids) {
            if (-not $JobId -or $fid -ceq $JobId) {
                $extras.Add([pscustomobject]@{ Id = $fid; Kind = $kind; Binding = $binding })
            }
            continue
        }
        if ($kind -eq 'pending') { $pendingById[$fid] = $binding } else { $instanceById[$fid] = $binding }
    }

    $accountedHandles = [Collections.Generic.HashSet[long]]::new()
    foreach ($b in (@($pendingById.Values) + @($instanceById.Values) + @($extras | ForEach-Object Binding))) {
        if ($b -and $b.Window.Handle) { [void]$accountedHandles.Add([long]$b.Window.Handle) }
    }
    foreach ($w in @([FleetWindow]::FindJobTitles($LockHash))) {
        if (-not $accountedHandles.Contains([long]$w)) {
            Add-FleetStatusDiagnostic $Diagnostics 'unaccounted-job-window' 'A live Agent Fleet window matches this installation without a matching binding.' $state
        }
    }

    $rows = [Collections.Generic.List[object]]::new()
    foreach ($id in $selectedIds) {
        $cfg = $configuredById[$id]
        $git = Get-FleetGitStatus ([string]$cfg.Directory)
        $rows.Add([pscustomobject]@{
            Id = $id
            Configured = [pscustomobject]@{
                Client = $cfg.Client
                Directory = $cfg.Directory
            }
            Pending = if ($pendingById.ContainsKey($id)) { $pendingById[$id] } else { $null }
            Instance = if ($instanceById.ContainsKey($id)) { $instanceById[$id] } else { $null }
            Git = $git
        })
    }

    $claudeExe = if (Test-FleetProperty $manifest 'Claude') { [string]$manifest.Claude } else { '' }
    [pscustomobject]@{
        Jobs = $rows.ToArray()
        UnconfiguredBindings = $extras.ToArray()
        ProviderSessions = [pscustomobject]@{
            Claude = Get-FleetClaudeSessions $claudeExe
        }
        Diagnostics = $diagnostics.ToArray()
    }
}

function Get-FleetLifecycleStatus([string]$InstallRoot, [string]$LockHash, [string]$JobId = '') {
    $started = [DateTime]::UtcNow.ToString('o')
    $snapshot = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $before = Get-FleetStatusFileStamp (Get-FleetStatusFileSet $InstallRoot)
        $collection = Get-FleetStatusCollection $InstallRoot $LockHash $JobId
        $after = Get-FleetStatusFileStamp (Get-FleetStatusFileSet $InstallRoot)
        $consistent = ($before -join "`n") -ceq ($after -join "`n")
        if ($consistent -or $attempt -eq 2) {
            $finished = [DateTime]::UtcNow.ToString('o')
            $diagList = [Collections.Generic.List[object]]::new()
            foreach ($d in @($collection.Diagnostics)) { $diagList.Add($d) }
            if (-not $consistent) {
                Add-FleetStatusDiagnostic $diagList 'snapshot-concurrent-change' 'State files changed concurrently while collecting status.' $InstallRoot
            }
            $hasErrors = @($diagList).Count -gt 0
            $snapshot = [ordered]@{
                SchemaVersion = 2
                CollectionStartedAtUtc = $started
                CollectionFinishedAtUtc = $finished
                Result = if ($hasErrors) { 'degraded' } else { 'observed' }
                Jobs = $collection.Jobs
                UnconfiguredBindings = $collection.UnconfiguredBindings
                ProviderSessions = $collection.ProviderSessions
                Diagnostics = $diagList.ToArray()
                ExitCode = if ($hasErrors) { 1 } else { 0 }
            }
            break
        }
    }
    [pscustomobject]$snapshot
}

function Write-FleetJobState([string]$Path, $Value) {
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('n') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Move-FleetFileReplacing $temporary $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Read-FleetJobEvidence([string]$Path, [string]$LockHash, [string]$InstallRoot = $PSScriptRoot) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The Jobs state file is missing: $Path" }
    $evidence = Read-FleetSharedText $Path | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('Id','Client','Directory','GitDirectory','ObservedHead','NativeExecutable','InstallationTag','Property','InstanceProperty','WindowName','Title','TitleMode','ContextPath')) {
        if (-not (Test-FleetProperty $evidence $field) -or $evidence.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($evidence.$field)) {
            throw "The Jobs state binding is missing or invalid: $field in $Path"
        }
    }
    $layout = 'JobWindows'
    if (Test-FleetProperty $evidence 'Layout') {
        if ($evidence.Layout -isnot [string] -or $evidence.Layout -cnotin @('JobWindows', 'SingleWindow')) {
            throw "The Jobs state layout is invalid: $Path"
        }
        $layout = $evidence.Layout
    }
    if ($evidence.Id -isnot [string] -or $evidence.Id -cnotmatch '^[a-z][a-z0-9-]{0,31}$' -or
        $evidence.Client -isnot [string] -or $evidence.Client -cnotin @('Codex','Claude','Antigravity','OpenCode') -or
        $evidence.GitDirectory -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($evidence.GitDirectory) -or
        $evidence.InstallationTag -cne $LockHash -or
        $evidence.Property -cne (Get-FleetJobProperty $LockHash $evidence.Id)) {
        throw "The Jobs state binding is incomplete or invalid: $Path"
    }
    if ($layout -ceq 'SingleWindow') {
        if ($evidence.TitleMode -cne 'Native' -or
            $evidence.LaunchNonce -isnot [string] -or $evidence.LaunchNonce -cnotmatch '^[a-f0-9]{32}$' -or
            $evidence.WindowNonce -isnot [string] -or $evidence.WindowNonce -cnotmatch '^[a-f0-9]{32}$' -or
            $evidence.WindowName -cne "AgentFleetJobs-$LockHash-$($evidence.WindowNonce)" -or
            $evidence.Title -cne "Agent Fleet Jobs | $LockHash/$($evidence.WindowNonce)" -or
            $evidence.WindowProperty -cne (Get-FleetWindowProperty $LockHash $evidence.WindowNonce)) {
            throw "The Jobs state binding is incomplete or invalid: $Path"
        }
        $nonce = $evidence.LaunchNonce
    } else {
        if ((Test-FleetProperty $evidence 'WindowNonce') -or (Test-FleetProperty $evidence 'WindowProperty') -or (Test-FleetProperty $evidence 'LaunchNonce')) {
            throw "The Jobs state binding is incomplete or invalid: $Path"
        }
        if ($evidence.WindowName -cnotmatch "^AgentFleetJob-$LockHash-$($evidence.Id)-(?<nonce>[a-f0-9]{32})$") {
            throw "The Jobs state window name is invalid: $Path"
        }
        $nonce = $Matches.nonce
        if ($evidence.Title -cne "Agent Fleet Job [$($evidence.Id)] | $($evidence.Client) | $LockHash/$nonce") {
            throw "The Jobs state binding is incomplete or invalid: $Path"
        }
    }
    $expectedContextPath = Join-Path ([IO.Path]::GetDirectoryName($Path)) "launch-context-$nonce.json"
    if ($evidence.InstanceProperty -cne "AgentFleet.$LockHash.Instance.$nonce" -or
        $evidence.ContextPath -cne $expectedContextPath) {
        throw "The Jobs state binding is incomplete or invalid: $Path"
    }
    $context = Read-FleetLaunchContext $evidence.ContextPath $false $InstallRoot
    $contextLayout = if (Test-FleetProperty $context 'Layout') { $context.Layout } else { 'JobWindows' }
    if ($contextLayout -cne $layout -or
        $context.InstallationTag -cne $LockHash -or $context.Nonce -cne $nonce -or
        $context.Id -cne $evidence.Id -or $context.Client -cne $evidence.Client -or
        $context.Directory -cne $evidence.Directory -or $context.GitDirectory -cne $evidence.GitDirectory -or
        $context.ObservedHead -cne $evidence.ObservedHead -or
        $context.NativeExecutable -cne $evidence.NativeExecutable -or
        $context.WindowName -cne $evidence.WindowName -or $context.Title -cne $evidence.Title -or
        $context.TitleMode -cne $evidence.TitleMode -or
        ($layout -ceq 'SingleWindow' -and $context.WindowNonce -cne $evidence.WindowNonce)) {
        throw "The Jobs state differs from its launch context: $Path"
    }
    $evidence
}

function Confirm-FleetJobWindow($Evidence, [long]$Window, [string]$StateDirectory) {
    $isSingleWindow = (Test-FleetProperty $Evidence 'Layout') -and $Evidence.Layout -ceq 'SingleWindow'
    if (-not [FleetWindow]::Register($Window, $Evidence.Property) -or
        -not [FleetWindow]::Register($Window, $Evidence.InstanceProperty) -or
        -not [FleetWindow]::Register($Window, "AgentFleet.$($Evidence.InstallationTag).Jobs") -or
        ($isSingleWindow -and -not [FleetWindow]::Register($Window, $Evidence.WindowProperty))) {
        throw 'The Jobs window appeared but could not be registered for reuse.'
    }
    $instancePath = Get-FleetJobStatePath $StateDirectory $Evidence.Id 'instance'
    Write-FleetJobState $instancePath $Evidence
    $pendingPath = Get-FleetJobStatePath $StateDirectory $Evidence.Id 'pending'
    Remove-Item -LiteralPath $pendingPath
}

function Resolve-FleetPendingWindow($Evidence, [string]$StateDirectory, [string]$LockHash, [string]$InstallRoot) {
    $instancePath = Get-FleetJobStatePath $StateDirectory $Evidence.Id 'instance'
    $pendingPath = Get-FleetJobStatePath $StateDirectory $Evidence.Id 'pending'
    $isSingleWindow = (Test-FleetProperty $Evidence 'Layout') -and $Evidence.Layout -ceq 'SingleWindow'
    $instanceWindows = @([FleetWindow]::Find($Evidence.InstanceProperty))
    $jobWindows = @([FleetWindow]::Find($Evidence.Property))
    $windowPropMatches = if ($isSingleWindow) { @([FleetWindow]::Find($Evidence.WindowProperty)) } else { @() }
    if (Test-Path -LiteralPath $instancePath -PathType Leaf) {
        $instance = Read-FleetJobEvidence $instancePath $LockHash $InstallRoot
        if ($instance.Id -cne $Evidence.Id) { throw 'The retained instance file belongs to another job. Inspect it before recovery.' }
        if ($instance.InstanceProperty -ceq $Evidence.InstanceProperty) {
            $instanceLayout = if (Test-FleetProperty $instance 'Layout') { $instance.Layout } else { 'JobWindows' }
            $evidenceLayout = if ($isSingleWindow) { 'SingleWindow' } else { 'JobWindows' }
            if ($instanceLayout -cne $evidenceLayout -or
                $instance.WindowName -cne $Evidence.WindowName -or
                $instance.ContextPath -cne $Evidence.ContextPath -or
                $instance.GitDirectory -cne $Evidence.GitDirectory -or
                $instance.NativeExecutable -cne $Evidence.NativeExecutable -or
                ($isSingleWindow -and ($instance.WindowNonce -cne $Evidence.WindowNonce -or $instance.WindowProperty -cne $Evidence.WindowProperty))) {
                throw 'The pending launch differs from the retained instance. Inspect both bindings before recovery.'
            }
            if ($instanceWindows.Count -ne 1 -or $jobWindows.Count -ne 1 -or $instanceWindows[0] -ne $jobWindows[0] -or
                ($isSingleWindow -and ($windowPropMatches.Count -ne 1 -or $windowPropMatches[0] -ne $instanceWindows[0]))) {
                throw 'The retained instance has no unique live owned window. Inspect it before recovery.'
            }
            Remove-Item -LiteralPath $pendingPath
            return [long]$instanceWindows[0]
        }
        if (@([FleetWindow]::Find($instance.InstanceProperty)).Count -gt 0) {
            throw 'The pending launch differs from a live retained instance. Inspect both bindings before recovery.'
        }
    }
    $titleMatches = @([FleetWindow]::FindTitle($Evidence.Title))
    if ($titleMatches.Count -gt 1) { throw "The pending launch has $($titleMatches.Count) exact window matches. Inspect it before resetting this job." }
    if ($windowPropMatches.Count -gt 1) { throw "The pending launch has $($windowPropMatches.Count) matching window property handles. Inspect it before resetting this job." }
    if ($titleMatches.Count -eq 1 -and $windowPropMatches.Count -eq 1 -and $titleMatches[0] -ne $windowPropMatches[0]) {
        throw 'The pending launch title and window property identify different windows. Inspect it before recovery.'
    }
    $matches = @(@($windowPropMatches) + @($titleMatches) | Select-Object -Unique)
    if ($matches.Count -ne 1) { throw "The pending launch has $($matches.Count) exact window matches. Inspect it before resetting this job." }
    if (($instanceWindows.Count -gt 0 -and ($instanceWindows.Count -ne 1 -or $instanceWindows[0] -ne $matches[0])) -or
        ($jobWindows.Count -gt 0 -and ($jobWindows.Count -ne 1 -or $jobWindows[0] -ne $matches[0]))) {
        throw 'The pending launch properties identify another window. Inspect it before recovery.'
    }
    Confirm-FleetJobWindow $Evidence ([long]$matches[0]) $StateDirectory
    return [long]$matches[0]
}

function Invoke-FleetJobBatch($Manifest, [string]$JobId, [bool]$ResetPending, [bool]$Arrange,
    [string]$StateDirectory, [string]$LockHash, [string]$InstallRoot = $PSScriptRoot) {
    $retainedPending = $ResetPending -and $JobId -cmatch '^[a-z][a-z0-9-]{0,31}$' -and (Test-Path -LiteralPath (Get-FleetJobStatePath $StateDirectory $JobId 'pending') -PathType Leaf)
    $ids = @(try { Get-FleetJobIds $Manifest } catch { if (-not $retainedPending) { throw } })
    if ($JobId -and $JobId -cnotin $ids -and -not $retainedPending) { throw "The Jobs ID is not configured: $JobId" }
    if ($ResetPending -and -not $JobId) { throw '-ResetPending requires -Job in Jobs mode.' }
    if ($Arrange -and $JobId) { throw '-Arrange applies to the configured Jobs layout; omit -Job.' }
    if ($Arrange -and $ResetPending) { throw '-Arrange cannot be combined with -ResetPending.' }
    $selectedIds = if ($JobId) { @($JobId) } else { $ids }
    $results = [Collections.Generic.List[object]]::new()
    $byId = @{}
    foreach ($id in $selectedIds) {
        $result = [pscustomobject]@{ Id = $id; Result = 'error'; Message = ''; Notice = $false; Window = $null; FocusGranted = $null; ObservedHead = $null }
        $results.Add($result)
        $byId[$id] = $result
    }
    $bindings = [Collections.Generic.List[object]]::new()
    $accounted = [Collections.Generic.HashSet[long]]::new()
    $liveLayoutByHandle = @{}
    $uncertainState = $false
    foreach ($file in @(Get-ChildItem -LiteralPath $StateDirectory -Filter 'job-*.json')) {
        if ($file.Name -cnotmatch '^job-(?<id>[a-z][a-z0-9-]{0,31})\.(?<kind>pending|instance)\.json$') {
            $uncertainState = $true
            continue
        }
        $fileId = $Matches.id
        $kind = $Matches.kind
        try {
            $evidence = Read-FleetJobEvidence $file.FullName $LockHash $InstallRoot
            if ($evidence.Id -cne $fileId) { throw 'The Jobs state file ID differs from its binding.' }
            $isEvidenceSingleWindow = (Test-FleetProperty $evidence 'Layout') -and $evidence.Layout -ceq 'SingleWindow'
            if ($kind -eq 'pending') {
                $bindings.Add($evidence)
                foreach ($window in @([FleetWindow]::FindTitle($evidence.Title))) { [void]$accounted.Add([long]$window) }
                if ($isEvidenceSingleWindow) {
                    foreach ($window in @([FleetWindow]::Find($evidence.WindowProperty))) {
                        [void]$accounted.Add([long]$window)
                        $liveLayoutByHandle[[long]$window] = 'SingleWindow'
                    }
                }
            } else {
                $live = @([FleetWindow]::Find($evidence.InstanceProperty))
                if ($live.Count -gt 1) { $uncertainState = $true }
                if ($live.Count -gt 0) {
                    $bindings.Add($evidence)
                    foreach ($window in $live) {
                        [void]$accounted.Add([long]$window)
                        if ($isEvidenceSingleWindow) { $liveLayoutByHandle[[long]$window] = 'SingleWindow' }
                    }
                }
            }
        } catch { $uncertainState = $true }
    }
    foreach ($window in @([FleetWindow]::FindJobTitles($LockHash))) {
        if (-not $accounted.Contains([long]$window)) { $uncertainState = $true }
    }
    foreach ($window in @([FleetWindow]::Find("AgentFleet.$LockHash.Jobs"))) {
        if (-not $accounted.Contains([long]$window)) { $uncertainState = $true }
    }
    $focusedByHandle = @{}
    if (-not $ResetPending -and -not $Arrange) {
        foreach ($id in $selectedIds) {
            $pendingPath = Get-FleetJobStatePath $StateDirectory $id 'pending'
            if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) { continue }
            try {
                $evidence = Read-FleetJobEvidence $pendingPath $LockHash $InstallRoot
                $window = Resolve-FleetPendingWindow $evidence $StateDirectory $LockHash $InstallRoot
                $byId[$id].Window = $window
                $byId[$id].Result = 'recovered'
                $byId[$id].Message = 'The exact pending window was recovered.'
                if (-not $focusedByHandle.ContainsKey($window)) { $focusedByHandle[$window] = [FleetWindow]::Focus($window) }
                $focused = [bool]$focusedByHandle[$window]
                $byId[$id].FocusGranted = $focused
                if (-not $focused) {
                    $byId[$id].Message += ' Select it from the taskbar.'
                    $byId[$id].Notice = $true
                }
                $nonce = Get-FleetEvidenceNonce $evidence
                if ($nonce -and @(Get-ChildItem -LiteralPath $StateDirectory -Filter "invocation-$nonce-*.json").Count -eq 0) {
                    if (Test-Path -LiteralPath (Join-Path $StateDirectory "registration-timeout-$nonce.json") -PathType Leaf) {
                        $byId[$id].Message += ' No client call is recorded for it. If its shell shows the registration timeout, start the client there or close the window.'
                        $byId[$id].Notice = $true
                    } else {
                        $byId[$id].Message += ' If its shell is still waiting, its client starts now.'
                    }
                }
            } catch {
                $byId[$id].Result = 'blocked'
                $byId[$id].Message = $_.Exception.Message
            }
        }
    }
    $existing = @{}
    foreach ($id in $selectedIds) {
        if ($byId[$id].Result -ne 'error') { continue }
        $property = Get-FleetJobProperty $LockHash $id
        $windows = @([FleetWindow]::Find($property))
        if ($windows.Count -gt 1) {
            $byId[$id].Result = 'blocked'
            $byId[$id].Message = 'More than one owned window matches this job.'
        } elseif ($windows.Count -eq 1) {
            $existing[$id] = [long]$windows[0]
            $byId[$id].Window = $existing[$id]
            $byId[$id].Result = 'existing'
            $byId[$id].Message = 'The owned window is open. Its sessions and position are unchanged.'
            if (-not $Arrange -and -not $ResetPending) {
                $hwnd = $existing[$id]
                if (-not $focusedByHandle.ContainsKey($hwnd)) { $focusedByHandle[$hwnd] = [FleetWindow]::Focus($hwnd) }
                $focused = [bool]$focusedByHandle[$hwnd]
                $byId[$id].FocusGranted = $focused
                if (-not $focused) {
                    $byId[$id].Message = 'The owned window is open, but focus was denied. Select it from the taskbar; its sessions are unchanged.'
                    $byId[$id].Notice = $true
                }
            }
            if (-not $accounted.Contains($existing[$id])) { $uncertainState = $true }
        }
    }
    if ($ResetPending) {
        $pendingPath = Get-FleetJobStatePath $StateDirectory $JobId 'pending'
        if ($byId[$JobId].Result -eq 'blocked') {
        } elseif ($existing.ContainsKey($JobId)) {
            $byId[$JobId].Result = 'blocked'
            $byId[$JobId].Message = 'An owned window is open. Close it before resetting this pending job.'
        } elseif ($uncertainState) {
            $byId[$JobId].Result = 'blocked'
            $byId[$JobId].Message = 'Jobs state or window identity is uncertain. Inspect it before resetting this job.'
        } elseif (Test-Path -LiteralPath $pendingPath) {
            try {
                $evidence = Read-FleetJobEvidence $pendingPath $LockHash $InstallRoot
                $matches = @(@([FleetWindow]::FindTitle($evidence.Title)) + $(if ((Test-FleetProperty $evidence 'Layout') -and $evidence.Layout -ceq 'SingleWindow') { @([FleetWindow]::Find($evidence.WindowProperty)) } else { @() }) | Select-Object -Unique)
                if ($matches.Count -ne 0) {
                    $byId[$JobId].Result = 'blocked'
                    $byId[$JobId].Message = "$($matches.Count) exact window matches remain. Close or inspect them before reset."
                } else {
                    Remove-Item -LiteralPath $pendingPath
                    $byId[$JobId].Result = 'reset'
                    $byId[$JobId].Message = 'The pending operation was cleared after operator inspection.'
                }
            } catch {
                $byId[$JobId].Result = 'blocked'
                $byId[$JobId].Message = $_.Exception.Message
            }
        } else {
            $byId[$JobId].Result = 'reset'
            $byId[$JobId].Message = 'No pending operation remains for this job.'
        }
        $overall = if ($byId[$JobId].Result -eq 'blocked') { 'partial' } else { 'reset' }
        return [pscustomobject]@{ Result = $overall; Jobs = $results.ToArray() }
    }
    if ($Arrange) {
        $area = [FleetWindow]::GetCurrentWorkArea()
        $handleJobCounts = @{}
        foreach ($hwnd in $existing.Values) {
            $key = [long]$hwnd
            $handleJobCounts[$key] = if ($handleJobCounts.ContainsKey($key)) { $handleJobCounts[$key] + 1 } else { 1 }
        }
        $placedByHandle = @{}
        for ($index = 0; $index -lt $ids.Count; $index++) {
            $id = $ids[$index]
            $result = $byId[$id]
            if ($result.Result -eq 'blocked') { continue }
            if (-not $existing.ContainsKey($id)) {
                $result.Result = 'skipped'
                $result.Message = 'No registered window is open for this job.'
                continue
            }
            $hwnd = [long]$existing[$id]
            if ($placedByHandle.ContainsKey($hwnd)) {
                $result.Result = 'arranged'
                $result.Message = $placedByHandle[$hwnd]
                continue
            }
            $isShared = $handleJobCounts[$hwnd] -gt 1 -or ($liveLayoutByHandle.ContainsKey($hwnd) -and $liveLayoutByHandle[$hwnd] -ceq 'SingleWindow')
            $bounds = if ($isShared) { [FleetWindow]::TileBounds($area, 0, 1) } else { [FleetWindow]::TileBounds($area, $index, $ids.Count) }
            if ([FleetWindow]::Place($hwnd, $bounds)) {
                $msg = if ($isShared) { 'Placed the shared Jobs window to fill the current work area.' } else { 'Placed this job window in its tile.' }
                $placedByHandle[$hwnd] = $msg
                $result.Result = 'arranged'
                $result.Message = $msg
            } else {
                $result.Result = 'blocked'
                $result.Message = 'The window position could not be changed.'
            }
        }
        $overall = if (@($results | Where-Object { $_.Result -eq 'blocked' }).Count -gt 0) { 'partial' } else { 'arranged' }
        return [pscustomobject]@{ Result = $overall; Jobs = $results.ToArray() }
    }

    $openIds = @($selectedIds | Where-Object { $byId[$_].Result -eq 'error' })
    if ($openIds.Count -eq 0) {
        $overall = if (@($results | Where-Object { $_.Result -eq 'blocked' }).Count -gt 0) { 'partial' } else { 'focused' }
        return [pscustomobject]@{ Result = $overall; Jobs = $results.ToArray() }
    }
    if ($uncertainState) {
        foreach ($id in $openIds) {
            $byId[$id].Result = 'blocked'
            $byId[$id].Message = 'Jobs state or window identity is uncertain. Inspect before opening another window.'
        }
        return [pscustomobject]@{ Result = 'partial'; Jobs = $results.ToArray() }
    }

    $layout = Get-FleetJobsLayout $Manifest
    $openFleetPath = Join-Path $PSScriptRoot 'Open-Fleet.ps1'
    $allPlanned = @(Get-FleetJobs $Manifest $InstallRoot $openFleetPath '')
    $byPlannedId = @{}
    foreach ($p in $allPlanned) { $byPlannedId[$p.Id] = $p }
    $toOpen = @($openIds | ForEach-Object { $byPlannedId[$_] })

    $area = [FleetWindow]::GetCurrentWorkArea()
    if ($layout -ceq 'SingleWindow' -and -not $JobId -and $toOpen.Count -gt 0) {
        $canShareOpen = $existing.Count -eq 0
        if ($canShareOpen) {
            $plan = New-FleetSingleWindowPlan $Manifest.PowerShell $openFleetPath $InstallRoot $LockHash $toOpen[0].WindowNonce $toOpen
            foreach ($jobPlan in $toOpen) {
                $ctx = [ordered]@{
                    Nonce = $jobPlan.Nonce; InstallationTag = $LockHash; Id = $jobPlan.Id; Client = $jobPlan.Client
                    Directory = $jobPlan.Directory; GitDirectory = $jobPlan.GitDirectory; ObservedHead = $jobPlan.ObservedHead
                    NativeExecutable = $jobPlan.NativeExecutable; NativeArguments = $jobPlan.NativeArguments; NativeEnv = $jobPlan.NativeEnv
                    WindowName = $jobPlan.WindowName; Title = $jobPlan.Title; TitleMode = 'Native'
                    Layout = 'SingleWindow'; WindowNonce = $plan.WindowNonce
                }
                Write-FleetJobState $jobPlan.ContextPath $ctx
                $ev = [ordered]@{
                    Id = $jobPlan.Id; Client = $jobPlan.Client; Directory = $jobPlan.Directory
                    GitDirectory = $jobPlan.GitDirectory; ObservedHead = $jobPlan.ObservedHead; NativeExecutable = $jobPlan.NativeExecutable
                    InstallationTag = $LockHash; Property = $jobPlan.Property; InstanceProperty = $jobPlan.InstanceProperty
                    WindowName = $plan.WindowName; Title = $plan.Title; TitleMode = 'Native'; ContextPath = $jobPlan.ContextPath
                    Layout = 'SingleWindow'; LaunchNonce = $jobPlan.Nonce; WindowNonce = $plan.WindowNonce; WindowProperty = $plan.WindowProperty
                }
                Write-FleetJobState $jobPlan.StatePath $ev
            }
            try {
                [void](Start-Process -FilePath $Manifest.Terminal -ArgumentList $plan.Arguments)
            } catch {
                foreach ($jobPlan in $toOpen) {
                    if (Test-Path -LiteralPath $jobPlan.StatePath) { Remove-Item -LiteralPath $jobPlan.StatePath }
                }
                throw
            }
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            $foundHwnd = $null
            while ($deadline.ElapsedMilliseconds -lt 25000) {
                $titleWins = @([FleetWindow]::FindTitle($plan.Title))
                if ($titleWins.Count -gt 1) { throw 'Multiple windows match the newly opened SingleWindow title.' }
                if ($titleWins.Count -eq 1) { $foundHwnd = [long]$titleWins[0]; break }
                Start-Sleep -Milliseconds 150
            }
            if ($null -eq $foundHwnd) {
                foreach ($jobPlan in $toOpen) {
                    $byId[$jobPlan.Id].Result = 'blocked'
                    $byId[$jobPlan.Id].Message = 'Terminal was requested, but its window was not observed. Inspect or reset pending state before retrying.'
                    $byId[$jobPlan.Id].ObservedHead = $jobPlan.ObservedHead
                }
                return [pscustomobject]@{ Result = 'partial'; Jobs = $results.ToArray() }
            }
            foreach ($jobPlan in $toOpen) {
                $ev = Read-FleetSharedText $jobPlan.StatePath | ConvertFrom-Json
                Confirm-FleetJobWindow $ev $foundHwnd $StateDirectory
                $byId[$jobPlan.Id].Window = $foundHwnd
                $byId[$jobPlan.Id].Result = 'launched'
                $byId[$jobPlan.Id].ObservedHead = $jobPlan.ObservedHead
                $byId[$jobPlan.Id].Message = 'Opened shared Agent Fleet Jobs window.'
            }
            $bounds = [FleetWindow]::TileBounds($area, 0, 1)
            [void][FleetWindow]::Place($foundHwnd, $bounds)
            return [pscustomobject]@{ Result = 'launched'; Jobs = $results.ToArray() }
        }
    }

    for ($i = 0; $i -lt $toOpen.Count; $i++) {
        $jobPlan = $toOpen[$i]
        $slotIndex = [Array]::IndexOf($ids, $jobPlan.Id)
        $windowName = "AgentFleetJob-$LockHash-$($jobPlan.Id)-$($jobPlan.Nonce)"
        $title = "Agent Fleet Job [$($jobPlan.Id)] | $($jobPlan.Client) | $LockHash/$($jobPlan.Nonce)"
        $ctx = [ordered]@{
            Nonce = $jobPlan.Nonce; InstallationTag = $LockHash; Id = $jobPlan.Id; Client = $jobPlan.Client
            Directory = $jobPlan.Directory; GitDirectory = $jobPlan.GitDirectory; ObservedHead = $jobPlan.ObservedHead
            NativeExecutable = $jobPlan.NativeExecutable; NativeArguments = $jobPlan.NativeArguments; NativeEnv = $jobPlan.NativeEnv
            WindowName = $windowName; Title = $title; TitleMode = 'Native'; Layout = 'JobWindows'
        }
        Write-FleetJobState $jobPlan.ContextPath $ctx
        $ev = [ordered]@{
            Id = $jobPlan.Id; Client = $jobPlan.Client; Directory = $jobPlan.Directory
            GitDirectory = $jobPlan.GitDirectory; ObservedHead = $jobPlan.ObservedHead; NativeExecutable = $jobPlan.NativeExecutable
            InstallationTag = $LockHash; Property = $jobPlan.Property; InstanceProperty = $jobPlan.InstanceProperty
            WindowName = $windowName; Title = $title; TitleMode = 'Native'; ContextPath = $jobPlan.ContextPath; Layout = 'JobWindows'
        }
        Write-FleetJobState $jobPlan.StatePath $ev
        $paneArgs = @('-w', $windowName, 'new-tab') + (New-FleetJobPaneArguments $Manifest.PowerShell $openFleetPath $InstallRoot $jobPlan $jobPlan.ContextPath $title)
        try {
            [void](Start-Process -FilePath $Manifest.Terminal -ArgumentList $paneArgs)
        } catch {
            if (Test-Path -LiteralPath $jobPlan.StatePath) { Remove-Item -LiteralPath $jobPlan.StatePath }
            $byId[$jobPlan.Id].Result = 'blocked'
            $byId[$jobPlan.Id].Message = $_.Exception.Message
            continue
        }
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        $foundHwnd = $null
        while ($deadline.ElapsedMilliseconds -lt 20000) {
            $titleWins = @([FleetWindow]::FindTitle($title))
            if ($titleWins.Count -gt 1) { break }
            if ($titleWins.Count -eq 1) { $foundHwnd = [long]$titleWins[0]; break }
            Start-Sleep -Milliseconds 150
        }
        if ($null -eq $foundHwnd) {
            $byId[$jobPlan.Id].Result = 'blocked'
            $byId[$jobPlan.Id].Message = 'Terminal was requested, but its window was not observed. Inspect or reset pending state before retrying.'
            $byId[$jobPlan.Id].ObservedHead = $jobPlan.ObservedHead
            continue
        }
        Confirm-FleetJobWindow $ev $foundHwnd $StateDirectory
        $bounds = [FleetWindow]::TileBounds($area, $slotIndex, $ids.Count)
        [void][FleetWindow]::Place($foundHwnd, $bounds)
        $byId[$jobPlan.Id].Window = $foundHwnd
        $byId[$jobPlan.Id].Result = 'launched'
        $byId[$jobPlan.Id].ObservedHead = $jobPlan.ObservedHead
        $byId[$jobPlan.Id].Message = 'Opened dedicated Agent Fleet job window.'
    }
    $overall = if (@($results | Where-Object { $_.Result -eq 'blocked' }).Count -gt 0) { 'partial' } else { 'launched' }
    [pscustomobject]@{ Result = $overall; Jobs = $results.ToArray() }
}
