<#
.SYNOPSIS
    Self-contained (no Pester, no external modules/binaries) end-to-end test
    harness for ..\sync-configs.ps1.

.DESCRIPTION
    Builds an isolated sandbox per run under the system temp directory,
    drives the real script via a child PowerShell process exactly the way
    Vibepollo would (env var + -Mode do|undo), and asserts on-disk /
    profile / state.json outcomes for every scenario in the task brief
    (T1..T24). Prints a PASS/FAIL table and exits non-zero if anything
    failed.

    The child host mirrors whichever host is running this harness: PSEdition
    'Desktop' (Windows PowerShell 5.1) launches children with powershell.exe;
    PSEdition 'Core' launches children with the pwsh binary under this
    process's own $PSHOME. See the TEST_HOST_EXE parameter below to override.

    On real Windows, robocopy is real robocopy.exe already on PATH -- one of
    the two blind spots pure-Linux testing can't cover. On non-Windows
    platforms (where robocopy doesn't exist) this harness instead builds a
    tiny PATH shim (a script literally named 'robocopy') that mimics the
    exact subset of robocopy behavior sync-configs.ps1 depends on: copy
    contents of SRC into DST, overwrite existing files, never delete extras
    already in DST, create DST if missing, ignore the /R:1 /W:1 /NFL /NDL
    /NJH /NJS flags, and exit with a robocopy-style "success" code (< 8).
    -ForceShim forces this same shim on Windows too. T16 (forced robocopy
    failure via SHIM_ROBOCOPY_RC) only means anything with the shim in play,
    so it SKIPs (not fails) whenever real robocopy is in use.

.PARAMETER KeepSandbox
    Do not delete the temp sandbox tree afterwards (useful for debugging a
    failure). Normally the sandbox is removed when the harness exits.

.PARAMETER ForceShim
    Force use of the bash/cmd robocopy shim even on Windows, where the real
    robocopy.exe on PATH is normally preferred. Non-Windows platforms always
    use the shim regardless of this switch (robocopy doesn't exist there).

.NOTES
    Environment override: TEST_HOST_EXE, if set to an absolute path, forces
    the interpreter used to launch sync-configs.ps1 as a child process,
    taking priority over the Desktop/Core auto-detection described above.
    Intended for CI matrices or manual testing that need to pin a specific
    interpreter.
#>

param(
    [switch]$KeepSandbox,
    [switch]$ForceShim
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Locate the script under test and the interpreter to run it with.
# ---------------------------------------------------------------------------

$script:TestsDir = $PSScriptRoot
$script:RepoRoot = Split-Path -Path $script:TestsDir -Parent
$script:SyncScriptSource = Join-Path $script:RepoRoot 'sync-configs.ps1'

if (-not (Test-Path -LiteralPath $script:SyncScriptSource)) {
    Write-Host "FATAL: cannot find sync-configs.ps1 at $script:SyncScriptSource" -ForegroundColor Red
    exit 1
}

function Test-IsWindowsPlatform {
    # $IsWindows/$IsLinux/$IsMacOS only exist on PowerShell 6+. Windows
    # PowerShell 5.1 (PSEdition 'Desktop') is always Windows. Use
    # Get-Variable (not a direct $IsWindows reference) so this is safe
    # under Set-StrictMode on both editions.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue -ValueOnly)
}

# Child-host selection: always launch sync-configs.ps1 with the SAME
# PowerShell host that is running this harness -- PSEdition 'Desktop' means
# we ourselves are Windows PowerShell 5.1, so the child must be
# powershell.exe; PSEdition 'Core' means the child is the pwsh binary living
# under our own $PSHOME (so a harness run under, e.g., /opt/pwsh/pwsh
# naturally launches children with /opt/pwsh/pwsh too, and a Windows pwsh
# leg launches children with that same Windows pwsh.exe). $env:TEST_HOST_EXE
# is an absolute-path override checked first, for CI matrices or manual
# testing that need to force a specific interpreter.
if ($env:TEST_HOST_EXE) {
    $script:PwshExe = $env:TEST_HOST_EXE
}
elseif ($PSVersionTable.PSEdition -eq 'Desktop') {
    $script:PwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $script:PwshExe) { $script:PwshExe = 'powershell.exe' }
}
else {
    $pwshLeaf = 'pwsh'
    if (Test-IsWindowsPlatform) { $pwshLeaf = 'pwsh.exe' }
    $script:PwshExe = Join-Path $PSHOME $pwshLeaf
}

# Name (no extension/path) of the interpreter binary this harness launches
# children with -- e.g. 'pwsh' or 'powershell'. This process is, by
# construction, alive for the whole run of this harness (it's what's running
# THIS script, and it's also what every child -Mode settle scenario below
# gets launched with), so it doubles as a reliably-alive "streaming host"
# name for T21's SCP_HOST_PROCESS_NAMES override without hardcoding a
# platform-specific process name.
$script:HostAliveProcessName = [System.IO.Path]::GetFileNameWithoutExtension($script:PwshExe)

# ---------------------------------------------------------------------------
# Sandbox root + robocopy shim
# ---------------------------------------------------------------------------

$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-configs-tests-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 10)))
New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

$script:ShimDir = Join-Path $script:TempRoot 'shim'
New-Item -ItemType Directory -Path $script:ShimDir -Force | Out-Null

# On real Windows, prefer the real robocopy.exe already on PATH so CI
# exercises actual robocopy behavior (one of the two blind spots pure-Linux
# testing has). Only fall back to the shim on non-Windows platforms
# (robocopy doesn't exist there) or when -ForceShim is passed explicitly.
$script:UseShim = (-not (Test-IsWindowsPlatform)) -or $ForceShim

function New-RobocopyShim {
    # Bash shim used when this harness itself runs on Linux/macOS.
    #
    # Faithfully mimics real robocopy's /E-gated recursion (no /E or /S ->
    # top-level files only, subfolders silently skipped) instead of always
    # recursing -- a harness that always recurses regardless of flags would
    # mask exactly the class of bug where sync-configs.ps1 forgets to pass
    # /E to robocopy.
    #
    # Honors $env:SHIM_ROBOCOPY_RC (if set and non-empty) to force a
    # specific exit code after performing the copy, so a scenario can
    # exercise sync-configs.ps1's "rc >= 8 is an error" handling -- a path
    # real robocopy failures take but that a harness with only one hardcoded
    # exit code could never reach.
    $shPath = Join-Path $script:ShimDir 'robocopy'
    $shContent = @'
#!/usr/bin/env bash
# Minimal robocopy-compatible shim for non-Windows test runs.
# Mimics the exact subset sync-configs.ps1 relies on:
#   - copy contents of SRC into DST
#   - recurse into subfolders ONLY if /E or /S is present among the flags
#     (real robocopy default with neither is top-level-files-only)
#   - overwrite files that already exist in DST
#   - NEVER delete anything already in DST that isn't in SRC (no /MIR)
#   - create DST if it doesn't exist
#   - exit with a robocopy "success" code (< 8) by default -- 1 ("one or
#     more files copied successfully") -- unless SHIM_ROBOCOPY_RC overrides it
set -u
src="${1:-}"
dst="${2:-}"
shift 2 2>/dev/null || true

recurse=0
for arg in "$@"; do
    case "$arg" in
        /E|/e|/S|/s)
            recurse=1
            ;;
    esac
done

if [ -z "$src" ] || [ -z "$dst" ]; then
    exit 16
fi

mkdir -p "$dst" 2>/dev/null

if [ ! -d "$src" ]; then
    # robocopy itself would fail loudly; sync-configs.ps1 never calls us
    # with a missing source dir (it checks Test-Path first), but fail safe.
    exit 16
fi

if [ "$recurse" = "1" ]; then
    cp -a "$src"/. "$dst"/ 2>/dev/null
else
    find "$src" -maxdepth 1 -mindepth 1 -type f -exec cp -p {} "$dst"/ \; 2>/dev/null
fi

if [ -n "${SHIM_ROBOCOPY_RC:-}" ]; then
    exit "$SHIM_ROBOCOPY_RC"
fi

exit 1
'@ -replace "`r`n", "`n"

    # Only write the bash shim on non-Windows, and only the .cmd shim on
    # Windows (-ForceShim). Dropping both into the same shim directory
    # unconditionally would leave an extensionless 'robocopy' bash file
    # sitting alongside 'robocopy.cmd' on Windows -- a bare 'robocopy'
    # command-resolution order there could in principle be influenced by
    # PATH ordering, so avoid the ambiguity entirely by only ever writing
    # the one shim file relevant to the platform actually running us.
    if (-not (Test-IsWindowsPlatform)) {
        Set-Content -LiteralPath $shPath -Value $shContent -NoNewline -Encoding UTF8
        & chmod +x $shPath 2>$null | Out-Null
        return
    }

    # Windows-usable equivalent (used only with -ForceShim, since real
    # robocopy.exe is normally preferred on Windows).
    $cmdPath = Join-Path $script:ShimDir 'robocopy.cmd'
    $cmdContent = @'
@echo off
setlocal enabledelayedexpansion
set "SRC=%~1"
set "DST=%~2"
set "RECURSE=0"
for %%A in (%*) do (
    if /I "%%~A"=="/E" set "RECURSE=1"
    if /I "%%~A"=="/S" set "RECURSE=1"
)
if not exist "%DST%\" mkdir "%DST%" >nul 2>&1
if "%RECURSE%"=="1" (
    xcopy "%SRC%\*" "%DST%\" /E /Y /I /Q >nul 2>&1
) else (
    xcopy "%SRC%\*" "%DST%\" /Y /I /Q >nul 2>&1
)
if defined SHIM_ROBOCOPY_RC (
    exit /b %SHIM_ROBOCOPY_RC%
)
exit /b 1
'@ -replace "`r`n", "`n" -replace "`n", "`r`n"
    # Normalize to bare LF first, then re-expand to CRLF: the raw here-string
    # above already contains CRLF when this file itself is checked out with
    # CRLF line endings (e.g. Git for Windows' default core.autocrlf=true on
    # windows-latest runners, since this repo has no .gitattributes forcing
    # LF). A plain "-replace `n, `r`n" is NOT idempotent against that case --
    # it turns each existing \r\n into \r\r\n, corrupting the batch file.
    Set-Content -LiteralPath $cmdPath -Value $cmdContent -Encoding ASCII
}

New-RobocopyShim

if ($script:UseShim) {
    # Prepend the shim dir to PATH for every child process this harness
    # spawns. Left off PATH entirely on Windows without -ForceShim so
    # sync-configs.ps1 finds the real robocopy.exe already on PATH there.
    $env:PATH = $script:ShimDir + [System.IO.Path]::PathSeparator + $env:PATH
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

function Write-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Content -NoNewline -Encoding UTF8
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Get-FolderFileMap {
    # relative-path -> content, for every file under $Dir.
    param([string]$Dir)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Dir)) { return $map }
    $full = (Resolve-Path -LiteralPath $Dir).Path
    Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($full.Length).TrimStart('/', '\')
        $rel = $rel -replace '\\', '/'
        $map[$rel] = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
    }
    return $map
}

# Independent re-implementation of the engine's profile-entry naming rule
# ("<hash8> = first 8 hex chars of MD5 of the lowercased full path"), kept
# deliberately separate from sync-configs.ps1's own Get-Hash8 /
# Get-ProfileEntryName so a bug in the script's hashing can't hide behind
# a test that trusts the same buggy code to compute its own expectations.
function Test-Hash8 {
    param([string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $md5.ComputeHash($bytes)
        $hex = [System.BitConverter]::ToString($hashBytes) -replace '-', ''
        return $hex.Substring(0, 8).ToLowerInvariant()
    }
    finally {
        $md5.Dispose()
    }
}

function Test-ProfileEntryName {
    param([string]$Path)
    $lower = $Path.ToLowerInvariant()
    $hash8 = Test-Hash8 -Text $lower
    $leaf = Split-Path -Path $Path -Leaf
    return ('{0}_{1}' -f $hash8, $leaf)
}

# ---------------------------------------------------------------------------
# Sandbox + script invocation
# ---------------------------------------------------------------------------

function New-Sandbox {
    param([string]$Label)
    $root = Join-Path $script:TempRoot ("sbx-{0}-{1}" -f $Label, ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    $installDir = Join-Path $root 'install'
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $scriptCopy = Join-Path $installDir 'sync-configs.ps1'
    Copy-Item -LiteralPath $script:SyncScriptSource -Destination $scriptCopy -Force

    return [PSCustomObject]@{
        Root        = $root
        InstallDir  = $installDir
        ScriptPath  = $scriptCopy
        PathsFile   = Join-Path $installDir 'paths.txt'
        StateFile   = Join-Path $installDir 'state.json'
        LogFile     = Join-Path $installDir 'sync.log'
        ProfilesDir = Join-Path $installDir 'profiles'
    }
}

function Set-PathsFile {
    param($Sandbox, [string[]]$Lines)
    Set-Content -LiteralPath $Sandbox.PathsFile -Value $Lines -Encoding UTF8
}

function Invoke-Sync {
    # Drives the real script exactly as Vibepollo (do|undo) or the watchdog
    # (settle) would: a fresh child process, -Mode do|undo|settle,
    # APOLLO_CLIENT_NAME set (or deliberately absent) per scenario. Returns
    # the child process exit code. settle never has a client env var set in
    # real use, but callers are free to pass one anyway -- Get-ClientNameRaw
    # is simply never consulted by settle.
    param(
        $Sandbox,
        [ValidateSet('do', 'undo', 'settle')][string]$Mode,
        [string]$ApolloClient = $null,
        [string]$SunshineClient = $null
    )

    if ($null -ne $ApolloClient) { $env:APOLLO_CLIENT_NAME = $ApolloClient }
    else { Remove-Item Env:\APOLLO_CLIENT_NAME -ErrorAction SilentlyContinue }

    if ($null -ne $SunshineClient) { $env:SUNSHINE_CLIENT_NAME = $SunshineClient }
    else { Remove-Item Env:\SUNSHINE_CLIENT_NAME -ErrorAction SilentlyContinue }

    $global:LASTEXITCODE = $null
    # -ExecutionPolicy Bypass matches the documented Vibepollo invocation
    # (install.md: `powershell.exe -ExecutionPolicy Bypass -File
    # ...`) exactly, so the harness exercises the real shipped command line
    # rather than one that happens to work only because CI's default policy
    # is permissive. pwsh accepts (and ignores) the switch on every platform.
    & $script:PwshExe -NoProfile -ExecutionPolicy Bypass -File $Sandbox.ScriptPath -Mode $Mode | Out-Null
    return $LASTEXITCODE
}

function Start-DecoyHostProcess {
    # Spawns a short-lived background process for T23 (CONTRACT A: settle
    # guard v2's StartTime-vs-'since' instance check) under a distinctive,
    # test-only executable name, so a Get-Process -Name pattern (via
    # SCP_HOST_PROCESS_NAMES) can match it EXCLUSIVELY -- unlike T21's
    # $script:HostAliveProcessName trick (this harness's own long-lived
    # interpreter process, whose whole point is that it started long before
    # any test's pending state existed), T23 specifically needs a process
    # whose StartTime is LATER than a given 'since'. Matching on the
    # interpreter's own process name would also match this still-running
    # harness process itself (same binary), whose much-earlier StartTime
    # would corrupt the "earliest StartTime" comparison Get-HostProcessInstanceInfo
    # performs -- so this spawns something with a name nothing else on the
    # box will ever share.
    #
    # Achieved by copying a small, always-present OS binary that blocks for
    # a few seconds (/bin/sleep on Linux/macOS; PING.EXE on Windows, given a
    # target/count that keeps it busy without needing input) to a decoy file
    # name unique to this test run, then launching that copy directly --
    # Get-Process -Name reports the process under the name of the actual
    # file that was executed, not the original binary it was copied from.
    #
    # Returns a PSCustomObject { Process; Name; Path }. The caller owns
    # cleanup: Stop-Process the Process (best-effort, it may have already
    # exited) and Remove-Item the Path.
    param(
        [string]$DecoyName,
        [int]$Seconds = 6
    )

    $decoyDir = Join-Path $script:TempRoot 'decoy'
    if (-not (Test-Path -LiteralPath $decoyDir)) {
        New-Item -ItemType Directory -Path $decoyDir -Force | Out-Null
    }

    if (Test-IsWindowsPlatform) {
        $decoyPath = Join-Path $decoyDir ($DecoyName + '.exe')
        $pingPath = Join-Path $env:SystemRoot 'System32\PING.EXE'
        Copy-Item -LiteralPath $pingPath -Destination $decoyPath -Force
        # '-n' pings 127.0.0.1 (count+1) times, ~1 second apart, needs no
        # stdin/console interaction -- unlike timeout.exe/choice.exe.
        $proc = Start-Process -FilePath $decoyPath -ArgumentList @('-n', [string]($Seconds + 1), '127.0.0.1') -WindowStyle Hidden -PassThru
    }
    else {
        $decoyPath = Join-Path $decoyDir $DecoyName
        Copy-Item -LiteralPath '/bin/sleep' -Destination $decoyPath -Force
        & chmod +x $decoyPath 2>$null | Out-Null
        $proc = Start-Process -FilePath $decoyPath -ArgumentList @([string]$Seconds) -PassThru
    }

    return [PSCustomObject]@{
        Process = $proc
        Name    = $DecoyName
        Path    = $decoyPath
    }
}

function Stop-DecoyHostProcess {
    # Best-effort cleanup counterpart to Start-DecoyHostProcess.
    param($Decoy)

    if ($null -eq $Decoy) { return }
    try {
        if ($Decoy.Process -and -not $Decoy.Process.HasExited) {
            Stop-Process -Id $Decoy.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Process may have already exited on its own -- fine either way.
    }
    Remove-Item -LiteralPath $Decoy.Path -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Assertions / scenario bookkeeping
# ---------------------------------------------------------------------------

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:ScenarioResults = New-Object System.Collections.Generic.List[object]

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:Failures.Add($Message)
    }
}

function Assert-FolderContentEquals {
    # Asserts every entry in $Expected (relative-path -> content) exists
    # under $Dir with matching content. Does not care about extra files
    # present in $Dir beyond what's in $Expected (callers that need to
    # forbid extras check for that explicitly).
    param([string]$Dir, [hashtable]$Expected, [string]$Label)
    $actual = Get-FolderFileMap -Dir $Dir
    foreach ($key in $Expected.Keys) {
        if (-not $actual.ContainsKey($key)) {
            Assert-That $false "$Label`: expected file '$key' missing under $Dir"
            continue
        }
        Assert-That ($actual[$key] -eq $Expected[$key]) `
            "$Label`: content mismatch for '$key' under $Dir (expected '$($Expected[$key])', got '$($actual[$key])')"
    }
}

function Invoke-Scenario {
    param([string]$Name, [scriptblock]$Body)
    $script:Failures = New-Object System.Collections.Generic.List[string]
    try {
        & $Body
    }
    catch {
        $script:Failures.Add("EXCEPTION: $($_.Exception.Message)")
    }
    $pass = ($script:Failures.Count -eq 0)
    $script:ScenarioResults.Add([PSCustomObject]@{
        Name     = $Name
        Pass     = $pass
        Skip     = $false
        Reason   = $null
        Failures = @($script:Failures)
    })
    return $pass
}

function Add-SkippedScenario {
    # Records a scenario as SKIP instead of running it. Counted separately
    # from passed/failed in the summary table and total line; never
    # contributes to the failure count, so it never affects the exit code.
    param([string]$Name, [string]$Reason)
    $script:ScenarioResults.Add([PSCustomObject]@{
        Name     = $Name
        Pass     = $true
        Skip     = $true
        Reason   = $Reason
        Failures = @()
    })
}

# ===========================================================================
# T1..T6 — the main narrative (mirrors the original manual test plan),
# run sequentially against one shared sandbox since each step depends on
# the disk/profile state the previous step left behind.
# ===========================================================================

$sandbox = New-Sandbox -Label 'main'

$gameConfigsDir = Join-Path $sandbox.Root 'game-configs'
$filePath = Join-Path $gameConfigsDir 'settings.ini'
$folderPath = Join-Path $gameConfigsDir 'savefolder'

$fileOriginal = 'FILE:ORIGINAL'
$fileChangedV1 = 'FILE:CHANGED_V1'
$fileChangedV2 = 'FILE:CHANGED_V2'
$folderCfgOriginal = 'FOLDERCFG:ORIGINAL'
$folderCfgChangedV1 = 'FOLDERCFG:CHANGED_V1'
$folderCfgChangedV2 = 'FOLDERCFG:CHANGED_V2'
$folderNestedOriginal = 'FOLDERNESTED:ORIGINAL'

Write-TextFile -Path $filePath -Content $fileOriginal
Write-TextFile -Path (Join-Path $folderPath 'config.cfg') -Content $folderCfgOriginal
Write-TextFile -Path (Join-Path $folderPath 'nested/extra.dat') -Content $folderNestedOriginal

Set-PathsFile -Sandbox $sandbox -Lines @(
    '# T1-T6 main flow paths'
    $filePath
    $folderPath
)

$fileEntry = Test-ProfileEntryName -Path $filePath
$folderEntry = Test-ProfileEntryName -Path $folderPath

# --- T1: no client env vars -----------------------------------------------
Invoke-Scenario -Name 'T1: no client env vars -> no-op, exit 0' -Body {
    Remove-Item Env:\APOLLO_CLIENT_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\SUNSHINE_CLIENT_NAME -ErrorAction SilentlyContinue

    $rc = Invoke-Sync -Sandbox $sandbox -Mode 'do'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"
    Assert-That (-not (Test-Path -LiteralPath $sandbox.ProfilesDir)) 'profiles/ should not have been created'
    Assert-That (-not (Test-Path -LiteralPath $sandbox.StateFile)) 'state.json should not have been created'
} | Out-Null

# --- T2: first 'do' as iPad ------------------------------------------------
Invoke-Scenario -Name 'T2: first do as iPad -> seeds profile, backs up _local' -Body {
    $rc = Invoke-Sync -Sandbox $sandbox -Mode 'do' -ApolloClient 'iPad'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    $localDir = Join-Path $sandbox.ProfilesDir '_local'
    $iPadDir = Join-Path $sandbox.ProfilesDir 'iPad'
    Assert-That (Test-Path -LiteralPath $localDir) '_local profile dir should exist'
    Assert-That (Test-Path -LiteralPath $iPadDir) 'iPad profile dir should exist'

    Assert-That ((Read-TextFile (Join-Path $localDir $fileEntry)) -eq $fileOriginal) '_local file backup should hold original content'
    Assert-FolderContentEquals -Dir (Join-Path $localDir $folderEntry) -Expected @{
        'config.cfg'      = $folderCfgOriginal
        'nested/extra.dat' = $folderNestedOriginal
    } -Label '_local folder backup'

    Assert-That ((Read-TextFile (Join-Path $iPadDir $fileEntry)) -eq $fileOriginal) 'iPad seeded file should hold original content'
    Assert-FolderContentEquals -Dir (Join-Path $iPadDir $folderEntry) -Expected @{
        'config.cfg'      = $folderCfgOriginal
        'nested/extra.dat' = $folderNestedOriginal
    } -Label 'iPad seeded folder'

    Assert-That ((Read-TextFile $filePath) -eq $fileOriginal) 'disk file content must be unchanged after seeding'
    Assert-FolderContentEquals -Dir $folderPath -Expected @{
        'config.cfg'      = $folderCfgOriginal
        'nested/extra.dat' = $folderNestedOriginal
    } -Label 'disk folder content must be unchanged after seeding'

    Assert-That (Test-Path -LiteralPath $sandbox.StateFile) 'state.json should exist'
    $state = Get-Content -LiteralPath $sandbox.StateFile -Raw | ConvertFrom-Json
    Assert-That ($state.activeClient -eq 'iPad') "state.activeClient expected 'iPad', got '$($state.activeClient)'"
    Assert-That ([bool]$state.localBackedUp -eq $true) 'state.localBackedUp expected true'
    Assert-That (-not [string]::IsNullOrWhiteSpace([string]$state.since)) 'state.since expected non-empty'
} | Out-Null

# --- T3: in-game change, then undo -----------------------------------------
Invoke-Scenario -Name 'T3: in-game change + undo -> saved to iPad, disk restored to _local' -Body {
    Write-TextFile -Path $filePath -Content $fileChangedV1
    Write-TextFile -Path (Join-Path $folderPath 'config.cfg') -Content $folderCfgChangedV1

    $rc = Invoke-Sync -Sandbox $sandbox -Mode 'undo' -ApolloClient 'iPad'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    $iPadDir = Join-Path $sandbox.ProfilesDir 'iPad'
    Assert-That ((Read-TextFile (Join-Path $iPadDir $fileEntry)) -eq $fileChangedV1) 'iPad profile file should now hold the in-game change'
    Assert-FolderContentEquals -Dir (Join-Path $iPadDir $folderEntry) -Expected @{
        'config.cfg'      = $folderCfgChangedV1
        'nested/extra.dat' = $folderNestedOriginal
    } -Label 'iPad profile folder after undo'

    Assert-That ((Read-TextFile $filePath) -eq $fileOriginal) 'disk file should be restored to _local (original) content'
    Assert-FolderContentEquals -Dir $folderPath -Expected @{
        'config.cfg'      = $folderCfgOriginal
        'nested/extra.dat' = $folderNestedOriginal
    } -Label 'disk folder should be restored to _local (original) content'

    Assert-That (-not (Test-Path -LiteralPath $sandbox.StateFile)) 'state.json should be cleared/absent after undo'
} | Out-Null

# --- T4: second 'do' as iPad ------------------------------------------------
Invoke-Scenario -Name 'T4: second do as iPad -> restores iPad changed content to disk' -Body {
    $rc = Invoke-Sync -Sandbox $sandbox -Mode 'do' -ApolloClient 'iPad'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    Assert-That ((Read-TextFile $filePath) -eq $fileChangedV1) 'disk file should now show iPad changed content (restore works)'
    Assert-FolderContentEquals -Dir $folderPath -Expected @{
        'config.cfg'      = $folderCfgChangedV1
        'nested/extra.dat' = $folderNestedOriginal
    } -Label 'disk folder should now show iPad changed content'

    Assert-That (Test-Path -LiteralPath $sandbox.StateFile) 'state.json should exist'
    $state = Get-Content -LiteralPath $sandbox.StateFile -Raw | ConvertFrom-Json
    Assert-That ($state.activeClient -eq 'iPad') "state.activeClient expected 'iPad', got '$($state.activeClient)'"
} | Out-Null

# --- T5: pending session recovered by a different client's 'do' -----------
Invoke-Scenario -Name 'T5: pending iPad session + do as AppleTV -> saved to iPad, _local untouched' -Body {
    Write-TextFile -Path $filePath -Content $fileChangedV2
    Write-TextFile -Path (Join-Path $folderPath 'config.cfg') -Content $folderCfgChangedV2

    $rc = Invoke-Sync -Sandbox $sandbox -Mode 'do' -ApolloClient 'AppleTV'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    $iPadDir = Join-Path $sandbox.ProfilesDir 'iPad'
    Assert-That ((Read-TextFile (Join-Path $iPadDir $fileEntry)) -eq $fileChangedV2) 'pending iPad session should be saved with the pre-AppleTV disk state'
    Assert-FolderContentEquals -Dir (Join-Path $iPadDir $folderEntry) -Expected @{
        'config.cfg'      = $folderCfgChangedV2
        'nested/extra.dat' = $folderNestedOriginal
    } -Label 'iPad profile folder after pending-session recovery'

    $localDir = Join-Path $sandbox.ProfilesDir '_local'
    Assert-That ((Read-TextFile (Join-Path $localDir $fileEntry)) -eq $fileOriginal) '_local must NOT be touched by pending-session recovery'
    Assert-FolderContentEquals -Dir (Join-Path $localDir $folderEntry) -Expected @{
        'config.cfg'      = $folderCfgOriginal
        'nested/extra.dat' = $folderNestedOriginal
    } -Label '_local folder must remain original'

    $appleDir = Join-Path $sandbox.ProfilesDir 'AppleTV'
    Assert-That (Test-Path -LiteralPath $appleDir) 'AppleTV profile dir should be created'
    Assert-That ((Read-TextFile (Join-Path $appleDir $fileEntry)) -eq $fileChangedV2) 'AppleTV profile should be seeded from current (modified) disk state'
    Assert-FolderContentEquals -Dir (Join-Path $appleDir $folderEntry) -Expected @{
        'config.cfg'      = $folderCfgChangedV2
        'nested/extra.dat' = $folderNestedOriginal
    } -Label 'AppleTV profile folder seeded from disk'

    Assert-That (Test-Path -LiteralPath $sandbox.StateFile) 'state.json should exist'
    $state = Get-Content -LiteralPath $sandbox.StateFile -Raw | ConvertFrom-Json
    Assert-That ($state.activeClient -eq 'AppleTV') "state.activeClient expected 'AppleTV', got '$($state.activeClient)'"
} | Out-Null

# --- T6: undo as AppleTV -----------------------------------------------------
Invoke-Scenario -Name 'T6: undo as AppleTV -> disk back to _local original' -Body {
    $rc = Invoke-Sync -Sandbox $sandbox -Mode 'undo' -ApolloClient 'AppleTV'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    Assert-That ((Read-TextFile $filePath) -eq $fileOriginal) 'disk file should be back to _local (original) content'
    Assert-FolderContentEquals -Dir $folderPath -Expected @{
        'config.cfg'      = $folderCfgOriginal
        'nested/extra.dat' = $folderNestedOriginal
    } -Label 'disk folder should be back to _local (original) content'

    Assert-That (-not (Test-Path -LiteralPath $sandbox.StateFile)) 'state.json should be cleared/absent after undo'
} | Out-Null

# ===========================================================================
# T7 — nonexistent path in paths.txt: logged + skipped, others still work
# ===========================================================================

Invoke-Scenario -Name 'T7: nonexistent path in paths.txt -> logged, skipped, others processed' -Body {
    $sb = New-Sandbox -Label 'T7'
    $goodFile = Join-Path $sb.Root 'game-configs/good.cfg'
    Write-TextFile -Path $goodFile -Content 'GOOD:CONTENT'
    $missingPath = Join-Path $sb.Root 'game-configs/does-not-exist/missing.cfg'

    Set-PathsFile -Sandbox $sb -Lines @($goodFile, $missingPath)

    $rc = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'T7Client'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    Assert-That (Test-Path -LiteralPath $sb.LogFile) 'sync.log should have been written'
    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match [regex]::Escape($missingPath) -and $log -match 'skip-missing') `
        "sync.log should mention the missing path and a skip action; log content:`n$log"

    $goodEntry = Test-ProfileEntryName -Path $goodFile
    $missingEntry = Test-ProfileEntryName -Path $missingPath

    $localDir = Join-Path $sb.ProfilesDir '_local'
    $clientDir = Join-Path $sb.ProfilesDir 'T7Client'
    Assert-That ((Read-TextFile (Join-Path $localDir $goodEntry)) -eq 'GOOD:CONTENT') 'the existing path should still be backed up to _local'
    Assert-That ((Read-TextFile (Join-Path $clientDir $goodEntry)) -eq 'GOOD:CONTENT') 'the existing path should still be seeded to the client profile'

    Assert-That (-not (Test-Path -LiteralPath (Join-Path $localDir $missingEntry))) 'no _local entry should be created for the missing path'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $clientDir $missingEntry))) 'no client entry should be created for the missing path'
} | Out-Null

# ===========================================================================
# T8 — folder restore preserves extra files not present in the profile
# (no /MIR behavior)
# ===========================================================================

Invoke-Scenario -Name 'T8: folder restore preserves extra files (no /MIR)' -Body {
    $sb = New-Sandbox -Label 'T8'
    # Space in the path deliberately: exercises real robocopy.exe on Windows
    # through PowerShell's native-argv quoting for a folder path containing
    # a space, one of the two hazards the engine's trailing-separator
    # normalization exists for (see also T17).
    $folderDir = Join-Path $sb.Root 'game configs/cfg folder'
    Write-TextFile -Path (Join-Path $folderDir 'file1.txt') -Content 'F1:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($folderDir)

    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'FolderClient'
    Assert-That ($rc1 -eq 0) "first do exit code expected 0, got $rc1"

    $rc2 = Invoke-Sync -Sandbox $sb -Mode 'undo' -ApolloClient 'FolderClient'
    Assert-That ($rc2 -eq 0) "undo exit code expected 0, got $rc2"

    # Simulate something writing directly into the real config folder that
    # never went through the tool and is therefore absent from any profile.
    $extraFile = Join-Path $folderDir 'extra-not-in-profile.txt'
    Write-TextFile -Path $extraFile -Content 'EXTRA:DATA'

    $rc3 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'FolderClient'
    Assert-That ($rc3 -eq 0) "second do exit code expected 0, got $rc3"

    Assert-That (Test-Path -LiteralPath $extraFile) 'extra file must survive a folder restore (robocopy must not mirror/delete)'
    Assert-That ((Read-TextFile $extraFile) -eq 'EXTRA:DATA') 'extra file content must be untouched'
    Assert-That ((Read-TextFile (Join-Path $folderDir 'file1.txt')) -eq 'F1:ORIGINAL') 'profile-managed file should still be restored correctly'
} | Out-Null

# ===========================================================================
# T9 — client name needing filesystem sanitization
# ===========================================================================

Invoke-Scenario -Name 'T9: client name needing sanitization works without crashing' -Body {
    $sb = New-Sandbox -Label 'T9'
    $fileT9 = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $fileT9 -Content 'T9:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($fileT9)

    $rawClient = 'Apple TV: living/room'
    $rc = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient $rawClient
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"
    Assert-That (Test-Path -LiteralPath $sb.ProfilesDir) 'profiles/ should exist'

    $clientDirs = @(Get-ChildItem -LiteralPath $sb.ProfilesDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_local' })
    Assert-That ($clientDirs.Count -eq 1) "expected exactly one non-_local client profile dir, found $($clientDirs.Count): $($clientDirs.Name -join ', ')"

    if ($clientDirs.Count -ge 1) {
        $sanitized = $clientDirs[0].Name
        Assert-That ($sanitized -notmatch '[<>:"/\\|?*\x00-\x1F]') "sanitized folder name '$sanitized' still contains filesystem-invalid characters"
        Assert-That ($sanitized -ne '_local') "sanitized folder name must not collide with the reserved '_local' profile"
        Assert-That (-not [string]::IsNullOrWhiteSpace($sanitized)) 'sanitized folder name must not be blank'

        Assert-That (Test-Path -LiteralPath $sb.StateFile) 'state.json should exist'
        $state = Get-Content -LiteralPath $sb.StateFile -Raw | ConvertFrom-Json
        Assert-That ($state.activeClient -eq $sanitized) "state.activeClient ('$($state.activeClient)') should equal the sanitized folder name ('$sanitized')"

        $entry = Test-ProfileEntryName -Path $fileT9
        Assert-That ((Read-TextFile (Join-Path $clientDirs[0].FullName $entry)) -eq 'T9:ORIGINAL') 'sanitized client profile should be correctly seeded'
    }

    Assert-That ((Read-TextFile $fileT9) -eq 'T9:ORIGINAL') 'disk content must be unaffected by sanitization handling'
} | Out-Null

# ===========================================================================
# T10 — corrupt/truncated state.json must NOT be treated as "clean": the
# _local backup step must be skipped entirely rather than overwriting the
# true local config with whatever's on disk (which is presumably the
# interrupted previous client's session).
# ===========================================================================

Invoke-Scenario -Name 'T10: corrupt state.json -> _local left untouched, do still succeeds' -Body {
    $sb = New-Sandbox -Label 'T10'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T10:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    # Establish a known-good _local via one clean 'do'.
    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'ClientX'
    Assert-That ($rc1 -eq 0) "first do exit code expected 0, got $rc1"
    $localDir = Join-Path $sb.ProfilesDir '_local'
    Assert-That ((Read-TextFile (Join-Path $localDir $entry)) -eq 'T10:ORIGINAL') '_local should hold the original content after the first clean do'

    # Simulate an interrupted write leaving state.json truncated/corrupt,
    # and disk holding whatever ClientX's session left behind.
    Write-TextFile -Path $sb.StateFile -Content '{"activeClient":"Clie'
    Write-TextFile -Path $f -Content 'T10:CLIENTX_LEFTOVER'

    $rc2 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'ClientY'
    Assert-That ($rc2 -eq 0) "second do (corrupt state) exit code expected 0, got $rc2"

    Assert-That ((Read-TextFile (Join-Path $localDir $entry)) -eq 'T10:ORIGINAL') '_local must remain the ORIGINAL content -- corrupt state.json must not trigger a fresh _local backup'

    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match 'action=state-corrupt\b') 'sync.log should record state-corrupt'
    Assert-That ($null -ne $log -and $log -match 'action=state-corrupt-skip-local-backup') 'sync.log should record that the _local backup was skipped'

    # The incoming client (ClientY) should still be served normally.
    $clientYDir = Join-Path $sb.ProfilesDir 'ClientY'
    Assert-That (Test-Path -LiteralPath $clientYDir) 'ClientY profile dir should still be created despite the corrupt state.json'
    Assert-That ((Read-TextFile (Join-Path $clientYDir $entry)) -eq 'T10:CLIENTX_LEFTOVER') 'ClientY should be seeded from current (leftover) disk state'
} | Out-Null

# ===========================================================================
# T11 — state.json activeClient == "_local": must not let a pending-session
# save collide with (overwrite) the reserved _local profile.
# ===========================================================================

Invoke-Scenario -Name 'T11: state.json activeClient="_local" cannot clobber the real _local profile' -Body {
    $sb = New-Sandbox -Label 'T11'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T11:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'ClientX'
    Assert-That ($rc1 -eq 0) "first do exit code expected 0, got $rc1"
    $localDir = Join-Path $sb.ProfilesDir '_local'
    Assert-That ((Read-TextFile (Join-Path $localDir $entry)) -eq 'T11:ORIGINAL') '_local should hold the original content'

    # Hand-edit state.json so activeClient is literally the reserved name.
    Write-TextFile -Path $sb.StateFile -Content '{"activeClient":"_local","since":"2020-01-01T00:00:00Z","localBackedUp":true}'
    Write-TextFile -Path $f -Content 'T11:PENDING_DISK_STATE'

    $rc2 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'ClientY'
    Assert-That ($rc2 -eq 0) "second do exit code expected 0, got $rc2"

    Assert-That ((Read-TextFile (Join-Path $localDir $entry)) -eq 'T11:ORIGINAL') '_local must remain untouched/original -- a pending client literally named "_local" must never be allowed to write into it'

    # No directory literally named "_local" other than the one true local
    # profile should exist, and it must still hold the original content
    # (not the pending disk state) -- proving the pending save landed
    # somewhere sanitized, not on top of _local.
    $local1 = Get-ChildItem -LiteralPath $sb.ProfilesDir -Directory | Where-Object { $_.Name -ieq '_local' }
    Assert-That (@($local1).Count -eq 1) 'exactly one _local directory should exist'
} | Out-Null

# ===========================================================================
# T12 — state.json activeClient containing path-traversal characters must
# never cause a write outside profiles\.
# ===========================================================================

Invoke-Scenario -Name 'T12: state.json activeClient with traversal characters cannot escape profiles\' -Body {
    $sb = New-Sandbox -Label 'T12'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T12:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'ClientX'
    Assert-That ($rc1 -eq 0) "first do exit code expected 0, got $rc1"
    $localDir = Join-Path $sb.ProfilesDir '_local'

    Write-TextFile -Path $sb.StateFile -Content '{"activeClient":"../../escaped","since":"2020-01-01T00:00:00Z","localBackedUp":true}'
    Write-TextFile -Path $f -Content 'T12:PENDING_DISK_STATE'

    $rc2 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'ClientY'
    Assert-That ($rc2 -eq 0) "second do exit code expected 0, got $rc2"

    Assert-That ((Read-TextFile (Join-Path $localDir $entry)) -eq 'T12:ORIGINAL') '_local must remain untouched by a traversal-shaped pending client name'

    $escapedOutside = Join-Path $sb.Root 'escaped'
    Assert-That (-not (Test-Path -LiteralPath $escapedOutside)) 'nothing should be written outside profiles\ (no "escaped" dir at the sandbox root)'
    $escapedOutsideInstall = Join-Path $sb.InstallDir 'escaped'
    Assert-That (-not (Test-Path -LiteralPath $escapedOutsideInstall)) 'nothing should be written outside profiles\ (no "escaped" dir in the install dir)'

    # Every directory actually created under profiles\ must stay under it
    # and have no path-separator characters left in its name.
    Get-ChildItem -LiteralPath $sb.ProfilesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Assert-That ($_.Name -notmatch '[\\/]') "profile directory name '$($_.Name)' must not contain path separators"
    }
} | Out-Null

# ===========================================================================
# T13 — a second, spurious 'undo' (no pending session) must be a no-op: it
# must not overwrite the client's profile with the already-restored local
# config.
# ===========================================================================

Invoke-Scenario -Name 'T13: double-undo does not clobber the client profile' -Body {
    $sb = New-Sandbox -Label 'T13'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T13:LOCAL_ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'iPad'
    Assert-That ($rc1 -eq 0) "do exit code expected 0, got $rc1"

    Write-TextFile -Path $f -Content 'T13:IPAD_CHANGED'
    $rc2 = Invoke-Sync -Sandbox $sb -Mode 'undo' -ApolloClient 'iPad'
    Assert-That ($rc2 -eq 0) "first undo exit code expected 0, got $rc2"

    $iPadDir = Join-Path $sb.ProfilesDir 'iPad'
    Assert-That ((Read-TextFile (Join-Path $iPadDir $entry)) -eq 'T13:IPAD_CHANGED') 'iPad profile should hold the changed content after the first (real) undo'
    Assert-That ((Read-TextFile $f) -eq 'T13:LOCAL_ORIGINAL') 'disk should be back to local after the first undo'
    Assert-That (-not (Test-Path -LiteralPath $sb.StateFile)) 'state.json should be cleared after the first undo'

    # A second undo with no pending session must do nothing.
    $rc3 = Invoke-Sync -Sandbox $sb -Mode 'undo' -ApolloClient 'iPad'
    Assert-That ($rc3 -eq 0) "second (spurious) undo exit code expected 0, got $rc3"

    Assert-That ((Read-TextFile (Join-Path $iPadDir $entry)) -eq 'T13:IPAD_CHANGED') 'iPad profile must NOT be overwritten by a spurious second undo'
    Assert-That ((Read-TextFile $f) -eq 'T13:LOCAL_ORIGINAL') 'disk should remain local config after the spurious second undo'

    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match 'action=undo-no-pending-session') 'sync.log should record the spurious undo as a no-op'
} | Out-Null

# ===========================================================================
# T14 — an invalid -Mode value must still exit 0 (Vibepollo must never be
# blocked by a mangled prep-command argument).
# ===========================================================================

Invoke-Scenario -Name 'T14: invalid -Mode value still exits 0' -Body {
    $sb = New-Sandbox -Label 'T14'
    Remove-Item Env:\APOLLO_CLIENT_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:\SUNSHINE_CLIENT_NAME -ErrorAction SilentlyContinue

    $global:LASTEXITCODE = $null
    & $script:PwshExe -NoProfile -ExecutionPolicy Bypass -File $sb.ScriptPath -Mode 'bogus' | Out-Null
    $rc = $LASTEXITCODE
    Assert-That ($rc -eq 0) "exit code for an invalid -Mode expected 0, got $rc"
} | Out-Null

# ===========================================================================
# T15 — SUNSHINE_CLIENT_NAME fallback (used only when APOLLO_CLIENT_NAME is
# absent) must work end-to-end.
# ===========================================================================

Invoke-Scenario -Name 'T15: SUNSHINE_CLIENT_NAME fallback works when APOLLO_CLIENT_NAME is unset' -Body {
    $sb = New-Sandbox -Label 'T15'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T15:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    $rc = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient $null -SunshineClient 'SunshineClient'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    $clientDir = Join-Path $sb.ProfilesDir 'SunshineClient'
    Assert-That (Test-Path -LiteralPath $clientDir) 'SunshineClient profile dir should be created via the SUNSHINE_CLIENT_NAME fallback'
    Assert-That ((Read-TextFile (Join-Path $clientDir $entry)) -eq 'T15:ORIGINAL') 'SunshineClient profile should be seeded correctly'
} | Out-Null

# ===========================================================================
# T16 — a robocopy failure (rc >= 8) must be logged as an error and the
# process must still exit 0.
# ===========================================================================

if ($script:UseShim) {
    Invoke-Scenario -Name 'T16: forced robocopy failure (rc>=8) is logged as an error, process still exits 0' -Body {
        $sb = New-Sandbox -Label 'T16'
        $folderDir = Join-Path $sb.Root 'game-configs/failfolder'
        Write-TextFile -Path (Join-Path $folderDir 'file1.txt') -Content 'F1:ORIGINAL'
        Set-PathsFile -Sandbox $sb -Lines @($folderDir)

        $env:SHIM_ROBOCOPY_RC = '16'
        try {
            $rc = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'FailClient'
        }
        finally {
            Remove-Item Env:\SHIM_ROBOCOPY_RC -ErrorAction SilentlyContinue
        }
        Assert-That ($rc -eq 0) "exit code expected 0 even when robocopy fails, got $rc"

        $log = Read-TextFile $sb.LogFile
        Assert-That ($null -ne $log -and $log -match 'action=[a-z-]*error-robocopy-16') 'sync.log should record the forced robocopy failure with its exit code'
    } | Out-Null
}
else {
    # Real robocopy is in play here (Windows, no -ForceShim). There is no
    # supported way to force real robocopy.exe to return an arbitrary
    # failure code on demand, so this scenario only means anything when the
    # shim (which honors SHIM_ROBOCOPY_RC) is in the loop. Skip rather than
    # fake it or silently drop coverage of the rc>=8 handling path.
    Add-SkippedScenario -Name 'T16: forced robocopy failure (rc>=8) is logged as an error, process still exits 0' -Reason 'requires robocopy shim'
}

# ===========================================================================
# T17 — a folder path listed with a trailing separator normalizes to the
# SAME profile entry as the same folder listed without one.
# ===========================================================================

Invoke-Scenario -Name 'T17: trailing separator on a folder path normalizes to a single profile entry' -Body {
    $sb = New-Sandbox -Label 'T17'
    # Space in the path AND a trailing separator: the exact combined hazard
    # the engine's trailing-separator normalization exists for -- a folder path
    # with a space, before normalization ending in a trailing backslash,
    # passed through PowerShell 5.1 native-argv quoting to robocopy.exe.
    $folderDir = Join-Path $sb.Root 'game configs/trailing sep folder'
    Write-TextFile -Path (Join-Path $folderDir 'file1.txt') -Content 'F1:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @(($folderDir + '/'))

    $rc = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'SepClient'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    $expectedEntry = Test-ProfileEntryName -Path $folderDir
    $localDir = Join-Path $sb.ProfilesDir '_local'
    $entryDir = Join-Path $localDir $expectedEntry
    Assert-That (Test-Path -LiteralPath $entryDir) "expected a single normalized profile entry '$expectedEntry' under _local"

    $allEntries = @(Get-ChildItem -LiteralPath $localDir -Directory -ErrorAction SilentlyContinue)
    Assert-That ($allEntries.Count -eq 1) "expected exactly one profile entry under _local, found $($allEntries.Count): $($allEntries.Name -join ', ')"
} | Out-Null

# ===========================================================================
# T18 — missing paths.txt: 'do' with a client set must still succeed (zero
# paths), log 'paths-file-missing', and still write state.json.
# ===========================================================================

Invoke-Scenario -Name 'T18: missing paths.txt -> logged, exit 0, state.json still written, folders empty' -Body {
    $sb = New-Sandbox -Label 'T18'
    # Deliberately do NOT call Set-PathsFile -- the sandbox's paths.txt must
    # not exist for this scenario.
    Assert-That (-not (Test-Path -LiteralPath $sb.PathsFile)) 'sandbox paths.txt must not exist for this scenario'

    $rc = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'T18Client'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match 'action=paths-file-missing') 'sync.log should record paths-file-missing'
    Assert-That ($null -ne $log -and $log -match [regex]::Escape($sb.PathsFile)) 'sync.log should mention the paths.txt path'

    Assert-That (Test-Path -LiteralPath $sb.StateFile) 'state.json should still be written even with zero configured paths'
    $state = Get-Content -LiteralPath $sb.StateFile -Raw | ConvertFrom-Json
    Assert-That ($state.activeClient -eq 'T18Client') "state.activeClient expected 'T18Client', got '$($state.activeClient)'"

    # A missing paths.txt must not stop the tool from creating the usual
    # (empty) folder scaffolding -- this is exactly what makes the failure
    # mode silent: everything LOOKS like it worked except the folders hold
    # nothing.
    $clientDir = Join-Path $sb.ProfilesDir 'T18Client'
    $localDir = Join-Path $sb.ProfilesDir '_local'
    Assert-That (Test-Path -LiteralPath $clientDir) 'client profile dir should still be created even with paths.txt missing'
    Assert-That (Test-Path -LiteralPath $localDir) '_local profile dir should still be created even with paths.txt missing'
    Assert-That (@(Get-ChildItem -LiteralPath $clientDir -Force -ErrorAction SilentlyContinue).Count -eq 0) 'client profile dir should be empty when paths.txt is missing (zero configured paths)'
    Assert-That (@(Get-ChildItem -LiteralPath $localDir -Force -ErrorAction SilentlyContinue).Count -eq 0) '_local profile dir should be empty when paths.txt is missing (zero configured paths)'

    # The undo leg must behave the same way: still logs paths-file-missing,
    # still exits 0, still clears state.json -- nothing about the missing
    # paths.txt should make undo behave differently from a normal session.
    $rcUndo = Invoke-Sync -Sandbox $sb -Mode 'undo' -ApolloClient 'T18Client'
    Assert-That ($rcUndo -eq 0) "undo exit code expected 0, got $rcUndo"

    $logAfterUndo = Read-TextFile $sb.LogFile
    $missingCount = @([regex]::Matches($logAfterUndo, 'action=paths-file-missing')).Count
    Assert-That ($missingCount -ge 2) "sync.log should record paths-file-missing again on undo (found $missingCount occurrences)"
    Assert-That (-not (Test-Path -LiteralPath $sb.StateFile)) 'state.json should be cleared after undo even with paths.txt missing'
} | Out-Null

# ===========================================================================
# T19 — the shipped paths.example.txt template, used as-is, must sync
# nothing: its one example path is commented out, so a fresh install that
# copies the template verbatim (without editing it) produces empty profiles,
# not a crash or an accidentally-active path.
# ===========================================================================

Invoke-Scenario -Name 'T19: shipped paths.example.txt template syncs zero paths as-is' -Body {
    $sb = New-Sandbox -Label 'T19'
    $templateSource = Join-Path $script:RepoRoot 'paths.example.txt'
    Assert-That (Test-Path -LiteralPath $templateSource) "paths.example.txt should exist at $templateSource"
    Copy-Item -LiteralPath $templateSource -Destination $sb.PathsFile -Force

    $rc = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'T19Client'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    $clientDir = Join-Path $sb.ProfilesDir 'T19Client'
    Assert-That (Test-Path -LiteralPath $clientDir) 'client profile dir should still be created from the shipped template'
    Assert-That (@(Get-ChildItem -LiteralPath $clientDir -Force -ErrorAction SilentlyContinue).Count -eq 0) 'the shipped template has no active (uncommented) paths, so the client profile dir must be empty'

    # paths.txt exists (copied from the template) and has zero active paths,
    # so there is nothing to log an error/skip about -- sync.log may
    # legitimately not even be created (Write-SyncLog is only called for
    # specific actions, never for a bare no-op success). Either way,
    # paths-file-missing specifically must never appear.
    $log = Read-TextFile $sb.LogFile
    Assert-That (($null -eq $log) -or ($log -notmatch 'action=paths-file-missing')) 'paths.txt exists (copied from the template) -- paths-file-missing must NOT be logged'
} | Out-Null

# ===========================================================================
# T20 — settle with no pending state.json: no-op, logs 'settle-no-pending',
# touches nothing (state.json stays absent, profiles\ is never created).
# ===========================================================================

Invoke-Scenario -Name 'T20: settle with no pending state -> no-op, settle-no-pending logged' -Body {
    $sb = New-Sandbox -Label 'T20'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T20:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)

    Assert-That (-not (Test-Path -LiteralPath $sb.StateFile)) 'sandbox state.json must not exist for this scenario'
    Assert-That (-not (Test-Path -LiteralPath $sb.ProfilesDir)) 'sandbox profiles\ must not exist yet for this scenario'

    $rc = Invoke-Sync -Sandbox $sb -Mode 'settle'
    Assert-That ($rc -eq 0) "exit code expected 0, got $rc"

    Assert-That (-not (Test-Path -LiteralPath $sb.StateFile)) 'state.json must still be absent (settle must not create it)'
    Assert-That (-not (Test-Path -LiteralPath $sb.ProfilesDir)) 'profiles\ must not have been created (settle with no pending session touches nothing)'
    Assert-That ((Read-TextFile $f) -eq 'T20:ORIGINAL') 'disk content must be unaffected'

    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match 'action=settle-no-pending') "sync.log should record settle-no-pending; log content:`n$log"
} | Out-Null

# ===========================================================================
# T21 — CONTRACT A (settle guard v2) "same instance" branch: a pending
# session, and a matching host process whose StartTime is AT/BEFORE
# state.json's 'since' -- i.e. an instance that was already running when
# the session began and so could still be serving it -- is a no-op, logging
# 'settle-host-running' and touching nothing (pending session stays
# pending, disk untouched). This scenario gets that "earlier StartTime"
# property for free: $script:HostAliveProcessName names this very harness's
# own interpreter process, which -- by construction -- has been running
# since long before the 'do' below ever wrote state.json, so its StartTime
# is always <= 'since'. Contrast with T23, which spawns a decoy process
# specifically so its StartTime is LATER than 'since'.
# ===========================================================================

Invoke-Scenario -Name 'T21: settle with pending state + SAME host instance still running (StartTime <= since) -> no-op, settle-host-running logged' -Body {
    $sb = New-Sandbox -Label 'T21'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T21:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    # Establish a pending session the way a crash actually would: a normal
    # 'do' (backs up _local, seeds/restores the client profile), followed by
    # in-session edits with no matching 'undo'.
    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'PendingClient'
    Assert-That ($rc1 -eq 0) "do exit code expected 0, got $rc1"

    Write-TextFile -Path $f -Content 'T21:CRASH_STATE'

    # SCP_HOST_PROCESS_NAMES is set to the exact name of the interpreter
    # running this very harness (see $script:HostAliveProcessName above) --
    # guaranteed to be an actually-alive process in this test environment,
    # simulating a streaming-host process still being up.
    $env:SCP_HOST_PROCESS_NAMES = $script:HostAliveProcessName
    try {
        $rc2 = Invoke-Sync -Sandbox $sb -Mode 'settle'
    }
    finally {
        Remove-Item Env:\SCP_HOST_PROCESS_NAMES -ErrorAction SilentlyContinue
    }
    Assert-That ($rc2 -eq 0) "settle exit code expected 0, got $rc2"

    Assert-That ((Read-TextFile $f) -eq 'T21:CRASH_STATE') 'disk content must be untouched while the host process is running'

    $pendingDir = Join-Path $sb.ProfilesDir 'PendingClient'
    Assert-That ((Read-TextFile (Join-Path $pendingDir $entry)) -eq 'T21:ORIGINAL') 'pending client profile must NOT be updated while the host process is running'

    Assert-That (Test-Path -LiteralPath $sb.StateFile) 'state.json must still exist (session must remain pending)'
    $state = Get-Content -LiteralPath $sb.StateFile -Raw | ConvertFrom-Json
    Assert-That ($state.activeClient -eq 'PendingClient') "state.activeClient expected to remain 'PendingClient', got '$($state.activeClient)'"

    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match 'action=settle-host-running') "sync.log should record settle-host-running; log content:`n$log"
} | Out-Null

# ===========================================================================
# T22 — CONTRACT A (settle guard v2) "no process matches" branch: a pending
# session and NO process matching any host name pattern at all recovers
# unconditionally (nothing could possibly be serving the session) -- performs
# the crash-recovery save (disk -> pending client's profile) AND restores
# _local back onto disk AND clears state.json.
# ===========================================================================

Invoke-Scenario -Name 'T22: settle with pending state + no host process -> recovers pending client, restores _local, clears state' -Body {
    $sb = New-Sandbox -Label 'T22'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T22:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'CrashClient'
    Assert-That ($rc1 -eq 0) "do exit code expected 0, got $rc1"

    $localDir = Join-Path $sb.ProfilesDir '_local'
    Assert-That ((Read-TextFile (Join-Path $localDir $entry)) -eq 'T22:ORIGINAL') '_local should hold the original content after the do'

    # Simulate in-session edits, then a crash/disconnect with no 'undo'.
    Write-TextFile -Path $f -Content 'T22:CRASH_STATE'

    # A name guaranteed not to match any real running process.
    $env:SCP_HOST_PROCESS_NAMES = 'definitely-not-a-real-process-scp-test-xyz'
    try {
        $rc2 = Invoke-Sync -Sandbox $sb -Mode 'settle'
    }
    finally {
        Remove-Item Env:\SCP_HOST_PROCESS_NAMES -ErrorAction SilentlyContinue
    }
    Assert-That ($rc2 -eq 0) "settle exit code expected 0, got $rc2"

    $crashDir = Join-Path $sb.ProfilesDir 'CrashClient'
    Assert-That ((Read-TextFile (Join-Path $crashDir $entry)) -eq 'T22:CRASH_STATE') 'pending client profile should be saved with the disk state at settle time'

    Assert-That ((Read-TextFile $f) -eq 'T22:ORIGINAL') 'disk should be restored back to _local (original) content'

    Assert-That (-not (Test-Path -LiteralPath $sb.StateFile)) 'state.json should be cleared after settle recovers the pending session'

    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match 'mode=settle') "sync.log entries for this run should be tagged mode=settle; log content:`n$log"
} | Out-Null

# ===========================================================================
# T23 — CONTRACT A (settle guard v2) "later instance" branch: a pending
# session, and a matching host process whose StartTime is LATER than
# state.json's 'since', means every matching instance started AFTER this
# session began -- none of them can be the one that owns it, so it belongs
# to a previous host instance (crash/restart of the always-on service) and
# settle RECOVERS it anyway, exactly as if no process had matched at all.
# Unlike T21 (which reuses this harness's own already-running interpreter
# process, guaranteed to have started long before 'since'), this scenario
# spawns a brand-new decoy process AFTER the pending state is created, and
# points SCP_HOST_PROCESS_NAMES at a pattern that matches ONLY that decoy
# (see Start-DecoyHostProcess) -- proving the recovery decision is driven by
# the StartTime-vs-'since' comparison, not by whether a matching process
# happens to be alive.
# ===========================================================================

Invoke-Scenario -Name 'T23: settle with pending state + NEWER host instance (StartTime > since) -> recovers anyway while it is alive' -Body {
    $sb = New-Sandbox -Label 'T23'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T23:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'PendingClient23'
    Assert-That ($rc1 -eq 0) "do exit code expected 0, got $rc1"

    # Simulate in-session edits, then a crash/disconnect with no 'undo'.
    Write-TextFile -Path $f -Content 'T23:CRASH_STATE'

    # Give the clock a beat so the decoy process's StartTime is unambiguously
    # later than state.json's 'since' (written by the 'do' above), even on
    # coarse-grained clocks/filesystems.
    Start-Sleep -Milliseconds 1200

    $decoyName = 'scp23host-{0}' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $decoy = Start-DecoyHostProcess -DecoyName $decoyName -Seconds 6

    $env:SCP_HOST_PROCESS_NAMES = $decoyName
    try {
        # Sanity check on the test itself, BEFORE settle runs: the decoy
        # must actually be matchable by the same lookup Get-HostProcessInstanceInfo
        # uses (Get-Process -Name), not merely alive. A live-but-unmatchable
        # process (e.g. a process-name-recovery regression, or a renamed-
        # binary quirk) would make this scenario indistinguishable from
        # T22's "no process matches at all" case, silently turning this test
        # into a tautology that proves nothing about the StartTime-vs-'since'
        # comparison it exists to exercise.
        Assert-That (@(Get-Process -Name $decoyName -ErrorAction SilentlyContinue).Count -ge 1) 'decoy must be matchable by the SCP_HOST_PROCESS_NAMES pattern (test invariant)'

        $rc2 = Invoke-Sync -Sandbox $sb -Mode 'settle'

        # Sanity check on the test itself: the decoy must still have been
        # alive (matching the pattern) while settle ran -- otherwise this
        # scenario would be indistinguishable from T22's "no process
        # matches at all" case and would prove nothing about the
        # StartTime-vs-'since' comparison specifically.
        $decoy.Process.Refresh()
        Assert-That (-not $decoy.Process.HasExited) 'decoy host process should still be alive while settle ran (test invariant)'
    }
    finally {
        Remove-Item Env:\SCP_HOST_PROCESS_NAMES -ErrorAction SilentlyContinue
        Stop-DecoyHostProcess -Decoy $decoy
    }
    Assert-That ($rc2 -eq 0) "settle exit code expected 0, got $rc2"

    $crashDir = Join-Path $sb.ProfilesDir 'PendingClient23'
    Assert-That ((Read-TextFile (Join-Path $crashDir $entry)) -eq 'T23:CRASH_STATE') 'pending client profile should be saved with the disk state at settle time'

    Assert-That ((Read-TextFile $f) -eq 'T23:ORIGINAL') 'disk should be restored back to _local (original) content'

    Assert-That (-not (Test-Path -LiteralPath $sb.StateFile)) 'state.json should be cleared -- a newer host instance cannot be serving an older pending session'

    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match 'mode=settle') "sync.log entries for this run should be tagged mode=settle; log content:`n$log"
    Assert-That ($null -eq $log -or $log -notmatch 'action=settle-host-running') 'settle-host-running must NOT be logged -- the only matching process started after the session began'
} | Out-Null

# ===========================================================================
# T24 — CONTRACT A (settle guard v2) "unknown" branch: a pending session
# with a matching (alive) host process but an unparseable/missing 'since'
# means the StartTime-vs-'since' comparison cannot be made at all -- this is
# the conservative no-op safety valve, distinct from both settle-host-running
# (branch 3, comparison made and instance could still own the session) and
# recovery (branches 2/3-else, comparison made and it definitely can't). It
# must touch nothing: disk, profiles\, and state.json all stay exactly as
# the crash left them, logging the distinct 'settle-host-unknown' action.
# ===========================================================================

Invoke-Scenario -Name 'T24: settle with pending state + matching host process but unparseable since -> no-op, settle-host-unknown logged' -Body {
    $sb = New-Sandbox -Label 'T24'
    $f = Join-Path $sb.Root 'game-configs/settings.ini'
    Write-TextFile -Path $f -Content 'T24:ORIGINAL'
    Set-PathsFile -Sandbox $sb -Lines @($f)
    $entry = Test-ProfileEntryName -Path $f

    $rc1 = Invoke-Sync -Sandbox $sb -Mode 'do' -ApolloClient 'PendingClient24'
    Assert-That ($rc1 -eq 0) "do exit code expected 0, got $rc1"

    # Simulate in-session edits, then a crash/disconnect with no 'undo'.
    Write-TextFile -Path $f -Content 'T24:CRASH_STATE'

    # Hand-corrupt just the 'since' field -- activeClient stays the real
    # pending client so this scenario is otherwise identical to T21/T23,
    # isolating the unparseable-'since' branch specifically.
    Write-TextFile -Path $sb.StateFile -Content '{"activeClient":"PendingClient24","since":"not-a-timestamp","localBackedUp":true}'

    # A matching, guaranteed-alive process (this harness's own interpreter,
    # as T21 uses) -- Found must be true so the scenario actually exercises
    # "matching process, but can't read 'since'" rather than degenerating
    # into T22's "no process matches" branch.
    $env:SCP_HOST_PROCESS_NAMES = $script:HostAliveProcessName
    try {
        $rc2 = Invoke-Sync -Sandbox $sb -Mode 'settle'
    }
    finally {
        Remove-Item Env:\SCP_HOST_PROCESS_NAMES -ErrorAction SilentlyContinue
    }
    Assert-That ($rc2 -eq 0) "settle exit code expected 0, got $rc2"

    Assert-That ((Read-TextFile $f) -eq 'T24:CRASH_STATE') 'disk content must be untouched -- an unparseable since must not trigger recovery'

    $pendingDir = Join-Path $sb.ProfilesDir 'PendingClient24'
    Assert-That ((Read-TextFile (Join-Path $pendingDir $entry)) -eq 'T24:ORIGINAL') 'pending client profile must NOT be updated -- settle-host-unknown must be a pure no-op'

    Assert-That (Test-Path -LiteralPath $sb.StateFile) 'state.json must still exist (session must remain pending)'
    $state = Get-Content -LiteralPath $sb.StateFile -Raw | ConvertFrom-Json
    Assert-That ($state.activeClient -eq 'PendingClient24') "state.activeClient expected to remain 'PendingClient24', got '$($state.activeClient)'"

    $log = Read-TextFile $sb.LogFile
    Assert-That ($null -ne $log -and $log -match 'action=settle-host-unknown') "sync.log should record settle-host-unknown; log content:`n$log"
    Assert-That ($null -eq $log -or $log -notmatch 'action=settle-host-running') 'settle-host-running must NOT be logged -- since could not be parsed at all'
} | Out-Null

# ===========================================================================
# Report + cleanup
# ===========================================================================

Remove-Item Env:\APOLLO_CLIENT_NAME -ErrorAction SilentlyContinue
Remove-Item Env:\SUNSHINE_CLIENT_NAME -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Scenario Results' -ForegroundColor Cyan
Write-Host '================' -ForegroundColor Cyan

$maxNameLen = ($script:ScenarioResults | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
foreach ($r in $script:ScenarioResults) {
    if ($r.Skip) {
        $status = 'SKIP'
        $color = 'Yellow'
    }
    elseif ($r.Pass) {
        $status = 'PASS'
        $color = 'Green'
    }
    else {
        $status = 'FAIL'
        $color = 'Red'
    }
    $paddedName = $r.Name.PadRight($maxNameLen)
    Write-Host ("[{0}] {1}" -f $status, $paddedName) -ForegroundColor $color
    if ($r.Skip) {
        Write-Host ("       - reason: {0}" -f $r.Reason) -ForegroundColor Yellow
    }
    elseif (-not $r.Pass) {
        foreach ($f in $r.Failures) {
            Write-Host ("       - {0}" -f $f) -ForegroundColor Yellow
        }
    }
}

$skippedCount = @($script:ScenarioResults | Where-Object { $_.Skip }).Count
$failedCount = @($script:ScenarioResults | Where-Object { -not $_.Pass }).Count
$totalCount = $script:ScenarioResults.Count
$passedCount = $totalCount - $failedCount - $skippedCount

Write-Host ''
$summaryColor = if ($failedCount -eq 0) { 'Green' } else { 'Red' }
Write-Host ("TOTAL: {0} passed, {1} skipped, {2} failed (of {3})" -f $passedCount, $skippedCount, $failedCount, $totalCount) -ForegroundColor $summaryColor

if (-not $KeepSandbox) {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "Sandbox kept at: $script:TempRoot"
}

if ($failedCount -gt 0) {
    exit 1
}
else {
    exit 0
}
