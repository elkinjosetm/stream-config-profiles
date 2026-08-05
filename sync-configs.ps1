<#
.SYNOPSIS
    Per-client game config profile sync for Vibepollo/Apollo streaming sessions.

.DESCRIPTION
    See SPEC.md for the full design. Summary:
      - Reads a flat list of file/folder paths from paths.txt (relative to this
        script's own folder).
      - On "do" (session start): saves any pending previous session's disk
        state into that client's profile (crash/disconnect recovery), backs
        up the local PC config into profiles\_local when starting clean, then
        restores (or seeds) the incoming client's profile onto disk.
      - On "undo" (session end): saves the ending client's disk state into
        its profile, restores profiles\_local back onto disk, and clears the
        pending-session state file.
    All companion files (paths.txt, state.json, sync.log, profiles\) are
    resolved relative to $PSScriptRoot so the script can be invoked from any
    working directory.

    This file is written to be dot-sourceable by a test harness: pass -NoRun
    to load all functions without executing Main.

.PARAMETER Mode
    'do' (session start) or 'undo' (session end).

.PARAMETER NoRun
    When set, the script defines its functions and returns without calling
    Main. Used by test harnesses that dot-source this file.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$Mode,

    [switch]$NoRun
)

# Fail fast on cmdlet errors that would otherwise be non-terminating (e.g. a
# denied Copy-Item/New-Item/Set-Content/Remove-Item) so every try/catch in
# this file actually catches real failures instead of silently falling
# through to a "success" log line. Safe: Main() is always invoked inside the
# top-level try/catch below, and the script always exits 0 regardless of
# what bubbles up.
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Client identification
# ---------------------------------------------------------------------------

function Get-ClientNameRaw {
    # Client name comes from APOLLO_CLIENT_NAME, falling back to
    # SUNSHINE_CLIENT_NAME. Returns $null/empty if neither is set.
    $name = $env:APOLLO_CLIENT_NAME
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $env:SUNSHINE_CLIENT_NAME
    }
    return $name
}

function Get-SafeClientName {
    # Sanitizes a raw client name for use as a filesystem folder name:
    #   - trims whitespace
    #   - replaces characters invalid in Windows file/folder names
    #   - strips trailing dots/spaces (Windows disallows them)
    #   - avoids reserved Windows device names (CON, PRN, COM1, ...)
    #   - never allows collision with the reserved '_local' profile folder
    # Returns $null if nothing usable remains.
    param(
        [string]$RawName
    )

    if ([string]::IsNullOrWhiteSpace($RawName)) {
        return $null
    }

    $name = $RawName.Trim()

    # Replace characters that are invalid in Windows file/folder names,
    # plus control characters.
    $name = [regex]::Replace($name, '[<>:"/\\|?*\x00-\x1F]', '_')

    # Windows disallows trailing dots and spaces in file/folder names.
    $name = $name.TrimEnd('.', ' ')

    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    $reservedPattern = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
    if ($name -imatch $reservedPattern) {
        $name = $name + '_client'
    }

    # '_local' is reserved for the implicit local-PC profile; never let a
    # client name collide with it.
    if ($name -ieq '_local') {
        $name = $name + '_client'
    }

    return $name
}

# ---------------------------------------------------------------------------
# paths.txt parsing
# ---------------------------------------------------------------------------

function Get-NormalizedConfigPath {
    # Strips trailing path separators ('\' or '/') from an expanded path,
    # once, at the point of entry -- so hashing (Get-ProfileEntryName),
    # copying (robocopy/Copy-Item) and logging all see the exact same
    # string. Guards against reducing a drive root ("C:\") to something
    # unusable ("C:").
    param(
        [string]$ExpandedPath
    )

    $trimmed = $ExpandedPath.TrimEnd('\', '/')
    if ([string]::IsNullOrEmpty($trimmed) -or $trimmed -match '^[A-Za-z]:$') {
        return $ExpandedPath
    }
    return $trimmed
}

function Get-ConfigPaths {
    # Reads paths.txt: one path per line, blank lines and '#' comments
    # skipped, each line trimmed, environment variables expanded. No quote
    # stripping is performed -- the whole (trimmed) line is the path.
    # Trailing '\'/'/' are stripped once here (see Get-NormalizedConfigPath)
    # so every downstream consumer works from the same normalized path --
    # this also avoids a Windows PowerShell 5.1 native-argv quoting hazard
    # where a path ending in '\' immediately before the closing quote (e.g.
    # a path with a space AND a trailing backslash) gets mis-parsed by
    # robocopy.exe.
    param(
        [string]$PathsFile
    )

    $result = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $PathsFile)) {
        return $result.ToArray()
    }

    $lines = Get-Content -LiteralPath $PathsFile -Encoding UTF8
    foreach ($line in $lines) {
        if ($null -eq $line) { continue }
        $trimmed = $line.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }

        $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
        $normalized = Get-NormalizedConfigPath -ExpandedPath $expanded
        $result.Add($normalized)
    }

    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Hashing / profile entry naming
# ---------------------------------------------------------------------------

function Get-Hash8 {
    # First 8 hex chars (lowercase) of the MD5 hash of the given text,
    # computed over its UTF-8 bytes.
    param(
        [string]$Text
    )

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

function Get-ProfileEntryName {
    # Profile entry name for a configured path: <hash8>_<leaf>.
    # Per SPEC.md, <hash8> is computed over the lowercased path with
    # trailing separators removed. Callers already pass paths normalized by
    # Get-NormalizedConfigPath, so the TrimEnd below is a harmless no-op in
    # practice; it is kept so this function is correct standalone too.
    param(
        [string]$ExpandedPath
    )

    $normalized = $ExpandedPath.TrimEnd('\', '/')
    if ([string]::IsNullOrEmpty($normalized)) {
        $normalized = $ExpandedPath
    }

    $lower = $normalized.ToLowerInvariant()
    $hash8 = Get-Hash8 -Text $lower

    $leaf = Split-Path -Path $normalized -Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = 'root'
    }

    return ('{0}_{1}' -f $hash8, $leaf)
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$script:Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)

function Write-SyncLog {
    # Appends one line to sync.log: timestamp, mode, client, action, path.
    # A logging failure must never crash the script -- all errors swallowed.
    # Uses BOM-less UTF-8 explicitly (System.IO.File) so the on-disk log has
    # the same byte shape on Windows PowerShell 5.1 as it does under the
    # pwsh-7 test harness (Set-Content/Add-Content -Encoding UTF8 emits a
    # BOM on 5.1 but not on 7+).
    param(
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client,
        [string]$Action,
        [string]$Path
    )

    try {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = '[{0}] mode={1} client={2} action={3} path={4}{5}' -f $timestamp, $ModeLabel, $Client, $Action, $Path, [Environment]::NewLine

        $dir = Split-Path -Path $LogFile -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        [System.IO.File]::AppendAllText($LogFile, $line, $script:Utf8NoBomEncoding)
    }
    catch {
        # Never let logging failures crash the script.
    }
}

# ---------------------------------------------------------------------------
# state.json
# ---------------------------------------------------------------------------

function Read-SyncState {
    # Reads state.json. Absent file or a file that parses with no
    # activeClient are both "clean" (no pending session). A file that
    # exists but fails to parse (truncated/corrupt write) is NOT the same
    # as clean: the disk almost certainly still holds whatever the
    # interrupted write left behind, so it is returned with IsCorrupt=$true
    # and activeClient=$null, letting the caller take the conservative
    # branch (skip the _local backup rather than guessing) instead of
    # treating it as an ordinary clean session.
    param(
        [string]$StateFile,
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client
    )

    $empty = [PSCustomObject]@{
        activeClient  = $null
        since         = $null
        localBackedUp = $false
        IsCorrupt     = $false
    }

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $empty
    }

    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $empty
        }

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed) {
            return $empty
        }

        $activeClient = $null
        if ($parsed.PSObject.Properties.Match('activeClient').Count -gt 0) {
            $activeClient = $parsed.activeClient
        }
        if ([string]::IsNullOrWhiteSpace([string]$activeClient)) {
            $activeClient = $null
        }

        $since = $null
        if ($parsed.PSObject.Properties.Match('since').Count -gt 0) {
            $since = $parsed.since
        }

        $localBackedUp = $false
        if ($parsed.PSObject.Properties.Match('localBackedUp').Count -gt 0) {
            $localBackedUp = [bool]$parsed.localBackedUp
        }

        return [PSCustomObject]@{
            activeClient  = $activeClient
            since         = $since
            localBackedUp = $localBackedUp
            IsCorrupt     = $false
        }
    }
    catch {
        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'state-corrupt' -Path $StateFile
        return [PSCustomObject]@{
            activeClient  = $null
            since         = $null
            localBackedUp = $false
            IsCorrupt     = $true
        }
    }
}

function Write-SyncState {
    # Writes state.json as { activeClient, since, localBackedUp }. Writes to
    # a temp file first and renames it into place so a process kill/crash
    # mid-write can never leave state.json truncated -- Move-Item onto an
    # existing file is an atomic replace on both NTFS and Linux filesystems.
    param(
        [string]$StateFile,
        [string]$ActiveClient,
        [bool]$LocalBackedUp,
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client
    )

    try {
        $obj = [PSCustomObject]@{
            activeClient  = $ActiveClient
            since         = (Get-Date).ToString('o')
            localBackedUp = $LocalBackedUp
        }
        $json = $obj | ConvertTo-Json

        $dir = Split-Path -Path $StateFile -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $tempFile = $StateFile + '.tmp'
        [System.IO.File]::WriteAllText($tempFile, $json, $script:Utf8NoBomEncoding)
        Move-Item -LiteralPath $tempFile -Destination $StateFile -Force
    }
    catch {
        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'state-write-error' -Path $StateFile
    }
}

function Clear-SyncState {
    # Deletes state.json (or leaves it absent if it already is).
    param(
        [string]$StateFile,
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client
    )

    try {
        if (Test-Path -LiteralPath $StateFile) {
            Remove-Item -LiteralPath $StateFile -Force
        }
    }
    catch {
        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'state-clear-error' -Path $StateFile
    }
}

# ---------------------------------------------------------------------------
# Copy primitives
# ---------------------------------------------------------------------------

function Copy-ConfigItem {
    # Copies SourcePath onto DestPath. Files use Copy-Item -Force (creating
    # the destination directory as needed); folders use robocopy with /E
    # (recurse into subfolders -- required, otherwise real robocopy only
    # copies the top-level files of a folder and silently skips nested
    # content) but never /MIR (extra files at the destination are never
    # deleted). robocopy is invoked as a bare command name so a PATH shim
    # can replace it under test. Any failure is logged and swallowed --
    # callers continue with remaining paths regardless of the return value.
    #
    # -LogPath: the path recorded in sync.log (defaults to SourcePath). For
    # restore-type actions the meaningful, stable identifier is the real
    # on-disk config path, not the profile-entry path being read from --
    # callers pass the disk path explicitly via -LogPath in that case.
    #
    # -DestIsProfileEntry: set by callers when DestPath is a profile-managed
    # entry under profiles\ (safe to replace wholesale on a type mismatch,
    # e.g. source is now a folder but the stale profile entry is a file).
    # When DestPath is instead a real disk path (a restore), a type
    # mismatch is logged and skipped rather than deleting the user's file.
    param(
        [string]$SourcePath,
        [string]$DestPath,
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client,
        [string]$Action,
        [string]$LogPath,
        [switch]$DestIsProfileEntry
    )

    if ([string]::IsNullOrEmpty($LogPath)) {
        $LogPath = $SourcePath
    }

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action ($Action + '-skip-missing') -Path $LogPath
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $SourcePath -Force
        $sourceIsContainer = [bool]$item.PSIsContainer

        if (Test-Path -LiteralPath $DestPath) {
            $destItem = Get-Item -LiteralPath $DestPath -Force
            if ([bool]$destItem.PSIsContainer -ne $sourceIsContainer) {
                if ($DestIsProfileEntry) {
                    Remove-Item -LiteralPath $DestPath -Recurse -Force
                }
                else {
                    Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action ($Action + '-type-mismatch') -Path $LogPath
                    return $false
                }
            }
        }

        if ($sourceIsContainer) {
            if (-not (Test-Path -LiteralPath $DestPath)) {
                New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
            }

            robocopy $SourcePath $DestPath /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
            $rc = $LASTEXITCODE

            if ($rc -ge 8) {
                Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action ($Action + '-error-robocopy-' + $rc) -Path $LogPath
                return $false
            }
        }
        else {
            $destDir = Split-Path -Path $DestPath -Parent
            if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }

            Copy-Item -LiteralPath $SourcePath -Destination $DestPath -Force
        }

        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action $Action -Path $LogPath
        return $true
    }
    catch {
        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action ($Action + '-error') -Path $LogPath
        return $false
    }
}

function Backup-PathsToProfile {
    # Copies every configured path (disk -> profile) into ProfileDir, one
    # entry per path, named via Get-ProfileEntryName. DestPath is always a
    # profile entry here, so a type mismatch (stale entry of the wrong
    # kind) is safe to replace wholesale.
    param(
        [string[]]$Paths,
        [string]$ProfileDir,
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client,
        [string]$ActionName
    )

    foreach ($p in $Paths) {
        $entry = Get-ProfileEntryName -ExpandedPath $p
        $dest = Join-Path $ProfileDir $entry
        Copy-ConfigItem -SourcePath $p -DestPath $dest -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action $ActionName -DestIsProfileEntry | Out-Null
    }
}

function Restore-OrSeedPaths {
    # For every configured path: if the incoming client's profile entry
    # exists, restore it onto disk. Otherwise seed the profile entry from
    # the current disk state (first session for this client/path).
    param(
        [string[]]$Paths,
        [string]$ProfileDir,
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client
    )

    foreach ($p in $Paths) {
        $entry = Get-ProfileEntryName -ExpandedPath $p
        $profileEntryPath = Join-Path $ProfileDir $entry

        if (Test-Path -LiteralPath $profileEntryPath) {
            # Source is the profile entry, but the meaningful path for
            # sync.log is the real disk path being overwritten.
            Copy-ConfigItem -SourcePath $profileEntryPath -DestPath $p -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'restore' -LogPath $p | Out-Null
        }
        else {
            Copy-ConfigItem -SourcePath $p -DestPath $profileEntryPath -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'seed' -DestIsProfileEntry | Out-Null
        }
    }
}

function Restore-PathsFromLocal {
    # Restores every configured path from profiles\_local back onto disk.
    # If a given _local entry is missing (should not normally happen once
    # localBackedUp is true), logs and skips that path.
    param(
        [string[]]$Paths,
        [string]$LocalProfileDir,
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client
    )

    foreach ($p in $Paths) {
        $entry = Get-ProfileEntryName -ExpandedPath $p
        $profileEntryPath = Join-Path $LocalProfileDir $entry

        if (Test-Path -LiteralPath $profileEntryPath) {
            Copy-ConfigItem -SourcePath $profileEntryPath -DestPath $p -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'restore-local' -LogPath $p | Out-Null
        }
        else {
            Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'restore-local-skip-missing' -Path $profileEntryPath
        }
    }
}

# ---------------------------------------------------------------------------
# do / undo state machine
# ---------------------------------------------------------------------------

function Test-PathUnderRoot {
    # Defense-in-depth boundary check: is $CandidatePath (once resolved)
    # actually inside $RootPath? Get-SafeClientName already strips '/' and
    # '\' (and ':') from a raw name, which makes traversal via Join-Path
    # impossible in practice -- this is a cheap second check, not the
    # primary defense.
    param(
        [string]$RootPath,
        [string]$CandidatePath
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    $resolvedCandidate = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd('\', '/')
    $prefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    return ($resolvedCandidate -eq $resolvedRoot) -or $resolvedCandidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-Do {
    # SPEC.md "do (session start, incoming client = B)":
    #   1. Read state.json.
    #   2. Pending session (client A): save disk -> profiles\A; do not touch
    #      _local.
    #   3. Clean: back up disk -> profiles\_local (overwrite).
    #   4. For every path: restore profiles\B if present, else seed it.
    #   5. Write state.json -> { activeClient: B, since: now }.
    # A == B needs no special-casing -- it is handled naturally by the same
    # steps (save disk -> A/B, then restore B -> disk).
    #
    # Hardening beyond the literal spec text (see review findings):
    #   - state.json's activeClient is untrusted input (hand-edited,
    #     restored from an old backup, partially rewritten). It is run
    #     through Get-SafeClientName -- exactly like a live client name --
    #     and boundary-checked before ever being used to build a path, so
    #     it can neither collide with '_local' nor escape profiles\.
    #   - A state.json that exists but fails to parse (IsCorrupt) is NOT
    #     treated as clean: the disk most likely holds a previous client's
    #     interrupted session, so the _local backup step is skipped
    #     entirely rather than risking overwriting the true local config
    #     with someone else's settings.
    #   - localBackedUp written to state.json reflects whether profiles\
    #     _local actually exists on disk after this call, not a hardcoded
    #     $true -- so a _local backup that never happened (e.g. every `do`
    #     so far saw a pending/invalid session) is visible and diagnosable
    #     instead of silently lying.
    param(
        [string[]]$Paths,
        [string]$ProfilesRoot,
        [string]$StateFile,
        [string]$LogFile,
        [string]$Client
    )

    $state = Read-SyncState -StateFile $StateFile -LogFile $LogFile -ModeLabel 'do' -Client $Client

    $localDir = Join-Path $ProfilesRoot '_local'
    $clientDir = Join-Path $ProfilesRoot $Client

    if ($state.IsCorrupt) {
        # Unparseable, non-empty state.json: neither "clean" nor a known
        # pending client. Skip the _local backup rather than guessing --
        # never overwriting _local is the safe default.
        Write-SyncLog -LogFile $LogFile -ModeLabel 'do' -Client $Client -Action 'state-corrupt-skip-local-backup' -Path $StateFile
    }
    elseif ($state.activeClient) {
        $pendingClientSafe = Get-SafeClientName -RawName $state.activeClient
        $pendingDir = $null
        if ($pendingClientSafe) {
            $candidate = Join-Path $ProfilesRoot $pendingClientSafe
            if (Test-PathUnderRoot -RootPath $ProfilesRoot -CandidatePath $candidate) {
                $pendingDir = $candidate
            }
        }

        if ($null -eq $pendingDir) {
            # activeClient sanitized to nothing usable, or somehow still
            # resolved outside profiles\ -- do not write anywhere on the
            # strength of untrusted state.json content.
            Write-SyncLog -LogFile $LogFile -ModeLabel 'do' -Client $Client -Action 'state-invalid-client' -Path ([string]$state.activeClient)
        }
        else {
            if (-not (Test-Path -LiteralPath $pendingDir)) {
                New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
            }
            Backup-PathsToProfile -Paths $Paths -ProfileDir $pendingDir -LogFile $LogFile -ModeLabel 'do' -Client $pendingClientSafe -ActionName 'save-pending'

            if (-not (Test-Path -LiteralPath $localDir)) {
                Write-SyncLog -LogFile $LogFile -ModeLabel 'do' -Client $pendingClientSafe -Action 'local-backup-missing' -Path $localDir
            }
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $localDir)) {
            New-Item -ItemType Directory -Path $localDir -Force | Out-Null
        }
        Backup-PathsToProfile -Paths $Paths -ProfileDir $localDir -LogFile $LogFile -ModeLabel 'do' -Client $Client -ActionName 'backup-local'
    }

    if (-not (Test-Path -LiteralPath $clientDir)) {
        New-Item -ItemType Directory -Path $clientDir -Force | Out-Null
    }
    Restore-OrSeedPaths -Paths $Paths -ProfileDir $clientDir -LogFile $LogFile -ModeLabel 'do' -Client $Client

    $localBackedUpNow = Test-Path -LiteralPath $localDir
    Write-SyncState -StateFile $StateFile -ActiveClient $Client -LocalBackedUp $localBackedUpNow -LogFile $LogFile -ModeLabel 'do' -Client $Client
}

function Invoke-Undo {
    # SPEC.md "undo (session end, active client = B)":
    #   1. Save disk -> profiles\B.
    #   2. Restore profiles\_local -> disk.
    #   3. Delete/clear state.json.
    #
    # Hardening beyond the literal spec text: undo only actually acts when
    # state.json shows a pending session. Without this guard, a spurious or
    # repeated undo (duplicated Vibepollo hooks, a manual re-run, a client
    # that disconnects again after already being cleanly ended) would save
    # the *current* disk state -- which by then is already the restored
    # _local config -- into the client's profile, permanently overwriting
    # the very profile this tool exists to preserve.
    param(
        [string[]]$Paths,
        [string]$ProfilesRoot,
        [string]$StateFile,
        [string]$LogFile,
        [string]$Client
    )

    $state = Read-SyncState -StateFile $StateFile -LogFile $LogFile -ModeLabel 'undo' -Client $Client

    if (-not $state.activeClient) {
        Write-SyncLog -LogFile $LogFile -ModeLabel 'undo' -Client $Client -Action 'undo-no-pending-session' -Path $StateFile
        return
    }

    if ($state.activeClient -ne $Client) {
        Write-SyncLog -LogFile $LogFile -ModeLabel 'undo' -Client $Client -Action 'undo-client-mismatch' -Path ('state activeClient=' + [string]$state.activeClient)
    }

    $clientDir = Join-Path $ProfilesRoot $Client
    if (-not (Test-Path -LiteralPath $clientDir)) {
        New-Item -ItemType Directory -Path $clientDir -Force | Out-Null
    }
    Backup-PathsToProfile -Paths $Paths -ProfileDir $clientDir -LogFile $LogFile -ModeLabel 'undo' -Client $Client -ActionName 'save'

    $localDir = Join-Path $ProfilesRoot '_local'
    Restore-PathsFromLocal -Paths $Paths -LocalProfileDir $localDir -LogFile $LogFile -ModeLabel 'undo' -Client $Client

    Clear-SyncState -StateFile $StateFile -LogFile $LogFile -ModeLabel 'undo' -Client $Client
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Main {
    param(
        [string]$Mode
    )

    # $PSScriptRoot is inherited via the scope chain from the top-level
    # script into this function and is always populated for the documented
    # Vibepollo invocation (`-File "...\sync-configs.ps1"`). The only
    # fallback worth having is the current directory, for the rare case of
    # this file being dot-sourced/pasted with no backing script path (e.g.
    # -NoRun test harness usage) -- $MyInvocation inside a function reflects
    # this function's own invocation, never the top-level script's, so it
    # can never recover a script path here and previously was dead code.
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptRoot)) {
        $scriptRoot = (Get-Location).Path
    }

    if ($Mode -ne 'do' -and $Mode -ne 'undo') {
        # No/invalid mode: nothing to do, but make it diagnosable. Note:
        # -Mode intentionally has no [ValidateSet] -- PowerShell parameter
        # validation runs before the script body (before this try/catch and
        # before `exit 0`), so an invalid value would otherwise make the
        # process exit non-zero and could block a Vibepollo launch, which
        # is exactly the failure mode the "always exit 0" guarantee exists
        # to prevent.
        $logFileForBadMode = Join-Path $scriptRoot 'sync.log'
        Write-SyncLog -LogFile $logFileForBadMode -ModeLabel ([string]$Mode) -Client 'unknown' -Action 'invalid-mode' -Path ''
        return
    }

    $rawClient = Get-ClientNameRaw
    if ([string]::IsNullOrWhiteSpace($rawClient)) {
        # Neither APOLLO_CLIENT_NAME nor SUNSHINE_CLIENT_NAME set -- not a
        # streaming session. Exit doing nothing, per SPEC.md.
        return
    }

    $client = Get-SafeClientName -RawName $rawClient
    if ([string]::IsNullOrWhiteSpace($client)) {
        return
    }

    $pathsFile = Join-Path $scriptRoot 'paths.txt'
    $stateFile = Join-Path $scriptRoot 'state.json'
    $logFile = Join-Path $scriptRoot 'sync.log'
    $profilesRoot = Join-Path $scriptRoot 'profiles'

    if (-not (Test-Path -LiteralPath $profilesRoot)) {
        New-Item -ItemType Directory -Path $profilesRoot -Force | Out-Null
    }

    $paths = Get-ConfigPaths -PathsFile $pathsFile

    if ($Mode -eq 'do') {
        Invoke-Do -Paths $paths -ProfilesRoot $profilesRoot -StateFile $stateFile -LogFile $logFile -Client $client
    }
    else {
        Invoke-Undo -Paths $paths -ProfilesRoot $profilesRoot -StateFile $stateFile -LogFile $logFile -Client $client
    }
}

# ---------------------------------------------------------------------------
# Entry point guard (lets a test harness dot-source this file with -NoRun)
# ---------------------------------------------------------------------------

if (-not $NoRun) {
    try {
        Main -Mode $Mode
    }
    catch {
        try {
            $errRoot = $PSScriptRoot
            if ([string]::IsNullOrEmpty($errRoot)) {
                $errRoot = (Get-Location).Path
            }
            $errLogFile = Join-Path $errRoot 'sync.log'
            Write-SyncLog -LogFile $errLogFile -ModeLabel $Mode -Client 'unknown' -Action 'fatal-error' -Path $_.Exception.Message
        }
        catch {
            # Absolute last resort: swallow. The script must always exit 0.
        }
    }

    exit 0
}
