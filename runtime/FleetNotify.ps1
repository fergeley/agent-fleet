[CmdletBinding()]
param(
    [ValidateSet('Claude', 'Codex', 'Antigravity', 'OpenCode', 'Fleet', 'Custom')]
    [string]$Client = 'Custom',
    [ValidateSet('done', 'attention', 'error', 'idle')]
    [string]$Event = 'done',
    [string]$Job = '',
    [string]$Profile = '',
    [string]$Message = '',
    [string]$Root = $PSScriptRoot,
    [switch]$LogOnly,
    [switch]$Force,
    [switch]$NoToast,
    [switch]$Probe
)

$ErrorActionPreference = 'Stop'

function Test-FleetNotifyProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    $Object.PSObject.Properties.Match($Name).Count -gt 0
}

function Get-FleetNotifyProperty($Object, [string]$Name) {
    if (-not (Test-FleetNotifyProperty $Object $Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $Object.$Name
}

function Read-FleetNotifyStdin {
    if (-not [Console]::IsInputRedirected) { return '' }
    try {
        $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
        $task = $reader.ReadToEndAsync()
        if ($task.Wait(1500)) { return $task.Result }
    } catch { }
    ''
}

function Write-FleetNotifyLog([string]$Path, $Entry) {
    try {
        $directory = [IO.Path]::GetDirectoryName($Path)
        if ($directory) { [void][IO.Directory]::CreateDirectory($directory) }
        [IO.File]::AppendAllText($Path, (($Entry | ConvertTo-Json -Compress -Depth 6) + "`n"), [Text.UTF8Encoding]::new($false))
    } catch { }
}

function Test-FleetNotifyForegroundTerminal {
    try {
        if (-not ('FleetNotifyWindow' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FleetNotifyWindow
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
        }
        $processId = 0
        [void][FleetNotifyWindow]::GetWindowThreadProcessId([FleetNotifyWindow]::GetForegroundWindow(), [ref]$processId)
        if ($processId -eq 0) { return $false }
        $name = (Get-Process -Id $processId -ErrorAction SilentlyContinue).ProcessName
        return $name -match '^(WindowsTerminal|wt)$'
    } catch {
        return $false
    }
}

function Show-FleetNotifyToast([string]$Title, [string]$Body) {
    try {
        $safeTitle = [Security.SecurityElement]::Escape($Title)
        $safeBody = [Security.SecurityElement]::Escape($Body)
        $script = @"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > `$null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > `$null
`$x = New-Object Windows.Data.Xml.Dom.XmlDocument
`$x.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$safeTitle</text><text>$safeBody</text></binding></visual><audio silent='true'/></toast>")
`$id = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$id).Show([Windows.UI.Notifications.ToastNotification]::new(`$x))
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) -WindowStyle Hidden | Out-Null
    } catch { }
}

function Resolve-FleetNotifySound($Config, $Local, [string]$ClientName, [string]$EventName, [string]$JobName) {
    $candidates = @(
        @{ Node = $Local; Key = $JobName; Source = 'local' },
        @{ Node = $Local; Key = $ClientName; Source = 'local' },
        @{ Node = $Config; Key = $JobName; Source = 'config' },
        @{ Node = $Config; Key = $ClientName; Source = 'config' },
        @{ Node = $Config; Key = 'default'; Source = 'config' }
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate.Key) -or $null -eq $candidate.Node) { continue }
        if (-not (Test-FleetNotifyProperty $candidate.Node $candidate.Key)) { continue }
        $entry = Get-FleetNotifyProperty $candidate.Node $candidate.Key
        if ($entry -is [string]) { return [pscustomobject]@{ Sound = $entry; Source = $candidate.Source } }
        $value = Get-FleetNotifyProperty $entry $EventName
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [pscustomobject]@{ Sound = [string]$value; Source = $candidate.Source }
        }
    }
    $null
}

$rootFull = [IO.Path]::GetFullPath($Root)
$configPath = Join-Path $rootFull 'notifications.json'
$localPath = Join-Path $rootFull 'notifications.local.json'
$logPath = Join-Path $rootFull 'notify.log'
$probePath = Join-Path $rootFull 'notify-probe.jsonl'
$mutePath = Join-Path $rootFull 'mute'

$raw = ''
$payload = $null
$result = 'logged'
$soundPath = ''
$source = ''
$jobName = $Job
$profileName = $Profile
$clientName = $Client
$messageText = $Message

if ($Probe) {
    $raw = Read-FleetNotifyStdin
    try {
        $directory = [IO.Path]::GetDirectoryName($probePath)
        if ($directory) { [void][IO.Directory]::CreateDirectory($directory) }
        [IO.File]::AppendAllText($probePath, (($raw.Trim() + "`n")), [Text.UTF8Encoding]::new($false))
    } catch { }
    Write-FleetNotifyLog $logPath ([ordered]@{
        time = [DateTime]::UtcNow.ToString('o'); client = $Client; event = $Event; job = $Job; profile = $Profile; result = 'probe'; sound = ''; source = ''
    })
    exit 0
}

try {
    $raw = Read-FleetNotifyStdin
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { $payload = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $payload = $null }
    }

    if ($clientName -eq 'Custom') {
        $fromEnv = [Environment]::GetEnvironmentVariable('FLEET_CLIENT', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { $clientName = $fromEnv }
    }
    if ([string]::IsNullOrWhiteSpace($jobName)) { $jobName = [Environment]::GetEnvironmentVariable('FLEET_JOB_ID', 'Process') }
    if ([string]::IsNullOrWhiteSpace($profileName)) { $profileName = [Environment]::GetEnvironmentVariable('FLEET_PROFILE', 'Process') }
    if ([string]::IsNullOrWhiteSpace($messageText) -and $null -ne $payload) {
        foreach ($field in @('message', 'last_assistant_message', 'lastUserInput', 'error')) {
            $value = Get-FleetNotifyProperty $payload $field
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { $messageText = [string]$value; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($jobName) -and $null -ne $payload) {
        $cwd = [string](Get-FleetNotifyProperty $payload 'cwd')
        if ([string]::IsNullOrWhiteSpace($cwd)) {
            $workspacePaths = Get-FleetNotifyProperty $payload 'workspacePaths'
            if ($workspacePaths -is [Array] -and $workspacePaths.Count -gt 0) { $cwd = [string]$workspacePaths[0] }
        }
        if (-not [string]::IsNullOrWhiteSpace($cwd)) { $jobName = Split-Path -Leaf $cwd }
    }
    if ($messageText.Length -gt 200) { $messageText = $messageText.Substring(0, 200) }

    $config = $null
    $local = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
    if (Test-Path -LiteralPath $localPath -PathType Leaf) { $local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json }

    $muted = (Test-Path -LiteralPath $mutePath) -or ([bool](Get-FleetNotifyProperty $local 'muted'))
    if ($muted -and -not $Force) {
        $result = 'skipped-muted'
    } else {
        $focusPolicy = [string](Get-FleetNotifyProperty (Get-FleetNotifyProperty $config 'Focus') $Event)
        if ([string]::IsNullOrWhiteSpace($focusPolicy)) { $focusPolicy = 'always' }
        if ($focusPolicy -eq 'unfocused' -and -not $Force -and (Test-FleetNotifyForegroundTerminal)) {
            $result = 'skipped-focus'
        } else {
            $resolved = Resolve-FleetNotifySound $config $local $clientName $Event $jobName
            if ($null -ne $resolved) {
                $soundPath = [Environment]::ExpandEnvironmentVariables([string]$resolved.Sound)
                $source = [string]$resolved.Source
            }
            if ([string]::IsNullOrWhiteSpace($soundPath) -or -not (Test-Path -LiteralPath $soundPath -PathType Leaf)) {
                $result = 'missing'
                if (-not $LogOnly) { try { [console]::Beep(880, 120) } catch { } }
            } elseif ($LogOnly) {
                $result = 'logged'
            } else {
                try {
                    $player = New-Object -TypeName System.Media.SoundPlayer -ArgumentList $soundPath
                    $player.PlaySync()
                    $player.Dispose()
                    $result = 'played'
                } catch {
                    $result = 'error'
                    try { [console]::Beep(880, 120) } catch { }
                }
            }
            if (-not $LogOnly -and -not $NoToast) {
                $title = 'Agent Fleet'
                $parts = @($clientName)
                if (-not [string]::IsNullOrWhiteSpace($jobName)) { $parts += $jobName }
                if (-not [string]::IsNullOrWhiteSpace($profileName)) { $parts += $profileName }
                $parts += $Event
                $body = $parts -join ' | '
                if (-not [string]::IsNullOrWhiteSpace($messageText)) { $body += "`n$messageText" }
                Show-FleetNotifyToast $title $body
            }
        }
    }
} catch {
    $result = 'error'
} finally {
    Write-FleetNotifyLog $logPath ([ordered]@{
        time = [DateTime]::UtcNow.ToString('o')
        client = $clientName
        event = $Event
        job = $jobName
        profile = $profileName
        sound = $soundPath
        source = $source
        result = $result
    })
}
exit 0
