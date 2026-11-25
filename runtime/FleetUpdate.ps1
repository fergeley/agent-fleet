$ErrorActionPreference = 'Stop'

function Get-FleetUpdateFiles([int]$Protocol = 2) {
    if ($Protocol -ne 2) { throw "The Fleet update protocol is incompatible: $Protocol" }
    @('Fleet.ps1', 'FleetJobs.ps1', 'FleetDispatch.ps1', 'FleetWindow.cs', 'FleetSources.ps1', 'Open-Fleet.ps1', 'README.md')
}

function Get-FleetEntryLockHash([string]$InstallRoot) {
    if (-not ('FleetStartFolder' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class FleetStartFolder
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
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $installKey = $identity + '|' + [FleetStartFolder]::FinalPath($InstallRoot).ToUpperInvariant()
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($installKey))).Substring(0, 16)
}

function Get-FleetReleaseBytes([string]$Path) {
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $content = $encoding.GetString([IO.File]::ReadAllBytes($Path))
    if ($content.Length -gt 0 -and [int]$content[0] -eq 0xFEFF) { $content = $content.Substring(1) }
    if ($content.Replace("`r`n", '').Contains("`r")) {
        throw 'The Fleet release file is not valid UTF-8 text with CRLF or LF line endings.'
    }
    return ,$encoding.GetBytes($content.Replace("`r`n", "`n"))
}

function Get-FleetReleaseHash([string]$Path) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]](Get-FleetReleaseBytes $Path)))
}

function Remove-FleetPackageFiles([string]$Directory, [int]$Protocol = 2) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    foreach ($name in (@(Get-FleetUpdateFiles $Protocol) + 'release.json')) {
        $path = Join-Path $Directory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    [IO.Directory]::Delete($Directory)
}

function Read-FleetRelease([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'The Fleet release manifest is missing.' }
    if ((Get-Item -LiteralPath $Path).Length -gt 16384) { throw 'The Fleet release manifest is too large.' }
    $release = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($release -isnot [System.Collections.IDictionary] -or @($release.Keys).Count -ne 3 -or
        @($release.Keys | Where-Object { $_ -cnotin @('Protocol', 'Version', 'Files') }).Count -ne 0) {
        throw 'The Fleet release manifest has invalid fields.'
    }
    if ($release.Protocol -isnot [long] -or $release.Protocol -ne 2) { throw 'The Fleet update protocol is incompatible.' }
    if ($release.Version -isnot [string] -or $release.Version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
        throw 'The Fleet release version is invalid.'
    }
    if ($release.Files -isnot [System.Collections.IDictionary]) { throw 'The Fleet release file list is invalid.' }
    $expected = @(Get-FleetUpdateFiles ([int]$release.Protocol))
    if (@($release.Files.Keys).Count -ne $expected.Count) { throw 'The Fleet release file list is incomplete.' }
    foreach ($name in $expected) {
        if (-not $release.Files.Contains($name) -or $release.Files[$name] -isnot [string] -or
            $release.Files[$name] -cnotmatch '^[A-F0-9]{64}$') {
            throw "The Fleet release digest is invalid: $name"
        }
    }
    if (@($release.Files.Keys | Where-Object { $_ -cnotin $expected }).Count -ne 0) {
        throw 'The Fleet release contains an unexpected filename.'
    }
    return $release
}

function Assert-FleetReleaseFiles([string]$Directory, [System.Collections.IDictionary]$Release) {
    if ((Get-Item -LiteralPath $Directory).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The Fleet package directory cannot be a link.'
    }
    $manifest = Read-FleetRelease (Join-Path $Directory 'release.json')
    if ($manifest.Version -cne $Release.Version -or $manifest.Protocol -ne $Release.Protocol) {
        throw 'The Fleet package metadata differs from the release.'
    }
    $expectedFiles = @(Get-FleetUpdateFiles ([int]$Release.Protocol))
    foreach ($name in $expectedFiles) {
        if ($manifest.Files[$name] -cne $Release.Files[$name]) { throw "The Fleet package digest differs: $name" }
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The Fleet package file is missing: $name" }
        if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "The Fleet package file cannot be a link: $name" }
        $hash = Get-FleetReleaseHash $path
        if ($hash -cne $Release.Files[$name]) { throw "The Fleet package file digest differs: $name" }
        if ($name.EndsWith('.ps1', [StringComparison]::Ordinal)) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) { throw "The Fleet package PowerShell syntax is invalid: $name" }
        }
    }
    $actual = @(Get-ChildItem -LiteralPath $Directory -File | ForEach-Object Name)
    if (@($actual | Where-Object { $_ -cnotin ($expectedFiles + 'release.json') }).Count -ne 0) {
        throw 'The Fleet package has an unexpected file.'
    }
}

function Write-FleetUpdateJson([string]$Path, $Value) {
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('n') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        for ($attempt = 1; ; $attempt++) {
            try {
                [IO.File]::Move($temporary, $Path, $true)
                break
            } catch [UnauthorizedAccessException], [IO.IOException] {
                if ($attempt -ge 40) { throw }
                Start-Sleep -Milliseconds 25
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Publish-FleetGeneration([string]$InstallRoot, [string]$SourceRoot, [System.Collections.IDictionary]$Release) {
    $versions = Join-Path $InstallRoot 'versions'
    [void][IO.Directory]::CreateDirectory($versions)
    $name = $Release.Version + '-' + [Guid]::NewGuid().ToString('n')
    $relative = 'versions/' + $name
    $destination = Join-Path $versions $name
    [void][IO.Directory]::CreateDirectory($destination)
    try {
        foreach ($file in Get-FleetUpdateFiles ([int]$Release.Protocol)) {
            [IO.File]::WriteAllBytes((Join-Path $destination $file), [byte[]](Get-FleetReleaseBytes (Join-Path $SourceRoot $file)))
        }
        Write-FleetUpdateJson (Join-Path $destination 'release.json') $Release
        Assert-FleetReleaseFiles $destination $Release
        return $relative
    } catch {
        Remove-FleetPackageFiles $destination
        throw
    }
}

function Resolve-FleetRuntime([string]$InstallRoot, $Receipt) {
    $relative = [string]$Receipt.RuntimeDirectory
    if ($relative -cnotmatch '^versions/[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{32}$') {
        throw 'The Fleet runtime pointer is invalid.'
    }
    if ($Receipt.UpdateProtocol -ne 2 -or $Receipt.ReleaseVersion -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
        throw 'The Fleet installation receipt is incompatible.'
    }
    $runtime = Join-Path $InstallRoot $relative
    $versions = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'versions'))
    if ((Get-Item -LiteralPath $versions).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The Fleet versions directory cannot be a link.'
    }
    $full = [IO.Path]::GetFullPath($runtime)
    if (-not $full.StartsWith($versions + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Fleet runtime pointer leaves the installation.'
    }
    if ((Get-Item -LiteralPath $runtime).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'The Fleet runtime directory cannot be a link.'
    }
    $release = Read-FleetRelease (Join-Path $runtime 'release.json')
    if ($release.Version -cne $Receipt.ReleaseVersion) { throw 'The Fleet receipt version differs from its package.' }
    Assert-FleetReleaseFiles $runtime $release
    return $runtime
}

function Invoke-FleetPublicGitHubApi([string]$Endpoint, [string]$Accept, [Diagnostics.Stopwatch]$Clock) {
    $remaining = 20000 - [int]$Clock.ElapsedMilliseconds
    if ($remaining -le 0) { throw 'Fleet update check timed out.' }
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $cancel = [Threading.CancellationTokenSource]::new($remaining)
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "https://api.github.com/$Endpoint")
        [void]$request.Headers.UserAgent.ParseAdd('AgentFleet/2.0')
        if ($Accept) { [void]$request.Headers.Accept.ParseAdd($Accept) }
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -eq 404) {
            $missing = [Exception]::new('Fleet update check could not reach the release.')
            $missing.Data['HttpStatus'] = 404
            throw $missing
        }
        if (-not $response.IsSuccessStatusCode) {
            $failure = [Exception]::new('Fleet update check could not reach the release.')
            $failure.Data['HttpStatus'] = [int]$response.StatusCode
            throw $failure
        }
        $stream = $response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
        $memory = [IO.MemoryStream]::new()
        try {
            $buffer = [byte[]]::new(8192)
            while ($true) {
                $count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()
                if ($count -eq 0) { break }
                if ($memory.Length + $count -gt 2097152) { throw 'The Fleet update response is too large.' }
                $memory.Write($buffer, 0, $count)
            }
            return [Text.UTF8Encoding]::new($false, $true).GetString($memory.ToArray())
        } finally {
            $memory.Dispose()
            $stream.Dispose()
        }
    } catch [OperationCanceledException] {
        throw 'Fleet update check timed out.'
    } finally {
        $cancel.Dispose()
        $client.Dispose()
    }
}

function Invoke-FleetGhApi([string[]]$Arguments, [Diagnostics.Stopwatch]$Clock) {
    $remaining = 20000 - [int]$Clock.ElapsedMilliseconds
    if ($remaining -le 0) { throw 'Fleet update check timed out.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'gh'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['GH_PROMPT_DISABLED'] = '1'
    foreach ($arg in $Arguments) { [void]$start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $cancel = [Threading.CancellationTokenSource]::new($remaining)
    $response = [IO.MemoryStream]::new()
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $errorOutput = $process.StandardError.ReadToEndAsync()
        $buffer = [byte[]]::new(8192)
        while ($true) {
            $count = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            if ($response.Length + $count -gt 2097152) { throw 'The Fleet update response is too large.' }
            $response.Write($buffer, 0, $count)
        }
        $remaining = 20000 - [int]$Clock.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $process.WaitForExit($remaining)) { throw 'Fleet update check timed out.' }
        $errorText = $errorOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $failure = [Exception]::new('Fleet update check could not reach the release.')
            if ($errorText -match '\(HTTP (?<status>[0-9]{3})\)') { $failure.Data['HttpStatus'] = [int]$Matches.status }
            throw $failure
        }
        return [Text.UTF8Encoding]::new($false, $true).GetString($response.ToArray())
    } catch [OperationCanceledException] {
        throw 'Fleet update check timed out.'
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true) }
        $cancel.Dispose()
        $response.Dispose()
        $process.Dispose()
    }
}

function Get-FleetUpdateSource([string]$InstallRoot) {
    $repo = 'fergeley/agent-fleet'
    $transport = 'https'
    $manifestPath = Join-Path $InstallRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($manifest.PSObject.Properties.Match('UpdateRepo').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$manifest.UpdateRepo)) {
                $candidateRepo = ([string]$manifest.UpdateRepo).Trim()
                if ($candidateRepo -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'The UpdateRepo manifest field is invalid.' }
                $repo = $candidateRepo
            }
            if ($manifest.PSObject.Properties.Match('UpdateTransport').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$manifest.UpdateTransport)) {
                $candidateTransport = ([string]$manifest.UpdateTransport).Trim()
                if ($candidateTransport -cnotin @('https', 'gh')) { throw 'The UpdateTransport manifest field is invalid.' }
                $transport = $candidateTransport
            }
        } catch {
            if ($_.Exception.Message -match '^The Update') { throw }
        }
    }
    [pscustomobject]@{ Repo = $repo; Transport = $transport; PathPrefix = '' }
}

function Invoke-FleetUpdate([string]$InstallRoot, [switch]$Force) {
    $receiptPath = Join-Path $InstallRoot 'installation.json'
    $statusPath = Join-Path $InstallRoot 'status.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    $now = [DateTime]::UtcNow
    if (-not $Force -and -not $receipt.AutoUpdateEnabled) {
        return [pscustomobject]@{ Result = 'disabled'; Message = 'Automatic Fleet updates are off.' }
    }
    if (-not $Force -and (Test-Path -LiteralPath $statusPath)) {
        try {
            $previous = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $last = if ($previous.LastAttemptUtc -is [DateTime]) {
                $previous.LastAttemptUtc.ToUniversalTime()
            } else {
                [DateTimeOffset]::Parse([string]$previous.LastAttemptUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            }
            if ($last -le $now -and ($now - $last).TotalHours -lt 24) {
                return [pscustomobject]@{ Result = 'not-due'; Message = 'The daily Fleet update check is not due.' }
            }
        } catch { }
    }
    $status = [ordered]@{ LastAttemptUtc = $now.ToString('o'); Result = 'error'; Message = 'Fleet update check failed.'; SourceCommit = $null }
    Write-FleetUpdateJson $statusPath $status
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $download = $null
    try {
        $updateSource = Get-FleetUpdateSource $InstallRoot
        if ($updateSource.Transport -ceq 'gh') {
            $head = (Invoke-FleetGhApi @('api', '--hostname', 'github.com', "repos/$($updateSource.Repo)/commits/main", '--jq', '.sha') $clock).Trim()
        } else {
            $commitInfo = Invoke-FleetPublicGitHubApi "repos/$($updateSource.Repo)/commits/main" 'application/vnd.github+json' $clock | ConvertFrom-Json -ErrorAction Stop
            $head = ([string]$commitInfo.sha).Trim()
        }
        if ($head -cnotmatch '^[0-9a-f]{40}$') { throw 'The Fleet source commit is invalid.' }
        $status.SourceCommit = $head
        $prefix = "repos/$($updateSource.Repo)/contents/$($updateSource.PathPrefix)"
        try {
            if ($updateSource.Transport -ceq 'gh') {
                $releaseText = Invoke-FleetGhApi @('api', '--hostname', 'github.com', ($prefix + 'release.json?ref=' + $head), '-H', 'Accept:application/vnd.github.raw+json') $clock
            } else {
                $releaseText = Invoke-FleetPublicGitHubApi ($prefix + 'release.json?ref=' + $head) 'application/vnd.github.raw+json' $clock
            }
        } catch {
            if ($_.Exception.Data['HttpStatus'] -ne 404) { throw }
            $status.Result = 'unpublished'
            $status.Message = 'No Fleet release is published on main yet.'
            return [pscustomobject]$status
        }
        $download = Join-Path $InstallRoot ('versions/.download-' + [Guid]::NewGuid().ToString('n'))
        [void][IO.Directory]::CreateDirectory($download)
        [IO.File]::WriteAllText((Join-Path $download 'release.json'), $releaseText, [Text.UTF8Encoding]::new($false))
        $release = Read-FleetRelease (Join-Path $download 'release.json')
        $current = [Version]$receipt.ReleaseVersion
        $candidate = [Version]$release.Version
        if ($candidate -le $current) {
            $status.Result = 'current'
            $status.Message = 'Fleet is current; no newer compatible release is available.'
        } else {
            $state = Join-Path $InstallRoot 'state'
            if ((Test-Path -LiteralPath $state) -and
                (@(Get-ChildItem -LiteralPath $state -Filter 'job-*.pending.json').Count -gt 0)) {
                $status.Result = 'deferred'
                $status.Message = 'Fleet update waits for pending launches to finish.'
                return [pscustomobject]$status
            }
            foreach ($file in Get-FleetUpdateFiles ([int]$release.Protocol)) {
                if ($updateSource.Transport -ceq 'gh') {
                    $content = Invoke-FleetGhApi @('api', '--hostname', 'github.com', ($prefix + 'runtime/' + $file + '?ref=' + $head), '-H', 'Accept:application/vnd.github.raw+json') $clock
                } else {
                    $content = Invoke-FleetPublicGitHubApi ($prefix + 'runtime/' + $file + '?ref=' + $head) 'application/vnd.github.raw+json' $clock
                }
                [IO.File]::WriteAllText((Join-Path $download $file), $content, [Text.UTF8Encoding]::new($false))
            }
            Assert-FleetReleaseFiles $download $release
            $relative = Publish-FleetGeneration $InstallRoot $download $release
            $previousRuntime = [ordered]@{
                UpdateProtocol = $receipt.UpdateProtocol
                RuntimeDirectory = $receipt.RuntimeDirectory
                ReleaseVersion = $receipt.ReleaseVersion
                SourceCommit = $receipt.SourceCommit
            }
            if ($receipt.PSObject.Properties.Name -contains 'PreviousRuntime') { $receipt.PreviousRuntime = $previousRuntime }
            else { $receipt | Add-Member -NotePropertyName PreviousRuntime -NotePropertyValue $previousRuntime }
            $receipt.UpdateProtocol = [int]$release.Protocol
            $receipt.ReleaseVersion = $release.Version
            $receipt.RuntimeDirectory = $relative
            $receipt.SourceCommit = $head
            Write-FleetUpdateJson $receiptPath $receipt
            $status.Result = 'updated'
            $status.Message = "Fleet updated to $($release.Version)."
        }
    } catch {
        $status.Result = 'error'
        $status.Message = $_.Exception.Message
    } finally {
        if ($download -and (Test-Path -LiteralPath $download)) { Remove-FleetPackageFiles $download }
        Write-FleetUpdateJson $statusPath $status
    }
    return [pscustomobject]$status
}
