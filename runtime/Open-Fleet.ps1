param(
    [switch]$PrintPlan,
    [ValidateSet('None', 'Codex', 'Antigravity', 'Claude', 'OpenCode')]
    [string]$Pane = 'None',
    [string]$Directory,
    [string]$Job,
    [string]$LaunchNonce,
    [string]$WindowNonce,
    [string]$LaunchContext,
    [string]$InstallationTag,
    [string]$Profile = '',
    [psobject]$ManifestSnapshot,
    [int]$RegistrationTimeoutMilliseconds = 60000,
    [string]$InstallRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetSources.ps1')
Assert-FleetProfileName $Profile
$contextPane = $Pane -ne 'None'
$manifest = if ($contextPane) { $null } elseif ($null -ne $ManifestSnapshot) { $ManifestSnapshot } else { Get-Content -LiteralPath (Get-FleetManifestPath $InstallRoot $Profile) -Raw | ConvertFrom-Json }

if ($Pane -ne 'None') {
    Assert-FleetAbsolutePath $Directory
    if (-not $Job) { throw 'A Jobs pane needs its job ID.' }
    if (-not $LaunchContext) { throw 'A Jobs pane needs its launch context.' }
    $context = Read-FleetLaunchContext $LaunchContext $true $InstallRoot $Profile
    if ($context.Id -cne $Job -or $context.Client -cne $Pane -or
        $context.Directory -ne [IO.Path]::TrimEndingDirectorySeparator($Directory)) {
        throw 'The Jobs pane arguments differ from its launch context.'
    }
    Set-Location -LiteralPath $context.Directory
    if ($context.TitleMode -ceq 'Native') {
        $Host.UI.RawUI.WindowTitle = $context.Title
        if (-not ('FleetWindow' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'FleetWindow.cs') }
        . (Join-Path $PSScriptRoot 'FleetJobs.ps1')
        [void](Wait-FleetJobRegistration $context $LaunchContext $InstallRoot $RegistrationTimeoutMilliseconds $Profile)
        $tabPrefix = if ((Test-FleetProperty $context 'Tab') -and $context.Tab -and $context.Tab -cne 'fleet') { "$($context.Tab) | " } else { '' }
        $Host.UI.RawUI.WindowTitle = "$tabPrefix$($context.Client) · $($context.Id)"
    }
    $invocation = $null
    $invocationPath = $null
    $savedEnv = [ordered]@{}
    $addedEnv = [Collections.Generic.List[string]]::new()
    try {
        $invocation = New-FleetInvocationRecord $context $LaunchContext $PSScriptRoot
        $stateDir = Get-FleetStateDirectory $InstallRoot $Profile
        $invocationPath = Join-Path $stateDir "invocation-$($context.Nonce)-$($invocation.InvocationId).json"
        Write-FleetInvocationRecord $invocationPath $invocation $false
        if (Test-FleetProperty $context 'NativeArguments') {
            [string[]]$nativeArgs = @($context.NativeArguments)
        } else {
            [string[]]$nativeArgs = Get-FleetClientArguments $context.Client
        }
        if ((Test-FleetProperty $context 'NativeEnv') -and $null -ne $context.NativeEnv) {
            foreach ($prop in $context.NativeEnv.PSObject.Properties) {
                $existing = [Environment]::GetEnvironmentVariable($prop.Name, 'Process')
                if ($null -eq $existing) { $addedEnv.Add($prop.Name) } else { $savedEnv[$prop.Name] = $existing }
                [Environment]::SetEnvironmentVariable($prop.Name, [string]$prop.Value, 'Process')
            }
        }
        $global:LASTEXITCODE = 0
        & $context.NativeExecutable @nativeArgs
        $invocation.ReturnedAtUtc = [DateTime]::UtcNow.ToString('o')
        $invocation.ExitCode = $LASTEXITCODE
        Write-FleetInvocationRecord $invocationPath $invocation $true
    } finally {
        foreach ($name in $addedEnv) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        foreach ($entry in $savedEnv.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    }
    return
}

if (-not $PrintPlan) {
    throw 'Open-Fleet.ps1 supports -PrintPlan or pane execution; launch via Fleet.ps1 or Start-Fleet.ps1.'
}

$layout = Get-FleetJobsLayout $manifest
$openFleetPath = $PSCommandPath
$planned = @(Get-FleetJobs $manifest $InstallRoot $openFleetPath $Job $Profile)
$tabColors = Get-FleetTabColors $manifest
$lockHash = Get-FleetLaunchLockHash $InstallRoot $Profile
if ($layout -ceq 'SingleWindow' -and -not $Job) {
    $single = New-FleetSingleWindowPlan $manifest.PowerShell $openFleetPath $InstallRoot $lockHash $planned[0].WindowNonce $planned $tabColors $Profile
    [pscustomobject]@{
        Mode = 'Jobs'
        Layout = 'SingleWindow'
        Profile = if ($Profile) { $Profile } else { $null }
        Windows = @($single)
    } | ConvertTo-Json -Depth 9
} else {
    $windows = foreach ($jobPlan in $planned) {
        $paneArgs = @('-w', $jobPlan.WindowName, 'new-tab') + (New-FleetJobPaneArguments $manifest.PowerShell $openFleetPath $InstallRoot $jobPlan $jobPlan.ContextPath $jobPlan.Title $Profile $true)
        [pscustomobject]@{
            Id = $jobPlan.Id
            Client = $jobPlan.Client
            Tab = $jobPlan.Tab
            Directory = $jobPlan.Directory
            WindowName = $jobPlan.WindowName
            Title = $jobPlan.Title
            NativeArguments = $jobPlan.NativeArguments
            NativeEnv = $jobPlan.NativeEnv
            Arguments = $paneArgs
        }
    }
    [pscustomobject]@{
        Mode = 'Jobs'
        Layout = $layout
        Profile = if ($Profile) { $Profile } else { $null }
        Windows = @($windows)
    } | ConvertTo-Json -Depth 9
}
