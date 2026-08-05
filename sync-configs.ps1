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
    [ValidateSet('do', 'undo')]
    [string]$Mode,

    [switch]$NoRun
)

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

function Get-ConfigPaths {
    # Reads paths.txt: one path per line, blank lines and '#' comments
    # skipped, each line trimmed, environment variables expanded. No quote
    # stripping is performed -- the whole (trimmed) line is the path.
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
        $result.Add($expanded)
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
    # Normalization rule (documented per SPEC.md ambiguity): trailing path
    # separators ('\' or '/') are stripped BEFORE lowercasing/hashing and
    # before computing the leaf name, so "C:\Foo\" and "C:\Foo" produce the
    # same hash8 and the same leaf.
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

function Write-SyncLog {
    # Appends one line to sync.log: timestamp, mode, client, action, path.
    # A logging failure must never crash the script -- all errors swallowed.
    param(
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client,
        [string]$Action,
        [string]$Path
    )

    try {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = '[{0}] mode={1} client={2} action={3} path={4}' -f $timestamp, $ModeLabel, $Client, $Action, $Path

        $dir = Split-Path -Path $LogFile -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    catch {
        # Never let logging failures crash the script.
    }
}

# ---------------------------------------------------------------------------
# state.json
# ---------------------------------------------------------------------------

function Read-SyncState {
    # Reads state.json. Tolerates a missing, empty, or corrupt file -- all
    # treated as "no pending session". Corruption is logged.
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
        }
    }
    catch {
        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'state-corrupt' -Path $StateFile
        return $empty
    }
}

function Write-SyncState {
    # Writes state.json as { activeClient, since, localBackedUp }.
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

        Set-Content -LiteralPath $StateFile -Value $json -Encoding UTF8
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
    # the destination directory as needed); folders use robocopy (never
    # /MIR). robocopy is invoked as a bare command name so a PATH shim can
    # replace it under test. Any failure is logged and swallowed -- callers
    # continue with remaining paths regardless of the return value.
    param(
        [string]$SourcePath,
        [string]$DestPath,
        [string]$LogFile,
        [string]$ModeLabel,
        [string]$Client,
        [string]$Action
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action ($Action + '-skip-missing') -Path $SourcePath
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $SourcePath -Force

        if ($item.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $DestPath)) {
                New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
            }

            robocopy $SourcePath $DestPath /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
            $rc = $LASTEXITCODE

            if ($rc -ge 8) {
                Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action ($Action + '-error-robocopy-' + $rc) -Path $SourcePath
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

        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action $Action -Path $SourcePath
        return $true
    }
    catch {
        Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action ($Action + '-error') -Path $SourcePath
        return $false
    }
}

function Backup-PathsToProfile {
    # Copies every configured path (disk -> profile) into ProfileDir, one
    # entry per path, named via Get-ProfileEntryName.
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
        Copy-ConfigItem -SourcePath $p -DestPath $dest -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action $ActionName | Out-Null
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
            Copy-ConfigItem -SourcePath $profileEntryPath -DestPath $p -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'restore' | Out-Null
        }
        else {
            Copy-ConfigItem -SourcePath $p -DestPath $profileEntryPath -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'seed' | Out-Null
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
            Copy-ConfigItem -SourcePath $profileEntryPath -DestPath $p -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'restore-local' | Out-Null
        }
        else {
            Write-SyncLog -LogFile $LogFile -ModeLabel $ModeLabel -Client $Client -Action 'restore-local-skip-missing' -Path $profileEntryPath
        }
    }
}

# ---------------------------------------------------------------------------
# do / undo state machine
# ---------------------------------------------------------------------------

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

    if ($state.activeClient) {
        $pendingClient = $state.activeClient
        $pendingDir = Join-Path $ProfilesRoot $pendingClient
        if (-not (Test-Path -LiteralPath $pendingDir)) {
            New-Item -ItemType Directory -Path $pendingDir -Force | Out-Null
        }
        Backup-PathsToProfile -Paths $Paths -ProfileDir $pendingDir -LogFile $LogFile -ModeLabel 'do' -Client $pendingClient -ActionName 'save-pending'
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

    Write-SyncState -StateFile $StateFile -ActiveClient $Client -LocalBackedUp $true -LogFile $LogFile -ModeLabel 'do' -Client $Client
}

function Invoke-Undo {
    # SPEC.md "undo (session end, active client = B)":
    #   1. Save disk -> profiles\B.
    #   2. Restore profiles\_local -> disk.
    #   3. Delete/clear state.json.
    param(
        [string[]]$Paths,
        [string]$ProfilesRoot,
        [string]$StateFile,
        [string]$LogFile,
        [string]$Client
    )

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

    if ($Mode -ne 'do' -and $Mode -ne 'undo') {
        # No/invalid mode: nothing to do. (Vibepollo always passes -Mode
        # explicitly; this guards manual/dot-sourced invocation.)
        return
    }

    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptRoot)) {
        if ($MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
            $scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
        }
    }
    if ([string]::IsNullOrEmpty($scriptRoot)) {
        $scriptRoot = (Get-Location).Path
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
