$ErrorActionPreference = 'Stop'

function Get-FleetNotifyRoot([string]$InstallRoot) {
    Join-Path $InstallRoot 'notifications'
}

function Get-FleetNotifyConfigRoot([string]$ConfigRoot) {
    if (-not [string]::IsNullOrWhiteSpace($ConfigRoot)) { return [IO.Path]::GetFullPath($ConfigRoot) }
    [Environment]::GetFolderPath('UserProfile')
}

function Read-FleetNotifyJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Write-FleetNotifyJson([string]$Path, $Value) {
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if ($directory) { [void][IO.Directory]::CreateDirectory($directory) }
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('n') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-FleetNotifyPowerShellPath([string]$InstallRoot) {
    $manifestPath = Join-Path $InstallRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($manifest.PowerShell -is [string] -and -not [string]::IsNullOrWhiteSpace($manifest.PowerShell)) {
                return [IO.Path]::GetFullPath($manifest.PowerShell)
            }
        } catch { }
    }
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return [IO.Path]::GetFullPath($command.Source) }
    throw 'The PowerShell 7 executable could not be resolved.'
}

function ConvertTo-FleetNotifyCommandPath([string]$Path) {
    if ($Path.Contains('"')) { throw "A notification path cannot contain a double quote: $Path" }
    $Path.Replace('\', '/')
}

function New-FleetNotifyHookCommand([string]$PowerShell, [string]$Script, [string[]]$Arguments) {
    $exe = ConvertTo-FleetNotifyCommandPath $PowerShell
    $file = ConvertTo-FleetNotifyCommandPath $Script
    $parts = @('"' + $exe + '"', '-NoLogo', '-NoProfile', '-File', ('"' + $file + '"'))
    foreach ($argument in $Arguments) {
        if ($argument.Contains('"')) { throw "A notification argument cannot contain a double quote: $argument" }
        $parts += ('"' + $argument + '"')
    }
    $parts -join ' '
}

function Backup-FleetNotifyFile([string]$Path, [string]$BackupRoot) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    [void][IO.Directory]::CreateDirectory($BackupRoot)
    $name = ($Path -replace '[\\/:*?"<>|]', '_')
    $backup = Join-Path $BackupRoot ($name + '.bak')
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    $backup
}

function Get-FleetNotifyFileHash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-FleetNotifyHandler($Handler) {
    $id = [string]$Handler['_id']
    $command = [string]$Handler['command']
    ($id -like 'fleet-notify-*') -or ($command -match 'FleetNotify(\.ps1|Antigravity\.ps1)')
}

function Remove-FleetNotifyHandlers($Groups) {
    $kept = [Collections.Generic.List[object]]::new()
    foreach ($group in @($Groups)) {
        if ($null -eq $group -or $group -isnot [System.Collections.IDictionary]) { continue }
        $handlers = @($group['hooks'] | Where-Object { $null -ne $_ })
        $filtered = @($handlers | Where-Object { -not (Test-FleetNotifyHandler $_) })
        if ($filtered.Count -gt 0) {
            $group['hooks'] = $filtered
            $kept.Add($group)
        }
    }
    return $kept.ToArray()
}

function Get-FleetNotifyHooksMap($Settings) {
    if ($Settings.Contains('hooks') -and $Settings['hooks'] -is [System.Collections.IDictionary]) { return $Settings['hooks'] }
    $hooks = [ordered]@{}
    $Settings['hooks'] = $hooks
    $hooks
}

function Test-FleetNotifySettings([string]$Path, [string[]]$Events) {
    $settings = Read-FleetNotifyJson $Path
    if ($null -eq $settings -or -not $settings.Contains('hooks')) { return $false }
    $hooks = $settings['hooks']
    foreach ($event in $Events) {
        if (-not $hooks.Contains($event)) { continue }
        foreach ($group in @($hooks[$event])) {
            if ($null -eq $group -or $group -isnot [System.Collections.IDictionary]) { continue }
            foreach ($handler in @($group['hooks'])) {
                if ($null -ne $handler -and (Test-FleetNotifyHandler $handler)) { return $true }
            }
        }
    }
    return $false
}

function Install-FleetNotifyClaude([string]$Path, [string]$PowerShell, [string]$Notify, [switch]$DryRun) {
    $settings = Read-FleetNotifyJson $Path
    if ($null -eq $settings) { $settings = [ordered]@{} }
    $hooks = Get-FleetNotifyHooksMap $settings
    foreach ($event in @('Stop', 'Notification', 'StopFailure')) {
        $hooks[$event] = @(Remove-FleetNotifyHandlers $hooks[$event] | Where-Object { $null -ne $_ })
    }
    $stop = New-FleetNotifyHookCommand $PowerShell $Notify @('-Client', 'Claude', '-Event', 'done')
    $attention = New-FleetNotifyHookCommand $PowerShell $Notify @('-Client', 'Claude', '-Event', 'attention')
    $errorCommand = New-FleetNotifyHookCommand $PowerShell $Notify @('-Client', 'Claude', '-Event', 'error')
    $hooks['Stop'] = @($hooks['Stop'] | Where-Object { $null -ne $_ }) + @([ordered]@{
        hooks = @([ordered]@{ type = 'command'; command = $stop; _id = 'fleet-notify-claude-stop'; async = $true; timeout = 10 })
    })
    $hooks['Notification'] = @($hooks['Notification'] | Where-Object { $null -ne $_ }) + @([ordered]@{
        matcher = 'permission_prompt|idle_prompt'
        hooks = @([ordered]@{ type = 'command'; command = $attention; _id = 'fleet-notify-claude-attention'; async = $true; timeout = 10 })
    })
    $hooks['StopFailure'] = @($hooks['StopFailure'] | Where-Object { $null -ne $_ }) + @([ordered]@{
        hooks = @([ordered]@{ type = 'command'; command = $errorCommand; _id = 'fleet-notify-claude-error'; async = $true; timeout = 10 })
    })
    if (-not $DryRun) { Write-FleetNotifyJson $Path $settings }
    [pscustomobject]@{ Path = $Path; Hooks = @('Stop', 'Notification', 'StopFailure') }
}

function Install-FleetNotifyCodex([string]$Path, [string]$PowerShell, [string]$Notify, [switch]$DryRun) {
    $settings = Read-FleetNotifyJson $Path
    if ($null -eq $settings) { $settings = [ordered]@{} }
    $hooks = Get-FleetNotifyHooksMap $settings
    foreach ($event in @('Stop', 'PermissionRequest')) {
        $hooks[$event] = @(Remove-FleetNotifyHandlers $hooks[$event] | Where-Object { $null -ne $_ })
    }
    $stop = New-FleetNotifyHookCommand $PowerShell $Notify @('-Client', 'Codex', '-Event', 'done')
    $attention = New-FleetNotifyHookCommand $PowerShell $Notify @('-Client', 'Codex', '-Event', 'attention')
    $hooks['Stop'] = @($hooks['Stop'] | Where-Object { $null -ne $_ }) + @([ordered]@{
        hooks = @([ordered]@{ type = 'command'; command = $stop; async = $true; timeout = 10 })
    })
    $hooks['PermissionRequest'] = @($hooks['PermissionRequest'] | Where-Object { $null -ne $_ }) + @([ordered]@{
        hooks = @([ordered]@{ type = 'command'; command = $attention; async = $true; timeout = 10 })
    })
    if (-not $DryRun) { Write-FleetNotifyJson $Path $settings }
    [pscustomobject]@{ Path = $Path; Hooks = @('Stop', 'PermissionRequest') }
}

function Install-FleetNotifyAntigravity([string]$Path, [string]$PowerShell, [string]$Wrapper, [switch]$DryRun) {
    $settings = Read-FleetNotifyJson $Path
    if ($null -eq $settings) { $settings = [ordered]@{} }
    $attention = New-FleetNotifyHookCommand $PowerShell $Wrapper @('-Event', 'attention')
    $done = New-FleetNotifyHookCommand $PowerShell $Wrapper @('-Event', 'done')
    $settings['fleet-notify'] = [ordered]@{
        PreToolUse = @([ordered]@{
            matcher = 'ask_permission|ask_question'
            hooks = @([ordered]@{ type = 'command'; command = $attention; timeout = 10 })
        })
        Stop = @([ordered]@{ type = 'command'; command = $done; timeout = 10 })
    }
    if (-not $DryRun) { Write-FleetNotifyJson $Path $settings }
    [pscustomobject]@{ Path = $Path; Hooks = @('PreToolUse:ask_permission|ask_question', 'Stop') }
}

function Install-FleetNotifyOpenCode([string]$Path, [string]$NotifyRoot, [switch]$DryRun) {
    $settings = Read-FleetNotifyJson $Path
    if ($null -eq $settings) {
        $settings = [ordered]@{ '$schema' = 'https://opencode.ai/v2/cli.json' }
    }
    $matrix = Read-FleetNotifyJson (Join-Path $NotifyRoot 'notifications.json')
    if ($null -eq $matrix -or -not $matrix.Contains('OpenCode')) { throw 'The notification matrix is missing the OpenCode entry.' }
    $local = Read-FleetNotifyJson (Join-Path $NotifyRoot 'notifications.local.json')
    $entry = [ordered]@{}
    foreach ($key in @('done', 'attention', 'error')) { $entry[$key] = $matrix['OpenCode'][$key] }
    if ($null -ne $local -and $local.Contains('OpenCode') -and $local['OpenCode'] -is [System.Collections.IDictionary]) {
        foreach ($key in @('done', 'attention', 'error')) {
            if ($local['OpenCode'].Contains($key)) { $entry[$key] = $local['OpenCode'][$key] }
        }
    }
    $attention = if ($settings.Contains('attention') -and $settings['attention'] -is [System.Collections.IDictionary]) { $settings['attention'] } else { [ordered]@{} }
    $sounds = if ($attention.Contains('sounds') -and $attention['sounds'] -is [System.Collections.IDictionary]) { $attention['sounds'] } else { [ordered]@{} }
    $attention['enabled'] = $true
    $attention['notifications'] = $true
    $attention['sound'] = $true
    if (-not $attention.Contains('volume')) { $attention['volume'] = 0.4 }
    $sounds['done'] = [Environment]::ExpandEnvironmentVariables([string]$entry['done'])
    $sounds['permission'] = [Environment]::ExpandEnvironmentVariables([string]$entry['attention'])
    $sounds['question'] = [Environment]::ExpandEnvironmentVariables([string]$entry['attention'])
    $sounds['error'] = [Environment]::ExpandEnvironmentVariables([string]$entry['error'])
    $sounds['subagent_done'] = [Environment]::ExpandEnvironmentVariables([string]$entry['done'])
    $attention['sounds'] = $sounds
    $settings['attention'] = $attention
    if (-not $DryRun) { Write-FleetNotifyJson $Path $settings }
    [pscustomobject]@{ Path = $Path; Hooks = @('attention') }
}

function Get-FleetNotifyOpenCodePath([string]$ConfigRoot) {
    $cli = Join-Path $ConfigRoot '.config/opencode/cli.json'
    $tui = Join-Path $ConfigRoot '.config/opencode/tui.json'
    if (Test-Path -LiteralPath $cli -PathType Leaf) { return $cli }
    if (Test-Path -LiteralPath $tui -PathType Leaf) { return $tui }
    $cli
}

function Install-FleetNotifyHooks([string]$InstallRoot, [string]$ConfigRoot = '', [switch]$DryRun) {
    $root = Get-FleetNotifyRoot $InstallRoot
    $configHome = Get-FleetNotifyConfigRoot $ConfigRoot
    $notify = Join-Path $root 'FleetNotify.ps1'
    $wrapper = Join-Path $root 'FleetNotifyAntigravity.ps1'
    if (-not (Test-Path -LiteralPath $notify -PathType Leaf)) { throw "The notification script is missing: $notify" }
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { throw "The Antigravity notification wrapper is missing: $wrapper" }
    $powerShell = Get-FleetNotifyPowerShellPath $InstallRoot
    $backupRoot = Join-Path $root ('backups/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    $receiptPath = Join-Path $root 'install.json'
    $existing = Read-FleetNotifyJson $receiptPath
    $existingByPath = @{}
    if ($null -ne $existing) {
        foreach ($entry in @($existing['Files'])) { $existingByPath[[string]$entry['Path']] = $entry }
    }
    $targets = @(
        [pscustomobject]@{ Name = 'Claude'; Path = (Join-Path $configHome '.claude/settings.json') }
        [pscustomobject]@{ Name = 'Codex'; Path = (Join-Path $configHome '.codex/hooks.json') }
        [pscustomobject]@{ Name = 'Antigravity'; Path = (Join-Path $configHome '.gemini/config/hooks.json') }
        [pscustomobject]@{ Name = 'OpenCode'; Path = (Get-FleetNotifyOpenCodePath $configHome) }
    )
    $files = [Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        $currentHash = Get-FleetNotifyFileHash $target.Path
        $existingEntry = $existingByPath[$target.Path]
        $reuseBackup = $null -ne $existingEntry -and $currentHash -eq [string]$existingEntry['Hash']
        $backup = if ($reuseBackup) {
            [string]$existingEntry['Backup']
        } elseif ($DryRun) {
            $null
        } else {
            Backup-FleetNotifyFile $target.Path $backupRoot
        }
        switch ($target.Name) {
            'Claude' { [void](Install-FleetNotifyClaude $target.Path $powerShell $notify -DryRun:$DryRun) }
            'Codex' { [void](Install-FleetNotifyCodex $target.Path $powerShell $notify -DryRun:$DryRun) }
            'Antigravity' { [void](Install-FleetNotifyAntigravity $target.Path $powerShell $wrapper -DryRun:$DryRun) }
            'OpenCode' { [void](Install-FleetNotifyOpenCode $target.Path $root -DryRun:$DryRun) }
        }
        $files.Add([ordered]@{
            Client = $target.Name
            Path = $target.Path
            Backup = $backup
            Hash = if ($DryRun) { '' } else { Get-FleetNotifyFileHash $target.Path }
        })
    }
    $receipt = [ordered]@{
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        InstallRoot = $InstallRoot
        Files = $files.ToArray()
    }
    if (-not $DryRun) { Write-FleetNotifyJson (Join-Path $root 'install.json') $receipt }
    [pscustomobject]@{ Result = if ($DryRun) { 'planned' } else { 'installed' }; Files = $files.ToArray() }
}

function Uninstall-FleetNotifyHooks([string]$InstallRoot, [string]$ConfigRoot = '', [switch]$DryRun) {
    $root = Get-FleetNotifyRoot $InstallRoot
    $configHome = Get-FleetNotifyConfigRoot $ConfigRoot
    $receiptPath = Join-Path $root 'install.json'
    $receipt = Read-FleetNotifyJson $receiptPath
    if ($null -eq $receipt) {
        return [pscustomobject]@{ Result = 'not-installed'; Files = @() }
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($file in @($receipt['Files'])) {
        $path = [string]$file['Path']
        $backup = [string]$file['Backup']
        $installedHash = [string]$file['Hash']
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $results.Add([pscustomobject]@{ Path = $path; Result = 'missing' })
            continue
        }
        $currentHash = Get-FleetNotifyFileHash $path
        if ($currentHash -eq $installedHash) {
            if (-not $DryRun) {
                if (-not [string]::IsNullOrWhiteSpace($backup) -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
                    Copy-Item -LiteralPath $backup -Destination $path -Force
                } else {
                    Remove-Item -LiteralPath $path -Force
                }
            }
            $results.Add([pscustomobject]@{ Path = $path; Result = if ($DryRun) { 'would-restore' } else { 'restored' } })
            continue
        }
        # The file changed after installation. Remove only the Fleet hooks and keep the other edits.
        switch ([string]$file['Client']) {
            'Claude' {
                $settings = Read-FleetNotifyJson $path
                if ($null -ne $settings -and $settings.Contains('hooks')) {
                    $hooks = $settings['hooks']
                    foreach ($event in @('Stop', 'Notification', 'StopFailure')) {
                        if ($hooks.Contains($event)) { $hooks[$event] = @(Remove-FleetNotifyHandlers $hooks[$event]) }
                    }
                    if (-not $DryRun) { Write-FleetNotifyJson $path $settings }
                }
                $results.Add([pscustomobject]@{ Path = $path; Result = if ($DryRun) { 'would-remove-hooks' } else { 'hooks-removed' } })
            }
            'Codex' {
                $settings = Read-FleetNotifyJson $path
                if ($null -ne $settings -and $settings.Contains('hooks')) {
                    $hooks = $settings['hooks']
                    foreach ($event in @('Stop', 'PermissionRequest')) {
                        if ($hooks.Contains($event)) { $hooks[$event] = @(Remove-FleetNotifyHandlers $hooks[$event]) }
                    }
                    if (-not $DryRun) { Write-FleetNotifyJson $path $settings }
                }
                $results.Add([pscustomobject]@{ Path = $path; Result = if ($DryRun) { 'would-remove-hooks' } else { 'hooks-removed' } })
            }
            'Antigravity' {
                $settings = Read-FleetNotifyJson $path
                if ($null -ne $settings -and $settings.Contains('fleet-notify')) {
                    $settings.Remove('fleet-notify')
                    if (-not $DryRun) { Write-FleetNotifyJson $path $settings }
                }
                $results.Add([pscustomobject]@{ Path = $path; Result = if ($DryRun) { 'would-remove-hooks' } else { 'hooks-removed' } })
            }
            default {
                $results.Add([pscustomobject]@{ Path = $path; Result = 'kept-changed' })
            }
        }
    }
    if (-not $DryRun) { Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{ Result = if ($DryRun) { 'planned' } else { 'uninstalled' }; Files = $results.ToArray() }
}

function Get-FleetNotifyStatus([string]$InstallRoot, [string]$ConfigRoot = '') {
    $root = Get-FleetNotifyRoot $InstallRoot
    $configHome = Get-FleetNotifyConfigRoot $ConfigRoot
    $local = Read-FleetNotifyJson (Join-Path $root 'notifications.local.json')
    $muted = (Test-Path -LiteralPath (Join-Path $root 'mute')) -or ($null -ne $local -and $local.Contains('muted') -and [bool]$local['muted'])
    $installed = Test-Path -LiteralPath (Join-Path $root 'install.json')
    $hooks = [ordered]@{
        Claude = $false
        Codex = $false
        Antigravity = $false
        OpenCode = $false
    }
    $hooks.Claude = Test-FleetNotifySettings (Join-Path $configHome '.claude/settings.json') @('Stop', 'Notification', 'StopFailure')
    $hooks.Codex = Test-FleetNotifySettings (Join-Path $configHome '.codex/hooks.json') @('Stop', 'PermissionRequest')
    $antigravity = Read-FleetNotifyJson (Join-Path $configHome '.gemini/config/hooks.json')
    if ($null -ne $antigravity) { $hooks.Antigravity = $antigravity.Contains('fleet-notify') }
    $openCode = Read-FleetNotifyJson (Get-FleetNotifyOpenCodePath $configHome)
    if ($null -ne $openCode -and $openCode.Contains('attention') -and $openCode['attention'] -is [System.Collections.IDictionary]) {
        $hooks.OpenCode = [bool]$openCode['attention']['enabled']
    }
    $log = @()
    $logPath = Join-Path $root 'notify.log'
    if (Test-Path -LiteralPath $logPath -PathType Leaf) { $log = @(Get-Content -LiteralPath $logPath -Tail 20) }
    [pscustomobject]@{
        Root = $root
        Installed = $installed
        Muted = $muted
        Hooks = [pscustomobject]$hooks
        Log = $log
    }
}

function Set-FleetNotifyMuted([string]$InstallRoot, [bool]$Muted) {
    $root = Get-FleetNotifyRoot $InstallRoot
    $path = Join-Path $root 'notifications.local.json'
    $local = Read-FleetNotifyJson $path
    if ($null -eq $local) { $local = [ordered]@{} }
    $local['muted'] = $Muted
    Write-FleetNotifyJson $path $local
    [pscustomobject]@{ Muted = $Muted; Path = $path }
}

function Test-FleetNotifySounds([string]$InstallRoot, [switch]$LogOnly) {
    $root = Get-FleetNotifyRoot $InstallRoot
    $notify = Join-Path $root 'FleetNotify.ps1'
    $matrix = Read-FleetNotifyJson (Join-Path $root 'notifications.json')
    if ($null -eq $matrix) { throw 'The notification matrix is missing.' }
    $played = [Collections.Generic.List[object]]::new()
    foreach ($client in @('Claude', 'Codex', 'Antigravity', 'OpenCode')) {
        foreach ($event in @('done', 'attention', 'error')) {
            $entry = $matrix[$client]
            if ($null -eq $entry -or -not $entry.Contains($event)) { continue }
            $sound = [Environment]::ExpandEnvironmentVariables([string]$entry[$event])
            $arguments = @{ Client = $client; Event = $event; Root = $root; Force = $true; NoToast = $true }
            if ($LogOnly) { $arguments['LogOnly'] = $true }
            & $notify @arguments | Out-Null
            $played.Add([pscustomobject]@{ Client = $client; Event = $event; Sound = $sound })
        }
    }
    $played.ToArray()
}
