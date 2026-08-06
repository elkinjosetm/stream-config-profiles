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

.PARAMETER SkipLogon
    register-watchdog only: skip registering the logon/unlock task (poll-only).
    Declared here as a plain switch with the ordinary default ($false) --
    unlike the -IncludeLogon parameter this replaces, that default needs no
    special pleading: this is THE parameter that crosses the elevation
    boundary (Invoke-Elevated relaunches this exact script via
    powershell.exe/pwsh -File), and -File cannot bind an explicit
    -Name:$true/-Name:$false token to a switch parameter -- the literal
    "$true"/"$false" text arrives unevaluated and fails to convert to
    SwitchParameter (see ConvertTo-ElevatedArgumentString: every switch
    crossing that boundary is rendered as a bare -Name for true or omitted
    entirely for false). Presence/absence of a default-$false switch is the
    one shape -File binds identically on Windows PowerShell 5.1 and pwsh
    7+: absent -> Logon included (the ergonomic default, matching every
    existing headless caller); present -> poll-only. There is no
    ContainsKey defaulting trick needed anywhere for this parameter -- "not
    passed" and "declared default" are the same value by construction, so
    there is nothing for a host-specific -File binding quirk to disagree
    about. (This replaces a former top-level -IncludeLogon switch, default
    $false for the same -File reason, whose "omitted still means Logon
    included" ergonomic had to be restored one layer up in
    Invoke-ManagerAction via $PSBoundParameters.ContainsKey('IncludeLogon');
    that mechanism was the suspected carrier of a real-world Windows
    PowerShell 5.1-only field failure where a poll-only elevated retry's
    declined Logon task was silently re-registered anyway -- see
    Invoke-ManagerAction's own -IncludeLogon parameter and the bottom CLI
    dispatch for the one-time SkipLogon-to-IncludeLogon conversion that
    replaces it.) The CLI dispatch at the bottom of this file converts
    -SkipLogon to Invoke-ManagerAction's own -IncludeLogon (IncludeLogon =
    -not $SkipLogon) and forwards it explicitly bound, so
    Invoke-ManagerAction never needs to distinguish "caller said nothing"
    from "caller said false" for its own -IncludeLogon at all. Registering
    the Logon task is the operation that can prompt Windows for
    administrator approval (logon-type scheduled-task triggers require
    elevation to REGISTER even when the task's own principal is the calling
    user) -- pass -SkipLogon (bare; presence always means true for a
    switch) to avoid that. register-watchdog is a full desired-state
    reconciler, though: passing -SkipLogon also REMOVES an
    already-registered Logon task in the same call, so a poll-only call is
    not guaranteed to be prompt-free if that removal is itself denied (e.g.
    the Logon task was registered admin-owned by an earlier elevated
    retry).

.PARAMETER IncludePoll
    register-watchdog only: also register the periodic poll task (off by
    default). The poll task uses a time/repetition trigger, which never
    needs elevation to register.

.PARAMETER PollMinutes
    register-watchdog only: poll interval in minutes when -IncludePoll is
    set. Clamped to a minimum of 5.

.PARAMETER RemoveData
    uninstall only: also delete the DATA directory (profiles, paths.txt,
    state.json, sync.log). Without it, DATA is left in place -- it holds
    the user's configured paths and per-client profiles.

.PARAMETER DesktopDir
    uninstall only: overrides the Desktop folder whose "Stream Config
    Profiles.lnk" shortcut (if any) is removed. Defaults to
    [Environment]::GetFolderPath('Desktop'). The GUI always passes this
    explicitly when relaunching itself elevated, resolved once in the
    original unelevated process, for the same over-the-shoulder-admin
    reason -UserId is.

.PARAMETER ProgramsDir
    uninstall only: overrides the Start Menu Programs folder whose
    shortcut is removed. Defaults to [Environment]::GetFolderPath('Programs').

.PARAMETER AddStartMenuShortcut
    install only: also create a "Stream Config Profiles" Start Menu
    shortcut for manager.ps1. Off by default headlessly (the GUI wizard's
    own Start Menu checkbox defaults checked instead -- see
    Show-WizardDoneStep).

.PARAMETER AddDesktopShortcut
    install only: also create a "Stream Config Profiles" Desktop shortcut
    for manager.ps1. Off by default, same as the GUI wizard's Desktop
    checkbox.

.PARAMETER ManagerScriptPath
    Overrides the path copied into PROGRAM\manager.ps1 by Install-App, and
    the path re-launched by Invoke-Elevated. Defaults to $PSCommandPath.

.PARAMETER UserId
    register-watchdog only: the account the Logon/Poll tasks run as.
    Defaults to a SID resolved from the current process when omitted (see
    Get-ResolvedUserId), falling back to "DOMAIN\User"/$env:USERNAME where
    a SID isn't available. The GUI always passes this explicitly when
    relaunching itself elevated, so the elevated child never re-derives it
    from its own identity -- which matters when that elevated child is a
    DIFFERENT account than the one that launched the GUI (an
    over-the-shoulder admin approval), not when the GUI itself was already
    launched elevated to begin with.

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

    # Plain switch, ordinary default ($false) -- see the .PARAMETER
    # SkipLogon comment above: THE parameter that crosses the elevation
    # boundary (-File). Absent -> Logon included; present -> poll-only.
    # The bottom CLI dispatch converts this once (IncludeLogon = -not
    # $SkipLogon) before calling Invoke-ManagerAction.
    [switch]$SkipLogon,
    [switch]$IncludePoll,
    [int]$PollMinutes = 15,

    [switch]$RemoveData,

    # uninstall only: overrides for the Desktop/Start Menu folders whose
    # shortcut file gets removed. Resolved from [Environment]::GetFolderPath
    # when omitted -- see Get-ResolvedDesktopDir/Get-ResolvedProgramsDir.
    [string]$DesktopDir,
    [string]$ProgramsDir,

    # install only: create the Start Menu and/or Desktop .lnk shortcut for
    # manager.ps1. Both default off headlessly -- see the matching
    # parameter on Invoke-ManagerAction for why -- the GUI wizard's own
    # Start Menu checkbox default (checked) lives in Show-WizardDoneStep,
    # not here.
    [switch]$AddStartMenuShortcut,
    [switch]$AddDesktopShortcut,

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

function Get-ResolvedDesktopDir {
    # Same explicit-param-wins-else-default shape as every other resolver
    # here. Threaded through Invoke-ManagerAction's 'uninstall' branch so
    # an elevated re-entry (see Invoke-Elevated) uses the Desktop folder
    # resolved once in the ORIGINAL unelevated process, never re-derived
    # inside the elevated child -- the same over-the-shoulder-admin hazard
    # -UserId already guards against, applied to shortcut removal.
    param([string]$DesktopDir)
    if (-not [string]::IsNullOrWhiteSpace($DesktopDir)) {
        return $DesktopDir
    }
    return [Environment]::GetFolderPath('Desktop')
}

function Get-ResolvedProgramsDir {
    param([string]$ProgramsDir)
    if (-not [string]::IsNullOrWhiteSpace($ProgramsDir)) {
        return $ProgramsDir
    }
    return [Environment]::GetFolderPath('Programs')
}

function Get-ResolvedConfPath {
    param([string]$ConfPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfPath)) {
        return $ConfPath
    }
    return Find-HostConf
}

function Get-CurrentWindowsUserSid {
    # Isolated wrapper around WindowsIdentity.GetCurrent() -- kept as its
    # own tiny function, exactly like the ScheduledTasks/Start-Process
    # wrappers elsewhere in this file, so a test harness running under pwsh
    # on Linux (where a SID is never available anyway) can ALSO redefine
    # this one to deterministically force the "no SID available" branch of
    # Get-ResolvedUserId on a real Windows CI runner -- where a SID is
    # always genuinely available and the natural (non-shimmed) code path
    # can therefore never exercise that branch at all. Returns $null/empty
    # on any failure (not on Windows, or WindowsIdentity unavailable here);
    # never throws.
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if (-not [string]::IsNullOrWhiteSpace($sid)) {
            return $sid
        }
    }
    catch {
        # Not on Windows, or WindowsIdentity unavailable here -- fall
        # through to returning $null below, exactly as if no SID were
        # available.
    }
    return $null
}

function Get-ResolvedUserId {
    # The only place the CALLING process's own identity is read for
    # watchdog-principal purposes (see the architecture note on
    # Register-WatchdogTask): every Core function above it takes UserId as
    # an explicit parameter so tests can drive it deterministically and so
    # an over-the-shoulder elevation by a different admin account can't
    # silently register a user-level task under the wrong identity picked
    # up deep inside the call stack.
    #
    # Prefers an unambiguous SID (New-ScheduledTaskPrincipal/the
    # session-unlock trigger's -UserId both accept one directly) over a
    # bare name: a bare $env:USERNAME is ambiguous on a domain-joined
    # machine, or wherever a local account happens to share a name with a
    # domain account -- Task Scheduler resolves that bare name itself, in
    # whatever context ends up registering the task (including an elevated
    # child, or Task Scheduler's own service context), which can silently
    # bind a different principal than the interactive user this resolver
    # exists to pin down. "DOMAIN\User" is the fallback when a SID can't be
    # obtained (also accepted by both APIs); a bare name is the last resort
    # for a non-Windows/no-domain-info environment (e.g. this test harness).
    param([string]$UserId)
    if (-not [string]::IsNullOrWhiteSpace($UserId)) {
        return $UserId
    }
    $sid = Get-CurrentWindowsUserSid
    if (-not [string]::IsNullOrWhiteSpace($sid)) {
        return $sid
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN) -and -not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        return "$env:USERDOMAIN\$env:USERNAME"
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
# Shortcuts (Start Menu / Desktop)
#
# Get-ManagerShortcutDefinition is pure logic (no COM, no Windows
# dependency) so it is unit-testable directly on any platform -- the
# interesting part to get right is the target executable, argument
# quoting, and working directory a shortcut should carry, not the .lnk
# file format itself. New-ShortcutFile is the one function in this file
# that actually talks to WScript.Shell COM automation (Windows-only,
# unavailable on this Linux test host) -- isolated exactly like the
# watchdog/elevation cmdlet wrappers above so a test harness can redefine
# it (dot-source override, same scope) to record calls instead of
# touching real COM. Deleting a shortcut needs no COM at all, so
# Remove-ManagerShortcutFile is a real (never shimmed) Remove-Item wrapper
# that tests can exercise directly against a sandboxed path.
# ---------------------------------------------------------------------------

function Get-ManagerShortcutDefinition {
    # The target/arguments/working-directory a "Stream Config Profiles"
    # shortcut should carry, given PROGRAM (the folder Install-App copies
    # manager.ps1 into). Always launches via the real Windows PowerShell
    # 5.1 executable -- see Get-WindowsPowerShellExePath's own comment on
    # why never a bare "powershell.exe" -- with -NoProfile
    # -ExecutionPolicy Bypass -File "<PROGRAM>\manager.ps1", the no-arg GUI
    # entry point.
    param(
        [Parameter(Mandatory = $true)][string]$ProgramDir,
        [string]$SystemRoot = $env:SystemRoot
    )
    $managerPath = Join-Path $ProgramDir 'manager.ps1'
    $exe = Get-WindowsPowerShellExePath -SystemRoot $SystemRoot
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-QuotedCommandLineArgument -Value $managerPath)
    return [PSCustomObject]@{
        Name             = 'Stream Config Profiles'
        TargetPath       = $exe
        Arguments        = $arguments
        WorkingDirectory = $ProgramDir
    }
}

function Get-ManagerShortcutPaths {
    # The two well-known shortcut file paths this app ever creates/removes,
    # given the parent folder each lives in. Parent folders are explicit
    # parameters (not read internally), consistent with every other path
    # resolver in this file, so tests can point this at sandbox
    # directories -- and so a location whose folder is unavailable on this
    # platform (e.g. [Environment]::GetFolderPath('Desktop') returns an
    # empty string on this Linux test host) degrades to $null rather than
    # building a bogus relative path.
    param(
        [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
        [string]$ProgramsDir = [Environment]::GetFolderPath('Programs')
    )
    $desktopPath = $null
    if (-not [string]::IsNullOrWhiteSpace($DesktopDir)) {
        $desktopPath = Join-Path $DesktopDir 'Stream Config Profiles.lnk'
    }
    $startMenuPath = $null
    if (-not [string]::IsNullOrWhiteSpace($ProgramsDir)) {
        $startMenuPath = Join-Path $ProgramsDir 'Stream Config Profiles.lnk'
    }
    return [PSCustomObject]@{
        Desktop   = $desktopPath
        StartMenu = $startMenuPath
    }
}

function New-ShortcutFile {
    # Isolated wrapper around WScript.Shell COM automation -- the only
    # function in this file that creates a .lnk file. Windows-only and
    # unavailable in this Linux test harness, so tests redefine this
    # function (dot-source override, same scope, exactly like the
    # watchdog cmdlet wrappers) to record calls instead of touching real
    # COM.
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)]$Definition
    )
    $dir = Split-Path -Path $ShortcutPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $Definition.TargetPath
    $shortcut.Arguments = $Definition.Arguments
    $shortcut.WorkingDirectory = $Definition.WorkingDirectory
    $shortcut.Save()
}

function Remove-ManagerShortcutFile {
    # Isolated wrapper for deleting one shortcut file. Kept separate from
    # New-ShortcutFile (not folded into a shared "shortcut cmdlet"
    # wrapper) specifically so tests can shim JUST the COM-dependent
    # creation side while still exercising a REAL delete against a
    # sandboxed path -- Remove-Item needs no COM and behaves identically
    # on every platform.
    param([Parameter(Mandatory = $true)][string]$ShortcutPath)
    if (Test-Path -LiteralPath $ShortcutPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force
    }
}

function New-ManagerShortcut {
    # Creates the requested shortcut(s) (Start Menu on by default, Desktop
    # opt-in) for PROGRAM\manager.ps1. Best-effort per location: a failure
    # creating one (e.g. a locked/read-only Start Menu folder) is reported
    # in that location's own result, not thrown, so it never blocks the
    # other location the user did want.
    param(
        [Parameter(Mandatory = $true)][string]$ProgramDir,
        [switch]$StartMenu = $true,
        [switch]$Desktop,
        [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
        [string]$ProgramsDir = [Environment]::GetFolderPath('Programs')
    )

    $definition = Get-ManagerShortcutDefinition -ProgramDir $ProgramDir
    $paths = Get-ManagerShortcutPaths -DesktopDir $DesktopDir -ProgramsDir $ProgramsDir
    $results = New-Object System.Collections.Generic.List[object]

    if ($StartMenu) {
        if ([string]::IsNullOrWhiteSpace($paths.StartMenu)) {
            $results.Add([PSCustomObject]@{ Location = 'StartMenu'; Path = $null; Success = $false; Message = 'Programs folder is unavailable on this system' })
        }
        else {
            try {
                New-ShortcutFile -ShortcutPath $paths.StartMenu -Definition $definition
                $results.Add([PSCustomObject]@{ Location = 'StartMenu'; Path = $paths.StartMenu; Success = $true; Message = 'created' })
            }
            catch {
                $results.Add([PSCustomObject]@{ Location = 'StartMenu'; Path = $paths.StartMenu; Success = $false; Message = $_.Exception.Message })
            }
        }
    }

    if ($Desktop) {
        if ([string]::IsNullOrWhiteSpace($paths.Desktop)) {
            $results.Add([PSCustomObject]@{ Location = 'Desktop'; Path = $null; Success = $false; Message = 'Desktop folder is unavailable on this system' })
        }
        else {
            try {
                New-ShortcutFile -ShortcutPath $paths.Desktop -Definition $definition
                $results.Add([PSCustomObject]@{ Location = 'Desktop'; Path = $paths.Desktop; Success = $true; Message = 'created' })
            }
            catch {
                $results.Add([PSCustomObject]@{ Location = 'Desktop'; Path = $paths.Desktop; Success = $false; Message = $_.Exception.Message })
            }
        }
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Vibepollo/Apollo conf discovery
# ---------------------------------------------------------------------------

function Get-HostConfRoots {
    # Every Program Files root worth probing, in order, de-duplicated
    # (case-insensitively -- two of these routinely point at the identical
    # path). ProgramW6432 is the field fix here: Windows PowerShell 5.1
    # launched as a 32-bit (WOW64) process on 64-bit Windows sees
    # $env:ProgramFiles pointing at "...\Program Files (x86)" --
    # ProgramW6432 is the environment variable WOW64 does NOT redirect, so
    # it still names the TRUE 64-bit Program Files in that case, which is
    # exactly where a 64-bit Vibepollo/Apollo install actually lives. This
    # is what the field host's install was missing before this fix: its
    # conf sat under the real (64-bit) Program Files, invisible to a
    # 32-bit-process $env:ProgramFiles lookup.
    $roots = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    # ProgramW6432 FIRST, not last: on a 64-bit machine it always names the
    # true 64-bit Program Files, whether or not THIS process happens to be
    # WOW64 -- so probing it first is a no-op for a normal 64-bit process
    # (it dedupes against $env:ProgramFiles below) but is the difference
    # between finding and missing a real 64-bit install for a 32-bit
    # process, where $env:ProgramFiles ITSELF already points at
    # "...\Program Files (x86)" (the exact WOW64 redirection this root list
    # exists to see past). Checking $env:ProgramFiles first would probe
    # that x86 alias before the true 64-bit root every time, silently
    # preferring a stale/decoy x86 install over the real one whenever both
    # exist -- putting ProgramW6432 first is what actually delivers the
    # field fix the comment below describes, rather than merely listing
    # the right root somewhere in the set.
    $ordered = @($env:ProgramW6432, $env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))
    foreach ($candidate in $ordered) {
        if ([string]::IsNullOrEmpty($candidate)) {
            continue
        }
        if ($seen.Add($candidate)) {
            $roots.Add($candidate)
        }
    }
    return $roots.ToArray()
}

function Get-HostConfCandidatePaths {
    # Common install locations for Vibepollo/Apollo/Sunshine's config file
    # under every root Get-HostConfRoots knows about. Order matters: first
    # existing candidate wins in Find-HostConf.
    $roots = Get-HostConfRoots

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

function Find-HostConfByWildcard {
    # Fallback used by Find-HostConf once every known-name candidate has
    # come up empty: scans every <root>\<appDir>\config directory that
    # actually exists for *.conf files by wildcard, rather than giving up
    # entirely on an install that renamed or customized its conf filename.
    # A single match anywhere wins outright. With multiple matches, a KNOWN
    # name (vibepollo.conf/apollo.conf/sunshine.conf, case-insensitively --
    # PowerShell's -contains is case-insensitive by default) is preferred
    # over an unrecognized one; ties within (or without) that preference
    # are broken by newest LastWriteTime. This is a best GUESS, never a
    # silent commitment: the wizard's conf field stays editable with a
    # Browse button regardless, so a wrong pick here is always correctable
    # by the user.
    #
    # Reachability note: as called from Find-HostConf, the known-name
    # preference branch below can never actually see a known-name match.
    # Find-HostConf's static pass already Test-Path's every
    # <root>/<appDir>/config/<knownName> combination this function would
    # also scan (both for -Roots and -ExtraConfigDirs -- see
    # Get-HostConfCandidatePaths and the service-derived candidates in
    # Find-HostConf) and returns on the first hit, so by the time control
    # reaches here none of those exact combinations can exist on disk. The
    # preference is real, tested, and load-bearing for any OTHER caller
    # (e.g. a future entry point that hands this function roots the static
    # pass never covered) -- it is just provably dead code on the one
    # production call path today. Left in deliberately rather than
    # removed: the newest-wins-only fallback it guards against is a worse
    # default the moment such a caller shows up.
    param(
        # AllowEmptyCollection: a Mandatory array parameter otherwise
        # rejects an EMPTY array outright ("Cannot bind argument ... it is
        # an empty array") -- a real, legitimate input here on any host
        # with no Program Files roots found at all (every non-Windows test
        # host, and a real Windows host with a non-standard environment).
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Roots,
        [string[]]$AppDirNames = @('Vibepollo', 'Apollo', 'Sunshine'),
        [string[]]$KnownConfFileNames = @('vibepollo.conf', 'apollo.conf', 'sunshine.conf'),
        # Extra directories to scan directly for *.conf, alongside the
        # <root>/<appDir>/config combinations built from -Roots/-AppDirNames.
        # Used by Find-HostConf to extend the wildcard fallback to a
        # matching service's own binary directory (and its config\
        # subfolder) -- a custom-location install (e.g. D:\Games\Apollo)
        # with a renamed conf is otherwise undiscoverable even though the
        # service's binary path is already known.
        [string[]]$ExtraConfigDirs = @()
    )

    $found = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        foreach ($appDir in $AppDirNames) {
            $configDir = Join-Path (Join-Path $root $appDir) 'config'
            if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
                continue
            }
            foreach ($file in @(Get-ChildItem -LiteralPath $configDir -Filter '*.conf' -File -ErrorAction SilentlyContinue)) {
                $found.Add($file)
            }
        }
    }
    foreach ($extraDir in $ExtraConfigDirs) {
        if ([string]::IsNullOrWhiteSpace($extraDir)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $extraDir -PathType Container)) {
            continue
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $extraDir -Filter '*.conf' -File -ErrorAction SilentlyContinue)) {
            $found.Add($file)
        }
    }

    if ($found.Count -eq 0) {
        return $null
    }
    if ($found.Count -eq 1) {
        return $found[0].FullName
    }

    $pool = $found
    $knownMatches = @($found | Where-Object { $KnownConfFileNames -contains $_.Name })
    if (@($knownMatches).Count -gt 0) {
        $pool = $knownMatches
    }

    $newest = @($pool | Sort-Object -Property LastWriteTime -Descending)[0]
    return $newest.FullName
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
    # locations first (unchanged, deterministic -- see
    # Get-HostConfCandidatePaths/Get-HostConfRoots), then a config\*.conf
    # sibling of any matching service's binary directory, then -- only if
    # every one of those came up empty -- a wildcard scan of every existing
    # <root>\<appDir>\config directory for ANY *.conf file (see
    # Find-HostConfByWildcard), for an install that renamed/customized its
    # conf filename away from the three known names. Returns $null if
    # nothing is found by any of that.
    param([string[]]$ExtraCandidates = @())

    $namePatterns = @('*vibepollo*', '*apollo*', '*sunshine*')
    $appDirNames = @('Vibepollo', 'Apollo', 'Sunshine')
    $confFileNames = @('vibepollo.conf', 'apollo.conf', 'sunshine.conf')

    $serviceDirs = @(Get-HostServiceBinaryDir -NamePatterns $namePatterns)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($c in (Get-HostConfCandidatePaths)) {
        $candidates.Add($c)
    }
    $extraConfigDirs = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $serviceDirs) {
        foreach ($confName in $confFileNames) {
            $candidates.Add((Join-Path $dir $confName))
            $candidates.Add((Join-Path (Join-Path $dir 'config') $confName))
        }
        # Same two directories the static pass above just probed for known
        # names, offered again to the wildcard fallback below so a
        # custom-location install with a RENAMED conf is still
        # discoverable -- the static pass alone only ever tries the three
        # known filenames.
        $extraConfigDirs.Add($dir)
        $extraConfigDirs.Add((Join-Path $dir 'config'))
    }
    foreach ($c in $ExtraCandidates) {
        $candidates.Add($c)
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    # @(...) around the call, not just parens: Get-HostConfRoots' own
    # return-an-empty-array collapses to $null across a bare function-call
    # boundary in PowerShell (a well-known zero-element-array-unrolling
    # quirk), which would otherwise fail to bind to Roots' mandatory
    # string[] parameter on any host with no Program Files roots set at
    # all (every non-Windows test host). @() forces array context so an
    # empty result stays an empty array, not $null.
    $wildcardMatch = Find-HostConfByWildcard -Roots @(Get-HostConfRoots) -AppDirNames $appDirNames -KnownConfFileNames $confFileNames -ExtraConfigDirs @($extraConfigDirs.ToArray())
    if (-not [string]::IsNullOrWhiteSpace($wildcardMatch)) {
        return $wildcardMatch
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

function Test-AnyAncestorIsReparsePoint {
    # True if any PARENT directory of Path (not Path itself -- see
    # Test-IsReparsePoint for the leaf check) is a reparse point
    # (junction/symlink). Get-Item on the final leaf transparently
    # resolves through a reparse point sitting on one of its ANCESTORS, so
    # Test-IsReparsePoint's leaf-only check reports "not a reparse point"
    # for a perfectly ordinary conf file whose containing folder (or any
    # folder above it) is itself a junction planted by an unprivileged
    # user -- exactly the admin-level arbitrary-file-write primitive
    # Test-IsReparsePoint's own comment describes, just one directory
    # level up from where that check looks. Called alongside
    # Test-IsReparsePoint, never instead of it.
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = $null
    try {
        $current = Split-Path -Path $Path -Parent
    }
    catch {
        return $false
    }

    # HashSet guards against a pathological Split-Path loop (e.g. a
    # relative or malformed path that never reaches an empty parent)
    # turning this into an infinite loop.
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    while (-not [string]::IsNullOrEmpty($current)) {
        if (-not $seen.Add($current)) {
            break
        }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                return $true
            }
        }
        $parent = $null
        try {
            $parent = Split-Path -Path $current -Parent
        }
        catch {
            break
        }
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
    return $false
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
    if (Test-AnyAncestorIsReparsePoint -Path $ConfPath) {
        throw "New-ConfBackup: refusing to read through a reparse point (symlink/junction) in a parent directory of $ConfPath"
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
    if (Test-AnyAncestorIsReparsePoint -Path $ConfPath) {
        throw "Write-ConfGlobalPrepCmd: refusing to write through a reparse point (symlink/junction) in a parent directory of $ConfPath"
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

function Get-VibepolloConnectionStatus {
    # Headless computation of what the Main Window's Vibepollo/Apollo
    # status line should say, given a (possibly blank/$null) already-known
    # conf path and DataDir. Show-MainWindow's Sync-VibepolloStatus (GUI-
    # only, cannot run on this Linux test harness -- it touches WinForms
    # controls directly) is a thin renderer around this: it resolves
    # ConfPath (preferring a tracked "this session actually connected to"
    # path over a fresh Find-HostConf guess -- see $vibepolloConnection in
    # Show-MainWindow) and hands the result here. Extracted specifically
    # so the not-found / malformed-conf / connected / not-connected
    # branches are unit-testable directly, without any WinForms dependency
    # -- before this, Sync-VibepolloStatus's logic had zero functional
    # test coverage (only a source-regex check that the function existed
    # at all).
    #
    # State is one of 'NotFound' (no conf path known/found at all),
    # 'Unreadable' (the conf exists but Get-PrepCommandEntries could not
    # parse it -- malformed global_prep_cmd JSON, or it vanished between
    # detection and read), 'Connected', or 'NotConnected'.
    param(
        [string]$ConfPath,
        [Parameter(Mandatory = $true)][string]$DataDir
    )

    if ([string]::IsNullOrWhiteSpace($ConfPath)) {
        return [PSCustomObject]@{
            State    = 'NotFound'
            ConfPath = $null
            Text     = 'Not connected -- no Vibepollo/Apollo/Sunshine conf file was found automatically. Use Connect/Reconnect... to browse to it manually.'
        }
    }

    $entriesOutcome = Get-PrepCommandEntries -ConfPath $ConfPath
    if (-not $entriesOutcome.Success) {
        # Distinct from 'NotConnected': the conf file IS there, but it
        # could not be parsed -- collapsing this into "Not connected"
        # previously sent the user straight into a raw parse-error dialog
        # on Connect with no warning the conf itself was the problem.
        return [PSCustomObject]@{
            State    = 'Unreadable'
            ConfPath = $ConfPath
            Text     = "Conf found but unreadable ($($entriesOutcome.Message)): $ConfPath"
        }
    }

    $enginePath = Get-EngineIdentifierPath -DataDir $DataDir
    $ours = @($entriesOutcome.Entries | Where-Object { Test-PrepCommandEntryIsOurs -Entry $_ -EnginePath $enginePath })
    $isConnected = (@($ours).Count -gt 0)

    $statusWord = 'Not connected'
    $state = 'NotConnected'
    if ($isConnected) {
        $statusWord = 'Connected'
        $state = 'Connected'
    }
    return [PSCustomObject]@{
        State    = $state
        ConfPath = $ConfPath
        Text     = "${statusWord}: $ConfPath"
    }
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
    if ($DataDir.IndexOf('"') -ge 0) {
        # Same hazard Add-PrepCommandEntry already guards against: DataDir
        # is embedded, unescaped, inside a double-quoted -File "..."
        # fragment that becomes this scheduled task's own argument string.
        # An embedded quote would close that argument early and splice
        # extra tokens into the registered task's command line.
        throw "Get-SettleAction: DataDir must not contain a double-quote character: $DataDir"
    }
    $enginePath = Join-Path $DataDir 'sync-configs.ps1'
    return 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $enginePath + '" -Mode settle'
}

function Get-WatchdogTaskDefinitions {
    # Returns the set of watchdog task definitions that should exist given
    # the requested options. StreamConfigProfiles-Settle-Logon is included
    # unless the caller explicitly passes -IncludeLogon:$false (default ON:
    # every headless caller that doesn't say otherwise still gets it). Poll
    # is opt-in via -IncludePoll (defaults OFF per spec). PollMinutes is
    # clamped to a minimum of 5.
    #
    # NeedsAdmin here is about each task's own RunLevel/principal at RUN
    # TIME, not about whether Register-ScheduledTask needs elevation to
    # create it: both tasks run as the resolved UserId at Limited RunLevel,
    # never as an elevated principal. The two are genuinely different axes
    # on real Windows -- registering the Logon task (AtLogOn + a
    # session-unlock trigger) needs administrator approval even though the
    # principal being registered is the calling user themself; the Poll
    # task's time/repetition trigger does not. See Register-Watchdog /
    # Invoke-GuiElevatable for how the REGISTRATION step (not the
    # principal) handles that.
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
    # over-the-shoulder elevation by a different admin).
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$UserId,
        [switch]$IncludeLogon = $true,
        [switch]$IncludePoll,
        [int]$PollMinutes = 15
    )

    $action = Get-SettleAction -DataDir $DataDir
    $defs = New-Object System.Collections.Generic.List[object]

    if ($IncludeLogon) {
        $defs.Add([PSCustomObject]@{
            Name        = 'StreamConfigProfiles-Settle-Logon'
            Triggers    = @('AtLogOn', 'OnUnlock')
            Action      = $action
            NeedsAdmin  = $false
            LogonType   = 'Interactive'
            UserId      = $UserId
            PollMinutes = $null
        })
    }

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
    # Every task this registers RUNS as user-level (Interactive LogonType,
    # the resolved caller's own UserId, Limited RunLevel) -- see
    # Get-WatchdogTaskDefinitions. That is a runtime-principal guarantee,
    # not an elevation guarantee: on real Windows, Register-ScheduledTask
    # itself needs administrator approval to REGISTER a logon-type trigger
    # (AtLogOn / session-unlock) even though the principal being registered
    # is the calling user, so a per-task Success=$false below for the Logon
    # task is expected to happen unelevated and is the GUI's cue (via
    # Invoke-GuiElevatable) to retry elevated -- see the call sites in
    # #region Gui. The Poll task's time/repetition trigger never needs
    # elevation to register, which is why -IncludeLogon:$false (poll-only)
    # is guaranteed to succeed without ever prompting for admin.
    #
    # This is a full DESIRED-STATE reconciler, not an add-only function: any
    # well-known task NOT requested (IncludeLogon:$false / no -IncludePoll)
    # is also unregistered here, in the SAME call, if it happens to already
    # exist from a previous configuration. This used to be a separate,
    # unelevated Invoke-GuiSafe delete at each #region Gui call site --
    # harmless while registration itself never needed elevation, but once a
    # task can end up admin-owned (registered by an elevated retry), that
    # separate unelevated delete fails with the same access-denied and had
    # no retry path of its own. Folding both directions into one call means
    # the single Invoke-GuiElevatable wrapper around Register-Watchdog
    # covers add AND remove with one confirm-and-elevate retry.
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$UserId,
        [switch]$IncludeLogon = $true,
        [switch]$IncludePoll,
        [int]$PollMinutes = 15
    )

    $defs = Get-WatchdogTaskDefinitions -DataDir $DataDir -UserId $UserId -IncludeLogon:$IncludeLogon -IncludePoll:$IncludePoll -PollMinutes $PollMinutes
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

    # Reconcile the other direction: a well-known task not in the desired
    # set above is removed here rather than left stale (unless it never
    # existed, in which case Unregister-WatchdogTask is a no-op). This does
    # NOT register-then-immediately-unregister anything -- an undesired
    # task is never added to $defs in the first place, so this never
    # attempts (and never needs to elevate for) a registration the caller
    # didn't ask for.
    $desiredNames = @($defs | ForEach-Object { $_.Name })
    $allWellKnownTaskNames = @('StreamConfigProfiles-Settle-Logon', 'StreamConfigProfiles-Settle-Poll')
    foreach ($name in $allWellKnownTaskNames) {
        if ($desiredNames -contains $name) {
            continue
        }
        try {
            Unregister-WatchdogTask -Name $name
            $results.Add([PSCustomObject]@{ Name = $name; Success = $true; Message = 'unregistered (not requested)' })
        }
        catch {
            $results.Add([PSCustomObject]@{ Name = $name; Success = $false; Message = $_.Exception.Message })
        }
    }

    return $results.ToArray()
}

function Unregister-Watchdog {
    # Removes the current (user-level) watchdog task set -- Logon, Poll.
    # Deleting a task you own does not generally need elevation the way
    # registering a logon-type trigger does (see Register-Watchdog), but a
    # real failure here is still surfaced as Success=$false like any other
    # task result rather than assumed away -- the GUI call sites route this
    # through Invoke-GuiElevatable too, so an unexpected access-denied here
    # (a task an admin registered under a different account, an ACL
    # oddity, ...) still gets the same confirm-and-elevate retry instead of
    # a dead end.
    #
    # Also best-effort-removes the legacy 'StreamConfigProfiles-Settle-Boot'
    # task for anyone who installed the interim build that registered an
    # admin-level AtStartup task (see the architecture note on
    # Get-WatchdogTaskDefinitions for why this product no longer has one).
    # That legacy task can only be deleted by an elevated process; failing
    # to remove it here (running unelevated) is expected, not an error --
    # that specific best-effort cleanup is always reported as Success=$true
    # regardless of whether the underlying delete actually worked, so it
    # alone never triggers an elevation retry.
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
    # service, removes both shortcuts if present, and removes PROGRAM.
    # DATA (profiles\, paths.txt, state.json, sync.log) is left in place
    # unless -RemoveData is passed -- it holds the user's own data, not
    # just installed program files.
    param(
        [Parameter(Mandatory = $true)][string]$ProgramDir,
        [Parameter(Mandatory = $true)][string]$DataDir,
        [string]$ConfPath,
        [switch]$RemoveData,
        [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
        [string]$ProgramsDir = [Environment]::GetFolderPath('Programs')
    )

    $summary = [PSCustomObject]@{
        Success                 = $true
        WatchdogUnregistered    = $null
        ConfEntryRemoved        = $null
        ServiceRestart          = $null
        ShortcutsRemoved        = $null
        ProgramDirRemoved       = $false
        ProgramDirSkipReason    = $null
        DataDirRemoved          = $false
        DataDirSkipReason       = $null
    }

    # Move this process's own current directory away from ProgramDir/
    # DataDir BEFORE any recursive delete below. Windows refuses to remove
    # a directory that is any process's current directory
    # (ERROR_SHARING_VIOLATION -- .NET surfaces this as an IOException
    # whose message, "The process cannot access the file because it is
    # being used by another process.", does not look access-denied-shaped
    # to Test-GuiLooksLikeAccessDenied, so no elevated retry gets offered
    # either), and this is not merely theoretical: the Start Menu/Desktop
    # shortcut this app creates (see Get-ManagerShortcutDefinition) sets
    # WorkingDirectory to PROGRAM, so a manager.ps1 launched from that
    # shortcut already has its own CWD sitting exactly where -Recurse is
    # about to delete. Best-effort and cheap insurance regardless of how
    # this process was launched -- every path this function uses is
    # already absolute, so nothing here depends on the process's own
    # current directory.
    try {
        Set-Location -LiteralPath ([System.IO.Path]::GetTempPath()) -ErrorAction Stop
    }
    catch {
        # If even this fails (the temp directory should always exist),
        # the deletes below simply take their chances exactly as before.
    }

    $summary.WatchdogUnregistered = Unregister-Watchdog

    if (-not [string]::IsNullOrWhiteSpace($ConfPath) -and (Test-Path -LiteralPath $ConfPath)) {
        $summary.ConfEntryRemoved = Remove-PrepCommandEntry -ConfPath $ConfPath -DataDir $DataDir
    }

    # Surface a failed watchdog unregister at the TOP level. $summary
    # itself carried no Success property of its own before this, so
    # Test-ManagerResultIndicatesFailure (which only inspects the top level
    # of @($Result), by design -- see there) could not see a Success=$false
    # buried inside WatchdogUnregistered. Without this, the GUI showed the
    # unconditional "disconnected and uninstalled" success text, the
    # elevated CLI re-entry exited 0, and uninstall could never be judged
    # elevation-eligible -- all while an admin-owned Logon task kept firing
    # sync-configs.ps1 out of a DATA folder whose deletion PROGRAM had
    # already made irreversible.
    #
    # Deliberately scoped to WatchdogUnregistered only, NOT ConfEntryRemoved:
    # a failed conf edit (e.g. malformed existing JSON) is the same
    # business-logic failure register-vibepollo reports elsewhere -- retrying
    # elevated would not fix it, so it must stay a final Result-shaped
    # failure, not flip this into something Test-GuiWatchdogResultFailureIs-
    # ElevationEligible would offer to retry elevated.
    if (Test-ManagerResultIndicatesFailure -Result $summary.WatchdogUnregistered) {
        $summary.Success = $false
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
            $summary.ProgramDirSkipReason = "refusing to delete '$ProgramDir': it contains none of the expected marker files (manager.ps1)"
        }
    }

    if ($RemoveData -and (Test-Path -LiteralPath $DataDir)) {
        if (-not (Test-LooksLikeOurInstallDirectory -Path $DataDir -MarkerFileNames @('sync-configs.ps1', 'paths.txt', 'state.json'))) {
            $summary.DataDirSkipReason = "refusing to delete '$DataDir': it contains none of the expected marker files (sync-configs.ps1 / paths.txt / state.json)"
        }
        elseif (Test-AnyWatchdogTaskRegistered) {
            $summary.DataDirSkipReason = 'a StreamConfigProfiles-* scheduled task is still registered (its removal likely needs elevation); refusing to delete the data folder while an admin-level task could still be pointed at sync-configs.ps1 inside it -- retry uninstall elevated, or remove the remaining task(s) manually first'
        }
        else {
            Remove-Item -LiteralPath $DataDir -Recurse -Force
            $summary.DataDirRemoved = $true
        }
    }

    # Best-effort, logged: neither location existing/removing cleanly nor
    # a removal failure ever flips $summary.Success -- a leftover shortcut
    # is user-facing clutter, not the kind of dangling-privilege hazard
    # that a leftover admin-owned scheduled task is (see
    # Test-AnyWatchdogTaskRegistered), so it never gates the rest of
    # uninstall or offers an elevated retry.
    $shortcutPaths = Get-ManagerShortcutPaths -DesktopDir $DesktopDir -ProgramsDir $ProgramsDir
    $shortcutResults = New-Object System.Collections.Generic.List[object]
    foreach ($location in @('Desktop', 'StartMenu')) {
        $path = $shortcutPaths.$location
        if ([string]::IsNullOrWhiteSpace($path)) {
            $shortcutResults.Add([PSCustomObject]@{ Location = $location; Path = $null; Success = $true; Message = 'folder unavailable on this system; nothing to remove' })
            continue
        }
        try {
            $existed = Test-Path -LiteralPath $path
            Remove-ManagerShortcutFile -ShortcutPath $path
            $message = 'not present'
            if ($existed) {
                $message = 'removed'
            }
            $shortcutResults.Add([PSCustomObject]@{ Location = $location; Path = $path; Success = $true; Message = $message })
        }
        catch {
            $shortcutResults.Add([PSCustomObject]@{ Location = $location; Path = $path; Success = $false; Message = $_.Exception.Message })
        }
    }
    $summary.ShortcutsRemoved = $shortcutResults.ToArray()

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
            # Render a BARE -Name token for true, and OMIT the parameter
            # entirely for false -- never an explicit -Name:$true/-Name:
            # $false token. This used to render the explicit :$true/:$false
            # form on the theory that a bare-flag-for-true/omit-for-false
            # scheme was only "safe" by accident (relying on the CALLED
            # script's own declared default). That theory was correct as
            # far as it went, but the explicit-token form has a worse,
            # unconditional problem: powershell.exe/pwsh invoked with -File
            # (exactly how Invoke-Elevated always re-launches this script)
            # parses script arguments as LITERAL, unevaluated strings -- the
            # four/five characters "$true"/"$false" arrive as a bare
            # [string], and PowerShell's own parameter binder cannot convert
            # a [string] to [SwitchParameter], so EVERY explicit -Name:
            # $true/-Name:$false token fails elevation outright with
            # "Cannot process argument transformation ... Cannot convert
            # value "System.String" to type SwitchParameter" (the actual
            # field failure this guards against). A bare -Name (no colon,
            # no value) is exactly how a switch is normally supplied on any
            # command line and always binds to $true; omitting the
            # parameter always binds to whatever the RECEIVING script
            # declared as that switch's own default. For this scheme to be
            # sound, every switch that can cross this boundary MUST declare
            # a $false default at the receiving end. Every top-level switch
            # parameter of this script (including -SkipLogon -- see its own
            # comment) now genuinely defaults $false with no ergonomic
            # lie/restoration needed anywhere: -SkipLogon replaced a former
            # -IncludeLogon whose "omitted still means Logon included"
            # semantics used to require exactly that kind of restoration one
            # layer up (in Invoke-ManagerAction, via
            # $PSBoundParameters.ContainsKey), which was the suspected
            # carrier of a Windows PowerShell 5.1-only field failure.
            if ($value.IsPresent) {
                $argParts.Add('-' + $key)
            }
        }
        elseif ($value -is [bool]) {
            # Same -File string-literal hazard as [switch] above applies to
            # any [bool]-typed parameter that might cross this boundary --
            # there is no such parameter today (audited: every boundary
            # parameter is [switch], [string], or [int]), but if one is ever
            # added it must not silently regress to the broken :$true/
            # :$false form either. Bare-for-true/omit-for-false only works
            # here if the receiving parameter is also declared to default to
            # $false; there is deliberately no fallback branch that renders
            # an explicit boolean token.
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
    # elevation via Start-Process -Verb RunAs. Called for the specific
    # operations that can actually need admin: conf editing under Program
    # Files, host service restart, uninstall paths that touch protected
    # locations, and -- on real Windows -- register-watchdog/
    # unregister-watchdog, because registering a logon-type scheduled-task
    # trigger needs administrator approval even when the task's own
    # principal is the calling user (see Register-Watchdog). The GUI never
    # runs elevated wholesale; only this one re-entered -Action does.
    #
    # $Parameters MUST include an explicit -UserId for register-watchdog:
    # UserId is resolved once, in the ORIGINAL unelevated process (see
    # Get-ResolvedUserId), and threaded through here rather than re-derived
    # inside the elevated child -- an over-the-shoulder admin approval by a
    # DIFFERENT account must not register the task under that admin's
    # identity instead of the interactive user who asked for protection.
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
    #
    # -IncludeLogon is an ordinary in-process switch, default $true --
    # "omitted still means Logon included" for every caller that doesn't
    # say otherwise (tests, any future headless wrapper, and this file's own
    # bottom CLI dispatch). This function is NEVER itself relaunched via
    # -File -- only the top-level script parameters are (see -SkipLogon's
    # own comment) -- so there is no elevation-boundary reason for this
    # parameter to default to $false, and no need to distinguish "caller
    # passed -IncludeLogon:$false" from "caller omitted it" via
    # $PSBoundParameters the way an earlier version of this function (and
    # the top-level -IncludeLogon it used to mirror) had to. The bottom CLI
    # dispatch converts its own -SkipLogon to a plain boolean
    # (IncludeLogon = -not $SkipLogon) and forwards it here explicitly
    # bound, so this parameter's default is only ever consulted for a
    # direct in-process caller, exactly as intended.
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ScriptDir,
        [string]$ProgramDir,
        [string]$DataDir,
        [string]$ConfPath,
        [switch]$IncludeLogon = $true,
        [switch]$IncludePoll,
        [int]$PollMinutes = 15,
        [switch]$RemoveData,
        [string]$ManagerScriptPath,
        [string]$CommandPath,
        [string]$UserId,

        # uninstall only: same over-the-shoulder-admin hazard -UserId
        # already guards against, applied to shortcut removal -- resolved
        # once in the original unelevated GUI process and threaded through
        # explicitly (see Show-MainWindow's Disconnect/Uninstall handler)
        # so an elevated re-entry never re-derives these from whichever
        # account approved the elevation.
        [string]$DesktopDir,
        [string]$ProgramsDir,

        # install only: headless equivalent of the wizard Done step's two
        # shortcut checkboxes. Both default OFF here (unlike the wizard's
        # Start Menu checkbox, which defaults checked) so a plain headless
        # -Action install never touches Desktop/Start Menu unless
        # explicitly asked -- no surprise shortcut as a side effect of,
        # say, a test harness or CI dispatching 'install' with no opinion
        # on shortcuts at all.
        [switch]$AddStartMenuShortcut,
        [switch]$AddDesktopShortcut
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
            $installResult = Install-App -ProgramDir $resolvedProgramDir -DataDir $resolvedDataDir -ManagerScriptPath $resolvedManagerScriptPath -ScriptDir $ScriptDir
            if ($AddStartMenuShortcut -or $AddDesktopShortcut) {
                $shortcutResults = New-ManagerShortcut -ProgramDir $resolvedProgramDir -StartMenu:$AddStartMenuShortcut -Desktop:$AddDesktopShortcut
                $installResult | Add-Member -NotePropertyName 'ShortcutsCreated' -NotePropertyValue $shortcutResults
            }
            return $installResult
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
            # See this function's own header comment: -IncludeLogon's
            # ordinary $true default already gives every caller (direct or
            # via the bottom CLI dispatch's explicit forward) the right
            # value with no ContainsKey bookkeeping needed here.
            return Register-Watchdog -DataDir $resolvedDataDir -UserId $resolvedUserId -IncludeLogon:$IncludeLogon -IncludePoll:$IncludePoll -PollMinutes $PollMinutes
        }
        'unregister-watchdog' {
            return Unregister-Watchdog
        }
        'uninstall' {
            $resolvedConfPath = Get-ResolvedConfPath -ConfPath $ConfPath
            $resolvedDesktopDir = Get-ResolvedDesktopDir -DesktopDir $DesktopDir
            $resolvedProgramsDir = Get-ResolvedProgramsDir -ProgramsDir $ProgramsDir
            return Uninstall-App -ProgramDir $resolvedProgramDir -DataDir $resolvedDataDir -ConfPath $resolvedConfPath -RemoveData:$RemoveData -DesktopDir $resolvedDesktopDir -ProgramsDir $resolvedProgramsDir
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
# permissions problem -- conf file under Program Files, service restart, an
# uninstall path touching a protected location, or (on real Windows)
# register-watchdog/unregister-watchdog: registering a logon-type
# scheduled-task trigger needs administrator approval even though the
# task's own principal is always the calling user (see Register-Watchdog).
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
    # Detects an access-denied-shaped THROWN exception. Prefers
    # locale-independent signals -- the .NET exception type and the Win32
    # E_ACCESSDENIED HRESULT (0x80070005, which .NET surfaces as the signed
    # Int32 -2147024891) -- over message-text matching, because the actual
    # field failure this exists to catch surfaced as a LOCALIZED message
    # ("Acceso denegado", not "Access is denied"): a text-only check would
    # have silently never fired on that machine. The English regex is kept
    # only as a last-resort fallback for exception shapes that carry
    # neither a distinct type nor a propagated HResult.
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) {
        return $false
    }
    $exception = $ErrorRecord.Exception
    $accessDeniedHResult = -2147024891 # 0x80070005 / E_ACCESSDENIED as Int32
    $depth = 0
    while ($null -ne $exception -and $depth -lt 10) {
        if ($exception -is [System.UnauthorizedAccessException]) {
            return $true
        }
        if ($exception.HResult -eq $accessDeniedHResult) {
            return $true
        }
        $exception = $exception.InnerException
        $depth++
    }
    $msg = ''
    if ($null -ne $ErrorRecord.Exception) {
        $msg = [string]$ErrorRecord.Exception.Message
    }
    return ($msg -match '(?i)access is denied|access denied|denied|unauthorized')
}

function Test-GuiWatchdogResultFailureIsElevationEligible {
    # register-watchdog/unregister-watchdog report a per-task failure by
    # RETURNING Success=$false (see Register-Watchdog/Unregister-Watchdog),
    # not by throwing -- by the time that reaches here, only the
    # exception's .Message STRING survives (see their catch blocks), so a
    # reliable locale-independent signature (HResult/exception type, as
    # Test-GuiLooksLikeAccessDenied prefers for the thrown-exception path)
    # is not available from the string alone, and the real-world failure
    # this exists to catch is reported in the OS's display language
    # ("Acceso denegado"), not English, so matching English text here would
    # silently miss it again. These actions are therefore special-cased by
    # name: ANY Success=$false result from one of them is treated as
    # elevation-eligible and offered as a confirm-and-retry-elevated
    # dialog -- never silently auto-elevated -- rather than risk failing to
    # recognize a genuine access-denied failure. Every OTHER action (e.g.
    # register-vibepollo's malformed-conf-JSON Success=$false) keeps
    # reporting a Result-shaped failure as final, since those failures are
    # business-logic outcomes, not permissions problems, and elevating
    # would not fix them.
    #
    # uninstall is included for exactly the same reason: its ONLY top-level
    # Success=$false source is a failed watchdog unregister nested inside
    # WatchdogUnregistered (see Uninstall-App) -- a conf-edit failure never
    # sets it, deliberately, so it stays a final business-logic outcome the
    # way register-vibepollo's does. Without this, an admin-owned watchdog
    # task left behind by uninstall had no elevated retry offered anywhere,
    # since Uninstall-App itself never throws for that failure.
    param([Parameter(Mandatory = $true)][string]$Action)
    return ($Action -eq 'register-watchdog' -or $Action -eq 'unregister-watchdog' -or $Action -eq 'uninstall')
}

function Test-PathUnderTrustedProgramRoot {
    # True if Path sits under a Program Files root resolved via the
    # registry-backed [Environment]::GetFolderPath -- deliberately NOT
    # $env:ProgramFiles / $env:ProgramW6432 / $env:ProgramFiles(x86), which
    # this app ALSO reads (see Get-HostConfRoots) but which an unprivileged
    # user can override for their own future processes via
    # HKCU\Environment. That is a real, if narrow, confused-deputy angle:
    # this app auto-detects a conf path from those same environment
    # variables and then has an elevated process write to it. Used only to
    # WARN in the elevation consent prompt (see Invoke-GuiElevationRetry),
    # never to block: a legitimate portable/custom-location install
    # (reached through the wizard's own Browse button) must still be
    # elevatable -- the approving admin is just told plainly the target
    # isn't a standard location, so a poisoned environment variable can't
    # silently redirect an elevated write without at least surfacing that
    # in the consent dialog.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    $full = $null
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }
    foreach ($folder in @('ProgramFiles', 'ProgramFilesX86')) {
        $root = $null
        try {
            $root = [Environment]::GetFolderPath($folder)
        }
        catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        $rootFull = $null
        try {
            $rootFull = [System.IO.Path]::GetFullPath($root)
        }
        catch {
            continue
        }
        if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Invoke-GuiElevationRetry {
    # Shared confirm-and-elevate tail used by both branches of
    # Invoke-GuiElevatable below (a thrown access-denied-shaped exception,
    # and a register-watchdog/unregister-watchdog Success=$false result).
    # Never elevates without asking first.
    param(
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath,
        [Parameter(Mandatory = $true)][string]$Action,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory = $true)][string]$FailureMessage,

        # Optional human-readable description of what's about to be
        # rewritten, shown on its own line in the consent prompt (e.g. the
        # conf file path for register-vibepollo). The approving admin
        # otherwise sees only "This needs administrator approval" and the
        # Windows UAC dialog's own truncated command line -- neither names
        # the actual file. See Invoke-VibepolloConnectAction for the call
        # site that threads this through.
        [string]$TargetDescription = $null
    )

    if (Test-IsAdmin) {
        # Already running elevated (e.g. the whole GUI was launched via
        # "Run as administrator"): Start-Process -Verb RunAs still triggers
        # a FRESH UAC consent prompt even from an already-elevated process
        # (ShellExecute's "runas" verb always does, short of UAC being
        # disabled outright), to launch a second elevated process that
        # would hit this exact same failure again -- this process's lack of
        # permissions was never the actual cause. Report the original
        # failure directly instead of re-prompting for something elevating
        # again cannot fix.
        return [PSCustomObject]@{ Success = $false; Value = $null; Elevated = $false; ErrorMessage = "$FailureMessage (this process is already running as administrator; elevating again would not help)" }
    }

    $targetLine = ''
    if (-not [string]::IsNullOrWhiteSpace($TargetDescription)) {
        $targetLine = "`r`n`r`n$TargetDescription"
    }
    $confirm = Show-GuiConfirm -Text "This needs administrator approval. Retry elevated?$targetLine`r`n`r`n$FailureMessage"
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

function Invoke-GuiElevatable {
    # Tries UnelevatedAction first. If it throws something that looks like
    # a permissions failure (Test-GuiLooksLikeAccessDenied), OR it is a
    # register-watchdog/unregister-watchdog call whose RETURNED result
    # reports Success=$false (Test-GuiWatchdogResultFailureIsElevationEligible
    # -- see there for why those two actions are special-cased instead of
    # pattern-matching the failure message), asks the user whether to retry
    # elevated via Invoke-Elevated (re-running manager.ps1 -Action $Action
    # with $Parameters, using Start-Process -Verb RunAs). This is the only
    # path by which the GUI ever requests elevation, and only for the
    # specific operation that needs it, never the GUI process as a whole.
    param(
        [Parameter(Mandatory = $true)][scriptblock]$UnelevatedAction,
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath,
        [Parameter(Mandatory = $true)][string]$Action,
        [hashtable]$Parameters = @{},
        # See Invoke-GuiElevationRetry's own parameter of the same name --
        # passed straight through to both elevation-retry call sites below.
        [string]$TargetDescription = $null
    )

    try {
        $value = & $UnelevatedAction
        if (Test-ManagerResultIndicatesFailure -Result $value) {
            $msg = Get-ManagerResultFailureMessage -Result $value
            if (Test-GuiWatchdogResultFailureIsElevationEligible -Action $Action) {
                return Invoke-GuiElevationRetry -ManagerScriptPath $ManagerScriptPath -Action $Action -Parameters $Parameters -FailureMessage $msg -TargetDescription $TargetDescription
            }
            # Every other action's Result-shaped failure (e.g.
            # Add-PrepCommandEntry on malformed existing conf JSON) is a
            # real, final failure, not a permissions problem, so it is
            # surfaced directly rather than routed into the
            # elevation-retry path above.
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
        return Invoke-GuiElevationRetry -ManagerScriptPath $ManagerScriptPath -Action $Action -Parameters $Parameters -FailureMessage $_.Exception.Message -TargetDescription $TargetDescription
    }
}

function Invoke-VibepolloConnectAction {
    # Shared "what Connect actually does" body: adds/refreshes our
    # global_prep_cmd entry at ConfPath (via Invoke-GuiElevatable, so an
    # access-denied write under Program Files offers the elevated retry)
    # and restarts the host service in whichever process actually held the
    # rights to write it. Used by both the first-run wizard's Connect
    # button (Show-WizardVibepolloStep) and the Main Window's
    # Connect/Reconnect... dialog (Show-VibepolloConnectDialog), so both
    # surfaces share one code path instead of two copies that could drift.
    param(
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath,
        [Parameter(Mandatory = $true)][string]$ConfPath,
        [Parameter(Mandatory = $true)][string]$DataDir
    )

    $targetDescription = "Target: Vibepollo/Apollo conf file:`r`n$ConfPath"
    if (-not (Test-PathUnderTrustedProgramRoot -Path $ConfPath)) {
        $targetDescription += "`r`n(this path is not under a standard Program Files location -- double-check it before approving)"
    }

    return Invoke-GuiElevatable -ManagerScriptPath $ManagerScriptPath -Action 'register-vibepollo' -Parameters @{ ConfPath = $ConfPath; DataDir = $DataDir } -TargetDescription $targetDescription -UnelevatedAction {
        $result = Add-PrepCommandEntry -ConfPath $ConfPath -DataDir $DataDir
        if ($result.Success) {
            $result | Add-Member -NotePropertyName 'ServiceRestart' -NotePropertyValue (Restart-HostService)
        }
        return $result
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
        # From here on, every later step that can elevate (Connect, the
        # watchdog step) must relaunch the copy Install-App just wrote to
        # PROGRAM, not whatever path this process itself started from.
        # When launched via StreamConfigProfiles-Setup.bat, that starting
        # path is a throwaway extraction under %TEMP% -- re-elevating
        # against a %TEMP% script across a user-visible UAC consent delay
        # is a weaker target than PROGRAM (every other process on the box
        # can write into %TEMP%), and it stops the temp copy from being
        # relied on at all once the real, permanent copy exists.
        $State.ManagerScriptPath = $r.ManagerPath
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
    # A prior successful Connect must not keep gating Next as "connected"
    # once the user has typed or browsed to a DIFFERENT path -- field
    # testing found that connecting, then realising it was the wrong file
    # and Browse-ing to a different one WITHOUT clicking Connect again,
    # left VibepolloConnected sitting at $true from the earlier success:
    # the skip warning never fired even though the newly-selected conf was
    # never actually connected. $State.ConnectedConfPath (set only inside
    # the Connect handler's own Success branch below) is the path that
    # $true actually corresponds to; if the textbox no longer matches it,
    # the earlier success no longer applies.
    $txtConf.Add_TextChanged({
        if ([bool]$State.VibepolloConnected -and $txtConf.Text.Trim() -ne [string]$State.ConnectedConfPath) {
            $State.VibepolloConnected = $false
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
        # The restart happens INSIDE Invoke-VibepolloConnectAction
        # (whichever process -- elevated or not -- actually ran it), not
        # as a separate always-unelevated call afterward: restarting a
        # real Windows service unelevated routinely fails right after a
        # successful elevated conf write, which previously showed a
        # confusing "restart failed" message immediately below a
        # successful "Connected" message.
        $addOutcome = Invoke-VibepolloConnectAction -ManagerScriptPath $State.ManagerScriptPath -ConfPath $confPath -DataDir $dataDirForConnect

        if ($addOutcome.Success) {
            # Set ONLY here, on an actual Success=$true add -- never
            # optimistically on Connect being clicked, and never reset
            # back to $false by a later failed retry (a prior successful
            # connect is still valid even if a re-Connect attempt fails).
            # This is what Next's skip-confirmation below gates on: field
            # testing found that silently clicking past this step with no
            # connection made left profiles never syncing, with no record
            # anywhere that the user had skipped it.
            $State.VibepolloConnected = $true
            $State.ConnectedConfPath = $confPath
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
    $btnNext.Add_Click({
        # Gate, don't block: Next must still be reachable without ever
        # connecting (the user can always connect later from the main
        # window -- see Sync-VibepolloStatus/Show-VibepolloConnectDialog),
        # but skipping must never be SILENT. Before this fix, clicking
        # Next with no connection made produced no record anywhere that
        # the skip had happened, and no signal to the user that profiles
        # would not sync until they came back to connect it.
        if (-not [bool]$State.VibepolloConnected) {
            $proceedAnyway = Show-GuiConfirm -Text 'You have not connected to Vibepollo/Apollo -- profiles will not sync until you do. You can connect later from the main window. Continue anyway?'
            if (-not $proceedAnyway) {
                return
            }
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

function Show-WizardWatchdogStep {
    param([hashtable]$State)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles - Setup (4 of 5): Watchdog protection'
    $form.Size = New-Object System.Drawing.Size(520, 300)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $intro = New-GuiLabel -Text "The watchdog re-applies your local config if a stream ends without a clean disconnect (crash, force-quit, sleep). Windows may ask for administrator approval to register the logon/unlock protection below -- the watchdog itself always runs as your normal user account, never elevated." -X 15 -Y 15 -Width 480 -Height 65
    $form.Controls.Add($intro)

    $cbLogon = New-GuiCheckBox -Text 'Protect at logon / unlock (recommended)' -X 20 -Y 90 -Width 400 -Checked $true
    $form.Controls.Add($cbLogon)

    $cbPoll = New-GuiCheckBox -Text 'Also check periodically, every' -X 20 -Y 120 -Width 210 -Checked ([bool]$State.IncludePoll)
    $form.Controls.Add($cbPoll)

    $nudPoll = New-Object System.Windows.Forms.NumericUpDown
    $nudPoll.Location = New-Object System.Drawing.Point(235, 118)
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

    $lblMinutes = New-GuiLabel -Text 'minutes (min. 5)' -X 300 -Y 120 -Width 150
    $form.Controls.Add($lblMinutes)

    $cbPoll.Add_CheckedChanged({ $nudPoll.Enabled = $cbPoll.Checked })

    $btnBack = New-GuiButton -Text '< Back' -X 110 -Y 220 -Width 90
    $btnCancel = New-GuiButton -Text 'Cancel' -X 300 -Y 220 -Width 90
    $btnNext = New-GuiButton -Text 'Next >' -X 400 -Y 220 -Width 90
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
        # -- NOT re-derived inside an elevated re-entry (see
        # Invoke-Elevated/Parameters below), so an over-the-shoulder
        # elevation approval by a DIFFERENT account than the one running
        # this wizard can't sneak its identity in through the elevated
        # child. This guarantee is about the elevation boundary specifically
        # -- it does not cover the wizard itself having been launched
        # already elevated (e.g. Install.bat run as administrator), in
        # which case this process's own identity is already the approving
        # admin's.
        $userIdForWatchdog = Get-ResolvedUserId

        # Registering the Logon task can prompt Windows for administrator
        # approval even though the task's own principal is always the
        # calling user (see Register-Watchdog) -- Invoke-GuiElevatable
        # retries elevated on that specific denial. Register-Watchdog
        # itself never elevates on its own, and the Poll task's trigger
        # never needs admin, so a poll-only selection never attempts the
        # elevation-eligible Logon registration -- but it can still PROMPT
        # if this same call needs to remove a Logon task admin-owned by an
        # earlier elevated registration (see Register-Watchdog's reconcile
        # step below). Register-Watchdog is a full desired-state
        # reconciler -- unchecking Logon here removes any already-
        # registered Logon task itself (no separate unelevated delete
        # needed, which used to have no elevated-retry path of its own).
        # The Parameters hashtable below is what an elevation retry actually
        # serializes across the -File boundary (via ConvertTo-
        # ElevatedArgumentString/Invoke-Elevated), so it uses the elevated
        # child's top-level -SkipLogon surface, translated once from the
        # GUI's own includeLogon boolean (SkipLogon = -not includeLogon) --
        # never -IncludeLogon, which no longer exists at that boundary. The
        # UnelevatedAction closure below is a plain in-process call and
        # keeps using Register-Watchdog's own -IncludeLogon unchanged.
        $applyOutcome = Invoke-GuiElevatable -ManagerScriptPath $State.ManagerScriptPath -Action 'register-watchdog' -Parameters @{ DataDir = $dataDirForWatchdog; UserId = $userIdForWatchdog; SkipLogon = [switch](-not $includeLogon); IncludePoll = [switch]$includePollForWatchdog; PollMinutes = $pollMinutesForWatchdog } -UnelevatedAction {
            Register-Watchdog -DataDir $dataDirForWatchdog -UserId $userIdForWatchdog -IncludeLogon:$includeLogon -IncludePoll:$includePollForWatchdog -PollMinutes $pollMinutesForWatchdog
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
    $form.Size = New-Object System.Drawing.Size(520, 350)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $text = "Setup is complete.`r`n`r`nWhat's next:`r`n -  Add or remove game config paths from the main window (Add File / Add Folder).`r`n -  Watchdog and connection status are shown on the main window; you can re-run either step from there.`r`n -  See README.md for the paths.txt format and troubleshooting tips.`r`n`r`nData folder: $($State.DataDir)"
    $lbl = New-GuiLabel -Text $text -X 15 -Y 15 -Width 480 -Height 180
    $form.Controls.Add($lbl)

    $cbStartMenuShortcut = New-GuiCheckBox -Text 'Add to Start Menu' -X 20 -Y 200 -Width 250 -Checked $true
    $form.Controls.Add($cbStartMenuShortcut)
    $cbDesktopShortcut = New-GuiCheckBox -Text 'Create Desktop shortcut' -X 20 -Y 228 -Width 250 -Checked $false
    $form.Controls.Add($cbDesktopShortcut)

    $btnBack = New-GuiButton -Text '< Back' -X 300 -Y 275 -Width 90
    $btnFinish = New-GuiButton -Text 'Finish' -X 400 -Y 275 -Width 90
    $form.Controls.Add($btnBack)
    $form.Controls.Add($btnFinish)
    $form.AcceptButton = $btnFinish

    $btnBack.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::Retry; $form.Close() })
    $btnFinish.Add_Click({
        $addStartMenu = $cbStartMenuShortcut.Checked
        $addDesktop = $cbDesktopShortcut.Checked
        if ($addStartMenu -or $addDesktop) {
            # Best-effort, exactly like New-ManagerShortcut's own per-
            # location error handling: a shortcut failure must never block
            # finishing setup, which is why this still goes through
            # Invoke-GuiSafe on top even though New-ManagerShortcut itself
            # never throws for a single-location failure.
            Invoke-GuiSafe -Action {
                New-ManagerShortcut -ProgramDir $State.ProgramDir -StartMenu:$addStartMenu -Desktop:$addDesktop
            } | Out-Null
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

function Show-FirstRunWizard {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptDir,
        [Parameter(Mandatory = $true)][string]$ProgramDir,
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath
    )

    $state = @{
        ScriptDir           = $ScriptDir
        ProgramDir          = $ProgramDir
        DataDir             = $DataDir
        ManagerScriptPath   = $ManagerScriptPath
        ConfPath            = $null
        IncludePoll         = $false
        PollMinutes         = 15
        InstallDone         = $false
        # Set $true only on an actual Success=$true Add-PrepCommandEntry
        # (see Show-WizardVibepolloStep's Connect handler) -- never
        # optimistically, and never reset back to $false by a later
        # failed reconnect attempt. Gates the confirm-before-skip warning
        # on the Vibepollo step's Next button. Invalidated (reset to
        # $false) if the conf textbox is later edited away from
        # ConnectedConfPath -- see Show-WizardVibepolloStep's txtConf
        # TextChanged handler.
        VibepolloConnected  = $false
        # The exact conf path VibepolloConnected = $true corresponds to.
        ConnectedConfPath   = $null
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

    # Only hand the conf path down as "connected" when the wizard's own
    # Connect actually succeeded -- $state.ConfPath alone is set as soon
    # as the step's textbox has anything in it (auto-detected or
    # browsed-to), whether or not Connect was ever clicked successfully
    # (see Show-WizardVibepolloStep). Passing it through unconditionally
    # would make Show-MainWindow believe a conf was connected when the
    # user, in fact, skipped the step.
    $connectedConfPathForMainWindow = $null
    if ([bool]$state.VibepolloConnected) {
        $connectedConfPathForMainWindow = $state.ConfPath
    }
    Show-MainWindow -ScriptDir $state.ScriptDir -ProgramDir $state.ProgramDir -DataDir $state.DataDir -ManagerScriptPath $state.ManagerScriptPath -ConfPath $connectedConfPathForMainWindow
}

function Show-VibepolloConnectDialog {
    # The Main Window's "Connect/Reconnect..." dialog -- detect + editable
    # path + Browse + Connect, exactly like the wizard's own Vibepollo step
    # (Show-WizardVibepolloStep), sharing the same connect action
    # (Invoke-VibepolloConnectAction) so both surfaces do the same thing.
    # Kept as its own small dialog rather than reusing the wizard step's
    # Form directly -- that Form is wired for the Back/Next/Cancel wizard
    # flow (DialogResult drives Show-FirstRunWizard's step index), which
    # has no meaning once already installed.
    param(
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath,
        [Parameter(Mandatory = $true)][string]$DataDir
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles - Connect to Vibepollo/Apollo'
    $form.Size = New-Object System.Drawing.Size(560, 300)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false

    $detected = $null
    $detectOutcome = Invoke-GuiSafe -Action { Find-HostConf }
    if ($detectOutcome.Success) {
        $detected = $detectOutcome.Value
    }
    if ([string]::IsNullOrWhiteSpace($detected)) {
        $detected = ''
    }

    $lblConf = New-GuiLabel -Text 'Conf file path:' -X 15 -Y 15 -Width 150
    $form.Controls.Add($lblConf)
    $txtConf = New-GuiTextBox -X 15 -Y 37 -Width 420 -Text $detected
    $form.Controls.Add($txtConf)
    $btnBrowse = New-GuiButton -Text 'Browse...' -X 440 -Y 36 -Width 90
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
    $lblNote = New-GuiLabel -Text $noteText -X 15 -Y 67 -Width 510 -Height 20
    $form.Controls.Add($lblNote)

    $txtResult = New-Object System.Windows.Forms.TextBox
    $txtResult.Location = New-Object System.Drawing.Point(15, 95)
    $txtResult.Size = New-Object System.Drawing.Size(515, 100)
    $txtResult.Multiline = $true
    $txtResult.ReadOnly = $true
    $txtResult.ScrollBars = 'Vertical'
    $txtResult.Text = 'Click Connect to add/refresh the global prep command entry.'
    $form.Controls.Add($txtResult)

    # A PSCustomObject, not a bare scalar: its .Connected/.ConfPath
    # properties are mutated from inside the Connect click handler below
    # and read back after ShowDialog() returns -- a reference-type
    # property survives that round trip reliably, the same reason $State
    # is a hashtable throughout the wizard rather than separate scalar
    # variables. ConfPath is returned alongside Connected (not just the
    # bare bool) so the caller (Show-MainWindow) can remember WHICH conf
    # this dialog actually connected -- see $vibepolloConnection there --
    # instead of having to re-guess it later via Find-HostConf, which
    # cannot see a portable/custom-path install reached only via Browse.
    $outcomeState = [PSCustomObject]@{ Connected = $false; ConfPath = $null }

    $btnConnect = New-GuiButton -Text 'Connect' -X 15 -Y 205 -Width 110
    $form.Controls.Add($btnConnect)
    $btnConnect.Add_Click({
        $confPath = $txtConf.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($confPath) -or -not (Test-Path -LiteralPath $confPath)) {
            [System.Windows.Forms.MessageBox]::Show('Please choose a valid conf file first.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $addOutcome = Invoke-VibepolloConnectAction -ManagerScriptPath $ManagerScriptPath -ConfPath $confPath -DataDir $DataDir
        if ($addOutcome.Success) {
            $outcomeState.Connected = $true
            $outcomeState.ConfPath = $confPath
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

    $btnClose = New-GuiButton -Text 'Close' -X 450 -Y 205 -Width 90
    $form.Controls.Add($btnClose)
    $form.CancelButton = $btnClose
    $btnClose.Add_Click({ $form.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Close() })

    $form.ShowDialog() | Out-Null
    return $outcomeState
}

# ---------------------------------------------------------------------------
# Main Window (shown once already installed)
# ---------------------------------------------------------------------------

function Show-MainWindow {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptDir,
        [Parameter(Mandatory = $true)][string]$ProgramDir,
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$ManagerScriptPath,

        # The conf path this session already knows it connected to -- e.g.
        # the wizard's own successful Connect (see Show-FirstRunWizard,
        # which passes $state.ConfPath through here only when
        # $state.VibepolloConnected is true). Never re-guessed away by a
        # fresh Find-HostConf call below: Find-HostConf only ever returns
        # a Program-Files-rooted or service-binary-sibling path, which is
        # exactly the set that does NOT cover a portable/custom-location
        # install reached only via the wizard's Browse button -- silently
        # falling back to Find-HostConf here is the bug that let uninstall
        # "succeed" against a conf it never actually touched (see
        # $vibepolloConnection below).
        [string]$ConfPath
    )

    $pathsTxtPath = Join-Path $DataDir 'paths.txt'

    # Tracks the conf path THIS WINDOW knows it is actually connected to --
    # seeded from the wizard's own successful connect (-ConfPath above),
    # then kept up to date by the Connect/Reconnect... handler below.
    # Preferred over a fresh Find-HostConf guess everywhere a conf path is
    # needed (status display, and critically the Disconnect/Uninstall
    # handler), so a conf found only via Browse is never silently
    # re-guessed away. A PSCustomObject (reference type), not a bare
    # string, so nested event-handler scriptblocks below can mutate it and
    # have every other closure over this same Show-MainWindow scope see
    # the update -- the same pattern $State (the wizard) and
    # $outcomeState (Show-VibepolloConnectDialog) already use for exactly
    # this reason.
    $vibepolloConnection = [PSCustomObject]@{ ConfPath = $ConfPath }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'stream-config-profiles'
    $form.Size = New-Object System.Drawing.Size(640, 660)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(560, 580)

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

    $lblVibepollo = New-GuiLabel -Text 'Vibepollo/Apollo connection status:' -X 15 -Y 265 -Width 300
    $form.Controls.Add($lblVibepollo)

    $txtVibepolloStatus = New-Object System.Windows.Forms.TextBox
    $txtVibepolloStatus.Location = New-Object System.Drawing.Point(15, 288)
    $txtVibepolloStatus.Size = New-Object System.Drawing.Size(590, 40)
    $txtVibepolloStatus.Multiline = $true
    $txtVibepolloStatus.ReadOnly = $true
    $form.Controls.Add($txtVibepolloStatus)

    function Sync-VibepolloStatus {
        # Re-detects the conf path every time this window opens (or the
        # Connect/Reconnect dialog closes) rather than persisting a
        # "last-known" path anywhere -- there is deliberately no settings
        # store in this app (see Get-ResolvedDataDir's own comment on why
        # not), and re-running Find-HostConf is cheap and always reflects
        # reality, including a conf that moved or a fresh install found by
        # the wildcard fallback (see Find-HostConfByWildcard) since the
        # last time this ran.
        $confPath = $null
        if (-not [string]::IsNullOrWhiteSpace($vibepolloConnection.ConfPath) -and (Test-Path -LiteralPath $vibepolloConnection.ConfPath)) {
            # Prefer the conf this session actually connected to over a
            # fresh guess -- see $vibepolloConnection's own comment above.
            $confPath = $vibepolloConnection.ConfPath
        }
        else {
            $detectOutcome = Invoke-GuiSafe -Action { Find-HostConf }
            if ($detectOutcome.Success) {
                $confPath = $detectOutcome.Value
            }
        }

        # All the actual state logic (not-found / unreadable / connected /
        # not-connected) lives in Get-VibepolloConnectionStatus, a headless
        # Core function -- this renderer just resolves ConfPath and paints
        # the result. See Get-VibepolloConnectionStatus's own comment for
        # why it was pulled out (unit-testable independent of WinForms).
        $statusOutcome = Invoke-GuiSafe -Action { Get-VibepolloConnectionStatus -ConfPath $confPath -DataDir $DataDir }
        if ($statusOutcome.Success) {
            $txtVibepolloStatus.Text = $statusOutcome.Value.Text
        }
        else {
            $txtVibepolloStatus.Text = 'Status unavailable: ' + $statusOutcome.ErrorMessage
        }
    }
    Sync-VibepolloStatus

    $btnConnectVibepollo = New-GuiButton -Text 'Connect/Reconnect...' -X 15 -Y 330 -Width 160
    $form.Controls.Add($btnConnectVibepollo)
    $btnConnectVibepollo.Add_Click({
        $dialogResult = Show-VibepolloConnectDialog -ManagerScriptPath $ManagerScriptPath -DataDir $DataDir
        if ($null -ne $dialogResult -and $dialogResult.Connected -and -not [string]::IsNullOrWhiteSpace([string]$dialogResult.ConfPath)) {
            $vibepolloConnection.ConfPath = [string]$dialogResult.ConfPath
        }
        Sync-VibepolloStatus
    })

    $lblWatchdog = New-GuiLabel -Text 'Watchdog protection status:' -X 15 -Y 375 -Width 300
    $form.Controls.Add($lblWatchdog)

    $txtWatchdogStatus = New-Object System.Windows.Forms.TextBox
    $txtWatchdogStatus.Location = New-Object System.Drawing.Point(15, 398)
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

    $cbLogon2 = New-GuiCheckBox -Text 'Logon/Unlock' -X 15 -Y 462 -Width 130 -Checked ([bool]$initialStatus['StreamConfigProfiles-Settle-Logon'])
    $cbPoll2 = New-GuiCheckBox -Text 'Poll every' -X 150 -Y 462 -Width 90 -Checked ([bool]$initialStatus['StreamConfigProfiles-Settle-Poll'])
    $form.Controls.Add($cbLogon2)
    $form.Controls.Add($cbPoll2)

    $nudPoll2 = New-Object System.Windows.Forms.NumericUpDown
    $nudPoll2.Location = New-Object System.Drawing.Point(245, 460)
    $nudPoll2.Size = New-Object System.Drawing.Size(55, 23)
    $nudPoll2.Minimum = 5
    $nudPoll2.Maximum = 1440
    $nudPoll2.Value = 15
    $nudPoll2.Enabled = $cbPoll2.Checked
    $form.Controls.Add($nudPoll2)
    $cbPoll2.Add_CheckedChanged({ $nudPoll2.Enabled = $cbPoll2.Checked })

    $lblMin2 = New-GuiLabel -Text 'min' -X 305 -Y 462 -Width 40
    $form.Controls.Add($lblMin2)

    $btnApplyWatchdog = New-GuiButton -Text 'Register/Update' -X 425 -Y 458 -Width 130
    $form.Controls.Add($btnApplyWatchdog)

    $btnUnregisterWatchdog = New-GuiButton -Text 'Unregister All' -X 15 -Y 492 -Width 120
    $form.Controls.Add($btnUnregisterWatchdog)

    $btnApplyWatchdog.Add_Click({
        $includePoll = $cbPoll2.Checked
        $pollMinutes = [int]$nudPoll2.Value
        $includeLogon = $cbLogon2.Checked
        # Resolved once, in this process, and threaded through explicitly
        # (see Invoke-Elevated) so an over-the-shoulder elevation approval
        # by a DIFFERENT account than the one running this window can't
        # register the task under the wrong identity via the elevated
        # child. Does not cover this window itself having been launched
        # already elevated -- see Get-ResolvedUserId / Invoke-GuiElevationRetry.
        $userIdForWatchdog = Get-ResolvedUserId

        # Registering the Logon task can prompt Windows for administrator
        # approval even though the task's own principal is always the
        # calling user (see Register-Watchdog) -- Invoke-GuiElevatable
        # retries elevated on that specific denial. Register-Watchdog is a
        # full desired-state reconciler (see there): it also removes
        # whichever of Logon/Poll is now unchecked, in this SAME call, so
        # unchecking Poll or Logon actually removes an already-registered
        # task -- including one an earlier elevated retry left admin-owned
        # -- through this one confirm-and-elevate path, instead of a
        # separate unelevated delete with no retry of its own.
        # See the equivalent wizard call site's comment above: the Parameters
        # hashtable crosses the -File elevation boundary and so speaks
        # -SkipLogon (translated once from this GUI's own includeLogon
        # boolean), never -IncludeLogon; the UnelevatedAction closure is a
        # plain in-process call and keeps using Register-Watchdog's own
        # -IncludeLogon unchanged.
        $applyOutcome = Invoke-GuiElevatable -ManagerScriptPath $ManagerScriptPath -Action 'register-watchdog' -Parameters @{ DataDir = $DataDir; UserId = $userIdForWatchdog; SkipLogon = [switch](-not $includeLogon); IncludePoll = [switch]$includePoll; PollMinutes = $pollMinutes } -UnelevatedAction {
            Register-Watchdog -DataDir $DataDir -UserId $userIdForWatchdog -IncludeLogon:$includeLogon -IncludePoll:$includePoll -PollMinutes $pollMinutes
        }
        if ($applyOutcome.Success) {
            [System.Windows.Forms.MessageBox]::Show('Watchdog settings applied.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        Sync-WatchdogStatus
    })

    $btnUnregisterWatchdog.Add_Click({
        # Deleting your own scheduled tasks does not generally need
        # elevation the way registering a logon-type trigger does (see
        # Register-Watchdog / Unregister-Watchdog), but this still routes
        # through Invoke-GuiElevatable rather than Invoke-GuiSafe so an
        # unexpected access-denied (a task registered under a different
        # account, an ACL oddity, ...) gets the same confirm-and-elevate
        # retry instead of a dead end.
        $outcome = Invoke-GuiElevatable -ManagerScriptPath $ManagerScriptPath -Action 'unregister-watchdog' -Parameters @{} -UnelevatedAction { Unregister-Watchdog }
        if ($outcome.Success) {
            [System.Windows.Forms.MessageBox]::Show('Watchdog tasks removed.', 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        Sync-WatchdogStatus
    })

    $btnOpenData = New-GuiButton -Text 'Open data folder' -X 15 -Y 530 -Width 150
    $btnViewLog = New-GuiButton -Text 'View sync.log' -X 175 -Y 530 -Width 130
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

    $btnDisconnect = New-GuiButton -Text 'Disconnect all / Uninstall...' -X 320 -Y 530 -Width 285
    $form.Controls.Add($btnDisconnect)

    $btnDisconnect.Add_Click({
        $confirm1 = Show-GuiConfirm -Text 'This removes the Vibepollo/Apollo connection, the watchdog tasks, and the program files. Continue?' -Title 'Disconnect stream-config-profiles'
        if (-not $confirm1) {
            return
        }

        $removeData = Show-GuiConfirm -Text 'Also delete your data folder (configured paths, saved profiles, log)? This cannot be undone.' -Title 'Disconnect stream-config-profiles'

        $confPathForUninstall = $null
        if (-not [string]::IsNullOrWhiteSpace($vibepolloConnection.ConfPath) -and (Test-Path -LiteralPath $vibepolloConnection.ConfPath)) {
            # Prefer the conf this session actually connected to (from the
            # wizard, or a later Connect/Reconnect... in this window) over
            # a fresh Find-HostConf guess. This is the field fix: a
            # portable/custom-path install found only via Browse is
            # invisible to Find-HostConf (it only ever returns a
            # Program-Files-rooted or service-binary-sibling path), so
            # re-guessing here silently uninstalled without ever touching
            # the conf the user actually connected to -- global_prep_cmd
            # kept pointing at DATA\sync-configs.ps1 even after DATA was
            # deleted, while the GUI reported a clean disconnect.
            $confPathForUninstall = $vibepolloConnection.ConfPath
        }
        else {
            $confOutcome = Invoke-GuiSafe -Action { Find-HostConf }
            if ($confOutcome.Success) {
                $confPathForUninstall = $confOutcome.Value
            }
        }

        # Resolved once, here, in the original unelevated process -- same
        # over-the-shoulder-admin reason -UserId is threaded through
        # explicitly rather than re-derived (see Get-ResolvedUserId): an
        # elevated re-entry approved by a DIFFERENT account would
        # otherwise remove (or fail to find) shortcuts on THAT admin's
        # Desktop/Start Menu instead of the real user's.
        $desktopDirForUninstall = [Environment]::GetFolderPath('Desktop')
        $programsDirForUninstall = [Environment]::GetFolderPath('Programs')

        $uninstallParams = @{ ProgramDir = $ProgramDir; DataDir = $DataDir; DesktopDir = $desktopDirForUninstall; ProgramsDir = $programsDirForUninstall }
        if (-not [string]::IsNullOrWhiteSpace($confPathForUninstall)) {
            $uninstallParams['ConfPath'] = $confPathForUninstall
        }
        if ($removeData) {
            $uninstallParams['RemoveData'] = [switch]$true
        }

        $uninstallTargetDescription = "Target: PROGRAM `"$ProgramDir`""
        if ($removeData) {
            $uninstallTargetDescription += " and DATA `"$DataDir`""
        }
        if (-not [string]::IsNullOrWhiteSpace($confPathForUninstall)) {
            $uninstallTargetDescription += "`r`nConf entry: $confPathForUninstall"
        }

        $outcome = Invoke-GuiElevatable -ManagerScriptPath $ManagerScriptPath -Action 'uninstall' -Parameters $uninstallParams -TargetDescription $uninstallTargetDescription -UnelevatedAction {
            Uninstall-App -ProgramDir $ProgramDir -DataDir $DataDir -ConfPath $confPathForUninstall -RemoveData:$removeData
        }

        if ($outcome.Success) {
            $successText = 'stream-config-profiles has been disconnected and uninstalled.'
            if ([string]::IsNullOrWhiteSpace($confPathForUninstall)) {
                # Never let this say "disconnected" without qualification
                # when no conf was actually known/found -- see the field
                # bug fixed above (a portable/custom-path install's conf,
                # reachable only via Browse, silently never getting
                # touched while this dialog still reported success).
                $successText += "`r`n`r`nNo Vibepollo/Apollo conf file was connected or found automatically, so no connection entry was removed."
            }
            # $outcome.Value is the Uninstall-App summary ONLY on the
            # unelevated path -- Invoke-GuiElevationRetry has nothing but an
            # exit code from the elevated child (Start-Process -Verb RunAs
            # cannot have its stdout redirected), so a skip that happens to
            # occur only inside an elevated retry stays invisible here; this
            # still closes that gap for the common (no elevation needed)
            # case, where it used to be silently dropped even though the
            # data was right there in $outcome.Value.
            $skipReasons = New-Object System.Collections.Generic.List[string]
            if ($null -ne $outcome.Value) {
                if (-not [string]::IsNullOrWhiteSpace([string]$outcome.Value.ProgramDirSkipReason)) {
                    $skipReasons.Add([string]$outcome.Value.ProgramDirSkipReason)
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$outcome.Value.DataDirSkipReason)) {
                    $skipReasons.Add([string]$outcome.Value.DataDirSkipReason)
                }
            }
            if ($skipReasons.Count -gt 0) {
                $successText += "`r`n`r`nSome cleanup steps were skipped:`r`n - " + [string]::Join("`r`n - ", $skipReasons.ToArray())
            }
            [System.Windows.Forms.MessageBox]::Show($successText, 'stream-config-profiles', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
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
        # One-time SkipLogon -> IncludeLogon conversion, done exactly here
        # and nowhere else: -SkipLogon is THE parameter that crosses the
        # -File elevation boundary (see its own top-level .PARAMETER
        # comment), so it is always bound to a real, unambiguous
        # SwitchParameter in THIS process regardless of host (bare
        # -SkipLogon on this process's own command line -> $true; omitted
        # -> $false, this parameter's own plain-switch default). Negating it
        # once, here, and forwarding the result explicitly bound
        # (-IncludeLogon:$includeLogonForDispatch) into Invoke-ManagerAction
        # means that function's own -IncludeLogon is ALWAYS bound when
        # called from this dispatch -- it never needs to tell "caller said
        # false" apart from "caller said nothing" for this call path, so
        # there is no $PSBoundParameters trick left to get that distinction
        # wrong on any host.
        $includeLogonForDispatch = -not $SkipLogon
        $result = Invoke-ManagerAction -Action $Action -ScriptDir $scriptDirForRun -ProgramDir $ProgramDir -DataDir $DataDir -ConfPath $ConfPath -IncludeLogon:$includeLogonForDispatch -IncludePoll:$IncludePoll -PollMinutes $PollMinutes -RemoveData:$RemoveData -ManagerScriptPath $ManagerScriptPath -CommandPath $PSCommandPath -UserId $UserId -DesktopDir $DesktopDir -ProgramsDir $ProgramsDir -AddStartMenuShortcut:$AddStartMenuShortcut -AddDesktopShortcut:$AddDesktopShortcut
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
