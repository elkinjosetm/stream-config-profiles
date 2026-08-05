<#
.SYNOPSIS
    Headless-capable manager for stream-config-profiles: installs the engine
    (sync-configs.ps1) into its data directory, registers/unregisters it with
    Vibepollo/Apollo's global_prep_cmd, registers/unregisters the settle
    watchdog scheduled tasks, and uninstalls everything.

.DESCRIPTION
    See SPEC.md and the v2 install-layout contract for the full design.
    Summary of the on-disk layout this file manages:

      PROGRAM dir (%LOCALAPPDATA%\Programs\stream-config-profiles)
        manager.ps1            -- this file, copied here by Install-App

      DATA dir (%LOCALAPPDATA%\stream-config-profiles)
        sync-configs.ps1       -- the engine; untouched $PSScriptRoot logic
        paths.example.txt      -- shipped template
        paths.txt              -- user's copy; created once, never clobbered
        state.json / sync.log / profiles\ -- engine-owned, never touched here

    This file is structured in three regions:
      #region Core            -- all headless functions, StrictMode-safe,
                                  every function takes explicit path
                                  parameters (no hardcoded env lookups
                                  inside the logic itself -- only the thin
                                  "Get-Resolved*"/"Get-Default*" resolvers
                                  read environment variables, and only the
                                  CLI wiring at the bottom calls them).
      #region Gui              -- WinForms first-run wizard + main window.
      #region EmbeddedPayload  -- two here-string slots. Empty in the repo
                                  (dev mode): Get-EnginePayload /
                                  Get-TemplatePayload fall back to reading
                                  sync-configs.ps1 / paths.example.txt from
                                  this script's own directory. A release
                                  build process replaces the marker text
                                  inside each here-string with the real
                                  file contents, producing a self-contained
                                  dist\manager.ps1 that needs no neighbor
                                  files at all.

    Like sync-configs.ps1, this file is dot-sourceable by a test harness:
    pass -NoRun to load all functions/variables without executing the CLI
    entry point or the GUI.

.PARAMETER Action
    One of: install, register-vibepollo, unregister-vibepollo,
    register-watchdog, unregister-watchdog, uninstall. When omitted, the
    GUI is shown instead (today: a placeholder -- see #region Gui).

.PARAMETER ProgramDir
    Overrides the PROGRAM directory. Defaults to
    %LOCALAPPDATA%\Programs\stream-config-profiles.

.PARAMETER DataDir
    Overrides the DATA directory. Defaults to
    %LOCALAPPDATA%\stream-config-profiles.

.PARAMETER ConfPath
    Path to the Vibepollo/Apollo/Sunshine .conf file for
    register-vibepollo/unregister-vibepollo/uninstall. When omitted,
    Find-HostConf is used to guess it.

.PARAMETER IncludePoll
    register-watchdog only: also register the periodic poll task (off by
    default).

.PARAMETER PollMinutes
    register-watchdog only: poll interval in minutes when -IncludePoll is
    set. Clamped to a minimum of 5.

.PARAMETER RemoveData
    uninstall only: also delete the DATA directory (profiles, paths.txt,
    state.json, sync.log). Without it, DATA is left in place -- it holds
    the user's configured paths and per-client profiles.

.PARAMETER ManagerScriptPath
    Overrides the path copied into PROGRAM\manager.ps1 by Install-App, and
    the path re-launched by Invoke-Elevated. Defaults to $PSCommandPath.

.PARAMETER UserId
    register-watchdog only: the account the Logon/Poll tasks run as.
    Defaults to $env:USERNAME when omitted. The GUI always passes this
    explicitly when relaunching itself elevated, so the elevated child
    never re-derives it from its own (possibly different-admin) identity.

.PARAMETER NoRun
    When set, the script defines its functions/variables and returns
    without executing the CLI entry point or the GUI. Used by test
    harnesses that dot-source this file.
#>

# PositionalBinding = $false: every parameter below must be bound by name
# (-Action, -DataDir, ...). Without this, PowerShell assigns each
# unannotated parameter an implicit position in declaration order, so a
# value that gets space-split before reaching this script (e.g. an
# unquoted "C:\Program Files\..." surviving Start-Process -ArgumentList
# array-join, or a value containing " -SomeParam ...") would silently
# rebind onto the WRONG parameter instead of failing loudly -- exactly the
# elevation-argument-injection hazard Invoke-Elevated below is written to
# avoid on the *sending* side. This is the matching hardening on the
# *receiving* side: any stray positional token now raises a hard parameter
# -binding error.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('install', 'register-vibepollo', 'unregister-vibepollo', 'register-watchdog', 'unregister-watchdog', 'uninstall')]
    [string]$Action,

    [string]$ProgramDir,
    [string]$DataDir,
    [string]$ConfPath,

    [switch]$IncludePoll,
    [int]$PollMinutes = 15,

    [switch]$RemoveData,

    [string]$ManagerScriptPath,

    # register-watchdog only: the account the Logon/Poll tasks should run
    # as. Resolved from $env:USERNAME only when omitted (see
    # Get-ResolvedUserId) -- the GUI always passes this explicitly when
    # relaunching itself elevated, so the elevated child never re-derives
    # it from its own (possibly different-admin) identity.
    [string]$UserId,

    [switch]$NoRun
)

# Fail fast inside every function below so try/catch blocks actually catch
# real failures. Unlike sync-configs.ps1, this file's CLI actions are
# allowed (expected, even) to exit non-zero on failure -- installer/admin
# operations should surface errors loudly, not swallow them.
$ErrorActionPreference = 'Stop'

# BOM-less UTF-8, matching sync-configs.ps1, so files this tool writes have
# the same byte shape on Windows PowerShell 5.1 and pwsh 7.
$script:Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)

# ===========================================================================
# #region Core
# ===========================================================================

# ---------------------------------------------------------------------------
# Path resolvers -- the only functions in this file that read environment
# variables. Every other Core function takes its paths as explicit
# parameters so tests can drive them against sandbox directories on any
# platform.
# ---------------------------------------------------------------------------

function Get-DefaultProgramDir {
    # %LOCALAPPDATA%\Programs\stream-config-profiles. Falls back to a
    # HOME-relative path on platforms without LOCALAPPDATA (non-Windows
    # test hosts) so this never throws -- it is only ever used as a
    # fallback default, real installs are always on Windows.
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrEmpty($base)) {
        $base = Join-Path $HOME '.local'
    }
    $programs = Join-Path $base 'Programs'
    return Join-Path $programs 'stream-config-profiles'
}

function Get-DefaultDataDir {
    # %LOCALAPPDATA%\stream-config-profiles.
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrEmpty($base)) {
        $base = Join-Path $HOME '.local'
    }
    return Join-Path $base 'stream-config-profiles'
}

function Get-ResolvedProgramDir {
    param([string]$ProgramDir)
    if (-not [string]::IsNullOrWhiteSpace($ProgramDir)) {
        return $ProgramDir
    }
    return Get-DefaultProgramDir
}

function Get-ResolvedDataDir {
    # DataDir has exactly one source of truth: the explicit param (tests,
    # elevation re-entry) or the fixed default -- there is deliberately no
    # per-user "changeable data folder" any more (see Show-WizardWelcomeStep,
    # which now renders DataDir read-only exactly like ProgramDir already
    # was). PROGRAM is contractually allowed to hold manager.ps1 ONLY, so
    # there is nowhere contract-compliant to persist a chosen DataDir for a
    # later no-arg launch to recover -- the fix is to never let it diverge
    # from the default in the first place, not to invent a settings file.
    param([string]$DataDir)
    if (-not [string]::IsNullOrWhiteSpace($DataDir)) {
        return $DataDir
    }
    return Get-DefaultDataDir
}

function Get-ResolvedManagerScriptPath {
    # This is the path Invoke-Elevated relaunches WITH ADMIN RIGHTS (see
    # Invoke-Elevated / Start-ElevatedManagerProcess above), so unlike the
    # other resolvers in this file it deliberately does NOT fall back to
    # Join-Path $ScriptDir 'manager.ps1' when both ManagerScriptPath and
    # CommandPath are blank: $ScriptDir can itself be a (Get-Location).Path
    # fallback picked up by the CLI entry point when $PSScriptRoot is
    # empty, and elevating a path built from the CURRENT DIRECTORY means
    # anything that can drop a manager.ps1 into whatever folder happens to
    # be current gets that file executed as admin the next time the user
    # approves an elevation this app itself asked for. In real usage
    # (running via -File, which is the only supported entry point) either
    # $PSCommandPath or an explicit -ManagerScriptPath is always present;
    # failing closed here only ever affects the pathological case where
    # neither is, which is exactly the case worth refusing rather than
    # guessing.
    param(
        [string]$ManagerScriptPath,
        [string]$ScriptDir,
        [string]$CommandPath
    )
    if (-not [string]::IsNullOrWhiteSpace($ManagerScriptPath)) {
        return $ManagerScriptPath
    }
    if (-not [string]::IsNullOrWhiteSpace($CommandPath)) {
        return $CommandPath
    }
    throw 'Get-ResolvedManagerScriptPath: cannot determine the manager script path safely (no -ManagerScriptPath given and $PSCommandPath is unavailable). Re-run via "powershell.exe -File <path>\manager.ps1", or pass -ManagerScriptPath explicitly.'
}

function Get-ResolvedConfPath {
    param([string]$ConfPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfPath)) {
        return $ConfPath
    }
    return Find-HostConf
}

function Get-ResolvedUserId {
    # The only place $env:USERNAME is read for watchdog-principal purposes
    # (see the architecture note on Register-WatchdogTask): every Core
    # function above it takes UserId as an explicit parameter so tests can
    # drive it deterministically and so an over-the-shoulder elevation by a
    # different admin account can't silently register a user-level task
    # under the wrong identity picked up deep inside the call stack.
    param([string]$UserId)
    if (-not [string]::IsNullOrWhiteSpace($UserId)) {
        return $UserId
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        return $env:USERNAME
    }
    return [System.Environment]::UserName
}

# ---------------------------------------------------------------------------
# Payload access (dev-mode / embedded-release dual path)
# ---------------------------------------------------------------------------

$script:EnginePayloadMarker = '<#PAYLOAD:ENGINE#>'
$script:TemplatePayloadMarker = '<#PAYLOAD:TEMPLATE#>'

function Test-PayloadEmpty {
    # A payload slot counts as "empty" (dev mode) when it is null/blank, or
    # when it still holds nothing but its own bare marker text -- i.e. the
    # repo's committed, un-built state.
    param(
        [string]$PayloadText,
        [string]$MarkerText
    )
    if ([string]::IsNullOrEmpty($PayloadText)) {
        return $true
    }
    return ($PayloadText.Trim() -eq $MarkerText)
}

function Get-EnginePayload {
    # Returns sync-configs.ps1's full text: the embedded slot if a release
    # build has inlined it, otherwise (dev mode) the neighbor file living
    # alongside this script.
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptDir,

        [string]$PayloadText = $script:EnginePayload
    )

    if (-not (Test-PayloadEmpty -PayloadText $PayloadText -MarkerText $script:EnginePayloadMarker)) {
        return $PayloadText
    }

    $neighbor = Join-Path $ScriptDir 'sync-configs.ps1'
    if (-not (Test-Path -LiteralPath $neighbor)) {
        throw "Get-EnginePayload: embedded payload is empty (dev mode) and no neighbor file was found at $neighbor"
    }
    return Get-Content -LiteralPath $neighbor -Raw -Encoding UTF8
}

function Get-TemplatePayload {
    # Same idea as Get-EnginePayload, for paths.example.txt.
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptDir,

        [string]$PayloadText = $script:TemplatePayload
    )

    if (-not (Test-PayloadEmpty -PayloadText $PayloadText -MarkerText $script:TemplatePayloadMarker)) {
        return $PayloadText
    }

    $neighbor = Join-Path $ScriptDir 'paths.example.txt'
    if (-not (Test-Path -LiteralPath $neighbor)) {
        throw "Get-TemplatePayload: embedded payload is empty (dev mode) and no neighbor file was found at $neighbor"
    }
    return Get-Content -LiteralPath $neighbor -Raw -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

function Install-App {
    # Creates PROGRAM and DATA, writes the engine + template into DATA, and
    # copies this manager itself into PROGRAM. Idempotent: engine, template
    # and the manager binary are always (re)written -- that IS the upgrade
    # path -- but paths.txt is created from the template only if absent,
    # and state.json/sync.log/profiles\ are never touched (they belong to
    # the engine, not to install).
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProgramDir,

        [Parameter(Mandatory = $true)]
        [string]$DataDir,

        [Parameter(Mandatory = $true)]
        [string]$ManagerScriptPath,

        [string]$ScriptDir
    )

    if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
        $ScriptDir = Split-Path -Path $ManagerScriptPath -Parent
    }

    if (-not (Test-Path -LiteralPath $ProgramDir)) {
        New-Item -ItemType Directory -Path $ProgramDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    }

    $enginePayload = Get-EnginePayload -ScriptDir $ScriptDir
    $engineDest = Join-Path $DataDir 'sync-configs.ps1'
    [System.IO.File]::WriteAllText($engineDest, $enginePayload, $script:Utf8NoBomEncoding)

    $templatePayload = Get-TemplatePayload -ScriptDir $ScriptDir
    $templateDest = Join-Path $DataDir 'paths.example.txt'
    [System.IO.File]::WriteAllText($templateDest, $templatePayload, $script:Utf8NoBomEncoding)

    $pathsTxt = Join-Path $DataDir 'paths.txt'
    if (-not (Test-Path -LiteralPath $pathsTxt)) {
        [System.IO.File]::WriteAllText($pathsTxt, $templatePayload, $script:Utf8NoBomEncoding)
    }

    $managerContent = Get-Content -LiteralPath $ManagerScriptPath -Raw -Encoding UTF8
    $managerDest = Join-Path $ProgramDir 'manager.ps1'
    [System.IO.File]::WriteAllText($managerDest, $managerContent, $script:Utf8NoBomEncoding)

    return [PSCustomObject]@{
        ProgramDir  = $ProgramDir
        DataDir     = $DataDir
        EnginePath  = $engineDest
        TemplatePath = $templateDest
        PathsTxtPath = $pathsTxt
        ManagerPath = $managerDest
    }
}

# ---------------------------------------------------------------------------
# Vibepollo/Apollo conf discovery
# ---------------------------------------------------------------------------

function Get-HostConfCandidatePaths {
    # Common install locations for Vibepollo/Apollo/Sunshine's config file
    # under Program Files / Program Files (x86). Order matters: first
    # existing candidate wins in Find-HostConf.
    $roots = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($env:ProgramFiles)) {
        $roots.Add($env:ProgramFiles)
    }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrEmpty($pf86)) {
        $roots.Add($pf86)
    }

    $appDirNames = @('Vibepollo', 'Apollo', 'Sunshine')
    $confFileNames = @('vibepollo.conf', 'apollo.conf', 'sunshine.conf')

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        foreach ($appDir in $appDirNames) {
            $appRoot = Join-Path $root $appDir
            $configDir = Join-Path $appRoot 'config'
            foreach ($confName in $confFileNames) {
                $candidates.Add((Join-Path $configDir $confName))
            }
        }
    }
    return $candidates.ToArray()
}

function Get-HostServiceBinaryDir {
    # Isolated wrapper around Get-CimInstance Win32_Service -- unavailable
    # (or simply empty) on non-Windows hosts. Never throws: an
    # unavailable/erroring CIM call is treated as "nothing found", not a
    # fatal error, since this is only ever a best-effort hint.
    param([string[]]$NamePatterns)

    $found = New-Object System.Collections.Generic.List[string]
    try {
        $services = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop
        foreach ($svc in $services) {
            foreach ($pattern in $NamePatterns) {
                if ($svc.Name -like $pattern -and $svc.PathName) {
                    $exePath = $svc.PathName.Trim('"')
                    $dir = Split-Path -Path $exePath -Parent
                    if ($dir) {
                        $found.Add($dir)
                    }
                }
            }
        }
    }
    catch {
        # CIM unavailable (non-Windows, permissions, WMI not running): no
        # service-derived hint, callers fall back to the static candidate
        # list.
    }
    return $found.ToArray()
}

function Find-HostConf {
    # Best-guess Vibepollo/Apollo/Sunshine conf path: static well-known
    # locations first, then a config\*.conf sibling of any matching
    # service's binary directory. Returns $null if nothing is found.
    param([string[]]$ExtraCandidates = @())

    $namePatterns = @('*vibepollo*', '*apollo*', '*sunshine*')
    $confFileNames = @('vibepollo.conf', 'apollo.conf', 'sunshine.conf')

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($c in (Get-HostConfCandidatePaths)) {
        $candidates.Add($c)
    }
    foreach ($dir in (Get-HostServiceBinaryDir -NamePatterns $namePatterns)) {
        foreach ($confName in $confFileNames) {
            $candidates.Add((Join-Path $dir $confName))
            $candidates.Add((Join-Path (Join-Path $dir 'config') $confName))
        }
    }
    foreach ($c in $ExtraCandidates) {
        $candidates.Add($c)
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# global_prep_cmd parsing / merging
#
# The conf is a flat key=value (with surrounding whitespace tolerated) text
# file. global_prep_cmd's value is a JSON array of {do, undo, elevated}
# objects. Every function here preserves every unrelated line byte-for-byte
# and writes via temp+move so a crash mid-write never corrupts the file.
# ---------------------------------------------------------------------------

function Get-EngineIdentifierPath {
    # The path used to recognize "our" entry in global_prep_cmd: any entry
    # whose "do" command contains this path (case-insensitively) is ours.
    param([Parameter(Mandatory = $true)][string]$DataDir)
    return Join-Path $DataDir 'sync-configs.ps1'
}

function ConvertTo-PrepCommandJson {
    # Serializes an array of prep-command entry objects to a JSON array
    # string. Built by wrapping each entry individually and joining with
    # commas (rather than calling ConvertTo-Json once on the whole array)
    # specifically to avoid ConvertTo-Json's well-known single-element
    # array collapsing behavior, which differs across PowerShell versions
    # and would otherwise store a bare JSON object instead of a one-element
    # array.
    param([object[]]$Entries)

    if ($null -eq $Entries -or @($Entries).Count -eq 0) {
        return '[]'
    }

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Entries) {
        $items.Add((ConvertTo-Json -InputObject $entry -Compress))
    }
    return '[' + ([string]::Join(',', $items.ToArray())) + ']'
}

function Get-PrepCommandEntries {
    # Reads and parses global_prep_cmd from ConfPath. Returns:
    #   Success   -- $false only for a missing conf file or malformed JSON
    #                (never for a missing/empty key -- that is a normal,
    #                valid "no entries yet" state).
    #   KeyFound  -- whether a global_prep_cmd = ... line exists at all.
    #   Entries   -- parsed array (possibly empty).
    #   Message   -- set on failure.
    param([Parameter(Mandatory = $true)][string]$ConfPath)

    $result = [PSCustomObject]@{
        Success  = $true
        Message  = $null
        KeyFound = $false
        Entries  = @()
    }

    if (-not (Test-Path -LiteralPath $ConfPath)) {
        $result.Success = $false
        $result.Message = "conf file not found: $ConfPath"
        return $result
    }

    $raw = Get-Content -LiteralPath $ConfPath -Raw -Encoding UTF8
    if ([string]::IsNullOrEmpty($raw)) {
        return $result
    }

    $lines = $raw -split "`r`n|`n"
    $valueText = $null
    foreach ($line in $lines) {
        if ($line -match '^\s*global_prep_cmd\s*=\s*(.*)$') {
            $valueText = $Matches[1]
            $result.KeyFound = $true
            break
        }
    }

    if (-not $result.KeyFound) {
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($valueText)) {
        return $result
    }

    try {
        $parsed = $valueText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $result.Success = $false
        $result.Message = "global_prep_cmd is not valid JSON in ${ConfPath}: $($_.Exception.Message)"
        return $result
    }

    if ($null -eq $parsed) {
        return $result
    }

    $result.Entries = @($parsed)
    return $result
}

function Test-IsReparsePoint {
    # True if Path exists and is a symlink/junction/hardlink-style reparse
    # point. Used before writing through a conf path (or a freshly-created
    # temp/backup path) from a possibly-elevated process: a reparse point
    # planted by an unprivileged user in a directory it can write to is
    # exactly how a predictable filename turns into an admin-level
    # arbitrary-file-write primitive.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function New-ConfBackup {
    # Timestamped + randomized backup alongside ConfPath, created before
    # every write. The random suffix (on top of the timestamp) plus
    # FileMode.CreateNew make the destination path both hard to predict
    # and impossible to silently overwrite: if anything is already sitting
    # at the chosen path (a pre-planted file or link), this throws instead
    # of copying through it.
    param([Parameter(Mandatory = $true)][string]$ConfPath)

    if (Test-IsReparsePoint -Path $ConfPath) {
        throw "New-ConfBackup: refusing to read through a reparse point (symlink/junction) at $ConfPath"
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $randomSuffix = [System.IO.Path]::GetRandomFileName() -replace '[^A-Za-z0-9]', ''
    $backupPath = '{0}.{1}.{2}.bak' -f $ConfPath, $stamp, $randomSuffix.Substring(0, [Math]::Min(8, $randomSuffix.Length))

    $sourceStream = [System.IO.File]::Open($ConfPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        # CreateNew: throws if $backupPath already exists (pre-planted file
        # or link) instead of following/overwriting it.
        $destStream = [System.IO.File]::Open($backupPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        try {
            $sourceStream.CopyTo($destStream)
        }
        finally {
            $destStream.Dispose()
        }
    }
    finally {
        $sourceStream.Dispose()
    }

    return $backupPath
}

function Write-ConfGlobalPrepCmd {
    # Rewrites (or appends) the "global_prep_cmd = <json>" line in
    # ConfPath, preserving every other line byte-for-byte and the file's
    # original line-ending style. Writes to a RANDOMLY-NAMED temp file
    # (created with FileMode.CreateNew, so an existing file/link at that
    # path is a hard failure, never a follow-through write) and then
    # File.Replace()s it into place -- File.Replace preserves the
    # destination's identity/ACLs, unlike Move-Item -Force which deletes
    # the original and lets the replacement inherit the directory's
    # default ACLs instead.
    param(
        [Parameter(Mandatory = $true)][string]$ConfPath,
        [Parameter(Mandatory = $true)][string]$JsonValue
    )

    if (Test-IsReparsePoint -Path $ConfPath) {
        throw "Write-ConfGlobalPrepCmd: refusing to write through a reparse point (symlink/junction) at $ConfPath"
    }

    $raw = Get-Content -LiteralPath $ConfPath -Raw -Encoding UTF8
    $lineEnding = "`n"
    if ($raw -match "`r`n") {
        $lineEnding = "`r`n"
    }

    $hadTrailingNewline = [bool]($raw -match "(`r`n|`n)$")
    $splitLines = $raw -split "`r`n|`n"
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in $splitLines) {
        $lines.Add($l)
    }
    if ($hadTrailingNewline -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }

    $newLine = 'global_prep_cmd = ' + $JsonValue
    $replaced = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*global_prep_cmd\s*=\s*(.*)$') {
            $lines[$i] = $newLine
            $replaced = $true
            break
        }
    }
    if (-not $replaced) {
        $lines.Add($newLine)
    }

    $content = [string]::Join($lineEnding, $lines.ToArray())
    if ($hadTrailingNewline -or -not $replaced) {
        $content = $content + $lineEnding
    }

    $tempPath = $null
    $tempStream = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $candidate = $ConfPath + '.' + [System.IO.Path]::GetRandomFileName() + '.tmp'
        try {
            $tempStream = [System.IO.File]::Open($candidate, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            $tempPath = $candidate
            break
        }
        catch [System.IO.IOException] {
            if ($attempt -eq 5) {
                throw
            }
        }
    }

    try {
        $bytes = $script:Utf8NoBomEncoding.GetBytes($content)
        $tempStream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $tempStream.Dispose()
    }

    # File.Replace's own destinationBackupFileName is required (a $null
    # third argument throws on at least the Unix File.Replace
    # implementation) but is otherwise redundant here -- New-ConfBackup
    # already made the real, timestamped backup callers rely on -- so this
    # is a throwaway, randomly-named scratch file, deleted immediately
    # afterward (best-effort; leaving it behind on a delete failure is
    # harmless clutter, not a correctness problem).
    $replaceScratchBackup = $ConfPath + '.' + [System.IO.Path]::GetRandomFileName() + '.replacebak'
    [System.IO.File]::Replace($tempPath, $ConfPath, $replaceScratchBackup)
    Remove-Item -LiteralPath $replaceScratchBackup -Force -ErrorAction SilentlyContinue
}

function Test-PrepCommandEntryIsOurs {
    # An entry is "ours" iff its "do" property contains EnginePath
    # (case-insensitive). StrictMode-safe against entries that lack a "do"
    # property at all (other tools' entries may have arbitrary shapes).
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)][string]$EnginePath
    )
    $doValue = $null
    if ($Entry.PSObject.Properties.Match('do').Count -gt 0) {
        $doValue = [string]$Entry.do
    }
    if ([string]::IsNullOrEmpty($doValue)) {
        return $false
    }
    return ($doValue.IndexOf($EnginePath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Add-PrepCommandEntry {
    # Adds/replaces our global_prep_cmd entry in ConfPath, merging with
    # (never clobbering) any other tool's entries. Re-running this is
    # idempotent: any existing entry of ours is replaced, never duplicated.
    # On malformed existing JSON, fails with a clear message and leaves the
    # conf file completely untouched (no backup, no write).
    param(
        [Parameter(Mandatory = $true)][string]$ConfPath,
        [Parameter(Mandatory = $true)][string]$DataDir
    )

    if ($DataDir.IndexOf('"') -ge 0) {
        # DataDir is embedded, unescaped, inside a double-quoted -File
        # "..." fragment (see $doCmd/$undoCmd below) that the streaming
        # host later re-expands into a command line on every stream start.
        # JSON-encoding escapes the quote for storage but does nothing to
        # neutralize it once re-expanded -- an embedded quote would close
        # that argument early and splice extra tokens into a command the
        # host runs elevated-or-not on its own. DataDir can be free-form
        # user input from the wizard's textbox, so reject rather than
        # silently emit something that would need escaping.
        return [PSCustomObject]@{ Success = $false; Message = "Add-PrepCommandEntry: DataDir must not contain a double-quote character: $DataDir"; BackupPath = $null }
    }

    $existing = Get-PrepCommandEntries -ConfPath $ConfPath
    if (-not $existing.Success) {
        return [PSCustomObject]@{ Success = $false; Message = $existing.Message; BackupPath = $null }
    }

    $enginePath = Get-EngineIdentifierPath -DataDir $DataDir
    $doCmd = 'powershell.exe -ExecutionPolicy Bypass -File "' + $enginePath + '" -Mode do'
    $undoCmd = 'powershell.exe -ExecutionPolicy Bypass -File "' + $enginePath + '" -Mode undo'

    $kept = @($existing.Entries | Where-Object { -not (Test-PrepCommandEntryIsOurs -Entry $_ -EnginePath $enginePath) })
    $ourEntry = [PSCustomObject]@{ do = $doCmd; undo = $undoCmd; elevated = $false }
    $newEntries = @($kept) + @($ourEntry)

    $json = ConvertTo-PrepCommandJson -Entries $newEntries

    $backupPath = New-ConfBackup -ConfPath $ConfPath
    Write-ConfGlobalPrepCmd -ConfPath $ConfPath -JsonValue $json

    return [PSCustomObject]@{ Success = $true; Message = 'entry added'; BackupPath = $backupPath }
}

function Remove-PrepCommandEntry {
    # Removes only our global_prep_cmd entry from ConfPath, leaving every
    # other entry untouched. A no-op (no backup, no write) if the key is
    # absent or no matching entry is found.
    param(
        [Parameter(Mandatory = $true)][string]$ConfPath,
        [Parameter(Mandatory = $true)][string]$DataDir
    )

    $existing = Get-PrepCommandEntries -ConfPath $ConfPath
    if (-not $existing.Success) {
        return [PSCustomObject]@{ Success = $false; Message = $existing.Message; BackupPath = $null }
    }

    if (-not $existing.KeyFound -or @($existing.Entries).Count -eq 0) {
        return [PSCustomObject]@{ Success = $true; Message = 'no matching entry found; nothing to remove'; BackupPath = $null }
    }

    $enginePath = Get-EngineIdentifierPath -DataDir $DataDir
    $kept = @($existing.Entries | Where-Object { -not (Test-PrepCommandEntryIsOurs -Entry $_ -EnginePath $enginePath) })

    if ($kept.Count -eq @($existing.Entries).Count) {
        return [PSCustomObject]@{ Success = $true; Message = 'no matching entry found; nothing to remove'; BackupPath = $null }
    }

    $json = ConvertTo-PrepCommandJson -Entries $kept

    $backupPath = New-ConfBackup -ConfPath $ConfPath
    Write-ConfGlobalPrepCmd -ConfPath $ConfPath -JsonValue $json

    return [PSCustomObject]@{ Success = $true; Message = 'entry removed'; BackupPath = $backupPath }
}

# ---------------------------------------------------------------------------
# Host service restart
# ---------------------------------------------------------------------------

function Get-HostServiceCandidate {
    # Isolated wrapper around Get-Service. Never throws: Get-Service is
    # either unavailable or reliably empty on non-Windows hosts, and either
    # case should read as "no matching service", not a fatal error.
    param([string[]]$NamePatterns)

    $found = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in $NamePatterns) {
        try {
            # Named $matchedServices, not $matches: PowerShell variable
            # names are case-insensitive, so $matches would collide with
            # the automatic $Matches variable that -match populates --
            # this function is safe today (nothing here uses -match
            # afterwards) but Get-PrepCommandEntries elsewhere in this
            # file DOES rely on $Matches, so avoid the footgun outright.
            $matchedServices = @(Get-Service -Name $pattern -ErrorAction SilentlyContinue)
            foreach ($m in $matchedServices) {
                $found.Add($m)
            }
        }
        catch {
            # Get-Service unavailable/erroring: treat as "none found".
        }
    }
    return @($found | Sort-Object -Property Name -Unique)
}

function Restart-HostServiceByName {
    # Isolated wrapper around Restart-Service.
    param([Parameter(Mandatory = $true)][string]$Name)
    Restart-Service -Name $Name -Force -ErrorAction Stop
}

function Restart-HostService {
    # Finds a running Vibepollo/Apollo/Sunshine service by name pattern and
    # restarts it. Returns Success=$false with a "restart manually" message
    # when no matching service is found, rather than failing loudly --
    # some installs (portable Vibepollo) never run as a service at all.
    param([string[]]$NamePatterns = @('*vibepollo*', '*apollo*', '*sunshine*'))

    $candidates = Get-HostServiceCandidate -NamePatterns $NamePatterns
    if (@($candidates).Count -eq 0) {
        return [PSCustomObject]@{ Success = $false; ServiceName = $null; Message = 'no matching service found; restart manually' }
    }

    $target = @($candidates)[0]
    try {
        Restart-HostServiceByName -Name $target.Name
        return [PSCustomObject]@{ Success = $true; ServiceName = $target.Name; Message = 'restarted' }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; ServiceName = $target.Name; Message = "restart failed: $($_.Exception.Message); restart manually" }
    }
}

# ---------------------------------------------------------------------------
# Watchdog (scheduled tasks)
#
# Get-WatchdogTaskDefinitions is pure logic (no Windows dependency) so it
# can be unit-tested directly on any platform. Register-Watchdog /
# Unregister-Watchdog call the real ScheduledTasks cmdlets only through the
# four tiny wrapper functions below -- a test harness dot-sources this file
# with -NoRun and then redefines those four wrappers (they are ordinary
# script-scope functions, so a later definition in the same scope replaces
# them) to record calls instead of touching the (Windows-only) real
# cmdlets.
# ---------------------------------------------------------------------------

function Get-SettleAction {
    param([Parameter(Mandatory = $true)][string]$DataDir)
    $enginePath = Join-Path $DataDir 'sync-configs.ps1'
    return 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $enginePath + '" -Mode settle'
}

function Get-WatchdogTaskDefinitions {
    # Returns the set of watchdog task definitions that should exist given
    # the requested options. StreamConfigProfiles-Settle-Logon is always
    # included (user-level, no admin needed). Poll is opt-in via
    # -IncludePoll (defaults OFF per spec). PollMinutes is clamped to a
    # minimum of 5.
    #
    # There is deliberately no boot-time (AtStartup) task in this product:
    # local play after a reboot always requires a logon first, and the
    # Logon task's AtLogOn trigger already fires at exactly that moment --
    # an AtStartup task would only ever add an elevation-and-escalation
    # surface (a SYSTEM-level scheduled task pointing at a script in the
    # user's own writable DATA folder) for zero additional protection. See
    # Unregister-Watchdog for the best-effort removal of a legacy Boot task
    # left behind by an earlier build that did register one.
    #
    # Each definition also carries the principal it must run under
    # (LogonType/UserId), not just NeedsAdmin, because RunLevel alone is
    # not enough to make a task actually fire in the context its trigger
    # implies: Logon/Poll need LogonType=Interactive under the resolved
    # UserId (passed in explicitly -- see Get-ResolvedUserId -- rather
    # than read from $env:USERNAME deep in Register-WatchdogTask, which
    # would silently pick up the WRONG account during an
    # over-the-shoulder elevation by a different admin). Both tasks are
    # user-level, so registering/unregistering the watchdog never needs
    # elevation.
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$UserId,
        [switch]$IncludePoll,
        [int]$PollMinutes = 15
    )

    $action = Get-SettleAction -DataDir $DataDir
    $defs = New-Object System.Collections.Generic.List[object]

    $defs.Add([PSCustomObject]@{
        Name        = 'StreamConfigProfiles-Settle-Logon'
        Triggers    = @('AtLogOn', 'OnUnlock')
        Action      = $action
        NeedsAdmin  = $false
        LogonType   = 'Interactive'
        UserId      = $UserId
        PollMinutes = $null
    })

    if ($IncludePoll) {
        $effectivePollMinutes = $PollMinutes
        if ($effectivePollMinutes -lt 5) {
            $effectivePollMinutes = 5
        }
        $defs.Add([PSCustomObject]@{
            Name        = 'StreamConfigProfiles-Settle-Poll'
            Triggers    = @('Repeat')
            Action      = $action
            NeedsAdmin  = $false
            LogonType   = 'Interactive'
            UserId      = $UserId
            PollMinutes = $effectivePollMinutes
        })
    }

    return $defs.ToArray()
}

function New-WatchdogTaskTrigger {
    # Isolated wrapper around New-ScheduledTaskTrigger (or, for OnUnlock, a
    # real session-unlock CIM trigger -- see below).
    param(
        [Parameter(Mandatory = $true)][string]$TriggerType,
        [int]$PollMinutes,
        [string]$UserId
    )

    switch ($TriggerType) {
        'AtLogOn' { return New-ScheduledTaskTrigger -AtLogOn }
        'OnUnlock' {
            # New-ScheduledTaskTrigger has no -AtUnlock parameter; the real
            # session-unlock trigger type (TASK_SESSION_STATE_CHANGE,
            # StateChange=SessionUnlock) is only reachable via the
            # MSFT_TaskSessionStateChangeTrigger CIM class. This is a
            # Windows built-in (Root/Microsoft/Windows/TaskScheduler
            # namespace, present on every Windows install with Task
            # Scheduler) -- no module/dependency added.
            $sessionStateChangeClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
            $trigger = New-CimInstance -CimClass $sessionStateChangeClass -ClientOnly
            # StateChange = 8 -> TASK_SESSION_UNLOCK in the
            # TASK_SESSION_STATE_CHANGE_TYPE enum used by this CIM class.
            $trigger.StateChange = 8
            if (-not [string]::IsNullOrWhiteSpace($UserId)) {
                $trigger.UserId = $UserId
            }
            $trigger.Enabled = $true
            return $trigger
        }
        'Repeat' {
            return New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $PollMinutes) -RepetitionDuration ([TimeSpan]::MaxValue)
        }
        default {
            throw "New-WatchdogTaskTrigger: unknown trigger type '$TriggerType'"
        }
    }
}

function New-WatchdogTaskAction {
    # Isolated wrapper around New-ScheduledTaskAction. Command is the full
    # "powershell.exe ... -Mode settle" string from a task definition (kept
    # exactly as the contract's literal text for logging/testing purposes --
    # see Get-SettleAction); the ACTUAL -Execute value handed to the
    # scheduled task is the fully-qualified powershell.exe path instead of
    # that literal leading token, so Task Scheduler never resolves a bare
    # "powershell.exe" name against a search path that could include a
    # user-writable directory.
    param([Parameter(Mandatory = $true)][string]$Command)

    $exe = Get-WindowsPowerShellExePath
    $spaceIndex = $Command.IndexOf(' ')
    $arguments = ''
    if ($spaceIndex -ge 0) {
        $arguments = $Command.Substring($spaceIndex + 1)
    }
    return New-ScheduledTaskAction -Execute $exe -Argument $arguments
}

function Register-WatchdogTask {
    # Isolated wrapper around Register-ScheduledTask (+ the principal it
    # needs). UserId/LogonType come from the task definition (see
    # Get-WatchdogTaskDefinitions) rather than being derived here -- every
    # real definition today is Interactive/user-level (NeedsAdmin is always
    # $false), but the principal is still driven by the definition, not
    # hardcoded, so the mechanism stays generic.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object[]]$Triggers,
        [Parameter(Mandatory = $true)]$Action,
        [Parameter(Mandatory = $true)][bool]$NeedsAdmin,
        [Parameter(Mandatory = $true)][string]$LogonType,
        [Parameter(Mandatory = $true)][string]$UserId
    )

    $runLevel = 'Limited'
    if ($NeedsAdmin) {
        $runLevel = 'Highest'
    }
    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType $LogonType -RunLevel $runLevel
    Register-ScheduledTask -TaskName $Name -Trigger $Triggers -Action $Action -Principal $principal -Force | Out-Null
}

function Unregister-WatchdogTask {
    # Isolated wrapper around Unregister-ScheduledTask. Tolerates a task
    # that simply doesn't exist (unregistering is always safe to repeat),
    # but does NOT swallow a real deletion failure -- that must propagate
    # to the caller. For the two real (user-level) tasks this should never
    # actually fail with access-denied; for the legacy admin-level Boot
    # task an earlier build may have left behind, Unregister-Watchdog below
    # is the one that swallows this failure, since removing that leftover
    # is a best-effort cleanup, not something worth demanding elevation
    # for. A blanket -ErrorAction SilentlyContinue on the delete itself
    # would report "unregistered" even when the task is still sitting
    # there afterwards, so that tolerance belongs at the call site instead.
    param([Parameter(Mandatory = $true)][string]$Name)

    $existing = $null
    try {
        $existing = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    }
    catch {
        $existing = $null
    }
    if ($null -eq $existing) {
        return
    }

    Unregister-ScheduledTask -TaskName $Name -Confirm:$false
}

function Register-Watchdog {
    # Every task this registers is user-level (Interactive LogonType, the
    # resolved caller's own UserId) -- see Get-WatchdogTaskDefinitions --
    # so this never needs elevation.
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$UserId,
        [switch]$IncludePoll,
        [int]$PollMinutes = 15
    )

    $defs = Get-WatchdogTaskDefinitions -DataDir $DataDir -UserId $UserId -IncludePoll:$IncludePoll -PollMinutes $PollMinutes
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($def in $defs) {
        try {
            $triggers = New-Object System.Collections.Generic.List[object]
            foreach ($triggerType in $def.Triggers) {
                $triggers.Add((New-WatchdogTaskTrigger -TriggerType $triggerType -PollMinutes $def.PollMinutes -UserId $def.UserId))
            }
            $action = New-WatchdogTaskAction -Command $def.Action
            Register-WatchdogTask -Name $def.Name -Triggers $triggers.ToArray() -Action $action -NeedsAdmin $def.NeedsAdmin -LogonType $def.LogonType -UserId $def.UserId
            $results.Add([PSCustomObject]@{ Name = $def.Name; Success = $true; Message = 'registered' })
        }
        catch {
            $results.Add([PSCustomObject]@{ Name = $def.Name; Success = $false; Message = $_.Exception.Message })
        }
    }

    return $results.ToArray()
}

function Unregister-Watchdog {
    # Removes the current (user-level) watchdog task set -- Logon, Poll --
    # neither of which ever needs elevation to delete, so a real failure
    # here is surfaced as Success=$false like any other task result.
    #
    # Also best-effort-removes the legacy 'StreamConfigProfiles-Settle-Boot'
    # task for anyone who installed the interim build that registered an
    # admin-level AtStartup task (see the architecture note on
    # Get-WatchdogTaskDefinitions for why this product no longer has one).
    # That legacy task can only be deleted by an elevated process; failing
    # to remove it here (running unelevated) is expected, not an error --
    # unregistering the watchdog must never itself demand elevation, so
    # this outcome is always reported as Success=$true regardless of
    # whether the underlying delete actually worked.
    $names = @('StreamConfigProfiles-Settle-Logon', 'StreamConfigProfiles-Settle-Poll')
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($n in $names) {
        try {
            Unregister-WatchdogTask -Name $n
            $results.Add([PSCustomObject]@{ Name = $n; Success = $true; Message = 'unregistered' })
        }
        catch {
            $results.Add([PSCustomObject]@{ Name = $n; Success = $false; Message = $_.Exception.Message })
        }
    }

    $legacyBootName = 'StreamConfigProfiles-Settle-Boot'
    try {
        Unregister-WatchdogTask -Name $legacyBootName
        $results.Add([PSCustomObject]@{ Name = $legacyBootName; Success = $true; Message = 'legacy task removed (best-effort)' })
    }
    catch {
        $results.Add([PSCustomObject]@{ Name = $legacyBootName; Success = $true; Message = "legacy task cleanup skipped (best-effort, likely needs elevation): $($_.Exception.Message)" })
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

function Test-LooksLikeOurInstallDirectory {
    # Defense-in-depth guard for the recursive deletes below: refuses a
    # directory that contains none of the marker files this tool itself
    # would have put there, so a bad ProgramDir/DataDir value can never
    # turn an uninstall into deleting an unrelated directory tree -- cheap
    # insurance on top of Invoke-Elevated's argument-quoting fix, not a
    # replacement for it. Deliberately does NOT also require a specific
    # leaf directory name: tests (and a user's -DataFolder override, where
    # supported) legitimately point this at sandbox/custom directories
    # that don't end in "stream-config-profiles".
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$MarkerFileNames
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    foreach ($marker in $MarkerFileNames) {
        if (Test-Path -LiteralPath (Join-Path $Path $marker)) {
            return $true
        }
    }
    return $false
}

function Test-AnyWatchdogTaskRegistered {
    # True if any of the three well-known StreamConfigProfiles-* tasks is
    # still present. Used to decide whether it is safe to delete DATA\
    # sync-configs.ps1. This product no longer registers an admin-level
    # task at all (see the architecture note on Get-WatchdogTaskDefinitions),
    # but a leftover legacy 'StreamConfigProfiles-Settle-Boot' task from an
    # earlier build -- one that Unregister-Watchdog's best-effort cleanup
    # could not remove because it needs elevation -- is exactly a dangling
    # privilege-escalation primitive: anything that can later recreate a
    # file at that path gets SYSTEM execution at next boot.
    $status = Get-WatchdogTaskExistence
    foreach ($key in $status.Keys) {
        if ($status[$key]) {
            return $true
        }
    }
    return $false
}

function Uninstall-App {
    # Unregisters the watchdog, removes our conf entry, restarts the
    # service, and removes PROGRAM. DATA (profiles\, paths.txt, state.json,
    # sync.log) is left in place unless -RemoveData is passed -- it holds
    # the user's own data, not just installed program files.
    param(
        [Parameter(Mandatory = $true)][string]$ProgramDir,
        [Parameter(Mandatory = $true)][string]$DataDir,
        [string]$ConfPath,
        [switch]$RemoveData
    )

    $summary = [PSCustomObject]@{
        WatchdogUnregistered    = $null
        ConfEntryRemoved        = $null
        ServiceRestart          = $null
        ProgramDirRemoved       = $false
        ProgramDirSkipReason    = $null
        DataDirRemoved          = $false
        DataDirSkipReason       = $null
    }

    $summary.WatchdogUnregistered = Unregister-Watchdog

    if (-not [string]::IsNullOrWhiteSpace($ConfPath) -and (Test-Path -LiteralPath $ConfPath)) {
        $summary.ConfEntryRemoved = Remove-PrepCommandEntry -ConfPath $ConfPath -DataDir $DataDir
    }

    # Only restart the host when an entry was actually removed -- restarting
    # unconditionally means every uninstall bounces the user's streaming
    # host even when no conf was touched at all (no ConfPath known, or the
    # entry was already gone), which is a pointless disruption to whatever
    # session might currently be running on it.
    if ($null -ne $summary.ConfEntryRemoved -and $summary.ConfEntryRemoved.Success -and $summary.ConfEntryRemoved.Message -eq 'entry removed') {
        $summary.ServiceRestart = Restart-HostService
    }

    if (Test-Path -LiteralPath $ProgramDir) {
        if (Test-LooksLikeOurInstallDirectory -Path $ProgramDir -MarkerFileNames @('manager.ps1')) {
            Remove-Item -LiteralPath $ProgramDir -Recurse -Force
            $summary.ProgramDirRemoved = $true
        }
        else {
            $summary.ProgramDirSkipReason = "refusing to delete '$ProgramDir': does not look like a stream-config-profiles PROGRAM directory (expected leaf name 'stream-config-profiles' containing manager.ps1)"
        }
    }

    if ($RemoveData -and (Test-Path -LiteralPath $DataDir)) {
        if (-not (Test-LooksLikeOurInstallDirectory -Path $DataDir -MarkerFileNames @('sync-configs.ps1', 'paths.txt', 'state.json'))) {
            $summary.DataDirSkipReason = "refusing to delete '$DataDir': does not look like a stream-config-profiles DATA directory (expected leaf name 'stream-config-profiles' containing sync-configs.ps1/paths.txt/state.json)"
        }
        elseif (Test-AnyWatchdogTaskRegistered) {
            $summary.DataDirSkipReason = 'a StreamConfigProfiles-* scheduled task is still registered (its removal likely needs elevation); refusing to delete the data folder while an admin-level task could still be pointed at sync-configs.ps1 inside it -- retry uninstall elevated, or remove the remaining task(s) manually first'
        }
        else {
            Remove-Item -LiteralPath $DataDir -Recurse -Force
            $summary.DataDirRemoved = $true
        }
    }

    return $summary
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------

function Test-IsAdmin {
    # Windows-only concept. On any non-Windows host (test environments)
    # there is nothing to elevate to, so this reports $false rather than
    # throwing.
    $isDesktopEdition = ($PSVersionTable.PSEdition -eq 'Desktop')
    $isWindowsCore = [bool](Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue -ValueOnly)
    if (-not ($isDesktopEdition -or $isWindowsCore)) {
        return $false
    }

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-WindowsPowerShellExePath {
    # Fully-qualified path to the Windows PowerShell 5.1 executable, used
    # anywhere this file launches a *new* powershell.exe process (elevated
    # re-entry, the watchdog scheduled-task action). Never a bare
    # "powershell.exe": CreateProcess's search order for an unqualified
    # name checks the CURRENT DIRECTORY before PATH/System32, so a bare
    # name is plantable by anything that can write a file into whatever
    # directory happens to be current when Start-Process / Task Scheduler
    # resolves it -- for the elevated (-Verb RunAs) case that would mean a
    # planted binary runs WITH ADMIN RIGHTS. Falls back to the bare name
    # only if $env:SystemRoot is unavailable (non-Windows test hosts),
    # where none of this is ever actually invoked.
    param([string]$SystemRoot = $env:SystemRoot)
    if ([string]::IsNullOrEmpty($SystemRoot)) {
        return 'powershell.exe'
    }
    $candidate = Join-Path (Join-Path (Join-Path $SystemRoot 'System32') 'WindowsPowerShell') 'v1.0'
    $candidate = Join-Path $candidate 'powershell.exe'
    return $candidate
}

function ConvertTo-QuotedCommandLineArgument {
    # Quotes a single value per the escaping rules every native Win32
    # process (including powershell.exe) expects from CommandLineToArgvW:
    # wrap in double quotes; a run of backslashes immediately before an
    # embedded quote (or before the final closing quote) is doubled, and
    # the embedded quote itself is backslash-escaped. This is what makes
    # it safe to pass a single pre-built command-line STRING to
    # Start-Process -ArgumentList instead of a string[] -- Start-Process
    # space-joins a string[] with NO quoting of its own, which is exactly
    # what let a path like "C:\Program Files\..." split into two
    # arguments and silently mis-bind onto the wrong parameter.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashRun = 0
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        if ($ch -eq '\') {
            $backslashRun++
            continue
        }
        if ($ch -eq '"') {
            [void]$sb.Append('\', ($backslashRun * 2 + 1))
            [void]$sb.Append('"')
            $backslashRun = 0
            continue
        }
        if ($backslashRun -gt 0) {
            [void]$sb.Append('\', $backslashRun)
            $backslashRun = 0
        }
        [void]$sb.Append($ch)
    }
    if ($backslashRun -gt 0) {
        [void]$sb.Append('\', ($backslashRun * 2))
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-ElevatedArgumentString {
    # Builds the single, fully-quoted command-line string passed to
    # Start-Process -ArgumentList for the elevated re-entry. Kept separate
    # from Invoke-Elevated so tests can assert on the produced string
    # (round-tripping a path with a space) without touching Start-Process.
    param(
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath,
        [Parameter(Mandatory = $true)][string]$Action,
        [hashtable]$Parameters = @{}
    )

    $argParts = New-Object System.Collections.Generic.List[string]
    $argParts.Add('-NoProfile')
    $argParts.Add('-ExecutionPolicy')
    $argParts.Add('Bypass')
    $argParts.Add('-File')
    $argParts.Add((ConvertTo-QuotedCommandLineArgument -Value $ManagerScriptPath))
    $argParts.Add('-Action')
    $argParts.Add((ConvertTo-QuotedCommandLineArgument -Value $Action))

    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) {
                $argParts.Add('-' + $key)
            }
        }
        elseif ($value -is [bool]) {
            if ($value) {
                $argParts.Add('-' + $key)
            }
        }
        else {
            $argParts.Add('-' + $key)
            $argParts.Add((ConvertTo-QuotedCommandLineArgument -Value ([string]$value)))
        }
    }

    return [string]::Join(' ', $argParts.ToArray())
}

function Start-ElevatedManagerProcess {
    # Isolated wrapper around Start-Process -Verb RunAs, so this can be
    # shimmed by tests exactly like the watchdog cmdlet wrappers above.
    # ArgumentList is a single, already-quoted command-line string (see
    # ConvertTo-ElevatedArgumentString) -- Start-Process passes a single
    # array element straight through with no further quoting or splitting.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList
    )
    return Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Verb RunAs -Wait -PassThru
}

function Invoke-Elevated {
    # Re-launches this manager script (or ManagerScriptPath explicitly)
    # with -Action $Action and the given supporting parameters, requesting
    # elevation via Start-Process -Verb RunAs. Only called for the specific
    # operations that actually need admin (conf editing under Program
    # Files, host service restart, and the uninstall paths that touch
    # protected locations) -- the GUI never runs elevated wholesale.
    # Watchdog registration/unregistration is user-level (CONTRACT B: the
    # AtStartup/SYSTEM Boot task is gone) and never elevates.
    param(
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath,
        [Parameter(Mandatory = $true)][string]$Action,
        [hashtable]$Parameters = @{}
    )

    $argumentString = ConvertTo-ElevatedArgumentString -ManagerScriptPath $ManagerScriptPath -Action $Action -Parameters $Parameters
    $proc = Start-ElevatedManagerProcess -FilePath (Get-WindowsPowerShellExePath) -ArgumentList $argumentString
    return $proc.ExitCode
}

# ---------------------------------------------------------------------------
# CLI wiring (also used by Invoke-Elevated re-entry)
# ---------------------------------------------------------------------------

function Invoke-ManagerAction {
    # Dispatches one headless -Action, resolving unset path parameters via
    # the Get-Resolved*/Get-Default* helpers above before calling into the
    # relevant Core function(s).
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ScriptDir,
        [string]$ProgramDir,
        [string]$DataDir,
        [string]$ConfPath,
        [switch]$IncludePoll,
        [int]$PollMinutes = 15,
        [switch]$RemoveData,
        [string]$ManagerScriptPath,
        [string]$CommandPath,
        [string]$UserId
    )

    $resolvedProgramDir = Get-ResolvedProgramDir -ProgramDir $ProgramDir
    $resolvedDataDir = Get-ResolvedDataDir -DataDir $DataDir
    $resolvedUserId = Get-ResolvedUserId -UserId $UserId

    switch ($Action) {
        'install' {
            # Resolved lazily, here, rather than unconditionally above:
            # this is the only action that actually needs
            # ManagerScriptPath, and Get-ResolvedManagerScriptPath fails
            # closed (see its own comment) when neither an explicit value
            # nor $PSCommandPath is available -- every OTHER action should
            # keep working headlessly even in whatever edge case makes
            # that resolution impossible.
            $resolvedManagerScriptPath = Get-ResolvedManagerScriptPath -ManagerScriptPath $ManagerScriptPath -ScriptDir $ScriptDir -CommandPath $CommandPath
            return Install-App -ProgramDir $resolvedProgramDir -DataDir $resolvedDataDir -ManagerScriptPath $resolvedManagerScriptPath -ScriptDir $ScriptDir
        }
        'register-vibepollo' {
            $resolvedConfPath = Get-ResolvedConfPath -ConfPath $ConfPath
            if ([string]::IsNullOrWhiteSpace($resolvedConfPath)) {
                throw 'register-vibepollo: no conf file found automatically; pass -ConfPath explicitly'
            }
            $addResult = Add-PrepCommandEntry -ConfPath $resolvedConfPath -DataDir $resolvedDataDir
            if ($addResult.Success) {
                # Restart happens HERE -- in whichever process (elevated or
                # not) actually holds the rights to have just written the
                # conf -- rather than being left to a separate GUI call
                # site that always runs unelevated and would fail (or
                # simply do nothing useful) immediately after a
                # successful elevated write.
                $addResult | Add-Member -NotePropertyName 'ServiceRestart' -NotePropertyValue (Restart-HostService)
            }
            return $addResult
        }
        'unregister-vibepollo' {
            $resolvedConfPath = Get-ResolvedConfPath -ConfPath $ConfPath
            if ([string]::IsNullOrWhiteSpace($resolvedConfPath)) {
                throw 'unregister-vibepollo: no conf file found automatically; pass -ConfPath explicitly'
            }
            $removeResult = Remove-PrepCommandEntry -ConfPath $resolvedConfPath -DataDir $resolvedDataDir
            if ($removeResult.Success -and $removeResult.Message -eq 'entry removed') {
                $removeResult | Add-Member -NotePropertyName 'ServiceRestart' -NotePropertyValue (Restart-HostService)
            }
            return $removeResult
        }
        'register-watchdog' {
            return Register-Watchdog -DataDir $resolvedDataDir -UserId $resolvedUserId -IncludePoll:$IncludePoll -PollMinutes $PollMinutes
        }
        'unregister-watchdog' {
            return Unregister-Watchdog
        }
        'uninstall' {
            $resolvedConfPath = Get-ResolvedConfPath -ConfPath $ConfPath
            return Uninstall-App -ProgramDir $resolvedProgramDir -DataDir $resolvedDataDir -ConfPath $resolvedConfPath -RemoveData:$RemoveData
        }
        default {
            throw "Invoke-ManagerAction: unknown action '$Action'"
        }
    }
}

# ---------------------------------------------------------------------------
# Result-shape helpers -- several Core functions above signal failure by
# RETURNING an object (or array of objects) with Success=$false rather than
# throwing (Add-/Remove-PrepCommandEntry on malformed conf JSON,
# Register-/Unregister-Watchdog on a per-task failure). Both the headless
# CLI entry point and Invoke-GuiElevatable need to recognize that shape --
# "didn't throw" is NOT the same thing as "succeeded" -- so it lives here,
# shared, rather than duplicated (and inevitably drifting) in both places.
# ---------------------------------------------------------------------------

function Test-ManagerResultIndicatesFailure {
    # True if $Result -- a single PSCustomObject or an array of them -- has
    # any element carrying a Success property equal to $false. Ignores
    # $null/scalars/objects with no Success property at all (a Success
    # property is opt-in: not every Core function returns one).
    param($Result)
    foreach ($item in @($Result)) {
        if ($null -eq $item) {
            continue
        }
        if ($item.PSObject.Properties.Match('Success').Count -eq 0) {
            continue
        }
        if ($item.Success -eq $false) {
            return $true
        }
    }
    return $false
}

function Get-ManagerResultFailureMessage {
    # The Message of the first failing element found by
    # Test-ManagerResultIndicatesFailure, or a generic fallback if the
    # failing element carries no Message property.
    param($Result)
    foreach ($item in @($Result)) {
        if ($null -eq $item) {
            continue
        }
        if ($item.PSObject.Properties.Match('Success').Count -eq 0 -or $item.Success -ne $false) {
            continue
        }
        if ($item.PSObject.Properties.Match('Message').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$item.Message)) {
            return [string]$item.Message
        }
        return 'operation reported failure'
    }
    return 'operation reported failure'
}

# ===========================================================================
# #region Gui
# ===========================================================================


# ---------------------------------------------------------------------------
# WinForms bootstrap
# ---------------------------------------------------------------------------

function Initialize-GuiAssemblies {
    # Loaded lazily (only when a GUI is actually about to be shown) so that
    # dot-sourcing this file with -NoRun on a headless Linux test host --
    # or running a headless -Action on Windows -- never touches WinForms.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

function Test-GuiIsStaThread {
    # WinForms common dialogs (OpenFileDialog, FolderBrowserDialog,
    # clipboard/drag-drop) need an STA thread. Windows PowerShell 5.1 is
    # STA by default; pwsh 7 is MTA by default. Never throws: an
    # unavailable ApartmentState (non-Windows) is treated as "fine, don't
    # bother relaunching".
    try {
        return ([System.Threading.Thread]::CurrentThread.ApartmentState -eq [System.Threading.ApartmentState]::STA)
    }
    catch {
        return $true
    }
}

function Start-GuiInStaIfNeeded {
    # Best-effort: if this process is not STA (i.e. pwsh 7 launched
    # normally), relaunch this same script with -sta and let the caller
    # return immediately without showing anything from the wrong-apartment
    # process. If the relaunch itself fails for any reason, proceeds in the
    # current apartment anyway -- most dialogs still work, only a few
    # WinForms features are flaky under MTA.
    param([Parameter(Mandatory = $true)][string]$ManagerScriptPath)

    if (Test-GuiIsStaThread) {
        return $false
    }

    try {
        # The current process's own resolved executable path -- avoids both
        # a bare-name CWD-search hijack and the same space-splitting hazard
        # ConvertTo-QuotedCommandLineArgument exists to fix for the elevated
        # relaunch (a ManagerScriptPath containing a space, e.g. under
        # "C:\Users\John Doe\...", would otherwise break this relaunch too).
        $psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $argumentString = '-NoProfile -sta -File ' + (ConvertTo-QuotedCommandLineArgument -Value $ManagerScriptPath)
        Start-Process -FilePath $psExe -ArgumentList $argumentString | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Safe-call / elevation-retry wrappers
#
# Every Core-function call site in the GUI goes through one of these two so
# the GUI can never die on an exception: Invoke-GuiSafe just catches and
# pops a MessageBox; Invoke-GuiElevatable additionally offers to relaunch
# the specific headless -Action elevated when the failure looks like a
# permissions problem (conf file under Program Files, service restart, or
# an uninstall path touching a protected location -- see Invoke-Elevated
# above; watchdog registration/unregistration is user-level and never
# elevates, CONTRACT B).
# ---------------------------------------------------------------------------

function Show-GuiConfirm {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'stream-config-profiles'
    )
    $result = [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Invoke-GuiSafe {
    # Runs Action; on any exception, shows a MessageBox with the exception
    # message and returns Success=$false instead of propagating. Every
    # button click handler in this region routes its Core-function calls
    # through this (directly, or via Invoke-GuiElevatable below).
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$ErrorTitle = 'stream-config-profiles'
    )
    try {
        $value = & $Action
        return [PSCustomObject]@{ Success = $true; Value = $value; ErrorMessage = $null }
    }
    catch {
        $msg = $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($msg, $ErrorTitle, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return [PSCustomObject]@{ Success = $false; Value = $null; ErrorMessage = $msg }
    }
}

function Test-GuiLooksLikeAccessDenied {
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) {
        return $false
    }
    $exception = $ErrorRecord.Exception
    if ($null -ne $exception -and $exception -is [System.UnauthorizedAccessException]) {
        return $true
    }
    $msg = ''
    if ($null -ne $exception) {
        $msg = [string]$exception.Message
    }
    return ($msg -match '(?i)denied|unauthorized')
}

function Invoke-GuiElevatable {
    # Tries UnelevatedAction first. If it throws something that looks like
    # a permissions failure, asks the user whether to retry elevated via
    # Invoke-Elevated (re-running manager.ps1 -Action $Action with
    # $Parameters, using Start-Process -Verb RunAs) -- this is the only
    # path by which the GUI ever requests elevation, and only for the
    # specific operation that needs it, never the GUI process as a whole.
    param(
        [Parameter(Mandatory = $true)][scriptblock]$UnelevatedAction,
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath,
        [Parameter(Mandatory = $true)][string]$Action,
        [hashtable]$Parameters = @{}
    )

    try {
        $value = & $UnelevatedAction
        if (Test-ManagerResultIndicatesFailure -Result $value) {
            # The Core function didn't throw, but its own return value
            # reports Success=$false (e.g. Add-PrepCommandEntry on
            # malformed existing conf JSON) -- that is a real, final
            # failure, not a permissions problem, so it is surfaced
            # directly rather than routed into the access-denied /
            # elevation-retry branch below.
            $msg = Get-ManagerResultFailureMessage -Result $value
            [System.Windows.Forms.MessageBox]::Show($msg, 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return [PSCustomObject]@{ Success = $false; Value = $value; Elevated = $false; ErrorMessage = $msg }
        }
        return [PSCustomObject]@{ Success = $true; Value = $value; Elevated = $false; ErrorMessage = $null }
    }
    catch {
        if (-not (Test-GuiLooksLikeAccessDenied -ErrorRecord $_)) {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return [PSCustomObject]@{ Success = $false; Value = $null; Elevated = $false; ErrorMessage = $_.Exception.Message }
        }

        $confirm = Show-GuiConfirm -Text "This needs administrator rights. Retry elevated?`r`n`r`n$($_.Exception.Message)"
        if (-not $confirm) {
            return [PSCustomObject]@{ Success = $false; Value = $null; Elevated = $false; ErrorMessage = 'cancelled (needs admin)' }
        }

        try {
            $exitCode = Invoke-Elevated -ManagerScriptPath $ManagerScriptPath -Action $Action -Parameters $Parameters
            if ($exitCode -eq 0) {
                return [PSCustomObject]@{ Success = $true; Value = $null; Elevated = $true; ErrorMessage = $null }
            }
            return [PSCustomObject]@{ Success = $false; Value = $null; Elevated = $true; ErrorMessage = "elevated process exited with code $exitCode" }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return [PSCustomObject]@{ Success = $false; Value = $null; Elevated = $true; ErrorMessage = $_.Exception.Message }
        }
    }
}

# ---------------------------------------------------------------------------
# Control factories -- trim the boilerplate out of the step/window builders
# below. Every one is a plain WinForms control with Location/Size set from
# the given coordinates; callers add behaviour (event handlers) themselves.
# ---------------------------------------------------------------------------

function New-GuiLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 20)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($Width, $Height)
    return $lbl
}

function New-GuiButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 100, [int]$Height = 28)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    return $btn
}

function New-GuiTextBox {
    param([int]$X, [int]$Y, [int]$Width, [string]$Text = '')
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point($X, $Y)
    $tb.Size = New-Object System.Drawing.Size($Width, 23)
    $tb.Text = $Text
    return $tb
}

function New-GuiCheckBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [bool]$Checked = $false)
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Text
    $cb.Location = New-Object System.Drawing.Point($X, $Y)
    $cb.Size = New-Object System.Drawing.Size($Width, 24)
    $cb.Checked = $Checked
    return $cb
}

# ---------------------------------------------------------------------------
# paths.txt editing (Main Window only) -- appends/removes whole path lines,
# preserving every comment/blank line byte-for-byte, mirroring the
# preserve-everything-else style of Write-ConfGlobalPrepCmd above.
# ---------------------------------------------------------------------------

function Get-PathsTxtEntries {
    # Returns the non-comment, non-blank path lines from paths.txt, in
    # file order, for display in the Main Window's ListBox.
    param([Parameter(Mandatory = $true)][string]$PathsTxtPath)

    if (-not (Test-Path -LiteralPath $PathsTxtPath)) {
        return @()
    }
    $raw = Get-Content -LiteralPath $PathsTxtPath -Raw -Encoding UTF8
    if ([string]::IsNullOrEmpty($raw)) {
        return @()
    }

    $lines = $raw -split "`r`n|`n"
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) {
            continue
        }
        if ($trimmed.StartsWith('#')) {
            continue
        }
        $entries.Add($trimmed)
    }
    return $entries.ToArray()
}

function Add-PathsTxtLine {
    # Appends one path line at the end of paths.txt. Creates the file if it
    # is somehow missing (should not happen post-install, but this must
    # never crash the GUI).
    param(
        [Parameter(Mandatory = $true)][string]$PathsTxtPath,
        [Parameter(Mandatory = $true)][string]$LineToAdd
    )

    $existing = ''
    if (Test-Path -LiteralPath $PathsTxtPath) {
        $existing = Get-Content -LiteralPath $PathsTxtPath -Raw -Encoding UTF8
    }

    if ([string]::IsNullOrEmpty($existing)) {
        $newContent = $LineToAdd + "`r`n"
    }
    elseif ($existing -match "(`r`n|`n)$") {
        $newContent = $existing + $LineToAdd + "`r`n"
    }
    else {
        $newContent = $existing + "`r`n" + $LineToAdd + "`r`n"
    }

    [System.IO.File]::WriteAllText($PathsTxtPath, $newContent, $script:Utf8NoBomEncoding)
}

function Remove-PathsTxtLine {
    # Removes every line whose trimmed text exactly matches LineToRemove
    # (normally exactly one), leaving comments/blank lines/other paths
    # untouched.
    param(
        [Parameter(Mandatory = $true)][string]$PathsTxtPath,
        [Parameter(Mandatory = $true)][string]$LineToRemove
    )

    if (-not (Test-Path -LiteralPath $PathsTxtPath)) {
        return
    }

    $raw = Get-Content -LiteralPath $PathsTxtPath -Raw -Encoding UTF8
    $lineEnding = "`n"
    if ($raw -match "`r`n") {
        $lineEnding = "`r`n"
    }
    $hadTrailingNewline = [bool]($raw -match "(`r`n|`n)$")
    $splitLines = $raw -split "`r`n|`n"

    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in $splitLines) {
        if ($line.Trim() -eq $LineToRemove.Trim()) {
            continue
        }
        $kept.Add($line)
    }
    if ($hadTrailingNewline -and $kept.Count -gt 0 -and $kept[$kept.Count - 1] -eq '') {
        $kept.RemoveAt($kept.Count - 1)
    }

    $content = [string]::Join($lineEnding, $kept.ToArray())
    if ($hadTrailingNewline) {
        $content = $content + $lineEnding
    }

    [System.IO.File]::WriteAllText($PathsTxtPath, $content, $script:Utf8NoBomEncoding)
}

# ---------------------------------------------------------------------------
# Watchdog status (Main Window)
# ---------------------------------------------------------------------------

function Get-WatchdogTaskExistence {
    # Best-effort Get-ScheduledTask wrapper -- never throws (missing task,
    # unavailable cmdlet, non-Windows host are all just "not registered").
    param(
        [string[]]$Names = @('StreamConfigProfiles-Settle-Boot', 'StreamConfigProfiles-Settle-Logon', 'StreamConfigProfiles-Settle-Poll')
    )
    $status = @{}
    foreach ($name in $Names) {
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            $status[$name] = ($null -ne $task)
        }
        catch {
            $status[$name] = $false
        }
    }
    return $status
}

# ---------------------------------------------------------------------------
# First-Run Wizard -- five steps, each its own modal Form (kept as separate
# dialogs rather than one Form with swapped panels: simpler control-scoping,
# no shared-panel-visibility bugs). Every step returns 'Next' / 'Back' /
# 'Cancel'; Show-FirstRunWizard below drives the step index off that.
# A step's own controls are read back into $State (a hashtable, passed by
# reference) before it reports 'Next'.
# ---------------------------------------------------------------------------

function Show-WizardWelcomeStep {
    param([hashtable]$State)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles - Setup (1 of 5): Welcome'
    $form.Size = New-Object System.Drawing.Size(520, 300)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $intro = New-GuiLabel -Text 'This wizard installs stream-config-profiles and connects it to Vibepollo/Apollo.' -X 15 -Y 15 -Width 480 -Height 30
    $form.Controls.Add($intro)

    $lblProgram = New-GuiLabel -Text 'Program folder (fixed):' -X 15 -Y 60 -Width 200
    $form.Controls.Add($lblProgram)
    $txtProgram = New-GuiTextBox -X 15 -Y 82 -Width 480 -Text $State.ProgramDir
    $txtProgram.ReadOnly = $true
    $form.Controls.Add($txtProgram)

    # Fixed, exactly like ProgramDir -- deliberately not user-changeable.
    # PROGRAM is contractually allowed to hold manager.ps1 ONLY, so there
    # is nowhere contract-compliant to persist a chosen DataDir for a
    # later no-arg launch to recover it from; a "Browse..." affordance
    # here previously let the folder silently diverge from the resolver's
    # default on every subsequent launch, which re-ran this wizard,
    # installed a second engine copy at the default location, and left
    # every other DataDir-dependent feature (paths list, sync.log viewer,
    # watchdog, uninstall's engine-identifier match) pointed at the wrong
    # folder.
    $lblData = New-GuiLabel -Text 'Data folder (paths.txt, profiles, log -- fixed):' -X 15 -Y 115 -Width 420
    $form.Controls.Add($lblData)
    $txtData = New-GuiTextBox -X 15 -Y 137 -Width 480 -Text $State.DataDir
    $txtData.ReadOnly = $true
    $form.Controls.Add($txtData)

    $btnCancel = New-GuiButton -Text 'Cancel' -X 300 -Y 220 -Width 90
    $btnNext = New-GuiButton -Text 'Next >' -X 400 -Y 220 -Width 90
    $form.Controls.Add($btnCancel)
    $form.Controls.Add($btnNext)
    $form.CancelButton = $btnCancel
    $form.AcceptButton = $btnNext

    $btnCancel.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })
    $btnNext.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return 'Next'
    }
    return 'Cancel'
}

function Show-WizardInstallStep {
    param([hashtable]$State)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles - Setup (2 of 5): Install files'
    $form.Size = New-Object System.Drawing.Size(520, 300)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $lblProgram = New-GuiLabel -Text ('Program folder: ' + $State.ProgramDir) -X 15 -Y 15 -Width 480 -Height 20
    $form.Controls.Add($lblProgram)
    $lblData = New-GuiLabel -Text ('Data folder: ' + $State.DataDir) -X 15 -Y 40 -Width 480 -Height 20
    $form.Controls.Add($lblData)

    $txtResult = New-Object System.Windows.Forms.TextBox
    $txtResult.Location = New-Object System.Drawing.Point(15, 75)
    $txtResult.Size = New-Object System.Drawing.Size(475, 135)
    $txtResult.Multiline = $true
    $txtResult.ReadOnly = $true
    $txtResult.ScrollBars = 'Vertical'
    $form.Controls.Add($txtResult)

    $btnBack = New-GuiButton -Text '< Back' -X 110 -Y 220 -Width 90
    $btnCancel = New-GuiButton -Text 'Cancel' -X 300 -Y 220 -Width 90
    $btnNext = New-GuiButton -Text 'Next >' -X 400 -Y 220 -Width 90
    $btnNext.Enabled = $false
    $form.Controls.Add($btnBack)
    $form.Controls.Add($btnCancel)
    $form.Controls.Add($btnNext)
    $form.CancelButton = $btnCancel

    # Runs as soon as this step is built (before ShowDialog), rather than
    # behind a separate "Install now" button -- Install-App only ever
    # touches the per-user DATA/PROGRAM dirs, never needs elevation, and is
    # idempotent, so there is nothing gained by making the user ask for it.
    $installOutcome = Invoke-GuiSafe -Action {
        Install-App -ProgramDir $State.ProgramDir -DataDir $State.DataDir -ManagerScriptPath $State.ManagerScriptPath -ScriptDir $State.ScriptDir
    }

    if ($installOutcome.Success) {
        $r = $installOutcome.Value
        $txtResult.Text = "Install succeeded.`r`n`r`nManager:   $($r.ManagerPath)`r`nEngine:    $($r.EnginePath)`r`nTemplate:  $($r.TemplatePath)`r`npaths.txt: $($r.PathsTxtPath)"
        $State.InstallDone = $true
        $btnNext.Enabled = $true
    }
    else {
        $txtResult.Text = "Install failed:`r`n`r`n" + $installOutcome.ErrorMessage
        $State.InstallDone = $false
    }

    $btnBack.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Retry; $form.Close() })
    $btnCancel.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })
    $btnNext.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })

    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return 'Next'
    }
    if ($result -eq [System.Windows.Forms.DialogResult]::Retry) {
        return 'Back'
    }
    return 'Cancel'
}

function Show-WizardVibepolloStep {
    param([hashtable]$State)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles - Setup (3 of 5): Connect to Vibepollo/Apollo'
    $form.Size = New-Object System.Drawing.Size(560, 340)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $intro = New-GuiLabel -Text 'Point this at your Vibepollo/Apollo/Sunshine .conf file. This adds one global prep command pair and keeps any existing entries from other tools.' -X 15 -Y 15 -Width 510 -Height 45
    $form.Controls.Add($intro)

    $detected = $null
    $detectOutcome = Invoke-GuiSafe -Action { Find-HostConf }
    if ($detectOutcome.Success) {
        $detected = $detectOutcome.Value
    }
    if ([string]::IsNullOrWhiteSpace($detected)) {
        $detected = ''
    }
    if ([string]::IsNullOrWhiteSpace($State.ConfPath)) {
        $State.ConfPath = $detected
    }

    $lblConf = New-GuiLabel -Text 'Conf file path:' -X 15 -Y 70 -Width 150
    $form.Controls.Add($lblConf)
    $txtConf = New-GuiTextBox -X 15 -Y 92 -Width 420 -Text $State.ConfPath
    $form.Controls.Add($txtConf)
    $btnBrowse = New-GuiButton -Text 'Browse...' -X 440 -Y 91 -Width 90
    $form.Controls.Add($btnBrowse)
    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'Config files (*.conf)|*.conf|All files (*.*)|*.*'
        if (-not [string]::IsNullOrWhiteSpace($txtConf.Text) -and (Test-Path -LiteralPath $txtConf.Text)) {
            $ofd.InitialDirectory = Split-Path -Path $txtConf.Text -Parent
        }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtConf.Text = $ofd.FileName
        }
    })

    $noteText = 'Not auto-detected -- browse to it manually if Vibepollo/Apollo is installed.'
    if (-not [string]::IsNullOrWhiteSpace($detected)) {
        $noteText = "Auto-detected: $detected"
    }
    $lblNote = New-GuiLabel -Text $noteText -X 15 -Y 122 -Width 510 -Height 20
    $form.Controls.Add($lblNote)

    $txtResult = New-Object System.Windows.Forms.TextBox
    $txtResult.Location = New-Object System.Drawing.Point(15, 150)
    $txtResult.Size = New-Object System.Drawing.Size(515, 90)
    $txtResult.Multiline = $true
    $txtResult.ReadOnly = $true
    $txtResult.ScrollBars = 'Vertical'
    $txtResult.Text = "Not connected yet -- click Connect, or Next to skip (you can run this later via manager.ps1 -Action register-vibepollo)."
    $form.Controls.Add($txtResult)

    $btnConnect = New-GuiButton -Text 'Connect' -X 15 -Y 250 -Width 110
    $form.Controls.Add($btnConnect)

    $btnBack = New-GuiButton -Text '< Back' -X 260 -Y 250 -Width 90
    $btnCancel = New-GuiButton -Text 'Cancel' -X 355 -Y 250 -Width 90
    $btnNext = New-GuiButton -Text 'Next >' -X 450 -Y 250 -Width 90
    $form.Controls.Add($btnBack)
    $form.Controls.Add($btnCancel)
    $form.Controls.Add($btnNext)
    $form.CancelButton = $btnCancel

    $btnConnect.Add_Click({
        $confPath = $txtConf.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($confPath) -or -not (Test-Path -LiteralPath $confPath)) {
            [System.Windows.Forms.MessageBox]::Show('Please choose a valid conf file first.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $State.ConfPath = $confPath
        $dataDirForConnect = $State.DataDir
        # The restart happens INSIDE this scriptblock (whichever process --
        # elevated or not -- actually ran it), not as a separate always-
        # unelevated call afterward: restarting a real Windows service
        # unelevated routinely fails right after a successful elevated
        # conf write, which previously showed a confusing "restart failed"
        # message immediately below a successful "Connected" message.
        $addOutcome = Invoke-GuiElevatable -ManagerScriptPath $State.ManagerScriptPath -Action 'register-vibepollo' -Parameters @{ ConfPath = $confPath; DataDir = $dataDirForConnect } -UnelevatedAction {
            $result = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDirForConnect
            if ($result.Success) {
                $result | Add-Member -NotePropertyName 'ServiceRestart' -NotePropertyValue (Restart-HostService)
            }
            return $result
        }

        if ($addOutcome.Success) {
            $restartMsg = 'restart status unknown'
            if ($null -ne $addOutcome.Value -and $addOutcome.Value.PSObject.Properties.Match('ServiceRestart').Count -gt 0) {
                $restartMsg = $addOutcome.Value.ServiceRestart.Message
            }
            elseif ($addOutcome.Elevated) {
                $restartMsg = 'handled by the elevated process'
            }
            $txtResult.Text = "Connected -- a timestamped backup of the conf file was saved alongside it.`r`nService: $restartMsg"
        }
        else {
            $txtResult.Text = 'Could not update the conf file: ' + $addOutcome.ErrorMessage
        }
    })

    $btnBack.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Retry; $form.Close() })
    $btnCancel.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })
    $btnNext.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })

    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return 'Next'
    }
    if ($result -eq [System.Windows.Forms.DialogResult]::Retry) {
        return 'Back'
    }
    return 'Cancel'
}

function Show-WizardWatchdogStep {
    param([hashtable]$State)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles - Setup (4 of 5): Watchdog protection'
    $form.Size = New-Object System.Drawing.Size(520, 280)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $intro = New-GuiLabel -Text 'The watchdog re-applies your local config if a stream ends without a clean disconnect (crash, force-quit, sleep). It runs entirely as you -- no administrator rights are needed.' -X 15 -Y 15 -Width 480 -Height 45
    $form.Controls.Add($intro)

    $cbLogon = New-GuiCheckBox -Text 'Protect at logon / unlock (recommended)' -X 20 -Y 70 -Width 400 -Checked $true
    $form.Controls.Add($cbLogon)

    $cbPoll = New-GuiCheckBox -Text 'Also check periodically, every' -X 20 -Y 100 -Width 210 -Checked ([bool]$State.IncludePoll)
    $form.Controls.Add($cbPoll)

    $nudPoll = New-Object System.Windows.Forms.NumericUpDown
    $nudPoll.Location = New-Object System.Drawing.Point(235, 98)
    $nudPoll.Size = New-Object System.Drawing.Size(60, 23)
    $nudPoll.Minimum = 5
    $nudPoll.Maximum = 1440
    $pollDefault = $State.PollMinutes
    if ($pollDefault -lt 5) {
        $pollDefault = 15
    }
    $nudPoll.Value = $pollDefault
    $nudPoll.Enabled = [bool]$State.IncludePoll
    $form.Controls.Add($nudPoll)

    $lblMinutes = New-GuiLabel -Text 'minutes (min. 5)' -X 300 -Y 100 -Width 150
    $form.Controls.Add($lblMinutes)

    $cbPoll.Add_CheckedChanged({ $nudPoll.Enabled = $cbPoll.Checked })

    $btnBack = New-GuiButton -Text '< Back' -X 110 -Y 200 -Width 90
    $btnCancel = New-GuiButton -Text 'Cancel' -X 300 -Y 200 -Width 90
    $btnNext = New-GuiButton -Text 'Next >' -X 400 -Y 200 -Width 90
    $form.Controls.Add($btnBack)
    $form.Controls.Add($btnCancel)
    $form.Controls.Add($btnNext)
    $form.CancelButton = $btnCancel

    $btnBack.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Retry; $form.Close() })
    $btnCancel.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close() })
    $btnNext.Add_Click({
        $State.IncludePoll = $cbPoll.Checked
        $State.PollMinutes = [int]$nudPoll.Value
        $includeLogon = $cbLogon.Checked
        $dataDirForWatchdog = $State.DataDir
        $includePollForWatchdog = $State.IncludePoll
        $pollMinutesForWatchdog = $State.PollMinutes
        # Resolved once, in this process, and threaded through explicitly
        # -- NOT re-derived from $env:USERNAME anywhere else, so a value
        # picked up under a different identity can never sneak in.
        $userIdForWatchdog = Get-ResolvedUserId

        # Register-Watchdog only ever registers user-level (Interactive)
        # tasks, so this never needs elevation -- Invoke-GuiSafe, not
        # Invoke-GuiElevatable.
        $applyOutcome = Invoke-GuiSafe -Action {
            $regResults = Register-Watchdog -DataDir $dataDirForWatchdog -UserId $userIdForWatchdog -IncludePoll:$includePollForWatchdog -PollMinutes $pollMinutesForWatchdog
            $failed = @($regResults | Where-Object { -not $_.Success })
            if (@($failed).Count -gt 0) {
                throw ('watchdog registration reported errors: ' + (($failed | ForEach-Object { $_.Message }) -join '; '))
            }
            return $regResults
        }

        if (-not $includeLogon) {
            Invoke-GuiSafe -Action { Unregister-WatchdogTask -Name 'StreamConfigProfiles-Settle-Logon' } | Out-Null
        }

        if ($applyOutcome.Success) {
            [System.Windows.Forms.MessageBox]::Show('Watchdog protection configured.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show('Watchdog setup had a problem: ' + $applyOutcome.ErrorMessage + "`r`n`r`nYou can retry this from the main window later.", 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }

        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return 'Next'
    }
    if ($result -eq [System.Windows.Forms.DialogResult]::Retry) {
        return 'Back'
    }
    return 'Cancel'
}

function Show-WizardDoneStep {
    param([hashtable]$State)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles - Setup (5 of 5): Done'
    $form.Size = New-Object System.Drawing.Size(520, 320)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $text = "Setup is complete.`r`n`r`nWhat's next:`r`n -  Add or remove game config paths from the main window (Add File / Add Folder).`r`n -  Watchdog and connection status are shown on the main window; you can re-run either step from there.`r`n -  See README.md for the paths.txt format and troubleshooting tips.`r`n`r`nData folder: $($State.DataDir)"
    $lbl = New-GuiLabel -Text $text -X 15 -Y 15 -Width 480 -Height 220
    $form.Controls.Add($lbl)

    $btnBack = New-GuiButton -Text '< Back' -X 300 -Y 245 -Width 90
    $btnFinish = New-GuiButton -Text 'Finish' -X 400 -Y 245 -Width 90
    $form.Controls.Add($btnBack)
    $form.Controls.Add($btnFinish)
    $form.AcceptButton = $btnFinish

    $btnBack.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Retry; $form.Close() })
    $btnFinish.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })

    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return 'Next'
    }
    if ($result -eq [System.Windows.Forms.DialogResult]::Retry) {
        return 'Back'
    }
    return 'Cancel'
}

function Show-FirstRunWizard {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptDir,
        [Parameter(Mandatory = $true)][string]$ProgramDir,
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath
    )

    $state = @{
        ScriptDir         = $ScriptDir
        ProgramDir        = $ProgramDir
        DataDir           = $DataDir
        ManagerScriptPath = $ManagerScriptPath
        ConfPath          = $null
        IncludePoll       = $false
        PollMinutes       = 15
        InstallDone       = $false
    }

    $step = 1
    while ($step -ge 1 -and $step -le 5) {
        $result = switch ($step) {
            1 { Show-WizardWelcomeStep -State $state }
            2 { Show-WizardInstallStep -State $state }
            3 { Show-WizardVibepolloStep -State $state }
            4 { Show-WizardWatchdogStep -State $state }
            5 { Show-WizardDoneStep -State $state }
            default { 'Cancel' }
        }

        if ($result -eq 'Next') {
            $step = $step + 1
        }
        elseif ($result -eq 'Back') {
            if ($step -gt 1) {
                $step = $step - 1
            }
        }
        else {
            return
        }
    }

    Show-MainWindow -ScriptDir $state.ScriptDir -ProgramDir $state.ProgramDir -DataDir $state.DataDir -ManagerScriptPath $state.ManagerScriptPath
}

# ---------------------------------------------------------------------------
# Main Window (shown once already installed)
# ---------------------------------------------------------------------------

function Show-MainWindow {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptDir,
        [Parameter(Mandatory = $true)][string]$ProgramDir,
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath
    )

    $pathsTxtPath = Join-Path $DataDir 'paths.txt'

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles'
    $form.Size = New-Object System.Drawing.Size(640, 560)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(560, 480)

    $lblPaths = New-GuiLabel -Text 'Configured game config paths:' -X 15 -Y 15 -Width 300
    $form.Controls.Add($lblPaths)

    $lstPaths = New-Object System.Windows.Forms.ListBox
    $lstPaths.Location = New-Object System.Drawing.Point(15, 40)
    $lstPaths.Size = New-Object System.Drawing.Size(590, 180)
    $lstPaths.Anchor = 'Top,Left,Right'
    $form.Controls.Add($lstPaths)

    function Sync-PathsList {
        $lstPaths.Items.Clear()
        $entriesOutcome = Invoke-GuiSafe -Action { Get-PathsTxtEntries -PathsTxtPath $pathsTxtPath }
        if ($entriesOutcome.Success) {
            foreach ($e in $entriesOutcome.Value) {
                $lstPaths.Items.Add($e) | Out-Null
            }
        }
    }
    Sync-PathsList

    $btnAddFile = New-GuiButton -Text 'Add File...' -X 15 -Y 230 -Width 110
    $btnAddFolder = New-GuiButton -Text 'Add Folder...' -X 135 -Y 230 -Width 120
    $btnRemove = New-GuiButton -Text 'Remove Selected' -X 265 -Y 230 -Width 140
    $form.Controls.Add($btnAddFile)
    $form.Controls.Add($btnAddFolder)
    $form.Controls.Add($btnRemove)

    $btnAddFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = 'Choose a config file'
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $outcome = Invoke-GuiSafe -Action { Add-PathsTxtLine -PathsTxtPath $pathsTxtPath -LineToAdd $ofd.FileName }
            if ($outcome.Success) {
                Sync-PathsList
            }
        }
    })
    $btnAddFolder.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = 'Choose a config folder'
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $outcome = Invoke-GuiSafe -Action { Add-PathsTxtLine -PathsTxtPath $pathsTxtPath -LineToAdd $fbd.SelectedPath }
            if ($outcome.Success) {
                Sync-PathsList
            }
        }
    })
    $btnRemove.Add_Click({
        if ($null -eq $lstPaths.SelectedItem) {
            [System.Windows.Forms.MessageBox]::Show('Select a path to remove first.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $selected = [string]$lstPaths.SelectedItem
        $outcome = Invoke-GuiSafe -Action { Remove-PathsTxtLine -PathsTxtPath $pathsTxtPath -LineToRemove $selected }
        if ($outcome.Success) {
            Sync-PathsList
        }
    })

    $lblWatchdog = New-GuiLabel -Text 'Watchdog protection status:' -X 15 -Y 275 -Width 300
    $form.Controls.Add($lblWatchdog)

    $txtWatchdogStatus = New-Object System.Windows.Forms.TextBox
    $txtWatchdogStatus.Location = New-Object System.Drawing.Point(15, 298)
    $txtWatchdogStatus.Size = New-Object System.Drawing.Size(590, 55)
    $txtWatchdogStatus.Multiline = $true
    $txtWatchdogStatus.ReadOnly = $true
    $form.Controls.Add($txtWatchdogStatus)

    function Sync-WatchdogStatus {
        $outcome = Invoke-GuiSafe -Action { Get-WatchdogTaskExistence }
        if ($outcome.Success) {
            $s = $outcome.Value
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add('Logon/Unlock: ' + $(if ($s['StreamConfigProfiles-Settle-Logon']) { 'active' } else { 'not registered' }))
            $lines.Add('Polling: ' + $(if ($s['StreamConfigProfiles-Settle-Poll']) { 'active' } else { 'not registered' }))
            # No boot-time task exists in this product any more (a logon
            # already covers post-reboot local play), but a leftover from
            # an earlier build is still worth surfacing since only an
            # elevated process can remove it -- see Unregister-Watchdog.
            if ($s['StreamConfigProfiles-Settle-Boot']) {
                $lines.Add('Boot (legacy, no longer used): still present -- click Unregister All to try removing it')
            }
            $txtWatchdogStatus.Text = [string]::Join("`r`n", $lines.ToArray())
        }
        else {
            $txtWatchdogStatus.Text = 'Status unavailable on this system.'
        }
    }
    Sync-WatchdogStatus

    # Seeded from reality (Get-WatchdogTaskExistence), not hardcoded --
    # otherwise this row reads as a "desired state" control while actually
    # behaving as an add-only one (unchecking a box that was never checked
    # to begin with looks like a no-op either way, hiding the bug).
    $initialStatusOutcome = Invoke-GuiSafe -Action { Get-WatchdogTaskExistence }
    $initialStatus = @{}
    if ($initialStatusOutcome.Success) {
        $initialStatus = $initialStatusOutcome.Value
    }

    $cbLogon2 = New-GuiCheckBox -Text 'Logon/Unlock' -X 15 -Y 362 -Width 130 -Checked ([bool]$initialStatus['StreamConfigProfiles-Settle-Logon'])
    $cbPoll2 = New-GuiCheckBox -Text 'Poll every' -X 150 -Y 362 -Width 90 -Checked ([bool]$initialStatus['StreamConfigProfiles-Settle-Poll'])
    $form.Controls.Add($cbLogon2)
    $form.Controls.Add($cbPoll2)

    $nudPoll2 = New-Object System.Windows.Forms.NumericUpDown
    $nudPoll2.Location = New-Object System.Drawing.Point(245, 360)
    $nudPoll2.Size = New-Object System.Drawing.Size(55, 23)
    $nudPoll2.Minimum = 5
    $nudPoll2.Maximum = 1440
    $nudPoll2.Value = 15
    $nudPoll2.Enabled = $cbPoll2.Checked
    $form.Controls.Add($nudPoll2)
    $cbPoll2.Add_CheckedChanged({ $nudPoll2.Enabled = $cbPoll2.Checked })

    $lblMin2 = New-GuiLabel -Text 'min' -X 305 -Y 362 -Width 40
    $form.Controls.Add($lblMin2)

    $btnApplyWatchdog = New-GuiButton -Text 'Register/Update' -X 425 -Y 358 -Width 130
    $form.Controls.Add($btnApplyWatchdog)

    $btnUnregisterWatchdog = New-GuiButton -Text 'Unregister All' -X 15 -Y 392 -Width 120
    $form.Controls.Add($btnUnregisterWatchdog)

    $btnApplyWatchdog.Add_Click({
        $includePoll = $cbPoll2.Checked
        $pollMinutes = [int]$nudPoll2.Value
        $includeLogon = $cbLogon2.Checked
        $userIdForWatchdog = Get-ResolvedUserId

        # Register-Watchdog only ever ADDS the checked set; reconcile the
        # other direction first so unchecking Poll actually removes it
        # instead of leaving a stale, previously-registered task in place
        # (Logon already had this unregister-if-unchecked path below).
        if (-not $includePoll) {
            Invoke-GuiSafe -Action { Unregister-WatchdogTask -Name 'StreamConfigProfiles-Settle-Poll' } | Out-Null
        }

        # Register-Watchdog only ever registers user-level (Interactive)
        # tasks, so this never needs elevation -- Invoke-GuiSafe, not
        # Invoke-GuiElevatable.
        $applyOutcome = Invoke-GuiSafe -Action {
            $regResults = Register-Watchdog -DataDir $DataDir -UserId $userIdForWatchdog -IncludePoll:$includePoll -PollMinutes $pollMinutes
            $failed = @($regResults | Where-Object { -not $_.Success })
            if (@($failed).Count -gt 0) {
                throw ('watchdog registration reported errors: ' + (($failed | ForEach-Object { $_.Message }) -join '; '))
            }
            return $regResults
        }
        if (-not $includeLogon) {
            Invoke-GuiSafe -Action { Unregister-WatchdogTask -Name 'StreamConfigProfiles-Settle-Logon' } | Out-Null
        }
        if ($applyOutcome.Success) {
            [System.Windows.Forms.MessageBox]::Show('Watchdog settings applied.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        Sync-WatchdogStatus
    })

    $btnUnregisterWatchdog.Add_Click({
        $outcome = Invoke-GuiSafe -Action { Unregister-Watchdog }
        if ($outcome.Success) {
            [System.Windows.Forms.MessageBox]::Show('Watchdog tasks removed.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        Sync-WatchdogStatus
    })

    $btnOpenData = New-GuiButton -Text 'Open data folder' -X 15 -Y 430 -Width 150
    $btnViewLog = New-GuiButton -Text 'View sync.log' -X 175 -Y 430 -Width 130
    $form.Controls.Add($btnOpenData)
    $form.Controls.Add($btnViewLog)

    $btnOpenData.Add_Click({
        # -ArgumentList is a single already-quoted string, not a raw path:
        # DataDir can contain spaces (e.g. under a "John Doe" profile), and
        # an unquoted multi-word argument would otherwise be split into
        # several positional args by explorer.exe's own command-line parsing.
        Invoke-GuiSafe -Action { Start-Process -FilePath 'explorer.exe' -ArgumentList (ConvertTo-QuotedCommandLineArgument -Value $DataDir) } | Out-Null
    })
    $btnViewLog.Add_Click({
        $logPath = Join-Path $DataDir 'sync.log'
        Invoke-GuiSafe -Action {
            if (Test-Path -LiteralPath $logPath) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList (ConvertTo-QuotedCommandLineArgument -Value $logPath)
            }
            else {
                [System.Windows.Forms.MessageBox]::Show('sync.log does not exist yet -- no session has run.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
        } | Out-Null
    })

    $btnDisconnect = New-GuiButton -Text 'Disconnect all / Uninstall...' -X 320 -Y 430 -Width 285
    $form.Controls.Add($btnDisconnect)

    $btnDisconnect.Add_Click({
        $confirm1 = Show-GuiConfirm -Text 'This removes the Vibepollo/Apollo connection, the watchdog tasks, and the program files. Continue?' -Title 'Disconnect stream-config-profiles'
        if (-not $confirm1) {
            return
        }

        $removeData = Show-GuiConfirm -Text 'Also delete your data folder (configured paths, saved profiles, log)? This cannot be undone.' -Title 'Disconnect stream-config-profiles'

        $confPathForUninstall = $null
        $confOutcome = Invoke-GuiSafe -Action { Find-HostConf }
        if ($confOutcome.Success) {
            $confPathForUninstall = $confOutcome.Value
        }

        $uninstallParams = @{ ProgramDir = $ProgramDir; DataDir = $DataDir }
        if (-not [string]::IsNullOrWhiteSpace($confPathForUninstall)) {
            $uninstallParams['ConfPath'] = $confPathForUninstall
        }
        if ($removeData) {
            $uninstallParams['RemoveData'] = [switch]$true
        }

        $outcome = Invoke-GuiElevatable -ManagerScriptPath $ManagerScriptPath -Action 'uninstall' -Parameters $uninstallParams -UnelevatedAction {
            Uninstall-App -ProgramDir $ProgramDir -DataDir $DataDir -ConfPath $confPathForUninstall -RemoveData:$removeData
        }

        if ($outcome.Success) {
            [System.Windows.Forms.MessageBox]::Show('stream-config-profiles has been disconnected and uninstalled.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            $form.Close()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show('Uninstall did not complete: ' + $outcome.ErrorMessage, 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $form.ShowDialog() | Out-Null
}

# ---------------------------------------------------------------------------
# GUI entry point
# ---------------------------------------------------------------------------

function Show-ManagerGui {
    # Dispatched when manager.ps1 runs with no -Action. Resolves the same
    # ProgramDir/DataDir/ManagerScriptPath defaults the headless CLI uses,
    # then shows the First-Run Wizard if the engine is not yet installed in
    # DATA, otherwise the Main Window. Wrapped in its own top-level
    # try/catch as defense in depth -- every individual Core-function call
    # site above already goes through Invoke-GuiSafe / Invoke-GuiElevatable,
    # but this outer guard means even a mistake in the GUI wiring itself
    # (e.g. a bad control property) surfaces as a MessageBox, not a crash.
    param(
        [string]$ScriptDir,
        [string]$ProgramDir,
        [string]$DataDir,
        [string]$ManagerScriptPath
    )

    $resolvedProgramDir = Get-ResolvedProgramDir -ProgramDir $ProgramDir
    $resolvedDataDir = Get-ResolvedDataDir -DataDir $DataDir
    $resolvedManagerScriptPath = Get-ResolvedManagerScriptPath -ManagerScriptPath $ManagerScriptPath -ScriptDir $ScriptDir -CommandPath $PSCommandPath
    $resolvedScriptDir = $ScriptDir
    if ([string]::IsNullOrWhiteSpace($resolvedScriptDir)) {
        $resolvedScriptDir = Split-Path -Path $resolvedManagerScriptPath -Parent
    }

    if (Start-GuiInStaIfNeeded -ManagerScriptPath $resolvedManagerScriptPath) {
        return
    }

    Initialize-GuiAssemblies

    $enginePath = Join-Path $resolvedDataDir 'sync-configs.ps1'
    $engineInstalled = Test-Path -LiteralPath $enginePath

    try {
        if (-not $engineInstalled) {
            Show-FirstRunWizard -ScriptDir $resolvedScriptDir -ProgramDir $resolvedProgramDir -DataDir $resolvedDataDir -ManagerScriptPath $resolvedManagerScriptPath
        }
        else {
            Show-MainWindow -ScriptDir $resolvedScriptDir -ProgramDir $resolvedProgramDir -DataDir $resolvedDataDir -ManagerScriptPath $resolvedManagerScriptPath
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

# ===========================================================================
# #region EmbeddedPayload
#
# Release build process: replace the marker text inside each here-string
# below with the literal contents of the corresponding file
# (sync-configs.ps1 / paths.example.txt), producing a self-contained
# dist\manager.ps1. In the repo (dev mode) these slots are left exactly as
# their bare marker text -- Get-EnginePayload / Get-TemplatePayload treat
# that as "empty" and fall back to the neighbor file in this script's own
# directory (see Test-PayloadEmpty above).
# ===========================================================================

$script:EnginePayload = @'
<#PAYLOAD:ENGINE#>
'@

$script:TemplatePayload = @'
<#PAYLOAD:TEMPLATE#>
'@

# ---------------------------------------------------------------------------
# Entry point guard (lets a test harness dot-source this file with -NoRun)
# ---------------------------------------------------------------------------

if (-not $NoRun) {
    $scriptDirForRun = $PSScriptRoot
    if ([string]::IsNullOrEmpty($scriptDirForRun)) {
        $scriptDirForRun = (Get-Location).Path
    }

    if (-not [string]::IsNullOrWhiteSpace($Action)) {
        $result = Invoke-ManagerAction -Action $Action -ScriptDir $scriptDirForRun -ProgramDir $ProgramDir -DataDir $DataDir -ConfPath $ConfPath -IncludePoll:$IncludePoll -PollMinutes $PollMinutes -RemoveData:$RemoveData -ManagerScriptPath $ManagerScriptPath -CommandPath $PSCommandPath -UserId $UserId
        $result | ConvertTo-Json -Depth 6
        # A Core function can signal failure by RETURNING Success=$false
        # instead of throwing (see Test-ManagerResultIndicatesFailure) --
        # without this check this process always exited 0, so an elevated
        # re-entry (judged by Invoke-GuiElevatable purely on exit code) and
        # a plain CLI caller (checking $LASTEXITCODE) both saw "success"
        # for an operation that wrote nothing.
        if (Test-ManagerResultIndicatesFailure -Result $result) {
            exit 1
        }
    }
    else {
        Show-ManagerGui -ScriptDir $scriptDirForRun -ProgramDir $ProgramDir -DataDir $DataDir -ManagerScriptPath $ManagerScriptPath
    }
}
