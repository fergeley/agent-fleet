[CmdletBinding()]
param(
    [ValidateSet('done', 'attention', 'error')]
    [string]$Event = 'done',
    [string]$Root = $PSScriptRoot,
    [switch]$LogOnly
)

$ErrorActionPreference = 'Stop'
$raw = ''
try {
    if ([Console]::IsInputRedirected) {
        $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
        $task = $reader.ReadToEndAsync()
        if ($task.Wait(1500)) { $raw = $task.Result }
    }
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { $payload = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $payload = $null }
    }
    $message = ''
    if ($null -ne $payload) {
        foreach ($field in @('error', 'lastUserInput')) {
            $value = $payload.$field
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { $message = [string]$value; break }
        }
    }
    $arguments = @{ Client = 'Antigravity'; Event = $Event; Root = $Root }
    if (-not [string]::IsNullOrWhiteSpace($message)) { $arguments['Message'] = $message }
    if ($LogOnly) { $arguments['LogOnly'] = $true }
    & (Join-Path $Root 'FleetNotify.ps1') @arguments | Out-Null
} catch { }

if ($Event -eq 'attention') {
    '{"decision":"allow"}'
} else {
    '{"decision":"stop"}'
}
exit 0
