$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runtimeRoot = Join-Path $repoRoot 'runtime'
. (Join-Path $runtimeRoot 'FleetNotifyInstall.ps1')

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-fleet-notify-test-' + [Guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($tmpRoot)

function Read-NotifyLog([string]$Path) {
    @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-NotifyHandlerCount([string]$Path, [string]$Event) {
    $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $count = 0
    if (-not $settings.Contains('hooks') -or -not $settings['hooks'].Contains($Event)) { return 0 }
    foreach ($group in @($settings['hooks'][$Event])) {
        foreach ($handler in @($group['hooks'])) {
            if ([string]$handler['command'] -match 'FleetNotify\.ps1') { $count++ }
        }
    }
    $count
}

try {
    $notifyRoot = Join-Path $tmpRoot 'notifications'
    [void][IO.Directory]::CreateDirectory($notifyRoot)
    foreach ($file in @('FleetNotify.ps1', 'FleetNotifyInstall.ps1', 'FleetNotifyAntigravity.ps1', 'notifications.json')) {
        Copy-Item -LiteralPath (Join-Path $runtimeRoot $file) -Destination (Join-Path $notifyRoot $file) -Force
    }
    $notify = Join-Path $notifyRoot 'FleetNotify.ps1'
    $wrapper = Join-Path $notifyRoot 'FleetNotifyAntigravity.ps1'
    $logPath = Join-Path $notifyRoot 'notify.log'

    # 1. The matrix resolves the provider and event, and -LogOnly never plays audio.
    & $notify -Client Claude -Event done -Root $notifyRoot -LogOnly
    & $notify -Client Codex -Event attention -Root $notifyRoot -LogOnly
    $log = Read-NotifyLog $logPath
    if (@($log).Count -ne 2) { throw 'The notifier did not write one log line per event.' }
    if ($log[0].client -cne 'Claude' -or $log[0].event -cne 'done' -or $log[0].sound -notmatch 'chimes\.wav') {
        throw 'Claude done did not resolve to the expected sound.'
    }
    if ($log[1].client -cne 'Codex' -or $log[1].event -cne 'attention' -or $log[1].sound -notmatch 'ding\.wav') {
        throw 'Codex attention did not resolve to the expected sound.'
    }

    # 2. Mute skips a sound, and -Force bypasses the mute.
    '{"muted":true}' | Set-Content -LiteralPath (Join-Path $notifyRoot 'notifications.local.json') -NoNewline
    & $notify -Client Claude -Event done -Root $notifyRoot -LogOnly
    $last = @(Read-NotifyLog $logPath)[-1]
    if ($last.result -cne 'skipped-muted') { throw 'Mute did not skip the sound.' }
    & $notify -Client Claude -Event done -Root $notifyRoot -LogOnly -Force
    $last = @(Read-NotifyLog $logPath)[-1]
    if ($last.result -cne 'logged') { throw '-Force did not bypass the mute.' }

    # 3. A missing sound is logged and falls back without failing the hook.
    '{"Custom":{"done":"C:\\does-not-exist\\missing.wav"}}' | Set-Content -LiteralPath (Join-Path $notifyRoot 'notifications.local.json') -NoNewline
    & $notify -Client Custom -Event done -Root $notifyRoot -LogOnly -Force
    $last = @(Read-NotifyLog $logPath)[-1]
    if ($last.result -cne 'missing') { throw 'A missing sound did not produce the missing result.' }
    Remove-Item -LiteralPath (Join-Path $notifyRoot 'notifications.local.json') -Force

    # 4. The installer merges hooks, preserves unrelated hooks, is idempotent, and restores on uninstall.
    $configHome = Join-Path $tmpRoot 'home'
    $claudePath = Join-Path $configHome '.claude/settings.json'
    $codexPath = Join-Path $configHome '.codex/hooks.json'
    $antigravityPath = Join-Path $configHome '.gemini/config/hooks.json'
    $openCodePath = Join-Path $configHome '.config/opencode/cli.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $claudePath))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $codexPath))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $antigravityPath))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $openCodePath))
    $claudeOriginal = '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo existing"}]}]}}'
    $codexOriginal = '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo existing"}]}]}}'
    $antigravityOriginal = '{"existing":{"Stop":[{"type":"command","command":"echo existing"}]}}'
    $openCodeOriginal = '{"$schema":"https://opencode.ai/v2/cli.json","theme":{"name":"one-dark"}}'
    $claudeOriginal | Set-Content -LiteralPath $claudePath -NoNewline
    $codexOriginal | Set-Content -LiteralPath $codexPath -NoNewline
    $antigravityOriginal | Set-Content -LiteralPath $antigravityPath -NoNewline
    $openCodeOriginal | Set-Content -LiteralPath $openCodePath -NoNewline

    $first = Install-FleetNotifyHooks -InstallRoot $tmpRoot -ConfigRoot $configHome
    if ($first.Result -cne 'installed') { throw 'The installer did not report installed.' }
    if ((Get-NotifyHandlerCount $claudePath 'Stop') -ne 1) { throw 'Claude Stop was not installed exactly once.' }
    if ((Get-NotifyHandlerCount $claudePath 'Notification') -ne 1) { throw 'Claude Notification was not installed exactly once.' }
    if ((Get-NotifyHandlerCount $claudePath 'StopFailure') -ne 1) { throw 'Claude StopFailure was not installed exactly once.' }
    if ((Get-NotifyHandlerCount $codexPath 'Stop') -ne 1) { throw 'Codex Stop was not installed exactly once.' }
    if ((Get-NotifyHandlerCount $codexPath 'PermissionRequest') -ne 1) { throw 'Codex PermissionRequest was not installed exactly once.' }
    $claude = Get-Content -LiteralPath $claudePath -Raw | ConvertFrom-Json -AsHashtable
    if (@($claude['hooks']['Stop'][0]['hooks']).Count -ne 1 -or [string]$claude['hooks']['Stop'][0]['hooks'][0]['command'] -notmatch 'echo existing') {
        throw 'Claude installer removed an unrelated hook.'
    }
    $antigravity = Get-Content -LiteralPath $antigravityPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $antigravity.Contains('existing') -or -not $antigravity.Contains('fleet-notify')) {
        throw 'Antigravity installer did not preserve the existing hook or add the Fleet hook.'
    }
    $openCode = Get-Content -LiteralPath $openCodePath -Raw | ConvertFrom-Json -AsHashtable
    if ($openCode['theme']['name'] -cne 'one-dark' -or -not $openCode['attention']['enabled']) {
        throw 'OpenCode installer did not preserve the theme or enable attention.'
    }

    $second = Install-FleetNotifyHooks -InstallRoot $tmpRoot -ConfigRoot $configHome
    if ((Get-NotifyHandlerCount $claudePath 'Stop') -ne 1) { throw 'The second install duplicated the Claude Stop hook.' }
    if ((Get-NotifyHandlerCount $codexPath 'Stop') -ne 1) { throw 'The second install duplicated the Codex Stop hook.' }

    $status = Get-FleetNotifyStatus -InstallRoot $tmpRoot -ConfigRoot $configHome
    if (-not $status.Installed -or -not $status.Hooks.Claude -or -not $status.Hooks.Codex -or -not $status.Hooks.Antigravity -or -not $status.Hooks.OpenCode) {
        throw 'The status did not report every installed hook.'
    }

    $removed = Uninstall-FleetNotifyHooks -InstallRoot $tmpRoot -ConfigRoot $configHome
    if ($removed.Result -cne 'uninstalled') { throw 'The uninstaller did not report uninstalled.' }
    if ((Get-Content -LiteralPath $claudePath -Raw).Trim() -cne $claudeOriginal) { throw 'Claude settings were not restored.' }
    if ((Get-Content -LiteralPath $codexPath -Raw).Trim() -cne $codexOriginal) { throw 'Codex hooks were not restored.' }
    if ((Get-Content -LiteralPath $antigravityPath -Raw).Trim() -cne $antigravityOriginal) { throw 'Antigravity hooks were not restored.' }
    if ((Get-Content -LiteralPath $openCodePath -Raw).Trim() -cne $openCodeOriginal) { throw 'OpenCode settings were not restored.' }

    # 5. The Antigravity wrapper returns the decision that each hook expects.
    $payload = '{"error":"boom","workspacePaths":["C:\\work\\job-3"]}'
    $stopOutput = $payload | powershell.exe -NoLogo -NoProfile -File $wrapper -Event done -Root $notifyRoot -LogOnly
    if ($stopOutput -notmatch '"decision":"stop"') { throw 'The Antigravity Stop wrapper did not return the stop decision.' }
    $attentionOutput = $payload | powershell.exe -NoLogo -NoProfile -File $wrapper -Event attention -Root $notifyRoot -LogOnly
    if ($attentionOutput -notmatch '"decision":"allow"') { throw 'The Antigravity PreToolUse wrapper did not return the allow decision.' }

    # 6. The test command resolves every provider and event without playing audio.
    $sounds = @(Test-FleetNotifySounds -InstallRoot $tmpRoot -LogOnly)
    if ($sounds.Count -ne 12) { throw "Expected 12 provider/event sounds, found $($sounds.Count)." }

    Write-Output 'PASS: notification sounds, mute, installer merge, idempotence, uninstall, and Antigravity decisions.'
} finally {
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
}
