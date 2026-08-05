<#
.SYNOPSIS
    Self-contained (no Pester, no external modules/binaries) end-to-end test
    harness for ..\sync-configs.ps1.

.DESCRIPTION
    Builds an isolated sandbox per run under the system temp directory,
    drives the real script via a child pwsh process exactly the way
    Vibepollo would (env var + -Mode do|undo), and asserts on-disk /
    profile / state.json outcomes for every scenario in the task brief
    (T1..T9). Prints a PASS/FAIL table and exits non-zero if anything
    failed.

    Because robocopy does not exist on Linux, this harness builds a tiny
    PATH shim (a script literally named 'robocopy') that mimics the exact
    subset of robocopy behavior sync-configs.ps1 depends on: copy contents
    of SRC into DST, overwrite existing files, never delete extras already
    in DST, create DST if missing, ignore the /R:1 /W:1 /NFL /NDL /NJH /NJS
    flags, and exit with a robocopy-style "success" code (< 8).

.PARAMETER KeepSandbox
    Do not delete the temp sandbox tree afterwards (useful for debugging a
    failure). Normally the sandbox is removed when the harness exits.
#>

param(
    [switch]$KeepSandbox
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

if (Test-Path -LiteralPath '/opt/pwsh/pwsh') {
    $script:PwshExe = '/opt/pwsh/pwsh'
}
elseif (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $script:PwshExe = (Get-Command pwsh).Source
}
else {
    # Windows fallback: PowerShell 5.1's own host.
    $script:PwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if (-not $script:PwshExe) { $script:PwshExe = 'powershell.exe' }
}

# ---------------------------------------------------------------------------
# Sandbox root + robocopy shim
# ---------------------------------------------------------------------------

$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-configs-tests-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 10)))
New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

$script:ShimDir = Join-Path $script:TempRoot 'shim'
New-Item -ItemType Directory -Path $script:ShimDir -Force | Out-Null

function Test-IsWindowsPlatform {
    # $IsWindows/$IsLinux/$IsMacOS only exist on PowerShell 6+. Windows
    # PowerShell 5.1 (PSEdition 'Desktop') is always Windows. Use
    # Get-Variable (not a direct $IsWindows reference) so this is safe
    # under Set-StrictMode on both editions.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue -ValueOnly)
}

function New-RobocopyShim {
    # Bash shim used when this harness itself runs on Linux/macOS.
    $shPath = Join-Path $script:ShimDir 'robocopy'
    $shContent = @'
#!/usr/bin/env bash
# Minimal robocopy-compatible shim for non-Windows test runs.
# Mimics the exact subset sync-configs.ps1 relies on:
#   - copy contents of SRC into DST (recursively)
#   - overwrite files that already exist in DST
#   - NEVER delete anything already in DST that isn't in SRC (no /MIR)
#   - create DST if it doesn't exist
#   - ignore all robocopy flags (/R:1 /W:1 /NFL /NDL /NJH /NJS ...)
#   - exit with a robocopy "success" code (< 8); we always use 1
#     ("one or more files copied successfully").
set -u
src="${1:-}"
dst="${2:-}"

if [ -z "$src" ] || [ -z "$dst" ]; then
    exit 16
fi

mkdir -p "$dst" 2>/dev/null

if [ ! -d "$src" ]; then
    # robocopy itself would fail loudly; sync-configs.ps1 never calls us
    # with a missing source dir (it checks Test-Path first), but fail safe.
    exit 16
fi

cp -a "$src"/. "$dst"/ 2>/dev/null

exit 1
'@ -replace "`r`n", "`n"

    Set-Content -LiteralPath $shPath -Value $shContent -NoNewline -Encoding UTF8
    if (-not (Test-IsWindowsPlatform)) {
        & chmod +x $shPath 2>$null | Out-Null
    }

    # Windows-usable equivalent, dropped alongside for portability so this
    # same harness (and shim directory) works unchanged if ever run on a
    # real Windows box, where a bare 'robocopy' resolution order could in
    # principle be influenced by PATH ordering.
    $cmdPath = Join-Path $script:ShimDir 'robocopy.cmd'
    $cmdContent = @'
@echo off
setlocal
set "SRC=%~1"
set "DST=%~2"
if not exist "%DST%\" mkdir "%DST%" >nul 2>&1
xcopy "%SRC%\*" "%DST%\" /E /Y /I /Q >nul 2>&1
exit /b 1
'@ -replace "`n", "`r`n"
    Set-Content -LiteralPath $cmdPath -Value $cmdContent -Encoding ASCII
}

New-RobocopyShim

# Prepend the shim dir to PATH for every child process this harness spawns.
$env:PATH = $script:ShimDir + [System.IO.Path]::PathSeparator + $env:PATH

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

# Independent re-implementation of SPEC.md's profile-entry naming rule
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
    # Drives the real script exactly as Vibepollo would: a fresh child
    # process, -Mode do|undo, APOLLO_CLIENT_NAME set (or deliberately
    # absent) per scenario. Returns the child process exit code.
    param(
        $Sandbox,
        [ValidateSet('do', 'undo')][string]$Mode,
        [string]$ApolloClient = $null,
        [string]$SunshineClient = $null
    )

    if ($null -ne $ApolloClient) { $env:APOLLO_CLIENT_NAME = $ApolloClient }
    else { Remove-Item Env:\APOLLO_CLIENT_NAME -ErrorAction SilentlyContinue }

    if ($null -ne $SunshineClient) { $env:SUNSHINE_CLIENT_NAME = $SunshineClient }
    else { Remove-Item Env:\SUNSHINE_CLIENT_NAME -ErrorAction SilentlyContinue }

    $global:LASTEXITCODE = $null
    & $script:PwshExe -NoProfile -File $Sandbox.ScriptPath -Mode $Mode | Out-Null
    return $LASTEXITCODE
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
        Failures = @($script:Failures)
    })
    return $pass
}

# ===========================================================================
# T1..T6 — the main narrative (mirrors SPEC.md's own manual test plan),
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
    $folderDir = Join-Path $sb.Root 'game-configs/cfgfolder'
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
# Report + cleanup
# ===========================================================================

Remove-Item Env:\APOLLO_CLIENT_NAME -ErrorAction SilentlyContinue
Remove-Item Env:\SUNSHINE_CLIENT_NAME -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Scenario Results' -ForegroundColor Cyan
Write-Host '================' -ForegroundColor Cyan

$maxNameLen = ($script:ScenarioResults | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
foreach ($r in $script:ScenarioResults) {
    $status = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    $color = if ($r.Pass) { 'Green' } else { 'Red' }
    $paddedName = $r.Name.PadRight($maxNameLen)
    Write-Host ("[{0}] {1}" -f $status, $paddedName) -ForegroundColor $color
    if (-not $r.Pass) {
        foreach ($f in $r.Failures) {
            Write-Host ("       - {0}" -f $f) -ForegroundColor Yellow
        }
    }
}

$failedCount = @($script:ScenarioResults | Where-Object { -not $_.Pass }).Count
$totalCount = $script:ScenarioResults.Count

Write-Host ''
$summaryColor = if ($failedCount -eq 0) { 'Green' } else { 'Red' }
Write-Host ("TOTAL: {0} passed, {1} failed (of {2})" -f ($totalCount - $failedCount), $failedCount, $totalCount) -ForegroundColor $summaryColor

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
