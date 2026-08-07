<#
.SYNOPSIS
    Self-contained (no Pester, no external modules/binaries) test harness
    for ..\manager.ps1.

.DESCRIPTION
    Dot-sources manager.ps1 with -NoRun (exactly like a real test harness
    for a headless-capable script) and calls its Core functions directly
    against sandbox directories under the system temp directory. Never
    invokes the real Windows-only ScheduledTasks/Get-Service cmdlets --
    those are isolated behind tiny wrapper functions in manager.ps1 that
    this harness redefines (dot-source override, same scope) before
    exercising Register-Watchdog/Unregister-Watchdog, recording calls
    instead. Prints a PASS/FAIL table and exits non-zero if anything
    failed.

.PARAMETER KeepSandbox
    Do not delete the temp sandbox tree afterwards (useful for debugging a
    failure).
#>

param(
    [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:TestsDir = $PSScriptRoot
$script:RepoRoot = Split-Path -Path $script:TestsDir -Parent
$script:ManagerScriptSource = Join-Path $script:RepoRoot 'manager.ps1'

if (-not (Test-Path -LiteralPath $script:ManagerScriptSource)) {
    Write-Host "FATAL: cannot find manager.ps1 at $script:ManagerScriptSource" -ForegroundColor Red
    exit 1
}

# Dot-source the real script under test, -NoRun so it only defines its
# functions/variables. Every function it defines is now available directly
# in this scope -- including the watchdog/elevation wrapper functions this
# harness redefines below to avoid ever touching the real (Windows-only)
# ScheduledTasks/Get-Service/Start-Process cmdlets.
. $script:ManagerScriptSource -NoRun

# ---------------------------------------------------------------------------
# Watchdog cmdlet shims -- redefine the four wrapper functions manager.ps1
# isolates its ScheduledTasks calls behind. Each records its call instead of
# invoking the real (Windows-only) cmdlet.
# ---------------------------------------------------------------------------

$script:WatchdogCalls = New-Object System.Collections.Generic.List[object]

# Names Unregister-WatchdogTask should THROW for when called (simulating a
# real access-denied delete, e.g. a legacy admin-level task hit by an
# unelevated caller). Empty by default; a scenario that needs this sets it,
# then MUST reset it to @() afterward (in a finally block) so the failure
# doesn't leak into later scenarios sharing this shim.
$script:UnregisterShouldThrowFor = @()

function New-WatchdogTaskTrigger {
    param([string]$TriggerType, [int]$PollMinutes, [string]$UserId)
    return [PSCustomObject]@{ Kind = 'Trigger'; TriggerType = $TriggerType; PollMinutes = $PollMinutes; UserId = $UserId }
}

function New-WatchdogTaskAction {
    param([string]$Command)
    return [PSCustomObject]@{ Kind = 'Action'; Command = $Command }
}

function Register-WatchdogTask {
    param([string]$Name, [object[]]$Triggers, $Action, [bool]$NeedsAdmin, [string]$LogonType, [string]$UserId)
    $script:WatchdogCalls.Add([PSCustomObject]@{
        Op         = 'Register'
        Name       = $Name
        Triggers   = $Triggers
        Action     = $Action
        NeedsAdmin = $NeedsAdmin
        LogonType  = $LogonType
        UserId     = $UserId
    })
}

function Unregister-WatchdogTask {
    param([string]$Name)
    $script:WatchdogCalls.Add([PSCustomObject]@{ Op = 'Unregister'; Name = $Name })
    if (@($script:UnregisterShouldThrowFor) -contains $Name) {
        throw "Access is denied. (simulated failure for '$Name')"
    }
}

# ---------------------------------------------------------------------------
# Shortcut creation shim -- redefine New-ShortcutFile, the one function in
# manager.ps1 that touches WScript.Shell COM automation (Windows-only,
# unavailable on this Linux test host). Records calls instead of creating a
# real .lnk. Remove-ManagerShortcutFile is NOT shimmed -- deleting a file
# needs no COM and is exercised for real against sandboxed paths.
# ---------------------------------------------------------------------------

$script:ShortcutCalls = New-Object System.Collections.Generic.List[object]

# Shortcut paths New-ShortcutFile should THROW for when called (simulating a
# locked/read-only folder). Empty by default; a scenario that needs this
# sets it, then MUST reset it to @() afterward (in a finally block).
$script:ShortcutCreateShouldThrowFor = @()

function New-ShortcutFile {
    param([string]$ShortcutPath, $Definition)
    $script:ShortcutCalls.Add([PSCustomObject]@{ ShortcutPath = $ShortcutPath; Definition = $Definition })
    if (@($script:ShortcutCreateShouldThrowFor) -contains $ShortcutPath) {
        throw "Access is denied. (simulated failure for '$ShortcutPath')"
    }
}

# ---------------------------------------------------------------------------
# User-identity shim -- redefine Get-CurrentWindowsUserSid, the one function
# Get-ResolvedUserId isolates its WindowsIdentity.GetCurrent() SID lookup
# behind, so the "no SID available" fallback branch (DOMAIN\User / bare
# USERNAME) is exercised deterministically on EVERY platform this harness
# runs on -- including real Windows CI, where a SID is always genuinely
# available and the un-shimmed code path could never reach that branch at
# all. Always returns $null (never a real SID); no test here needs the real
# platform SID.
# ---------------------------------------------------------------------------

function Get-CurrentWindowsUserSid {
    return $null
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

$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("manager-tests-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 10)))
New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

function New-Sbx {
    param([string]$Label)
    $root = Join-Path $script:TempRoot ("sbx-{0}-{1}" -f $Label, ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

# ---------------------------------------------------------------------------
# Assertions / scenario bookkeeping (same style as run-tests.ps1)
# ---------------------------------------------------------------------------

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:ScenarioResults = New-Object System.Collections.Generic.List[object]

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:Failures.Add($Message)
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
# Payload dev-mode loading
# ===========================================================================

Invoke-Scenario -Name 'Payload: Get-EnginePayload dev-mode falls back to neighbor sync-configs.ps1' -Body {
    $realEngine = Read-TextFile (Join-Path $script:RepoRoot 'sync-configs.ps1')
    $loaded = Get-EnginePayload -ScriptDir $script:RepoRoot
    Assert-That ($loaded -eq $realEngine) 'Get-EnginePayload should return sync-configs.ps1 content verbatim in dev mode'
} | Out-Null

Invoke-Scenario -Name 'Payload: Get-TemplatePayload dev-mode falls back to neighbor paths.example.txt' -Body {
    $realTemplate = Read-TextFile (Join-Path $script:RepoRoot 'paths.example.txt')
    $loaded = Get-TemplatePayload -ScriptDir $script:RepoRoot
    Assert-That ($loaded -eq $realTemplate) 'Get-TemplatePayload should return paths.example.txt content verbatim in dev mode'
} | Out-Null

Invoke-Scenario -Name 'Payload: an embedded (non-marker) payload is returned as-is, no file lookup' -Body {
    $custom = 'FAKE ENGINE CONTENT'
    $loaded = Get-EnginePayload -ScriptDir '/does/not/exist' -PayloadText $custom
    Assert-That ($loaded -eq $custom) 'a non-empty embedded payload should be returned directly, bypassing dev-mode file lookup'
} | Out-Null

Invoke-Scenario -Name 'Payload: missing neighbor file in dev mode throws a clear error' -Body {
    $threw = $false
    try {
        Get-EnginePayload -ScriptDir (New-Sbx -Label 'empty-payload-dir')
    }
    catch {
        $threw = $true
        Assert-That ($_.Exception.Message -match 'sync-configs\.ps1') 'error message should mention the missing neighbor file'
    }
    Assert-That $threw 'Get-EnginePayload should throw when the embedded payload is empty and no neighbor file exists'
} | Out-Null

# ===========================================================================
# Install-App: layout + idempotency
# ===========================================================================

Invoke-Scenario -Name 'Install-App: fresh install creates the documented layout' -Body {
    $sbx = New-Sbx -Label 'install-fresh'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'

    $result = Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot

    Assert-That (Test-Path -LiteralPath (Join-Path $programDir 'manager.ps1')) 'PROGRAM\manager.ps1 should exist'
    Assert-That (Test-Path -LiteralPath (Join-Path $dataDir 'sync-configs.ps1')) 'DATA\sync-configs.ps1 should exist'
    Assert-That (Test-Path -LiteralPath (Join-Path $dataDir 'paths.example.txt')) 'DATA\paths.example.txt should exist'
    Assert-That (Test-Path -LiteralPath (Join-Path $dataDir 'paths.txt')) 'DATA\paths.txt should exist (created from template)'

    $realManager = Read-TextFile $script:ManagerScriptSource
    $realEngine = Read-TextFile (Join-Path $script:RepoRoot 'sync-configs.ps1')
    $realTemplate = Read-TextFile (Join-Path $script:RepoRoot 'paths.example.txt')

    Assert-That ((Read-TextFile $result.ManagerPath) -eq $realManager) 'installed manager.ps1 should match the source manager.ps1'
    Assert-That ((Read-TextFile $result.EnginePath) -eq $realEngine) 'installed sync-configs.ps1 should match the repo copy'
    Assert-That ((Read-TextFile $result.TemplatePath) -eq $realTemplate) 'installed paths.example.txt should match the repo copy'
    Assert-That ((Read-TextFile $result.PathsTxtPath) -eq $realTemplate) 'freshly created paths.txt should start out identical to the template'
} | Out-Null

Invoke-Scenario -Name 'Install-App: re-install is idempotent -- upgrades engine/manager, never touches paths.txt/state/profiles' -Body {
    $sbx = New-Sbx -Label 'install-idempotent'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'

    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    # Simulate user edits / engine-owned state that must survive a reinstall.
    $pathsTxt = Join-Path $dataDir 'paths.txt'
    Write-TextFile -Path $pathsTxt -Content "# my own path`nC:\MyGame\config.ini"
    $stateFile = Join-Path $dataDir 'state.json'
    Write-TextFile -Path $stateFile -Content '{"activeClient":"iPad"}'
    $profileFile = Join-Path $dataDir 'profiles/_local/deadbeef_config.ini'
    Write-TextFile -Path $profileFile -Content 'LOCAL:CONFIG'

    $before = Read-TextFile $pathsTxt

    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    Assert-That ((Read-TextFile $pathsTxt) -eq $before) 'paths.txt must be preserved verbatim across reinstall'
    Assert-That ((Read-TextFile $stateFile) -eq '{"activeClient":"iPad"}') 'state.json must be preserved verbatim across reinstall'
    Assert-That ((Read-TextFile $profileFile) -eq 'LOCAL:CONFIG') 'profiles\ contents must be preserved verbatim across reinstall'

    $realEngine = Read-TextFile (Join-Path $script:RepoRoot 'sync-configs.ps1')
    Assert-That ((Read-TextFile (Join-Path $dataDir 'sync-configs.ps1')) -eq $realEngine) 'engine should still match the (re-copied) source after reinstall'
} | Out-Null

# ===========================================================================
# Upgrade detection: running a newer Setup.bat/manager.ps1 against an
# existing installation must actually upgrade it (see Get-ManagerUpgrade-
# Decision / Test-ManagerUpgradeNeeded / Update-ManagerInstallationInPlace /
# Invoke-ManagerAutoUpgrade).
# ===========================================================================

Invoke-Scenario -Name 'Upgrade detection: Get-ManagerUpgradeDecision -- running FROM the installed copy (same path) is never an upgrade, even with different content' -Body {
    $decision = Get-ManagerUpgradeDecision -RunningScriptPath 'C:\Program Files\App\manager.ps1' -InstalledManagerPath 'C:\Program Files\App\manager.ps1' -InstalledManagerExists $true -RunningScriptContent 'OLD' -InstalledManagerContent 'NEW'
    Assert-That ($decision -eq $false) 'identical (resolved, case-insensitive) paths must never trigger an upgrade -- that IS the installed copy'

    # Case-insensitive path comparison (Windows paths).
    $decisionCaseInsensitive = Get-ManagerUpgradeDecision -RunningScriptPath 'C:\Program Files\App\manager.ps1' -InstalledManagerPath 'c:\program files\app\MANAGER.PS1' -InstalledManagerExists $true -RunningScriptContent 'OLD' -InstalledManagerContent 'NEW'
    Assert-That ($decisionCaseInsensitive -eq $false) 'path comparison should be case-insensitive'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: Get-ManagerUpgradeDecision -- identical content from a different path is a no-op' -Body {
    $decision = Get-ManagerUpgradeDecision -RunningScriptPath '/tmp/scp_abc/manager.ps1' -InstalledManagerPath 'C:\Program Files\App\manager.ps1' -InstalledManagerExists $true -RunningScriptContent 'SAME CONTENT' -InstalledManagerContent 'SAME CONTENT'
    Assert-That ($decision -eq $false) 'identical content should never trigger an upgrade, regardless of path'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: Get-ManagerUpgradeDecision -- different content, running from outside PROGRAM -> upgrade' -Body {
    $decision = Get-ManagerUpgradeDecision -RunningScriptPath '/tmp/scp_abc/manager.ps1' -InstalledManagerPath 'C:\Program Files\App\manager.ps1' -InstalledManagerExists $true -RunningScriptContent 'NEW VERSION' -InstalledManagerContent 'OLD VERSION'
    Assert-That ($decision -eq $true) 'different content while running from outside PROGRAM must trigger an upgrade -- this is the Setup.bat-from-%TEMP% field scenario'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: Get-ManagerUpgradeDecision -- no installed copy at all is never an upgrade (nothing to upgrade)' -Body {
    $decision = Get-ManagerUpgradeDecision -RunningScriptPath '/tmp/scp_abc/manager.ps1' -InstalledManagerPath 'C:\Program Files\App\manager.ps1' -InstalledManagerExists $false -RunningScriptContent 'NEW VERSION' -InstalledManagerContent $null
    Assert-That ($decision -eq $false) 'a missing installed copy must never crash or trigger an upgrade -- there is nothing there to upgrade'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: Test-ManagerUpgradeNeeded (disk-facing) -- real files, all three decision branches' -Body {
    $sbx = New-Sbx -Label 'upgrade-needed-disk'
    $programDir = Join-Path $sbx 'program'
    New-Item -ItemType Directory -Path $programDir -Force | Out-Null
    $installedManagerPath = Join-Path $programDir 'manager.ps1'
    Write-TextFile -Path $installedManagerPath -Content 'OLD MANAGER CONTENT'

    # Same path as the installed copy -> no upgrade regardless of content.
    Assert-That ((Test-ManagerUpgradeNeeded -RunningScriptPath $installedManagerPath -ProgramDir $programDir) -eq $false) 'running the installed copy itself must never be treated as an upgrade'

    # Different path, identical content -> no upgrade.
    $sameContentPath = Join-Path $sbx 'same-content-manager.ps1'
    Write-TextFile -Path $sameContentPath -Content 'OLD MANAGER CONTENT'
    Assert-That ((Test-ManagerUpgradeNeeded -RunningScriptPath $sameContentPath -ProgramDir $programDir) -eq $false) 'identical content from elsewhere on disk must not trigger an upgrade'

    # Different path, different content -> upgrade.
    $newerPath = Join-Path $sbx 'newer-manager.ps1'
    Write-TextFile -Path $newerPath -Content 'NEW MANAGER CONTENT'
    Assert-That ((Test-ManagerUpgradeNeeded -RunningScriptPath $newerPath -ProgramDir $programDir) -eq $true) 'different content from a different (outside-PROGRAM) path must trigger an upgrade'

    # No installed copy at all -> no upgrade, never throws.
    $freshProgramDir = Join-Path $sbx 'program-not-installed-yet'
    Assert-That ((Test-ManagerUpgradeNeeded -RunningScriptPath $newerPath -ProgramDir $freshProgramDir) -eq $false) 'a ProgramDir with no manager.ps1 at all must not throw and must not report an upgrade'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: Update-ManagerInstallationInPlace performs the real upgrade (Install-App) and rewrites only shortcuts that already exist' -Body {
    $script:ShortcutCalls.Clear()
    $sbx = New-Sbx -Label 'upgrade-inplace'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    $desktopDir = Join-Path $sbx 'desktop'
    $programsDir = Join-Path $sbx 'startmenu'

    # Simulate an existing (older) installation.
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    # Simulate a pre-launch.vbs Start Menu shortcut that already exists on
    # disk (the field symptom: it must be REWRITTEN, not left stale) --
    # only the Start Menu one exists; Desktop was never created (the
    # user's original choice, which must be respected -- no Desktop
    # shortcut should be created by the upgrade).
    $startMenuLnk = Join-Path $programsDir 'Stream Config Profiles.lnk'
    Write-TextFile -Path $startMenuLnk -Content 'stale shortcut placeholder'
    $desktopLnk = Join-Path $desktopDir 'Stream Config Profiles.lnk'
    Assert-That (-not (Test-Path -LiteralPath $desktopLnk)) 'sanity: the Desktop shortcut must not exist yet'

    # Simulate a NEWER running script (e.g. Setup.bat's %TEMP%-extracted
    # copy) with different content than what got installed above.
    $newerRunningScript = Join-Path $sbx 'newer-manager.ps1'
    $originalManagerContent = Read-TextFile $script:ManagerScriptSource
    Write-TextFile -Path $newerRunningScript -Content ($originalManagerContent + "`n# newer build marker`n")

    Update-ManagerInstallationInPlace -RunningManagerScriptPath $newerRunningScript -ProgramDir $programDir -DataDir $dataDir -ScriptDir $script:RepoRoot -DesktopDir $desktopDir -ProgramsDir $programsDir

    # Install-App must have actually re-run: PROGRAM\manager.ps1 now
    # matches the newer running script, not the original install.
    $installedManagerContent = Read-TextFile (Join-Path $programDir 'manager.ps1')
    Assert-That ($installedManagerContent -eq (Read-TextFile $newerRunningScript)) 'PROGRAM\manager.ps1 should be refreshed to match the newer running script'

    # Only the EXISTING (Start Menu) shortcut should have been rewritten;
    # no Desktop shortcut should have been created.
    Assert-That ($script:ShortcutCalls.Count -eq 1) "expected exactly 1 shortcut rewrite (Start Menu only, since it already existed), got $($script:ShortcutCalls.Count)"
    if ($script:ShortcutCalls.Count -eq 1) {
        Assert-That ($script:ShortcutCalls[0].ShortcutPath -eq $startMenuLnk) 'the one shortcut rewritten should be the pre-existing Start Menu one'
        Assert-That ($script:ShortcutCalls[0].Definition.TargetPath -match 'wscript') 'the rewritten shortcut should target wscript.exe (the current launch.vbs indirection), not powershell.exe directly'
    }
    Assert-That (-not (Test-Path -LiteralPath $desktopLnk)) 'Update-ManagerInstallationInPlace must never CREATE a Desktop shortcut the user never had'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: Update-ManagerInstallationInPlace creates no shortcuts at all when neither location already exists' -Body {
    $script:ShortcutCalls.Clear()
    $sbx = New-Sbx -Label 'upgrade-inplace-no-shortcuts'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    $desktopDir = Join-Path $sbx 'desktop'
    $programsDir = Join-Path $sbx 'startmenu'

    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    Update-ManagerInstallationInPlace -RunningManagerScriptPath $script:ManagerScriptSource -ProgramDir $programDir -DataDir $dataDir -ScriptDir $script:RepoRoot -DesktopDir $desktopDir -ProgramsDir $programsDir

    Assert-That ($script:ShortcutCalls.Count -eq 0) 'no shortcut file exists at either location -- the upgrade must not create one (respect the original no-shortcut choice)'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: Invoke-ManagerAutoUpgrade routes both the decision check and the upgrade itself through Invoke-GuiSafe (never throws, never blocks the Main Window)' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Invoke-ManagerAutoUpgrade \{.*?\n\}\r?\n\r?\nfunction Show-ManagerGui')
    Assert-That $body.Success 'sanity: should be able to locate Invoke-ManagerAutoUpgrade''s body'

    Assert-That ($body.Value -match [regex]::Escape('Invoke-GuiSafe -Action { Test-ManagerUpgradeNeeded')) 'the upgrade-needed check should run through Invoke-GuiSafe, not a bare call that could throw'
    Assert-That ($body.Value -match [regex]::Escape('Invoke-GuiSafe -Action {') -and $body.Value -match [regex]::Escape('Update-ManagerInstallationInPlace')) 'the actual upgrade (Install-App + shortcut refresh) should run through Invoke-GuiSafe'
    Assert-That (-not ($body.Value -match 'throw ')) 'Invoke-ManagerAutoUpgrade itself should never throw -- any failure must be swallowed by Invoke-GuiSafe so Show-ManagerGui can still open the Main Window'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: Show-ManagerGui only auto-upgrades on the Main Window path, never before the First-Run Wizard' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Show-ManagerGui \{.*?\n\}\r?\n\r?\n# =')
    Assert-That $body.Success 'sanity: should be able to locate Show-ManagerGui''s body'

    $wizardBranch = [regex]::Match($body.Value, '(?s)if\s*\(-not\s*\$engineInstalled\)\s*\{.*?\}\r?\n\s*else\s*\{(.*?)\}\r?\n\s*\}\r?\n\s*catch')
    Assert-That $wizardBranch.Success 'sanity: should be able to locate the engineInstalled if/else branches'

    $ifBranchText = [regex]::Match($body.Value, '(?s)if\s*\(-not\s*\$engineInstalled\)\s*\{(.*?)\}\r?\n\s*else')
    Assert-That $ifBranchText.Success 'sanity: should be able to isolate the First-Run Wizard branch'
    Assert-That (-not ($ifBranchText.Groups[1].Value -match 'Invoke-ManagerAutoUpgrade')) 'the First-Run Wizard branch must never call Invoke-ManagerAutoUpgrade -- there is nothing installed yet'

    Assert-That ($wizardBranch.Groups[1].Value -match 'Invoke-ManagerAutoUpgrade') 'the Main Window (else) branch must call Invoke-ManagerAutoUpgrade before Show-MainWindow'
    $upgradeIndex = $wizardBranch.Groups[1].Value.IndexOf('Invoke-ManagerAutoUpgrade')
    $showMainIndex = $wizardBranch.Groups[1].Value.IndexOf('Show-MainWindow')
    Assert-That ($upgradeIndex -ge 0 -and $showMainIndex -ge 0 -and $upgradeIndex -lt $showMainIndex) 'Invoke-ManagerAutoUpgrade must run BEFORE Show-MainWindow opens'
} | Out-Null

Invoke-Scenario -Name 'Upgrade detection: the headless -Action dispatch never reaches the auto-upgrade path (source-level)' -Body {
    $source = Read-TextFile $script:ManagerScriptSource

    $actionBody = [regex]::Match($source, '(?s)function Invoke-ManagerAction \{.*?\nfunction Test-ManagerResultIndicatesFailure')
    Assert-That $actionBody.Success 'sanity: should be able to locate Invoke-ManagerAction''s body'
    Assert-That (-not ($actionBody.Value -match 'Invoke-ManagerAutoUpgrade')) 'Invoke-ManagerAction (the headless -Action dispatcher) must never call Invoke-ManagerAutoUpgrade'
    Assert-That (-not ($actionBody.Value -match 'Show-ManagerGui')) 'Invoke-ManagerAction (the headless -Action dispatcher) must never call Show-ManagerGui either'

    # The bottom CLI dispatch: Show-ManagerGui (the only path that can reach
    # Invoke-ManagerAutoUpgrade) must be gated behind "no -Action given",
    # mutually exclusive with the -Action -> Invoke-ManagerAction branch.
    $dispatchBody = [regex]::Match($source, '(?s)if \(-not \[string\]::IsNullOrWhiteSpace\(\$Action\)\) \{(.*?)\r?\n    \}\r?\n    else \{(.*?)\r?\n    \}\r?\n\}\r?\n\z')
    Assert-That $dispatchBody.Success 'sanity: should be able to locate the bottom Action/no-Action CLI dispatch'
    Assert-That ($dispatchBody.Groups[1].Value -match 'Invoke-ManagerAction') 'the -Action branch should call Invoke-ManagerAction'
    Assert-That (-not ($dispatchBody.Groups[1].Value -match 'Show-ManagerGui')) 'the -Action branch must never call Show-ManagerGui (and therefore never Invoke-ManagerAutoUpgrade)'
    Assert-That ($dispatchBody.Groups[2].Value -match 'Show-ManagerGui') 'the no-Action (GUI) branch should call Show-ManagerGui'
} | Out-Null

# ===========================================================================
# Auto-upgrade path repointing (SECURITY): mirrors the wizard's own
# Show-WizardInstallStep -> $State.ManagerScriptPath = $r.ManagerPath fix
# (pinned above at "a successful install repoints State.ManagerScriptPath").
# Without this, every elevation the Main Window can perform after an
# auto-upgrade (register/unregister-watchdog, Disconnect/Uninstall, Connect)
# would keep re-elevating against the pre-upgrade running path -- a
# %TEMP%\scp_<guid>\manager.ps1 extraction when launched via Setup.bat,
# writable by any other process on the box for as long as this GUI runs.
# ===========================================================================

Invoke-Scenario -Name 'Update-ManagerInstallationInPlace: returns Install-App''s own result object (not discarded), so callers can read .ManagerPath' -Body {
    $sbx = New-Sbx -Label 'upgrade-inplace-return-value'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    $desktopDir = Join-Path $sbx 'desktop'
    $programsDir = Join-Path $sbx 'startmenu'

    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $result = Update-ManagerInstallationInPlace -RunningManagerScriptPath $script:ManagerScriptSource -ProgramDir $programDir -DataDir $dataDir -ScriptDir $script:RepoRoot -DesktopDir $desktopDir -ProgramsDir $programsDir

    $expectedManagerPath = Join-Path $programDir 'manager.ps1'
    Assert-That ($null -ne $result) 'Update-ManagerInstallationInPlace should return a value, not discard Install-App''s result'
    Assert-That ($result.ManagerPath -eq $expectedManagerPath) "Update-ManagerInstallationInPlace's return value should expose .ManagerPath = $expectedManagerPath (got '$($result.ManagerPath)') -- this is what Invoke-ManagerAutoUpgrade needs to repoint ManagerScriptPath at PROGRAM after a successful upgrade"
} | Out-Null

Invoke-Scenario -Name 'Update-ManagerInstallationInPlace: a shortcut refresh failure at one location is best-effort -- the other location still refreshes and the function still returns normally' -Body {
    $script:ShortcutCalls.Clear()
    $sbx = New-Sbx -Label 'upgrade-inplace-shortcut-best-effort'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    $desktopDir = Join-Path $sbx 'desktop'
    $programsDir = Join-Path $sbx 'startmenu'

    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    # Both shortcut locations already exist on disk (both must be
    # considered for refresh)...
    $desktopLnk = Join-Path $desktopDir 'Stream Config Profiles.lnk'
    Write-TextFile -Path $desktopLnk -Content 'stale desktop shortcut placeholder'
    $startMenuLnk = Join-Path $programsDir 'Stream Config Profiles.lnk'
    Write-TextFile -Path $startMenuLnk -Content 'stale start menu shortcut placeholder'

    # ...but the Desktop one is simulated as locked/read-only (New-ShortcutFile
    # throws for it specifically, exactly like New-ManagerShortcut's own
    # per-location failure scenario above).
    $script:ShortcutCreateShouldThrowFor = @($desktopLnk)
    try {
        $result = $null
        $threw = $false
        try {
            $result = Update-ManagerInstallationInPlace -RunningManagerScriptPath $script:ManagerScriptSource -ProgramDir $programDir -DataDir $dataDir -ScriptDir $script:RepoRoot -DesktopDir $desktopDir -ProgramsDir $programsDir
        }
        catch {
            $threw = $true
        }

        Assert-That (-not $threw) 'a single shortcut-location failure must never propagate out of Update-ManagerInstallationInPlace (best-effort, exactly like New-ManagerShortcut''s own per-location try/catch)'
        Assert-That ($null -ne $result -and $result.ManagerPath -eq (Join-Path $programDir 'manager.ps1')) 'Install-App''s own result must still be returned even when a later shortcut refresh fails'

        $startMenuCall = @($script:ShortcutCalls | Where-Object { $_.ShortcutPath -eq $startMenuLnk })
        Assert-That (@($startMenuCall).Count -eq 1) 'the Start Menu shortcut (the one that did NOT fail) must still have been refreshed despite the Desktop one throwing'
    }
    finally {
        $script:ShortcutCreateShouldThrowFor = @()
    }
} | Out-Null

Invoke-Scenario -Name 'Invoke-ManagerAutoUpgrade: returns the original running path unchanged when no upgrade is needed (safe to call live -- never reaches the WinForms-only success path)' -Body {
    $sbx = New-Sbx -Label 'auto-upgrade-no-upgrade-needed'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null
    $installedManagerPath = Join-Path $programDir 'manager.ps1'

    # Running FROM the installed copy itself -- Get-ManagerUpgradeDecision's
    # path-equality guard means no upgrade is needed, so this returns before
    # ever reaching the MessageBox-showing success branch (unreachable on
    # this headless Linux host, which has no System.Windows.Forms at all).
    $returnedPath = Invoke-ManagerAutoUpgrade -RunningManagerScriptPath $installedManagerPath -ProgramDir $programDir -DataDir $dataDir -ScriptDir $script:RepoRoot
    Assert-That ($returnedPath -eq $installedManagerPath) 'running from the installed copy itself needs no upgrade, so the path should be returned unchanged'
} | Out-Null

Invoke-Scenario -Name 'Invoke-ManagerAutoUpgrade (source-level): the success branch repoints its return value at Update-ManagerInstallationInPlace''s own ManagerPath, not the pre-upgrade running path' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Invoke-ManagerAutoUpgrade \{.*?\n\}\r?\n\r?\nfunction Show-ManagerGui')
    Assert-That $body.Success 'sanity: should be able to locate Invoke-ManagerAutoUpgrade''s body'

    Assert-That ($body.Value -match [regex]::Escape('return $RunningManagerScriptPath')) 'Invoke-ManagerAutoUpgrade should fall back to returning the path it was given (no upgrade needed, or the upgrade failed)'
    Assert-That ($body.Value -match [regex]::Escape('$upgradeOutcome.Value.ManagerPath')) 'the success branch should read .ManagerPath off Update-ManagerInstallationInPlace''s own return value'
    $returnManagerPathIndex = $body.Value.IndexOf('return [string]$upgradeOutcome.Value.ManagerPath')
    Assert-That ($returnManagerPathIndex -ge 0) 'a successful upgrade should return the freshly-written PROGRAM manager path, not fall through to the pre-upgrade path'
} | Out-Null

Invoke-Scenario -Name 'Show-ManagerGui (source-level): captures Invoke-ManagerAutoUpgrade''s return value and hands THAT to Show-MainWindow -- not the pre-upgrade $resolvedManagerScriptPath directly' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Show-ManagerGui \{.*?\n\}\r?\n\r?\n# =')
    Assert-That $body.Success 'sanity: should be able to locate Show-ManagerGui''s body'

    Assert-That ($body.Value -match [regex]::Escape('Invoke-ManagerAutoUpgrade -RunningManagerScriptPath $resolvedManagerScriptPath')) 'Invoke-ManagerAutoUpgrade should still be called with the running script''s own resolved path'
    Assert-That ($body.Value -match '\$\w+\s*=\s*Invoke-ManagerAutoUpgrade\b') 'Invoke-ManagerAutoUpgrade''s return value must be captured into a variable, not discarded, so a successful auto-upgrade can repoint the path used afterward'
    Assert-That (-not ($body.Value -match [regex]::Escape('Show-MainWindow -ScriptDir $resolvedScriptDir -ProgramDir $resolvedProgramDir -DataDir $resolvedDataDir -ManagerScriptPath $resolvedManagerScriptPath'))) 'Show-MainWindow must not be called with the pre-upgrade $resolvedManagerScriptPath directly any more -- it must use Invoke-ManagerAutoUpgrade''s (possibly repointed) return value instead'
} | Out-Null

# ===========================================================================
# Install-App atomicity ordering: PROGRAM (manager.ps1/launch.vbs) is
# written before DATA (engine/template), so a mid-Install-App failure never
# leaves PROGRAM pointing at a manager.ps1 that is older than what
# Get-ManagerUpgradeDecision would have already treated as "no upgrade
# needed" on the next launch (see Install-App's own comment for the full
# failure-mode analysis).
# ===========================================================================

Invoke-Scenario -Name 'Install-App (source-level): PROGRAM\manager.ps1 is written before DATA\sync-configs.ps1' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Install-App \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $body.Success 'sanity: should be able to locate Install-App''s body'

    $managerWriteIndex = $body.Value.IndexOf("Join-Path `$ProgramDir 'manager.ps1'")
    $engineWriteIndex = $body.Value.IndexOf("Join-Path `$DataDir 'sync-configs.ps1'")
    Assert-That ($managerWriteIndex -ge 0 -and $engineWriteIndex -ge 0) 'sanity: should be able to locate both destination-path computations'
    Assert-That ($managerWriteIndex -lt $engineWriteIndex) 'PROGRAM\manager.ps1 (and launch.vbs, written right after it) must be written before DATA\sync-configs.ps1 -- a failure partway through must never leave PROGRAM stale while DATA already reflects the new version'
} | Out-Null

# ===========================================================================
# global_prep_cmd conf round-trip
# ===========================================================================

function New-ConfFixture {
    param([string]$Path, [string]$Content)
    Write-TextFile -Path $Path -Content $Content
}

Invoke-Scenario -Name 'Conf: Add-PrepCommandEntry creates the key when absent, preserves other lines' -Body {
    $sbx = New-Sbx -Label 'conf-add-missing-key'
    $confPath = Join-Path $sbx 'sunshine.conf'
    $original = "origin_web_ui_allowed = lan`nsunshine_name = MyPC`n"
    New-ConfFixture -Path $confPath -Content $original

    $dataDir = Join-Path $sbx 'data'
    $result = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir

    Assert-That $result.Success 'Add-PrepCommandEntry should succeed'
    Assert-That (-not [string]::IsNullOrWhiteSpace($result.BackupPath)) 'a backup path should be returned'
    Assert-That (Test-Path -LiteralPath $result.BackupPath) 'the backup file should exist on disk'
    Assert-That ((Read-TextFile $result.BackupPath) -eq $original) 'the backup should hold the pre-write original content'

    $newContent = Read-TextFile $confPath
    Assert-That ($newContent -match [regex]::Escape('origin_web_ui_allowed = lan')) 'unrelated line 1 should be preserved'
    Assert-That ($newContent -match [regex]::Escape('sunshine_name = MyPC')) 'unrelated line 2 should be preserved'
    Assert-That ($newContent -match 'global_prep_cmd = ') 'global_prep_cmd key should now exist'

    $enginePath = Join-Path $dataDir 'sync-configs.ps1'
    $entries = (Get-PrepCommandEntries -ConfPath $confPath).Entries
    Assert-That (@($entries).Count -eq 1) "expected exactly 1 entry, found $(@($entries).Count)"
    Assert-That ($entries[0].do -match [regex]::Escape($enginePath)) 'the entry do-command should reference the DATA engine path'
    Assert-That ($entries[0].do -match '-Mode do') 'the do-command should use -Mode do'
    Assert-That ($entries[0].undo -match '-Mode undo') 'the undo-command should use -Mode undo'
} | Out-Null

Invoke-Scenario -Name 'Conf: Add-PrepCommandEntry merges with an existing unrelated entry' -Body {
    $sbx = New-Sbx -Label 'conf-add-merge'
    $confPath = Join-Path $sbx 'apollo.conf'
    $otherEntryJson = '[{"do":"C:\\other\\tool.exe start","undo":"C:\\other\\tool.exe stop","elevated":false}]'
    $original = "some_key = value`nglobal_prep_cmd = $otherEntryJson`nanother_key = 123`n"
    New-ConfFixture -Path $confPath -Content $original

    $dataDir = Join-Path $sbx 'data'
    $result = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That $result.Success 'Add-PrepCommandEntry should succeed'

    $newContent = Read-TextFile $confPath
    Assert-That ($newContent -match [regex]::Escape('some_key = value')) 'unrelated line before the key should be preserved'
    Assert-That ($newContent -match [regex]::Escape('another_key = 123')) 'unrelated line after the key should be preserved'

    $entries = (Get-PrepCommandEntries -ConfPath $confPath).Entries
    Assert-That (@($entries).Count -eq 2) "expected 2 entries (other tool + ours), found $(@($entries).Count)"
    $otherStillPresent = @($entries | Where-Object { $_.do -match 'other\\tool\.exe' })
    Assert-That (@($otherStillPresent).Count -eq 1) 'the other tool entry should still be present'
} | Out-Null

Invoke-Scenario -Name 'Conf: Add-PrepCommandEntry is idempotent -- adding twice yields a single entry' -Body {
    $sbx = New-Sbx -Label 'conf-add-twice'
    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "k = v`n"
    $dataDir = Join-Path $sbx 'data'

    Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir | Out-Null
    $result2 = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That $result2.Success 'second Add-PrepCommandEntry should succeed'

    $entries = (Get-PrepCommandEntries -ConfPath $confPath).Entries
    Assert-That (@($entries).Count -eq 1) "expected exactly 1 entry after adding twice, found $(@($entries).Count)"
} | Out-Null

Invoke-Scenario -Name 'Conf: Remove-PrepCommandEntry deletes only our entry' -Body {
    $sbx = New-Sbx -Label 'conf-remove'
    $confPath = Join-Path $sbx 'sunshine.conf'
    $otherEntryJson = '[{"do":"C:\\other\\tool.exe start","undo":"C:\\other\\tool.exe stop","elevated":false}]'
    New-ConfFixture -Path $confPath -Content "global_prep_cmd = $otherEntryJson`n"
    $dataDir = Join-Path $sbx 'data'

    Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir | Out-Null
    $afterAdd = (Get-PrepCommandEntries -ConfPath $confPath).Entries
    Assert-That (@($afterAdd).Count -eq 2) 'sanity: should have 2 entries before removal'

    $result = Remove-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That $result.Success 'Remove-PrepCommandEntry should succeed'
    Assert-That (-not [string]::IsNullOrWhiteSpace($result.BackupPath)) 'a backup should be created before removal'

    $afterRemove = (Get-PrepCommandEntries -ConfPath $confPath).Entries
    Assert-That (@($afterRemove).Count -eq 1) "expected exactly 1 entry after removal, found $(@($afterRemove).Count)"
    Assert-That ($afterRemove[0].do -match 'other\\tool\.exe') 'the remaining entry should be the other tool, not ours'

    $enginePath = Join-Path $dataDir 'sync-configs.ps1'
    $stillOurs = @($afterRemove | Where-Object { $_.do -match [regex]::Escape($enginePath) })
    Assert-That (@($stillOurs).Count -eq 0) 'our entry must be gone'
} | Out-Null

Invoke-Scenario -Name 'Conf: malformed JSON fails cleanly and leaves the file untouched' -Body {
    $sbx = New-Sbx -Label 'conf-malformed'
    $confPath = Join-Path $sbx 'sunshine.conf'
    $original = "some_key = value`nglobal_prep_cmd = {this is not valid json`n"
    New-ConfFixture -Path $confPath -Content $original
    $dataDir = Join-Path $sbx 'data'

    $result = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That (-not $result.Success) 'Add-PrepCommandEntry should report failure on malformed JSON'
    Assert-That (-not [string]::IsNullOrWhiteSpace($result.Message)) 'a clear error message should be returned'
    Assert-That ((Read-TextFile $confPath) -eq $original) 'the conf file must be completely untouched on malformed JSON'

    $backupCount = @(Get-ChildItem -LiteralPath $sbx -Filter '*.bak').Count
    Assert-That ($backupCount -eq 0) 'no backup should be created when nothing is written'

    $removeResult = Remove-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That (-not $removeResult.Success) 'Remove-PrepCommandEntry should also report failure on malformed JSON'
    Assert-That ((Read-TextFile $confPath) -eq $original) 'the conf file must remain untouched after a failed remove too'
} | Out-Null

Invoke-Scenario -Name 'Conf: missing global_prep_cmd key is treated as zero entries, not an error' -Body {
    $sbx = New-Sbx -Label 'conf-missing-key'
    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "some_key = value`n"

    $result = Get-PrepCommandEntries -ConfPath $confPath
    Assert-That $result.Success 'a missing key should not be a failure'
    Assert-That (-not $result.KeyFound) 'KeyFound should be false'
    Assert-That (@($result.Entries).Count -eq 0) 'Entries should be empty'
} | Out-Null

Invoke-Scenario -Name 'Conf: Get-PrepCommandEntries fails clearly when the conf file does not exist' -Body {
    $sbx = New-Sbx -Label 'conf-nonexistent'
    $confPath = Join-Path $sbx 'does-not-exist.conf'
    $result = Get-PrepCommandEntries -ConfPath $confPath
    Assert-That (-not $result.Success) 'a missing conf file should be a failure'
} | Out-Null

# ===========================================================================
# Watchdog task definition builders
# ===========================================================================

Invoke-Scenario -Name 'Watchdog: Get-WatchdogTaskDefinitions default (Logon only)' -Body {
    $dataDir = '/fake/data'
    $defs = Get-WatchdogTaskDefinitions -DataDir $dataDir -UserId 'TestUser'
    Assert-That (@($defs).Count -eq 1) "expected exactly 1 task by default, found $(@($defs).Count)"
    Assert-That ($defs[0].Name -eq 'StreamConfigProfiles-Settle-Logon') 'default task should be the Logon task'
    Assert-That (-not $defs[0].NeedsAdmin) 'Logon task should not need admin'
    Assert-That (@($defs[0].Triggers) -contains 'AtLogOn') 'Logon task should have an AtLogOn trigger'
    Assert-That (@($defs[0].Triggers) -contains 'OnUnlock') 'Logon task should have an OnUnlock trigger'

    $expectedEngine = Join-Path $dataDir 'sync-configs.ps1'
    Assert-That ($defs[0].Action -match [regex]::Escape($expectedEngine)) 'action should point at the DATA engine path'
    Assert-That ($defs[0].Action -match '-Mode settle') 'action should use -Mode settle'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Get-WatchdogTaskDefinitions contains exactly Logon (AtLogOn + SessionUnlock) and optional Poll -- no Boot task ever' -Body {
    # Contract B: the AtStartup/Boot task is removed from the product
    # entirely. Local play after a reboot always requires a logon first,
    # and the Logon task's AtLogOn trigger already fires at exactly that
    # moment, so a SYSTEM-level AtStartup task would only ever add an
    # elevation-and-escalation surface for zero additional protection.
    # There is deliberately no -IncludeBoot switch any more.
    $defaultDefs = Get-WatchdogTaskDefinitions -DataDir '/fake/data' -UserId 'TestUser'
    Assert-That (@($defaultDefs).Count -eq 1) "default definitions should contain exactly one task (Logon), found $(@($defaultDefs).Count)"
    Assert-That ($defaultDefs[0].Name -eq 'StreamConfigProfiles-Settle-Logon') 'the only default task should be Logon'
    Assert-That (@($defaultDefs[0].Triggers) -contains 'AtLogOn') 'Logon task should have an AtLogOn trigger'
    Assert-That (@($defaultDefs[0].Triggers) -contains 'OnUnlock') 'Logon task should have a session-unlock trigger'
    Assert-That (@($defaultDefs | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Boot' }).Count -eq 0) 'no Boot task should exist in the default definition set'

    $pollDefs = Get-WatchdogTaskDefinitions -DataDir '/fake/data' -UserId 'TestUser' -IncludePoll -PollMinutes 20
    Assert-That (@($pollDefs).Count -eq 2) "definitions with -IncludePoll should contain exactly two tasks (Logon, Poll), found $(@($pollDefs).Count)"
    $pollDefNames = @($pollDefs | ForEach-Object { $_.Name })
    Assert-That ($pollDefNames -contains 'StreamConfigProfiles-Settle-Logon') 'Logon task should still be present alongside Poll'
    Assert-That ($pollDefNames -contains 'StreamConfigProfiles-Settle-Poll') 'Poll task should be present when -IncludePoll is passed'
    Assert-That (-not ($pollDefNames -contains 'StreamConfigProfiles-Settle-Boot')) 'no Boot task should exist even with -IncludePoll'

    $cmd = Get-Command -Name Get-WatchdogTaskDefinitions
    Assert-That (-not $cmd.Parameters.ContainsKey('IncludeBoot')) 'Get-WatchdogTaskDefinitions should not accept -IncludeBoot any more'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: -IncludePoll adds the poll task with the requested (valid) interval' -Body {
    $defs = Get-WatchdogTaskDefinitions -DataDir '/fake/data' -UserId 'TestUser' -IncludePoll -PollMinutes 30
    $poll = @($defs | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })
    Assert-That (@($poll).Count -eq 1) 'poll task should be present'
    Assert-That (-not $poll[0].NeedsAdmin) 'poll task should not need admin (user-level)'
    Assert-That ($poll[0].PollMinutes -eq 30) "expected PollMinutes 30, got $($poll[0].PollMinutes)"
    Assert-That (@($poll[0].Triggers) -contains 'Repeat') 'poll task should have a Repeat trigger'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: poll interval is clamped to a minimum of 5 minutes' -Body {
    $defs = Get-WatchdogTaskDefinitions -DataDir '/fake/data' -UserId 'TestUser' -IncludePoll -PollMinutes 1
    $poll = @($defs | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })
    Assert-That ($poll[0].PollMinutes -eq 5) "expected PollMinutes clamped to 5, got $($poll[0].PollMinutes)"
} | Out-Null

Invoke-Scenario -Name 'Watchdog: poll task is OFF by default (no -IncludePoll)' -Body {
    $defs = Get-WatchdogTaskDefinitions -DataDir '/fake/data' -UserId 'TestUser'
    $poll = @($defs | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })
    Assert-That (@($poll).Count -eq 0) 'poll task must not be present unless -IncludePoll is passed'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Get-WatchdogTaskDefinitions -IncludeLogon:$false omits the Logon task entirely (poll-only never attempts the elevation-eligible registration)' -Body {
    # Registering the Logon task (AtLogOn + session-unlock) is the
    # operation that can prompt Windows for administrator approval, even
    # though its principal is the calling user (see Register-Watchdog).
    # A poll-only selection must never even ATTEMPT that registration, or
    # unchecking Logon in the GUI would still trigger a spurious elevation
    # prompt for a task the user explicitly does not want.
    $noneDefs = Get-WatchdogTaskDefinitions -DataDir '/fake/data' -UserId 'TestUser' -IncludeLogon:$false
    Assert-That (@($noneDefs).Count -eq 0) "with -IncludeLogon:`$false and no -IncludePoll, no tasks should be produced at all, found $(@($noneDefs).Count)"

    $pollOnlyDefs = Get-WatchdogTaskDefinitions -DataDir '/fake/data' -UserId 'TestUser' -IncludeLogon:$false -IncludePoll -PollMinutes 10
    Assert-That (@($pollOnlyDefs).Count -eq 1) "with -IncludeLogon:`$false -IncludePoll, exactly the Poll task should be produced, found $(@($pollOnlyDefs).Count)"
    Assert-That ($pollOnlyDefs[0].Name -eq 'StreamConfigProfiles-Settle-Poll') 'the sole poll-only task should be Poll'

    $defaultDefs = Get-WatchdogTaskDefinitions -DataDir '/fake/data' -UserId 'TestUser'
    Assert-That (@($defaultDefs | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Logon' }).Count -eq 1) '-IncludeLogon should default to on (present) when omitted, matching every existing headless caller'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Register-Watchdog drives the isolated cmdlet wrappers (shimmed), not real ScheduledTasks' -Body {
    $script:WatchdogCalls.Clear()
    $results = Register-Watchdog -DataDir '/fake/data' -UserId 'TestUser' -IncludePoll -PollMinutes 10
    Assert-That (@($results | Where-Object { -not $_.Success }).Count -eq 0) 'all registrations should report success against the shim'

    $registerCalls = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Register' })
    Assert-That (@($registerCalls).Count -eq 2) "expected 2 Register calls (Logon+Poll), got $(@($registerCalls).Count)"

    $names = @($registerCalls | ForEach-Object { $_.Name })
    Assert-That ($names -contains 'StreamConfigProfiles-Settle-Logon') 'Logon task should have been registered'
    Assert-That ($names -contains 'StreamConfigProfiles-Settle-Poll') 'Poll task should have been registered'
    Assert-That (-not ($names -contains 'StreamConfigProfiles-Settle-Boot')) 'a Boot task should never be registered -- there is no registration path for it any more'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Register-Watchdog always registers a Limited-RunLevel, Interactive/resolved-user principal (registering the Logon trigger may still need admin approval)' -Body {
    # The task's own RUNTIME principal (RunLevel/LogonType/UserId) is a
    # separate axis from whether REGISTERING it needs elevation: on real
    # Windows, Register-ScheduledTask needs administrator approval to
    # create the Logon task's session-unlock/AtLogOn triggers even though
    # the principal being registered is the calling user themself. Every
    # real task definition today is still Limited/Interactive/user-level --
    # there is no admin-principal path left to exercise -- but that is no
    # longer the same claim as "registering it never needs elevation" (see
    # Invoke-GuiElevatable's register-watchdog/unregister-watchdog routing).
    $script:WatchdogCalls.Clear()
    Register-Watchdog -DataDir '/fake/data' -UserId 'ExplicitUser' -IncludePoll -PollMinutes 10 | Out-Null

    $registerCalls = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Register' })
    $logon = @($registerCalls | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Logon' })[0]
    $poll = @($registerCalls | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })[0]

    Assert-That (-not $logon.NeedsAdmin) 'Logon task RunLevel should still be Limited (not an admin principal)'
    Assert-That ($logon.LogonType -eq 'Interactive') "Logon task LogonType should be Interactive, got '$($logon.LogonType)'"
    Assert-That ($logon.UserId -eq 'ExplicitUser') "Logon task UserId should be the resolved caller-supplied UserId, got '$($logon.UserId)'"
    Assert-That (-not $poll.NeedsAdmin) 'Poll task RunLevel should still be Limited (not an admin principal)'
    Assert-That ($poll.LogonType -eq 'Interactive') "Poll task LogonType should be Interactive, got '$($poll.LogonType)'"
    Assert-That ($poll.UserId -eq 'ExplicitUser') "Poll task UserId should be the resolved caller-supplied UserId, got '$($poll.UserId)'"
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Register-Watchdog -IncludeLogon:$false registers only Poll -- a poll-only selection never attempts the elevation-eligible Logon registration' -Body {
    $script:WatchdogCalls.Clear()
    $results = Register-Watchdog -DataDir '/fake/data' -UserId 'TestUser' -IncludeLogon:$false -IncludePoll -PollMinutes 10

    $registerCalls = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Register' })
    Assert-That (@($registerCalls).Count -eq 1) "expected exactly 1 Register call (Poll only) with -IncludeLogon:`$false, got $(@($registerCalls).Count)"
    Assert-That ($registerCalls[0].Name -eq 'StreamConfigProfiles-Settle-Poll') 'the only task registered should be Poll'
    Assert-That (-not ($registerCalls | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Logon' })) 'the Logon task must not even be attempted when -IncludeLogon:$false'
    Assert-That (@($results | Where-Object { -not $_.Success }).Count -eq 0) 'a poll-only registration should always succeed against the shim (and, on real Windows, unelevated -- the poll trigger never needs admin)'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Register-Watchdog is a desired-state reconciler -- unchecking Logon in the SAME call unregisters an already-registered Logon task, not just skips registering it' -Body {
    # Regression for the GUI reconcile-delete bug: the wizard/main window
    # used to unregister the "other direction" (unchecked box) via a
    # SEPARATE Invoke-GuiSafe call, unelevated, after this one. Once
    # registration itself could need elevation, that separate delete could
    # fail against an admin-owned task with no elevated-retry path of its
    # own. Folding the removal into Register-Watchdog means the single
    # Invoke-GuiElevatable wrapper around this call covers both directions.
    $script:WatchdogCalls.Clear()
    $results = Register-Watchdog -DataDir '/fake/data' -UserId 'TestUser' -IncludeLogon:$false -IncludePoll -PollMinutes 10

    $unregisterCalls = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Unregister' })
    Assert-That (@($unregisterCalls | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Logon' }).Count -eq 1) 'unchecking Logon should unregister it in the same Register-Watchdog call, not just skip registering it'
    Assert-That (-not ($unregisterCalls | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })) 'Poll was requested, so it must not be reconcile-unregistered'
    $pollResult = @($results | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })[0]
    $logonResult = @($results | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Logon' })[0]
    Assert-That ($pollResult.Success -and $pollResult.Message -eq 'registered') 'Poll should still report a normal registration result'
    Assert-That ($logonResult.Success) 'the reconcile-unregister of Logon should report success against the shim'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Register-Watchdog reconcile-unregister does NOT register-then-delete -- an unrequested task is never attempted as a registration in the first place' -Body {
    $script:WatchdogCalls.Clear()
    Register-Watchdog -DataDir '/fake/data' -UserId 'TestUser' -IncludePoll -PollMinutes 10 | Out-Null

    # Default IncludeLogon:$true + explicit -IncludePoll -> both desired,
    # nothing to reconcile-unregister.
    Assert-That (@($script:WatchdogCalls | Where-Object { $_.Op -eq 'Unregister' }).Count -eq 0) 'when both tasks are desired, Register-Watchdog should not attempt to unregister anything'

    $script:WatchdogCalls.Clear()
    Register-Watchdog -DataDir '/fake/data' -UserId 'TestUser' -IncludeLogon:$false -PollMinutes 10 | Out-Null

    # Neither task desired here (-IncludeLogon:$false, no -IncludePoll):
    # both should be reconcile-unregistered, and NEITHER should ever appear
    # as a Register call first.
    $ops = @($script:WatchdogCalls | ForEach-Object { $_.Op })
    Assert-That (-not ($ops -contains 'Register')) 'no task was requested, so Register-Watchdog must never attempt a Register call'
    $unregisteredNames = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Unregister' } | ForEach-Object { $_.Name })
    Assert-That ($unregisteredNames -contains 'StreamConfigProfiles-Settle-Logon') 'Logon should be reconcile-unregistered when not requested'
    Assert-That ($unregisteredNames -contains 'StreamConfigProfiles-Settle-Poll') 'Poll should be reconcile-unregistered when not requested'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Register-Watchdog surfaces a failed reconcile-unregister as Success=$false, making it visible to Invoke-GuiElevatable' -Body {
    $script:UnregisterShouldThrowFor = @('StreamConfigProfiles-Settle-Logon')
    try {
        $script:WatchdogCalls.Clear()
        $results = Register-Watchdog -DataDir '/fake/data' -UserId 'TestUser' -IncludeLogon:$false -IncludePoll -PollMinutes 10
        Assert-That (Test-ManagerResultIndicatesFailure -Result $results) 'a denied reconcile-unregister of an admin-owned Logon task must surface as an overall Success=$false, so Invoke-GuiElevatable can offer the elevated retry'
    }
    finally {
        $script:UnregisterShouldThrowFor = @()
    }
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Get-SettleAction produces the exact contract-mandated command string' -Body {
    # The contract is specific: -NoProfile AND -WindowStyle Hidden AND
    # -ExecutionPolicy Bypass, in that order, ahead of -File "..." -Mode
    # settle. A substring/regex check alone would not catch a missing
    # -NoProfile or -WindowStyle Hidden shipping silently.
    $dataDir = Join-Path (New-Sbx -Label 'settle-action') 'stream-config-profiles'
    $enginePath = Join-Path $dataDir 'sync-configs.ps1'
    $expected = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $enginePath + '" -Mode settle'
    $actual = Get-SettleAction -DataDir $dataDir
    Assert-That ($actual -ceq $expected) "Get-SettleAction should produce the exact contract string.`nexpected: $expected`nactual:   $actual"
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Unregister-Watchdog unregisters Logon+Poll and best-effort-removes a legacy Boot task the shim reports present' -Body {
    $script:WatchdogCalls.Clear()
    $results = Unregister-Watchdog
    Assert-That (@($results).Count -eq 3) "expected 3 unregister results (Logon, Poll, legacy Boot cleanup), got $(@($results).Count)"

    $unregisterCalls = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Unregister' })
    $names = @($unregisterCalls | ForEach-Object { $_.Name })
    Assert-That ($names -contains 'StreamConfigProfiles-Settle-Logon') 'Logon task should have been unregistered'
    Assert-That ($names -contains 'StreamConfigProfiles-Settle-Poll') 'Poll task should have been unregistered'
    Assert-That ($names -contains 'StreamConfigProfiles-Settle-Boot') 'a legacy Boot task should still be attempted, for anyone who installed the interim build that registered one'

    Assert-That (@($results | Where-Object { -not $_.Success }).Count -eq 0) 'every result should report Success when the shim does not throw'
} | Out-Null

Invoke-Scenario -Name 'Watchdog: Unregister-Watchdog treats a failed legacy Boot removal as best-effort, never as an overall failure' -Body {
    # Simulates the real-world case: a leftover admin-level Boot task from
    # an earlier build can only be deleted by an elevated process, so an
    # unelevated Unregister-Watchdog call is expected to hit access-denied
    # trying. That must never surface as a failure that could trigger an
    # elevation retry -- unregistering the watchdog must never itself
    # demand elevation (Contract B).
    $script:WatchdogCalls.Clear()
    $script:UnregisterShouldThrowFor = @('StreamConfigProfiles-Settle-Boot')
    try {
        $results = Unregister-Watchdog
    }
    finally {
        $script:UnregisterShouldThrowFor = @()
    }

    $boot = @($results | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Boot' })[0]
    Assert-That ($null -ne $boot) 'a legacy Boot result should still be present even when the underlying delete throws'
    Assert-That ($boot.Success) 'a failed legacy Boot removal must still report Success=$true (best-effort, not a real failure)'
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result $results)) 'a failed legacy Boot removal must never make Unregister-Watchdog look like an overall failure needing elevation'

    $logon = @($results | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Logon' })[0]
    $poll = @($results | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })[0]
    Assert-That ($logon.Success) 'Logon removal should still succeed against the shim'
    Assert-That ($poll.Success) 'Poll removal should still succeed against the shim'
} | Out-Null

# ===========================================================================
# Uninstall keeps DATA without -RemoveData
# ===========================================================================

Invoke-Scenario -Name 'Uninstall-App: removes PROGRAM, keeps DATA by default' -Body {
    $sbx = New-Sbx -Label 'uninstall-keep-data'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'

    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null
    $pathsTxt = Join-Path $dataDir 'paths.txt'
    Write-TextFile -Path $pathsTxt -Content 'C:\MyGame\config.ini'
    $stateFile = Join-Path $dataDir 'state.json'
    Write-TextFile -Path $stateFile -Content '{"activeClient":"iPad"}'

    Assert-That (Test-Path -LiteralPath $programDir) 'sanity: PROGRAM should exist before uninstall'
    Assert-That (Test-Path -LiteralPath $dataDir) 'sanity: DATA should exist before uninstall'

    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $null

    Assert-That $summary.ProgramDirRemoved 'summary should report PROGRAM removed'
    Assert-That (-not (Test-Path -LiteralPath $programDir)) 'PROGRAM directory should actually be gone'

    Assert-That (-not $summary.DataDirRemoved) 'summary should report DATA NOT removed (no -RemoveData)'
    Assert-That (Test-Path -LiteralPath $dataDir) 'DATA directory should still exist'
    Assert-That ((Read-TextFile $pathsTxt) -eq 'C:\MyGame\config.ini') 'paths.txt content should be intact'
    Assert-That ((Read-TextFile $stateFile) -eq '{"activeClient":"iPad"}') 'state.json content should be intact'
} | Out-Null

Invoke-Scenario -Name 'Uninstall-App: -RemoveData also removes DATA' -Body {
    $sbx = New-Sbx -Label 'uninstall-remove-data'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'

    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $null -RemoveData

    Assert-That $summary.ProgramDirRemoved 'summary should report PROGRAM removed'
    Assert-That $summary.DataDirRemoved 'summary should report DATA removed'
    Assert-That (-not (Test-Path -LiteralPath $programDir)) 'PROGRAM directory should be gone'
    Assert-That (-not (Test-Path -LiteralPath $dataDir)) 'DATA directory should be gone'
} | Out-Null

Invoke-Scenario -Name 'Uninstall-App: does not restart the host service when no conf entry was actually removed' -Body {
    $sbx = New-Sbx -Label 'uninstall-no-restart-without-removal'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    # No ConfPath at all -> ConfEntryRemoved stays $null -> restarting the
    # user's streaming host for an uninstall that touched no conf entry
    # would be a pointless disruption.
    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $null

    Assert-That ($null -eq $summary.ConfEntryRemoved) 'sanity: no ConfPath means no conf entry removal was attempted'
    Assert-That ($null -eq $summary.ServiceRestart) 'the service must not be restarted when nothing was actually removed from the conf'
} | Out-Null

Invoke-Scenario -Name 'Uninstall-App: restarts the host service only when the conf entry was actually removed' -Body {
    $sbx = New-Sbx -Label 'uninstall-restart-on-removal'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "k = v`n"
    Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir | Out-Null

    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $confPath

    Assert-That $summary.ConfEntryRemoved.Success 'the conf entry should have been removed'
    Assert-That ($summary.ConfEntryRemoved.Message -eq 'entry removed') 'sanity: removal message should confirm an entry was actually removed'
    Assert-That ($null -ne $summary.ServiceRestart) 'a restart should have been attempted once an entry was actually removed (Restart-HostService itself is safe/no-throw with no matching service, which is the expected outcome on this test host)'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: a successful register-vibepollo attaches a ServiceRestart result (restart runs in the process holding the rights)' -Body {
    $sbx = New-Sbx -Label 'dispatch-register-restart'
    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "k = v`n"
    $dataDir = Join-Path $sbx 'data'

    $result = Invoke-ManagerAction -Action 'register-vibepollo' -ScriptDir $script:RepoRoot -DataDir $dataDir -ConfPath $confPath -ManagerScriptPath $script:ManagerScriptSource

    Assert-That $result.Success 'register-vibepollo dispatch should succeed'
    Assert-That ($result.PSObject.Properties.Match('ServiceRestart').Count -gt 0) 'a successful register-vibepollo should carry a ServiceRestart result, not leave the caller to restart it separately (and usually unelevated) afterward'
} | Out-Null

Invoke-Scenario -Name 'Uninstall-App: refuses to delete a directory that does not look like our install' -Body {
    $sbx = New-Sbx -Label 'uninstall-refuse-foreign-dir'
    $foreignProgramDir = Join-Path $sbx 'not-ours-program'
    New-Item -ItemType Directory -Path $foreignProgramDir -Force | Out-Null
    Write-TextFile -Path (Join-Path $foreignProgramDir 'unrelated.txt') -Content 'not ours'

    $dataDir = Join-Path $sbx 'data'
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

    $summary = Uninstall-App -ProgramDir $foreignProgramDir -DataDir $dataDir -ConfPath $null

    Assert-That (-not $summary.ProgramDirRemoved) 'a directory with no manager.ps1 marker must not be deleted'
    Assert-That (Test-Path -LiteralPath $foreignProgramDir) 'the foreign directory must still exist on disk'
    Assert-That (-not [string]::IsNullOrWhiteSpace($summary.ProgramDirSkipReason)) 'a skip reason should explain why nothing was deleted'
} | Out-Null

# ===========================================================================
# Path resolvers
# ===========================================================================

Invoke-Scenario -Name 'Resolvers: Get-ResolvedProgramDir / Get-ResolvedDataDir prefer the explicit param over the default' -Body {
    Assert-That ((Get-ResolvedProgramDir -ProgramDir '/explicit/program') -eq '/explicit/program') 'explicit ProgramDir should win'
    Assert-That (-not [string]::IsNullOrWhiteSpace((Get-ResolvedProgramDir -ProgramDir ''))) 'blank ProgramDir should fall back to a non-empty default'
    Assert-That ((Get-ResolvedDataDir -DataDir '/explicit/data') -eq '/explicit/data') 'explicit DataDir should win'
    Assert-That (-not [string]::IsNullOrWhiteSpace((Get-ResolvedDataDir -DataDir ''))) 'blank DataDir should fall back to a non-empty default'
} | Out-Null

Invoke-Scenario -Name 'Resolvers: Get-ResolvedDataDir has no per-user override -- DataDir cannot silently diverge from the default' -Body {
    # Regression guard for the "custom data folder is never persisted"
    # class of bug: DataDir has exactly one source of truth (the explicit
    # param) besides the fixed default -- there is deliberately no
    # PROGRAM-relative settings file to consult, because PROGRAM is
    # contractually allowed to hold manager.ps1 ONLY.
    $cmd = Get-Command 'Get-ResolvedDataDir'
    $paramNames = @($cmd.Parameters.Keys)
    Assert-That ($paramNames -contains 'DataDir') 'Get-ResolvedDataDir should still accept -DataDir'
    Assert-That (-not ($paramNames -contains 'ProgramDir')) 'Get-ResolvedDataDir must not read anything keyed off ProgramDir (no hidden per-install settings file)'
} | Out-Null

Invoke-Scenario -Name 'Resolvers: Get-ResolvedUserId prefers the explicit param, else falls back to a non-empty identity' -Body {
    Assert-That ((Get-ResolvedUserId -UserId 'ExplicitUser') -eq 'ExplicitUser') 'explicit UserId should win'
    Assert-That (-not [string]::IsNullOrWhiteSpace((Get-ResolvedUserId -UserId ''))) 'blank UserId should still resolve to something non-empty'
} | Out-Null

Invoke-Scenario -Name 'Resolvers: Get-ResolvedManagerScriptPath fails closed instead of falling back to the current directory' -Body {
    Assert-That ((Get-ResolvedManagerScriptPath -ManagerScriptPath '/explicit/manager.ps1' -ScriptDir '/some/dir' -CommandPath '') -eq '/explicit/manager.ps1') 'explicit ManagerScriptPath should win'
    Assert-That ((Get-ResolvedManagerScriptPath -ManagerScriptPath '' -ScriptDir '/some/dir' -CommandPath '/from/pscommandpath/manager.ps1') -eq '/from/pscommandpath/manager.ps1') 'CommandPath should win when ManagerScriptPath is blank'

    $threw = $false
    try {
        Get-ResolvedManagerScriptPath -ManagerScriptPath '' -ScriptDir '/some/dir' -CommandPath ''
    }
    catch {
        $threw = $true
    }
    # This is the elevated re-entry's target path -- silently building it
    # from a (possibly cwd-derived) ScriptDir when neither real source is
    # available would let anything that can drop a manager.ps1 into the
    # current directory get it executed with admin rights.
    Assert-That $threw 'Get-ResolvedManagerScriptPath should throw rather than fall back to Join-Path $ScriptDir manager.ps1 when both real sources are blank'
} | Out-Null

# ===========================================================================
# Elevation argument quoting (Invoke-Elevated / Start-Process -ArgumentList)
# ===========================================================================

Invoke-Scenario -Name 'Elevation: ConvertTo-QuotedCommandLineArgument round-trips a path containing a space' -Body {
    $value = 'C:\Program Files\Vibepollo\config\apollo.conf'
    $quoted = ConvertTo-QuotedCommandLineArgument -Value $value
    Assert-That ($quoted -eq ('"' + $value + '"')) "expected a plain double-quoted wrap for a value with no embedded quotes/backslash-before-quote, got: $quoted"
} | Out-Null

Invoke-Scenario -Name 'Elevation: ConvertTo-QuotedCommandLineArgument escapes an embedded double-quote and trailing backslash' -Body {
    $value = 'C:\Users\Weird"Name\'
    $quoted = ConvertTo-QuotedCommandLineArgument -Value $value
    # Expected per CommandLineToArgvW rules: the embedded quote is
    # backslash-escaped, and the single trailing backslash (which
    # otherwise would escape the closing quote) is doubled.
    Assert-That ($quoted -eq '"C:\Users\Weird\"Name\\"') "unexpected quoting: $quoted"
} | Out-Null

Invoke-Scenario -Name 'Elevation: ConvertTo-ElevatedArgumentString keeps a spaced path as ONE argument' -Body {
    # This is the regression test for the core bug: Start-Process
    # -ArgumentList space-joins a string[] with no quoting of its own, so
    # an unquoted "C:\Program Files\..." previously split into two
    # arguments and silently mis-bound onto the wrong parameter. The
    # single string this function returns must already be safe to hand to
    # Start-Process -ArgumentList as-is (one array element, no further
    # splitting).
    $managerPath = 'C:\Users\John Doe\AppData\Local\Programs\stream-config-profiles\manager.ps1'
    $confPath = 'C:\Program Files\Vibepollo\config\apollo.conf'
    $argString = ConvertTo-ElevatedArgumentString -ManagerScriptPath $managerPath -Action 'register-vibepollo' -Parameters @{ ConfPath = $confPath }

    Assert-That ($argString -match [regex]::Escape('-File "' + $managerPath + '"')) '-File value should be quoted as a single argument'
    Assert-That ($argString -match [regex]::Escape('-ConfPath "' + $confPath + '"')) '-ConfPath value should be quoted as a single argument'
    Assert-That ($argString -match '-Action "register-vibepollo"') '-Action value should be quoted'

    # Simulate exactly what Start-Process does with a STRING (not array)
    # -ArgumentList: it is passed straight through as one token, so
    # splitting on quoted-aware boundaries must yield the spaced path
    # intact, not split at the embedded space.
    Assert-That ($argString.Contains($confPath)) 'the full (unsplit) ConfPath must appear verbatim in the argument string'
} | Out-Null

Invoke-Scenario -Name 'Elevation: ConvertTo-ElevatedArgumentString renders switch/bool/int parameters correctly' -Body {
    # Contract (see ConvertTo-ElevatedArgumentString's own comment): a
    # present/true switch renders as a BARE -Name token; an absent/false
    # switch is OMITTED entirely. Never an explicit -Name:$true/-Name:
    # $false token -- powershell.exe/pwsh invoked with -File (exactly how
    # Invoke-Elevated always re-launches this script) parses script
    # arguments as literal, unevaluated strings, so an explicit ":$true"/
    # ":$false" token fails to bind to a [SwitchParameter] at all (the
    # actual field failure: "Cannot convert value "System.String" to type
    # SwitchParameter").
    $argString = ConvertTo-ElevatedArgumentString -ManagerScriptPath '/m.ps1' -Action 'register-watchdog' -Parameters @{ RemoveData = [switch]$true; IncludePoll = [switch]$false; PollMinutes = 10 }
    Assert-That ($argString -match '(?<!\S)-RemoveData(?!\S)') 'a present switch should appear as a bare -Name token'
    Assert-That ($argString -notmatch '-RemoveData:') 'a present switch must never render an explicit :$true/:$false value'
    Assert-That ($argString -notmatch '-IncludePoll(?!\S)') 'an absent/false switch must be omitted entirely, not rendered as a bare flag'
    Assert-That ($argString -notmatch '-IncludePoll:') 'an absent/false switch must never render an explicit :$true/:$false value either'
    Assert-That ($argString -match '-PollMinutes "10"') 'a non-string value should still be quoted'
} | Out-Null

Invoke-Scenario -Name 'Elevation: ConvertTo-ElevatedArgumentString renders a caller-requested -SkipLogon as a bare flag -- regression for the field bug where an explicit -Name:$false token failed to bind at all across the real -File elevation boundary' -Body {
    # CRITICAL correctness, and the root cause of the actual field failure:
    # powershell.exe/pwsh invoked with -File (exactly how Invoke-Elevated
    # always re-launches this script) parses script arguments as literal,
    # unevaluated strings. An explicit "-Name:$false"/"-Name:$true" token
    # therefore arrives as the bare string "$false"/"$true", which
    # PowerShell's own parameter binder cannot convert to a
    # [SwitchParameter] -- crashing the elevated child outright ("Cannot
    # convert value "System.String" to type SwitchParameter"). The fix is
    # not which token to render for false vs. true; it is to never render
    # an explicit value token AT ALL: a present switch is a BARE -Name, an
    # absent one is OMITTED, and -SkipLogon (the parameter that actually
    # crosses this boundary now -- see its own top-level comment) is
    # declared with the ordinary $false default so that omission is sound
    # in both directions with no special-casing.
    $argString = ConvertTo-ElevatedArgumentString -ManagerScriptPath '/m.ps1' -Action 'register-watchdog' -Parameters @{ DataDir = '/data'; UserId = 'OriginalInteractiveUser'; SkipLogon = [switch]$true; IncludePoll = [switch]$true; PollMinutes = 10 }
    Assert-That ($argString -match '(?<!\S)-SkipLogon(?!\S)') 'a caller-requested -SkipLogon (poll-only) must render as a bare -SkipLogon flag'
    Assert-That ($argString -notmatch '-SkipLogon:') 'a caller-requested -SkipLogon must never render an explicit :$true value token'
    Assert-That ($argString -match '(?<!\S)-IncludePoll(?!\S)') 'a caller-requested -IncludePoll must render as a bare -IncludePoll flag'
    Assert-That ($argString -notmatch '-IncludePoll:') 'a caller-requested -IncludePoll must never render an explicit :$true value token'
} | Out-Null

Invoke-Scenario -Name 'Elevation: ConvertTo-ElevatedArgumentString omits -SkipLogon entirely (Logon included) and carries the ORIGINAL -UserId through for a register-watchdog elevation retry' -Body {
    # CRITICAL correctness: this command line is what the elevated child
    # process actually receives. UserId must be the value resolved in the
    # ORIGINAL unelevated process (see Get-ResolvedUserId / the GUI call
    # sites), never left for the elevated child to re-derive from its own
    # (possibly different-admin) identity.
    $argString = ConvertTo-ElevatedArgumentString -ManagerScriptPath '/m.ps1' -Action 'register-watchdog' -Parameters @{ DataDir = '/data'; UserId = 'OriginalInteractiveUser'; SkipLogon = [switch]$false; IncludePoll = [switch]$false; PollMinutes = 15 }
    Assert-That ($argString -match '-UserId "OriginalInteractiveUser"') 'the elevated re-entry command line must carry the original UserId explicitly'
    Assert-That ($argString -notmatch '-SkipLogon(?!\S)') 'a caller that wants Logon included must have -SkipLogon omitted entirely, not rendered as a bare flag'
    Assert-That ($argString -notmatch '-SkipLogon:') 'an absent -SkipLogon must never render an explicit :$false value token either'
    Assert-That ($argString -notmatch '-IncludePoll(?!\S)') 'an absent -IncludePoll should be omitted entirely, not rendered as a bare flag'
    Assert-That ($argString -notmatch '-IncludePoll:') 'an absent -IncludePoll must never render an explicit :$false value token either'
    Assert-That ($argString -match "-Action ""register-watchdog""") 'the re-entered action should be register-watchdog'
} | Out-Null

function Invoke-E2EElevatedRegisterWatchdog {
    # Shared plumbing for the two end-to-end scenarios below: builds the
    # elevation-boundary argument string via the exact
    # ConvertTo-ElevatedArgumentString/Start-Process mechanism Invoke-Elevated
    # uses, runs it as a REAL child process, and returns the parsed JSON
    # result array (or $null if this platform has no Start-Process at all).
    # Start-Process -ArgumentList <single string> hands that string to the OS
    # exactly once, unparsed -- .NET's Process class parses a single
    # -ArgumentList/-Arguments string the same way on every platform before
    # exec'ing the child, so this reproduces on Linux exactly what
    # Invoke-Elevated does via Start-Process -Verb RunAs on real Windows
    # (RunAs is the only part that is Windows-only). The child process is the
    # real (non-dot-sourced, non-shimmed) manager.ps1, so it calls the real
    # (Windows-only) ScheduledTasks cmdlets and is EXPECTED to report
    # Success=$false / exit 1 on this Linux host -- that failure is not what
    # either scenario checks. What they check is WHICH task names were even
    # attempted (and, for Logon, whether it was a registration attempt or a
    # reconcile-unregister), which is decided entirely by how -SkipLogon/
    # -IncludePoll bound in the child, before any cmdlet call happens.
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][hashtable]$ExtraParameters
    )

    if (-not (Get-Command -Name 'Start-Process' -ErrorAction SilentlyContinue)) {
        return $null
    }
    $sbx = New-Sbx -Label $Label
    $stdout = Join-Path $sbx 'stdout.json'
    $stderr = Join-Path $sbx 'stderr.txt'
    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    $parameters = @{ DataDir = $sbx; UserId = 'E2EUser' } + $ExtraParameters
    $argString = ConvertTo-ElevatedArgumentString -ManagerScriptPath $script:ManagerScriptSource -Action 'register-watchdog' -Parameters $parameters

    $proc = Start-Process -FilePath $hostExe -ArgumentList $argString -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Assert-That ($null -ne $proc) 'the child process should have started'

    $stdoutText = Read-TextFile $stdout
    Assert-That (-not [string]::IsNullOrWhiteSpace($stdoutText)) "the child process should have printed its JSON result (stderr was: $(Read-TextFile $stderr))"

    # $_.Name/$_.Message are cast to [string] explicitly by every caller
    # below, and every filtered set is re-wrapped in @(...) before .Count,
    # rather than comparing/indexing the raw ConvertFrom-Json output
    # directly. This is the one code path in the whole suite that inspects
    # an object which crossed a REAL JSON serialize/deserialize boundary
    # (every other entries[0]/results[0]-style assertion elsewhere in this
    # file inspects a live in-process object). ConvertFrom-Json's shape
    # (bare PSCustomObject vs Object[]) for a given payload can differ
    # between Windows PowerShell 5.1 and pwsh 7, and a property fetched off
    # an array-shaped element enumerates across every element instead of
    # returning one scalar -- so an unguarded "$x.Name -eq ..." or
    # "$x.Message -eq ..." can silently evaluate to a filtered ARRAY (0 or
    # 2+ elements) instead of a plain scalar bool. Assert-That's own
    # [bool]$Condition parameter binder cannot convert a multi/zero-element
    # array ("Cannot convert value "System.Object[]" to type
    # "System.Boolean""), so that shape mismatch crashes the scenario
    # outright instead of failing a plain assertion. Casting to [string]
    # first costs nothing when the value is already the plain string it is
    # supposed to be, and guarantees a scalar either way.
    return @($stdoutText | ConvertFrom-Json)
}

Invoke-Scenario -Name 'Elevation (end-to-end): a poll-only elevation retry (-SkipLogon), run through a REAL child pwsh process via the exact ConvertTo-ElevatedArgumentString/Start-Process mechanism Invoke-Elevated uses, never attempts a Logon REGISTRATION' -Body {
    # This is the actual regression guard for the field bug. A
    # 'StreamConfigProfiles-Settle-Logon' entry in the output is NOT itself
    # the bug: Register-Watchdog is a full desired-state reconciler (see
    # there), so -SkipLogon legitimately produces a reconcile-UNREGISTER
    # result entry for Logon too. The actual field bug this guards against
    # (under the OLD -IncludeLogon:$false top-level surface this scenario
    # used to exercise) was TWO-FOLD: (1) an explicit "-IncludeLogon:$false"
    # token failed to bind AT ALL across this real -File process boundary
    # ("Cannot convert value "System.String" to type SwitchParameter", since
    # -File args are literal unevaluated strings), which is why the
    # serializer omits a false/absent switch entirely instead of rendering
    # an explicit value token; and (2), had that omission alone been the
    # whole fix without also changing the boundary parameter's own declared
    # default to $false, an omitted flag would have silently bound to a
    # stale $true default in the child -- a REGISTRATION attempt instead of
    # the reconcile-unregister this test expects. -SkipLogon replaces that
    # fragile two-part contract with one fact that -File binds identically
    # on every host: presence/absence of a switch whose declared default IS
    # absence. Distinguished here by message shape: a real Register attempt
    # on this cmdlet-less Linux host fails with a "term not recognized"
    # message, while the reconcile-unregister no-ops successfully with a
    # fixed message text.
    $parsed = Invoke-E2EElevatedRegisterWatchdog -Label 'e2e-elevated-poll-only' -ExtraParameters @{ SkipLogon = [switch]$true; IncludePoll = [switch]$true; PollMinutes = 10 }
    if ($null -eq $parsed) {
        return
    }

    $pollEntries = @($parsed | Where-Object { [string]$_.Name -eq 'StreamConfigProfiles-Settle-Poll' })
    Assert-That (@($pollEntries).Count -eq 1) "expected exactly one Poll result entry across the real process boundary, got names: $((@($parsed | ForEach-Object { [string]$_.Name })) -join ', ')"

    $logonEntries = @($parsed | Where-Object { [string]$_.Name -eq 'StreamConfigProfiles-Settle-Logon' })
    if (@($logonEntries).Count -gt 0) {
        $logonMessage = [string]$logonEntries[0].Message
        Assert-That ($logonMessage -eq 'unregistered (not requested)') "the field bug: a caller-requested -SkipLogon must never reach a REGISTRATION attempt in the elevated child (it bound to Logon-included instead, silently re-registering a task the user had just declined) -- got Logon result: Success=$($logonEntries[0].Success), Message='$logonMessage'"
    }
} | Out-Null

Invoke-Scenario -Name 'Elevation (end-to-end): the INVERSE of the poll-only case -- no -SkipLogon at all, run through a REAL child pwsh process, attempts a Logon REGISTRATION (not a reconcile-unregister)' -Body {
    # The other half of the SkipLogon boundary contract: omitting -SkipLogon
    # entirely (exactly what ConvertTo-ElevatedArgumentString renders when
    # the caller's SkipLogon is [switch]$false) must bind to Logon INCLUDED
    # in the real elevated child, on every host -- this is the direction
    # that was never actually broken by the original field bug, but is now
    # the one this whole redesign hinges on staying correct with no
    # ContainsKey trick anywhere between here and the child's own top-level
    # param block.
    $parsed = Invoke-E2EElevatedRegisterWatchdog -Label 'e2e-elevated-logon-included' -ExtraParameters @{ SkipLogon = [switch]$false; IncludePoll = [switch]$false }
    if ($null -eq $parsed) {
        return
    }

    $logonEntries = @($parsed | Where-Object { [string]$_.Name -eq 'StreamConfigProfiles-Settle-Logon' })
    Assert-That (@($logonEntries).Count -eq 1) "expected exactly one Logon result entry across the real process boundary, got names: $((@($parsed | ForEach-Object { [string]$_.Name })) -join ', ')"
    $logonMessage = [string]$logonEntries[0].Message
    Assert-That ($logonMessage -ne 'unregistered (not requested)') "an absent -SkipLogon must reach a REGISTRATION attempt in the elevated child (Logon included), not a reconcile-unregister -- got Logon result: Success=$($logonEntries[0].Success), Message='$logonMessage'"

    $pollEntries = @($parsed | Where-Object { [string]$_.Name -eq 'StreamConfigProfiles-Settle-Poll' })
    if (@($pollEntries).Count -gt 0) {
        $pollMessage = [string]$pollEntries[0].Message
        Assert-That ($pollMessage -eq 'unregistered (not requested)') "Poll was not requested (-IncludePoll omitted), so any Poll entry must be a reconcile-unregister, not a registration attempt -- got Poll result: Success=$($pollEntries[0].Success), Message='$pollMessage'"
    }
} | Out-Null

Invoke-Scenario -Name 'GUI: watchdog register/unregister route through Invoke-GuiElevatable so an access-denied registration can retry elevated' -Body {
    # Field bug: real Windows requires administrator APPROVAL to REGISTER a
    # scheduled task with a logon-type trigger (AtLogOn / session-unlock),
    # even though the task's own principal is always the calling user (see
    # Register-Watchdog). The old "watchdog never needs elevation" routing
    # (Invoke-GuiSafe only) left a real access-denied result with no retry
    # path. This is a source-level regression guard, since the GUI region
    # itself is not exercised by this headless harness.
    $source = Read-TextFile $script:ManagerScriptSource

    $registerElevatableSites = @([regex]::Matches($source, "(?s)Invoke-GuiElevatable.{0,300}-Action\s+'register-watchdog'"))
    Assert-That ($registerElevatableSites.Count -ge 2) "expected at least two GUI call sites routing register-watchdog through Invoke-GuiElevatable (wizard step 4 + main window Register/Update), found $($registerElevatableSites.Count)"

    $unregisterElevatableSites = @([regex]::Matches($source, "(?s)Invoke-GuiElevatable.{0,300}-Action\s+'unregister-watchdog'"))
    Assert-That ($unregisterElevatableSites.Count -ge 1) "expected at least one GUI call site routing unregister-watchdog through Invoke-GuiElevatable (main window Unregister All), found $($unregisterElevatableSites.Count)"

    $registerWatchdogGuiCallSites = @([regex]::Matches($source, 'Register-Watchdog -DataDir \$\w+ -UserId'))
    Assert-That ($registerWatchdogGuiCallSites.Count -ge 2) 'sanity: expected at least two GUI call sites for Register-Watchdog (wizard + main window)'
} | Out-Null

Invoke-Scenario -Name 'GUI: register-watchdog GUI call sites pass an explicit -UserId resolved BEFORE any elevation, not re-derived inside the elevated child' -Body {
    # CRITICAL correctness: Invoke-Elevated's -Parameters hashtable is what
    # the elevated re-entry's -UserId comes from. If a GUI call site instead
    # let the elevated child fall back to Get-ResolvedUserId with no
    # explicit UserId, an over-the-shoulder admin approval by a DIFFERENT
    # account would silently register the task under that admin's identity
    # instead of the interactive user who asked for protection.
    $source = Read-TextFile $script:ManagerScriptSource
    $registerElevatableWithUserId = @([regex]::Matches($source, "(?s)Invoke-GuiElevatable.{0,300}-Action\s+'register-watchdog'.{0,300}UserId\s*="))
    Assert-That ($registerElevatableWithUserId.Count -ge 2) "expected every register-watchdog Invoke-GuiElevatable call site to pass UserId explicitly in -Parameters, found $($registerElevatableWithUserId.Count) that do"
} | Out-Null

Invoke-Scenario -Name 'GUI: Test-GuiWatchdogResultFailureIsElevationEligible flags exactly register-watchdog/unregister-watchdog/uninstall' -Body {
    # register-watchdog/unregister-watchdog report a per-task failure by
    # RETURNING Success=$false rather than throwing (see
    # Register-Watchdog/Unregister-Watchdog), so by the time it reaches
    # Invoke-GuiElevatable only the exception's .Message STRING survives --
    # not a locale-independent HResult/exception type. The real field
    # failure arrived as a LOCALIZED message ("Acceso denegado"), so these
    # actions are special-cased by name instead of pattern-matching
    # English text that would silently never match again.
    Assert-That (Test-GuiWatchdogResultFailureIsElevationEligible -Action 'register-watchdog') 'register-watchdog Result failures should be elevation-eligible'
    Assert-That (Test-GuiWatchdogResultFailureIsElevationEligible -Action 'unregister-watchdog') 'unregister-watchdog Result failures should be elevation-eligible'
    Assert-That (-not (Test-GuiWatchdogResultFailureIsElevationEligible -Action 'register-vibepollo')) 'register-vibepollo Result failures (e.g. malformed conf JSON) are business-logic outcomes and must stay final, not elevation-eligible'
    # uninstall now IS elevation-eligible: Uninstall-App's top-level Success
    # is $false ONLY when the nested watchdog unregister failed (see
    # Uninstall-App) -- never for a nested conf-edit business-logic
    # failure -- so this can never wrongly offer to elevate-and-retry
    # something elevation would not fix.
    Assert-That (Test-GuiWatchdogResultFailureIsElevationEligible -Action 'uninstall') 'uninstall Result failures must be elevation-eligible now that its top-level Success reflects a failed nested watchdog unregister (see Uninstall-App)'
} | Out-Null

Invoke-Scenario -Name 'GUI: Test-GuiLooksLikeAccessDenied recognizes the E_ACCESSDENIED HRESULT even behind a localized (non-English) message' -Body {
    # Regression test for the actual field failure: "Acceso denegado" (a
    # Spanish Windows install's Register-ScheduledTask error) does not
    # match any English text pattern, but the underlying HRESULT
    # (0x80070005 / E_ACCESSDENIED, surfaced as Int32 -2147024891) is
    # locale-independent -- this must be the primary signal, not the
    # message text.
    $localizedComException = New-Object System.Runtime.InteropServices.COMException('Acceso denegado', -2147024891)
    $localizedErrorRecord = New-Object System.Management.Automation.ErrorRecord($localizedComException, 'Simulated', [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
    Assert-That (Test-GuiLooksLikeAccessDenied -ErrorRecord $localizedErrorRecord) 'a localized "Acceso denegado" message carrying HRESULT 0x80070005 should still be recognized as access-denied'

    $englishTextException = New-Object System.Exception('Access is denied.')
    $englishTextErrorRecord = New-Object System.Management.Automation.ErrorRecord($englishTextException, 'Simulated2', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    Assert-That (Test-GuiLooksLikeAccessDenied -ErrorRecord $englishTextErrorRecord) 'plain English "Access is denied" text should still be recognized as a fallback when no HResult/type signal is present'

    $unauthorizedException = New-Object System.UnauthorizedAccessException('some message')
    $unauthorizedErrorRecord = New-Object System.Management.Automation.ErrorRecord($unauthorizedException, 'Simulated3', [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
    Assert-That (Test-GuiLooksLikeAccessDenied -ErrorRecord $unauthorizedErrorRecord) 'a UnauthorizedAccessException should be recognized regardless of its message text'

    $unrelatedException = New-Object System.Exception('Algo salio mal por otra razon')
    $unrelatedErrorRecord = New-Object System.Management.Automation.ErrorRecord($unrelatedException, 'Simulated4', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    Assert-That (-not (Test-GuiLooksLikeAccessDenied -ErrorRecord $unrelatedErrorRecord)) 'an unrelated exception with no matching HResult/type/text must not be misdetected as access-denied'
} | Out-Null

Invoke-Scenario -Name 'GUI: Invoke-GuiElevationRetry skips the confirm/elevate dance entirely when this process is already running as administrator' -Body {
    # An already-elevated GUI process (e.g. Install.bat run as
    # administrator) offering "Retry elevated?" launches a SECOND elevated
    # process via Start-Process -Verb RunAs, which always shows a fresh UAC
    # consent prompt regardless of the caller's own elevation, only to hit
    # the exact same failure again -- this process's lack of permissions
    # was never the actual cause. Test-IsAdmin=$true must short-circuit
    # straight to reporting the original failure, with no confirm dialog
    # (which would need real WinForms, unavailable in this headless
    # harness) and no attempted re-elevation.
    #
    # `script:` scope on the override is required, not incidental: a bare
    # "function Test-IsAdmin {...}" here would define it in this scenario
    # body's own child scope, invisible to Invoke-GuiElevationRetry (which
    # resolves the name starting from ITS OWN definition scope, i.e. the
    # dot-sourced script scope) -- exactly like $script:UnregisterShouldThrowFor
    # above needs the same explicit scope to reach the shimmed cmdlet wrappers.
    function script:Test-IsAdmin { return $true }
    try {
        $result = Invoke-GuiElevationRetry -ManagerScriptPath '/m.ps1' -Action 'register-watchdog' -Parameters @{} -FailureMessage 'simulated non-permission failure'
        Assert-That (-not $result.Success) 'an already-elevated retry attempt should report failure, not silently succeed'
        Assert-That (-not $result.Elevated) 'an already-elevated retry must not report Elevated=$true -- it never launched a second elevated process'
        Assert-That ($result.ErrorMessage -match [regex]::Escape('simulated non-permission failure')) 'the original failure message should still be surfaced'
        Assert-That ($result.ErrorMessage -match '(?i)already running as administrator') 'the message should explain why elevating again was skipped'
    }
    finally {
        function script:Test-IsAdmin { return $false }
    }
} | Out-Null

Invoke-Scenario -Name 'Resolvers: Get-ResolvedUserId falls back to DOMAIN\User when USERDOMAIN/USERNAME are set and no SID is available' -Body {
    # Get-CurrentWindowsUserSid is shimmed (above) to always return $null,
    # forcing Get-ResolvedUserId through to its next-best signal on EVERY
    # platform this runs on -- including real Windows, where a SID is
    # otherwise always genuinely available and this fallback branch could
    # never be reached at all without the shim (the previous, unshimmed
    # version of this test relied on WindowsIdentity simply being
    # unavailable under pwsh on Linux, which made it pass here but fail on
    # real Windows CI, where a SID IS available and the function correctly
    # returns it instead of this fallback). This is exactly the ambiguity
    # the SID preference exists to avoid on real Windows: a bare name is
    # ambiguous on a domain-joined machine, so "DOMAIN\User" must be
    # preferred over a bare name whenever both environment variables are
    # actually available.
    $savedDomain = $env:USERDOMAIN
    $savedName = $env:USERNAME
    try {
        $env:USERDOMAIN = 'TESTDOMAIN'
        $env:USERNAME = 'TestUser'
        Assert-That ((Get-ResolvedUserId -UserId '') -eq 'TESTDOMAIN\TestUser') 'with both USERDOMAIN and USERNAME set (and no SID available), Get-ResolvedUserId should prefer the DOMAIN\User form over a bare name'

        $env:USERDOMAIN = ''
        Assert-That ((Get-ResolvedUserId -UserId '') -eq 'TestUser') 'with USERDOMAIN blank, Get-ResolvedUserId should fall back to the bare USERNAME'
    }
    finally {
        $env:USERDOMAIN = $savedDomain
        $env:USERNAME = $savedName
    }
} | Out-Null

Invoke-Scenario -Name 'Elevation: manager.ps1 declares PositionalBinding = $false' -Body {
    # Regression guard for the argument-injection angle of the same bug:
    # without this, PowerShell assigns every unannotated parameter an
    # implicit position in declaration order, so a value that gets
    # space-split before reaching this script would silently rebind onto
    # the WRONG parameter instead of failing loudly.
    $source = Read-TextFile $script:ManagerScriptSource
    Assert-That ($source -match '\[CmdletBinding\(\s*PositionalBinding\s*=\s*\$false\s*\)\]') 'manager.ps1 should declare [CmdletBinding(PositionalBinding = $false)] on its param block'
} | Out-Null

# ===========================================================================
# Result-failure helpers (CLI exit-code / Invoke-GuiElevatable propagation)
# ===========================================================================

Invoke-Scenario -Name 'Result helpers: Test-ManagerResultIndicatesFailure recognizes a single Success=$false object' -Body {
    Assert-That (Test-ManagerResultIndicatesFailure -Result ([PSCustomObject]@{ Success = $false; Message = 'boom' })) 'a single Success=$false object should be detected as a failure'
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result ([PSCustomObject]@{ Success = $true }))) 'a Success=$true object should not be a failure'
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result $null)) 'null should not be a failure'
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result 'a plain string')) 'a value with no Success property should not be a failure'
} | Out-Null

Invoke-Scenario -Name 'Result helpers: Test-ManagerResultIndicatesFailure recognizes a failure buried in an array' -Body {
    $arrayResult = @(
        [PSCustomObject]@{ Name = 'A'; Success = $true },
        [PSCustomObject]@{ Name = 'B'; Success = $false; Message = 'B failed' }
    )
    Assert-That (Test-ManagerResultIndicatesFailure -Result $arrayResult) 'an array with any Success=$false element should be a failure'
    Assert-That ((Get-ManagerResultFailureMessage -Result $arrayResult) -eq 'B failed') 'the failing element''s Message should be surfaced'
} | Out-Null

Invoke-Scenario -Name 'Result helpers: Get-ManagerResultFailureMessage falls back to a generic message when none is provided' -Body {
    $msg = Get-ManagerResultFailureMessage -Result ([PSCustomObject]@{ Success = $false })
    Assert-That (-not [string]::IsNullOrWhiteSpace($msg)) 'a generic fallback message should still be non-empty'
} | Out-Null

# ===========================================================================
# Invoke-ManagerAction dispatch surface (the headless CLI / elevation
# re-entry contract) -- previously entirely untested.
# ===========================================================================

Invoke-Scenario -Name 'Dispatch: install action lays down the documented layout' -Body {
    $sbx = New-Sbx -Label 'dispatch-install'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'

    $result = Invoke-ManagerAction -Action 'install' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource

    Assert-That (Test-Path -LiteralPath (Join-Path $programDir 'manager.ps1')) 'dispatched install should create PROGRAM\manager.ps1'
    Assert-That (Test-Path -LiteralPath (Join-Path $dataDir 'sync-configs.ps1')) 'dispatched install should create DATA\sync-configs.ps1'
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result $result)) 'a successful install should not look like a failure to the exit-code helper'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: register-vibepollo surfaces a malformed-conf failure through the Success=$false shape' -Body {
    $sbx = New-Sbx -Label 'dispatch-register-malformed'
    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "global_prep_cmd = {not valid json`n"
    $dataDir = Join-Path $sbx 'data'

    $result = Invoke-ManagerAction -Action 'register-vibepollo' -ScriptDir $script:RepoRoot -DataDir $dataDir -ConfPath $confPath -ManagerScriptPath $script:ManagerScriptSource

    Assert-That (-not $result.Success) 'malformed JSON should be reported as a failure'
    Assert-That (Test-ManagerResultIndicatesFailure -Result $result) 'the exit-code helper should also recognize it as a failure (this is what makes the CLI entry point exit non-zero)'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: register-vibepollo rejects a DataDir containing a double-quote' -Body {
    $sbx = New-Sbx -Label 'dispatch-register-quote-datadir'
    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "k = v`n"
    $dataDirWithQuote = (Join-Path $sbx 'data') + '"injected'

    $result = Invoke-ManagerAction -Action 'register-vibepollo' -ScriptDir $script:RepoRoot -DataDir $dataDirWithQuote -ConfPath $confPath -ManagerScriptPath $script:ManagerScriptSource

    Assert-That (-not $result.Success) 'a DataDir containing a double-quote must be rejected, not silently embedded in the do/undo command line'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: register-watchdog and unregister-watchdog round-trip through the shim' -Body {
    $script:WatchdogCalls.Clear()
    $result = Invoke-ManagerAction -Action 'register-watchdog' -ScriptDir $script:RepoRoot -DataDir '/fake/data' -UserId 'DispatchUser'
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result $result)) 'register-watchdog dispatch should succeed against the shim'
    Assert-That (@($script:WatchdogCalls | Where-Object { $_.Op -eq 'Register' -and $_.Name -eq 'StreamConfigProfiles-Settle-Logon' }).Count -eq 1) 'the Logon task should have been registered via dispatch'

    $script:WatchdogCalls.Clear()
    $unregResult = Invoke-ManagerAction -Action 'unregister-watchdog' -ScriptDir $script:RepoRoot -DataDir '/fake/data'
    Assert-That (@($unregResult).Count -eq 3) 'unregister-watchdog dispatch should report all three well-known tasks'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: -UserId passed to the register-watchdog CLI action flows all the way into the registered task principal' -Body {
    # CRITICAL correctness: this is exactly the value the elevated re-entry
    # relies on (see Invoke-Elevated / the GUI call sites) to register the
    # Logon task under the ORIGINAL interactive user rather than whatever
    # identity the elevated process itself happens to run as.
    $script:WatchdogCalls.Clear()
    Invoke-ManagerAction -Action 'register-watchdog' -ScriptDir $script:RepoRoot -DataDir '/fake/data' -UserId 'OriginalInteractiveUser' -IncludePoll -PollMinutes 10 | Out-Null

    $logonCall = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Register' -and $_.Name -eq 'StreamConfigProfiles-Settle-Logon' })[0]
    $pollCall = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Register' -and $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })[0]
    Assert-That ($null -ne $logonCall) 'sanity: the Logon task should have been registered'
    Assert-That ($logonCall.UserId -eq 'OriginalInteractiveUser') "the Logon task principal's UserId should be the -UserId passed to the CLI action, got '$($logonCall.UserId)'"
    Assert-That ($pollCall.UserId -eq 'OriginalInteractiveUser') "the Poll task principal's UserId should be the -UserId passed to the CLI action, got '$($pollCall.UserId)'"
} | Out-Null

Invoke-Scenario -Name 'Dispatch: register-watchdog -IncludeLogon:$false dispatches a poll-only registration with no Logon attempt' -Body {
    $script:WatchdogCalls.Clear()
    $result = Invoke-ManagerAction -Action 'register-watchdog' -ScriptDir $script:RepoRoot -DataDir '/fake/data' -UserId 'DispatchUser' -IncludeLogon:$false -IncludePoll -PollMinutes 10
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result $result)) 'poll-only register-watchdog dispatch should succeed against the shim'

    $registerCalls = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Register' })
    Assert-That (@($registerCalls).Count -eq 1) "expected exactly 1 Register call (Poll only), got $(@($registerCalls).Count)"
    Assert-That ($registerCalls[0].Name -eq 'StreamConfigProfiles-Settle-Poll') 'the only task dispatched should be Poll'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: uninstall action tears down a dispatched install' -Body {
    $sbx = New-Sbx -Label 'dispatch-uninstall'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Invoke-ManagerAction -Action 'install' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource | Out-Null

    $result = Invoke-ManagerAction -Action 'uninstall' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource

    Assert-That (-not (Test-Path -LiteralPath $programDir)) 'dispatched uninstall should remove PROGRAM'
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result $result)) 'a clean uninstall should not look like a failure'
} | Out-Null

Invoke-Scenario -Name 'Uninstall-App: a failed nested watchdog unregister surfaces at the TOP level as Success=$false' -Body {
    # Regression: $summary used to carry no top-level Success property at
    # all, so Test-ManagerResultIndicatesFailure (which only inspects the
    # top level of @($Result) by design) could not see a Success=$false
    # buried inside WatchdogUnregistered. That made the GUI show the
    # unconditional "disconnected and uninstalled" success text, the
    # elevated CLI re-entry exit 0, and uninstall could never be judged
    # elevation-eligible -- all while PROGRAM had already been deleted and
    # an admin-owned watchdog task was left behind, still pointed at DATA.
    $sbx = New-Sbx -Label 'uninstall-failed-watchdog'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $script:UnregisterShouldThrowFor = @('StreamConfigProfiles-Settle-Logon')
    try {
        $script:WatchdogCalls.Clear()
        $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir

        Assert-That ($summary.PSObject.Properties.Match('Success').Count -gt 0) 'Uninstall-App summary must carry a top-level Success property'
        Assert-That (-not $summary.Success) 'a denied watchdog unregister nested inside WatchdogUnregistered must flip the top-level Success to $false'
        Assert-That (Test-ManagerResultIndicatesFailure -Result $summary) 'Test-ManagerResultIndicatesFailure must now see the failure via the top-level Success property'
    }
    finally {
        $script:UnregisterShouldThrowFor = @()
    }
} | Out-Null

Invoke-Scenario -Name 'Uninstall-App: a nested conf-edit (business-logic) failure does NOT flip the top-level Success -- only a watchdog unregister failure does' -Body {
    # Deliberate scope limit (see Uninstall-App / Test-GuiWatchdogResultFailure-
    # IsElevationEligible): a malformed-conf-JSON failure is the same
    # business-logic outcome register-vibepollo reports elsewhere. Elevating
    # would not fix it, so it must stay a final Result-shaped failure nested
    # in ConfEntryRemoved, never flip the top-level Success that uninstall's
    # elevation-eligibility now keys off of.
    $sbx = New-Sbx -Label 'uninstall-malformed-conf'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "global_prep_cmd = {this is not valid json`n"

    $script:WatchdogCalls.Clear()
    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $confPath

    Assert-That (-not $summary.ConfEntryRemoved.Success) 'sanity: the malformed conf edit should itself report failure'
    Assert-That ($summary.Success) 'a nested conf-edit failure must NOT flip the top-level Success -- it is a business-logic outcome, not a permissions problem'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: uninstall action exits non-zero (via Test-ManagerResultIndicatesFailure) when the nested watchdog unregister fails' -Body {
    $sbx = New-Sbx -Label 'dispatch-uninstall-failed-watchdog'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Invoke-ManagerAction -Action 'install' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource | Out-Null

    $script:UnregisterShouldThrowFor = @('StreamConfigProfiles-Settle-Poll')
    try {
        $result = Invoke-ManagerAction -Action 'uninstall' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource
        Assert-That (Test-ManagerResultIndicatesFailure -Result $result) 'a dispatched uninstall with a denied watchdog unregister must be visible to Test-ManagerResultIndicatesFailure (this is what the CLI entry point/elevated re-entry gate their exit code on)'
    }
    finally {
        $script:UnregisterShouldThrowFor = @()
    }
} | Out-Null

# ===========================================================================
# global_prep_cmd conf round-trip: CRLF and no-trailing-newline
# ===========================================================================

Invoke-Scenario -Name 'Conf: Add-PrepCommandEntry preserves CRLF line endings' -Body {
    $sbx = New-Sbx -Label 'conf-crlf'
    $confPath = Join-Path $sbx 'sunshine.conf'
    $original = "origin_web_ui_allowed = lan`r`nsunshine_name = MyPC`r`n"
    New-ConfFixture -Path $confPath -Content $original
    $dataDir = Join-Path $sbx 'data'

    $result = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That $result.Success 'Add-PrepCommandEntry should succeed on a CRLF file'

    $newContent = Read-TextFile $confPath
    Assert-That ($newContent -match "origin_web_ui_allowed = lan`r`n") 'first line should keep its CRLF ending'
    Assert-That ($newContent -match "sunshine_name = MyPC`r`n") 'second line should keep its CRLF ending'
    Assert-That ($newContent -match "global_prep_cmd = .*`r`n") 'the newly-appended line should also use CRLF'
    Assert-That (-not ($newContent -match "(?<!\r)`n")) 'no bare LF should have been introduced into a CRLF file'
} | Out-Null

Invoke-Scenario -Name 'Conf: Add-PrepCommandEntry appending a brand-new key to a file with no trailing newline still terminates the new line' -Body {
    # No existing global_prep_cmd key -> the new line is APPENDED to the
    # line list, not swapped in place; Write-ConfGlobalPrepCmd always
    # terminates a freshly-appended line even if the original file had no
    # trailing newline, so the newly written key doesn't end up sharing a
    # physical line with whatever was already last in the file.
    $sbx = New-Sbx -Label 'conf-no-trailing-newline-append'
    $confPath = Join-Path $sbx 'sunshine.conf'
    $original = 'some_key = value'
    New-ConfFixture -Path $confPath -Content $original
    $dataDir = Join-Path $sbx 'data'

    $result = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That $result.Success 'Add-PrepCommandEntry should succeed'

    $newContent = Read-TextFile $confPath
    Assert-That ($newContent -match [regex]::Escape($original)) 'the original line should be preserved'
    Assert-That ($newContent -match "global_prep_cmd = .*`n$") 'the appended line should be newline-terminated even though the original file had no trailing newline'
} | Out-Null

Invoke-Scenario -Name 'Conf: Add-PrepCommandEntry REPLACING an existing key with no trailing newline preserves that exactly (adds none)' -Body {
    # Here the key already exists -> the line is REPLACED in place, and
    # the original "no trailing newline" style must be preserved exactly,
    # unlike the fresh-append case above.
    $sbx = New-Sbx -Label 'conf-no-trailing-newline-replace'
    $confPath = Join-Path $sbx 'sunshine.conf'
    $otherEntryJson = '[{"do":"C:\\other\\tool.exe start","undo":"C:\\other\\tool.exe stop","elevated":false}]'
    $original = "some_key = value`nglobal_prep_cmd = $otherEntryJson"
    New-ConfFixture -Path $confPath -Content $original
    $dataDir = Join-Path $sbx 'data'

    $result = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That $result.Success 'Add-PrepCommandEntry should succeed'

    $newContent = Read-TextFile $confPath
    Assert-That (-not ($newContent -match "(`r`n|`n)$")) 'replacing an existing key in a file with no trailing newline should not introduce one'
} | Out-Null

Invoke-Scenario -Name 'Conf: a foreign entry with no "do" property does not crash Test-PrepCommandEntryIsOurs under StrictMode' -Body {
    $sbx = New-Sbx -Label 'conf-foreign-no-do'
    $confPath = Join-Path $sbx 'sunshine.conf'
    # A foreign tool's entry that only has "undo" -- no "do" property at all.
    $foreignJson = '[{"undo":"C:\\other\\tool.exe stop","elevated":false}]'
    New-ConfFixture -Path $confPath -Content "global_prep_cmd = $foreignJson`n"
    $dataDir = Join-Path $sbx 'data'

    $result = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That $result.Success 'Add-PrepCommandEntry should succeed even when an existing entry lacks a "do" property'

    $entries = (Get-PrepCommandEntries -ConfPath $confPath).Entries
    Assert-That (@($entries).Count -eq 2) 'the foreign do-less entry should be kept alongside our new one'
} | Out-Null

# ===========================================================================
# paths.txt editing: comment/blank-line preservation
# ===========================================================================

Invoke-Scenario -Name 'PathsTxt: Add-PathsTxtLine preserves comments and blank lines' -Body {
    $sbx = New-Sbx -Label 'pathstxt-add-preserve'
    $pathsTxt = Join-Path $sbx 'paths.txt'
    $original = "# a comment`n`n# another comment`nC:\Existing\config.ini`n"
    Write-TextFile -Path $pathsTxt -Content $original

    Add-PathsTxtLine -PathsTxtPath $pathsTxt -LineToAdd 'C:\New\config.ini'

    $content = Read-TextFile $pathsTxt
    Assert-That ($content -match [regex]::Escape('# a comment')) 'first comment should survive'
    Assert-That ($content -match [regex]::Escape('# another comment')) 'second comment should survive'
    Assert-That ($content -match [regex]::Escape('C:\Existing\config.ini')) 'existing path should survive'
    Assert-That ($content -match [regex]::Escape('C:\New\config.ini')) 'new path should have been appended'

    $entries = Get-PathsTxtEntries -PathsTxtPath $pathsTxt
    Assert-That (@($entries).Count -eq 2) "expected exactly 2 non-comment path entries, found $(@($entries).Count)"
} | Out-Null

Invoke-Scenario -Name 'PathsTxt: Remove-PathsTxtLine removes only the matching path, keeps comments/blank lines' -Body {
    $sbx = New-Sbx -Label 'pathstxt-remove-preserve'
    $pathsTxt = Join-Path $sbx 'paths.txt'
    $original = "# keep me`n`nC:\Keep\config.ini`nC:\Remove\config.ini`n"
    Write-TextFile -Path $pathsTxt -Content $original

    Remove-PathsTxtLine -PathsTxtPath $pathsTxt -LineToRemove 'C:\Remove\config.ini'

    $content = Read-TextFile $pathsTxt
    Assert-That ($content -match [regex]::Escape('# keep me')) 'comment should survive removal'
    Assert-That ($content -match [regex]::Escape('C:\Keep\config.ini')) 'the other path should survive'
    Assert-That (-not ($content -match [regex]::Escape('C:\Remove\config.ini'))) 'the targeted path should be gone'
} | Out-Null

# ===========================================================================
# Find-HostConf: ProgramW6432 probing + wildcard fallback (field bug)
# ===========================================================================

function Backup-ProgramFilesEnv {
    return [PSCustomObject]@{
        ProgramFiles    = $env:ProgramFiles
        ProgramW6432    = $env:ProgramW6432
        ProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    }
}

function Restore-ProgramFilesEnv {
    param($Backup)
    $env:ProgramFiles = $Backup.ProgramFiles
    $env:ProgramW6432 = $Backup.ProgramW6432
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $Backup.ProgramFilesX86)
}

Invoke-Scenario -Name 'Find-HostConf: Get-HostConfRoots probes ProgramW6432 alongside ProgramFiles/ProgramFiles(x86), de-duplicated' -Body {
    $saved = Backup-ProgramFilesEnv
    try {
        $env:ProgramFiles = 'C:\PF32Path'
        $env:ProgramW6432 = 'C:\TrueProgramFiles'
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', 'C:\PF32Path')

        $roots = @(Get-HostConfRoots)
        Assert-That ($roots -contains 'C:\TrueProgramFiles') 'Get-HostConfRoots must include ProgramW6432 -- the field fix for a 32-bit process on 64-bit Windows hiding the real Program Files'
        Assert-That ($roots -contains 'C:\PF32Path') 'Get-HostConfRoots must still include ProgramFiles'
        Assert-That (@($roots | Where-Object { $_ -eq 'C:\PF32Path' }).Count -eq 1) 'a root equal to both ProgramFiles and ProgramFiles(x86) must be de-duplicated, not probed twice'
    }
    finally {
        Restore-ProgramFilesEnv -Backup $saved
    }
} | Out-Null

Invoke-Scenario -Name 'Find-HostConf: Get-HostConfCandidatePaths includes a path built from ProgramW6432' -Body {
    # Plain (non "C:\"-drive-letter) fake roots: Join-Path on a
    # non-Windows PowerShell host tries to resolve a leading "C:" against
    # a real PSDrive named C and throws "Cannot find drive" when none
    # exists (this test suite runs on Linux/pwsh in CI) -- an
    # implementation/test-host detail with no bearing on what this
    # scenario actually verifies (that ProgramW6432 feeds a candidate).
    $saved = Backup-ProgramFilesEnv
    try {
        $env:ProgramFiles = '/fake/PF32Path'
        $env:ProgramW6432 = '/fake/TrueProgramFiles'
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $null)

        $candidates = Get-HostConfCandidatePaths
        $expected = Join-Path (Join-Path (Join-Path '/fake/TrueProgramFiles' 'Apollo') 'config') 'apollo.conf'
        Assert-That ($candidates -contains $expected) "expected a ProgramW6432-rooted candidate ($expected) in the candidate list"
    }
    finally {
        Restore-ProgramFilesEnv -Backup $saved
    }
} | Out-Null

Invoke-Scenario -Name 'Find-HostConf: a real conf under ProgramW6432 is found even when ProgramFiles points elsewhere (WOW64 field bug)' -Body {
    # Reproduces the actual field scenario: a 32-bit Windows PowerShell
    # process on 64-bit Windows sees $env:ProgramFiles pointing at
    # "Program Files (x86)", but ProgramW6432 still names the true 64-bit
    # Program Files where the real install lives.
    $sbxWow64 = Join-Path (New-Sbx -Label 'find-conf-w6432') 'Program Files'
    $sbxX86 = Join-Path (Split-Path -Path $sbxWow64 -Parent) 'Program Files (x86)'
    $confPath = Join-Path (Join-Path (Join-Path $sbxWow64 'Apollo') 'config') 'apollo.conf'
    Write-TextFile -Path $confPath -Content 'sunshine_name = RealInstall'

    $saved = Backup-ProgramFilesEnv
    try {
        $env:ProgramFiles = $sbxX86
        $env:ProgramW6432 = $sbxWow64
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $sbxX86)

        $found = Find-HostConf
        Assert-That ($found -eq $confPath) "expected Find-HostConf to find the ProgramW6432-rooted conf ($confPath), got: $found"
    }
    finally {
        Restore-ProgramFilesEnv -Backup $saved
    }
} | Out-Null

Invoke-Scenario -Name 'Find-HostConfByWildcard: a single unknown-name conf file in a known appDir/config directory wins' -Body {
    $sbx = New-Sbx -Label 'wildcard-single-unknown'
    $confPath = Join-Path (Join-Path (Join-Path $sbx 'Vibepollo') 'config') 'my-custom-name.conf'
    Write-TextFile -Path $confPath -Content 'k = v'

    $found = Find-HostConfByWildcard -Roots @($sbx)
    Assert-That ($found -eq $confPath) "expected the single unknown-name conf to win, got: $found"
} | Out-Null

Invoke-Scenario -Name 'Find-HostConfByWildcard: multiple confs prefer a known name over an unrecognized one, even if the unknown one is newer' -Body {
    $sbx = New-Sbx -Label 'wildcard-prefer-known'
    $configDir = Join-Path (Join-Path $sbx 'Apollo') 'config'
    $knownPath = Join-Path $configDir 'apollo.conf'
    $unknownPath = Join-Path $configDir 'leftover-backup.conf'
    Write-TextFile -Path $knownPath -Content 'k = v'
    Write-TextFile -Path $unknownPath -Content 'k = v'

    # Make the unknown one strictly newer, so a naive newest-wins policy
    # (with no known-name preference) would pick the wrong file.
    (Get-Item -LiteralPath $unknownPath).LastWriteTime = (Get-Date).AddMinutes(10)
    (Get-Item -LiteralPath $knownPath).LastWriteTime = (Get-Date).AddMinutes(-10)

    $found = Find-HostConfByWildcard -Roots @($sbx)
    Assert-That ($found -eq $knownPath) "expected the known-name conf ($knownPath) to be preferred over a newer unrecognized one, got: $found"
} | Out-Null

Invoke-Scenario -Name 'Find-HostConfByWildcard: multiple unrecognized confs fall back to newest LastWriteTime' -Body {
    $sbx = New-Sbx -Label 'wildcard-newest-wins'
    $configDir = Join-Path (Join-Path $sbx 'Sunshine') 'config'
    $olderPath = Join-Path $configDir 'old.conf'
    $newerPath = Join-Path $configDir 'new.conf'
    Write-TextFile -Path $olderPath -Content 'k = v'
    Write-TextFile -Path $newerPath -Content 'k = v'
    (Get-Item -LiteralPath $olderPath).LastWriteTime = (Get-Date).AddMinutes(-10)
    (Get-Item -LiteralPath $newerPath).LastWriteTime = (Get-Date)

    $found = Find-HostConfByWildcard -Roots @($sbx)
    Assert-That ($found -eq $newerPath) "expected the newest unrecognized conf ($newerPath) to win, got: $found"
} | Out-Null

Invoke-Scenario -Name 'Find-HostConfByWildcard: returns $null when no config directory exists, and never throws on an empty Roots array' -Body {
    $sbx = New-Sbx -Label 'wildcard-nothing-there'
    $found = Find-HostConfByWildcard -Roots @($sbx)
    Assert-That ($null -eq $found) 'no appDir/config directory exists under the given root, so this should return $null'

    $foundEmpty = Find-HostConfByWildcard -Roots @()
    Assert-That ($null -eq $foundEmpty) 'an empty Roots array is a legitimate input (e.g. no Program Files env vars set at all) and must not throw'
} | Out-Null

Invoke-Scenario -Name 'Find-HostConf: falls back to the wildcard scan when no known-name candidate exists anywhere' -Body {
    $sbx = New-Sbx -Label 'find-conf-wildcard-fallback'
    $confPath = Join-Path (Join-Path (Join-Path $sbx 'Apollo') 'config') 'renamed-install.conf'
    Write-TextFile -Path $confPath -Content 'sunshine_name = RenamedInstall'

    $saved = Backup-ProgramFilesEnv
    try {
        $env:ProgramFiles = $sbx
        $env:ProgramW6432 = $sbx
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $null)

        $found = Find-HostConf
        Assert-That ($found -eq $confPath) "expected Find-HostConf's wildcard fallback to find the renamed conf ($confPath), got: $found"
    }
    finally {
        Restore-ProgramFilesEnv -Backup $saved
    }
} | Out-Null

Invoke-Scenario -Name 'Find-HostConf: a known-name conf is still found deterministically, never falling through to the wildcard scan unnecessarily' -Body {
    # Regression guard: the wildcard fallback must never change behavior
    # for the common case of a standard install using a known filename.
    $sbx = New-Sbx -Label 'find-conf-deterministic-still-wins'
    $confPath = Join-Path (Join-Path (Join-Path $sbx 'Sunshine') 'config') 'sunshine.conf'
    Write-TextFile -Path $confPath -Content 'sunshine_name = Standard'
    # Plant a decoy unknown-name file that a buggy implementation might
    # pick via the wildcard path instead.
    $decoyPath = Join-Path (Join-Path (Join-Path $sbx 'Sunshine') 'config') 'zzz-decoy.conf'
    Write-TextFile -Path $decoyPath -Content 'decoy'
    (Get-Item -LiteralPath $decoyPath).LastWriteTime = (Get-Date).AddMinutes(10)

    $saved = Backup-ProgramFilesEnv
    try {
        $env:ProgramFiles = $sbx
        $env:ProgramW6432 = $sbx
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $null)

        $found = Find-HostConf
        Assert-That ($found -eq $confPath) "the known-name conf should win deterministically, got: $found"
    }
    finally {
        Restore-ProgramFilesEnv -Backup $saved
    }
} | Out-Null

# ===========================================================================
# Vibepollo connection state (wizard gating) -- BUG B
# ===========================================================================

Invoke-Scenario -Name 'Vibepollo connect: Invoke-VibepolloConnectAction succeeds against a real conf -- this Success=$true is the ONLY trigger Show-WizardVibepolloStep uses to set State.VibepolloConnected' -Body {
    # Invoke-GuiElevatable's happy path (no failure, no exception) never
    # touches System.Windows.Forms, so this is genuinely exercisable
    # headlessly on this Linux harness -- it drives the exact same
    # function both Show-WizardVibepolloStep's Connect button and the Main
    # Window's Connect/Reconnect... dialog call.
    $sbx = New-Sbx -Label 'vibepollo-connect-action-success'
    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "k = v`n"
    $dataDir = Join-Path $sbx 'data'

    $outcome = Invoke-VibepolloConnectAction -ManagerScriptPath $script:ManagerScriptSource -ConfPath $confPath -DataDir $dataDir
    Assert-That $outcome.Success 'a clean conf should connect successfully'

    $enginePath = Join-Path $dataDir 'sync-configs.ps1'
    $entries = (Get-PrepCommandEntries -ConfPath $confPath).Entries
    $ours = @($entries | Where-Object { Test-PrepCommandEntryIsOurs -Entry $_ -EnginePath $enginePath })
    Assert-That (@($ours).Count -eq 1) 'our entry should actually be present in the conf after a successful connect'
} | Out-Null

Invoke-Scenario -Name 'Vibepollo connect: Show-FirstRunWizard initializes State.VibepolloConnected to $false' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    Assert-That ($source -match 'VibepolloConnected\s*=\s*\$false') 'the wizard state hashtable should initialize VibepolloConnected to $false'
} | Out-Null

Invoke-Scenario -Name 'Vibepollo connect: State.VibepolloConnected is set to $true only inside the Connect handler''s Success branch, never unconditionally' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $stepBody = [regex]::Match($source, '(?s)function Show-WizardVibepolloStep \{.*?\n\}\r?\n\r?\nfunction Show-WizardWatchdogStep')
    Assert-That $stepBody.Success 'sanity: should be able to locate Show-WizardVibepolloStep''s body'

    $setSites = @([regex]::Matches($stepBody.Value, 'State\.VibepolloConnected\s*=\s*\$true'))
    Assert-That (@($setSites).Count -eq 1) "expected exactly one site setting State.VibepolloConnected = `$true, found $(@($setSites).Count)"

    # It must be inside the addOutcome.Success branch: the nearest
    # preceding "if ($addOutcome.Success)" (or equivalent) must appear
    # closer than any addOutcome.Success -eq $false-shaped alternative.
    $successBranchIndex = $stepBody.Value.IndexOf('if ($addOutcome.Success)')
    $setIndex = $stepBody.Value.IndexOf('$State.VibepolloConnected = $true')
    Assert-That ($successBranchIndex -ge 0 -and $setIndex -gt $successBranchIndex) 'VibepolloConnected must be set to $true after (inside) the addOutcome.Success check, not unconditionally on Connect being clicked'
} | Out-Null

Invoke-Scenario -Name 'Vibepollo connect: the Next button warns and requires explicit confirmation before proceeding while not connected' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $stepBody = [regex]::Match($source, '(?s)function Show-WizardVibepolloStep \{.*?\n\}\r?\n\r?\nfunction Show-WizardWatchdogStep')
    Assert-That $stepBody.Success 'sanity: should be able to locate Show-WizardVibepolloStep''s body'

    $nextHandler = [regex]::Match($stepBody.Value, '(?s)\$btnNext\.Add_Click\(\{.*?\}\)')
    Assert-That $nextHandler.Success 'sanity: should be able to locate the Next button''s click handler'

    Assert-That ($nextHandler.Value -match [regex]::Escape('$State.VibepolloConnected')) 'the Next handler should gate on State.VibepolloConnected'
    Assert-That ($nextHandler.Value -match 'Show-GuiConfirm') 'the Next handler should ask for confirmation via Show-GuiConfirm, not just a MessageBox notice'
    Assert-That ($nextHandler.Value -match [regex]::Escape('You have not connected to Vibepollo/Apollo')) 'the confirmation text should match the specified warning'
    Assert-That ($nextHandler.Value -match [regex]::Escape('Continue anyway?')) 'the confirmation text should end with the specified question'
    Assert-That ($nextHandler.Value -match '(?s)if\s*\(-not\s*\$proceedAnyway\)\s*\{\s*return') 'declining the confirmation must actually stop Next from closing the dialog (an early return), not just show a warning and proceed regardless'
} | Out-Null

Invoke-Scenario -Name 'Vibepollo connect: Show-MainWindow exposes a Sync-VibepolloStatus function and a Connect/Reconnect... button wired to Show-VibepolloConnectDialog' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    Assert-That ($source -match 'function Sync-VibepolloStatus') 'Show-MainWindow should define Sync-VibepolloStatus'
    Assert-That ($source -match [regex]::Escape("New-GuiButton -Text 'Connect/Reconnect...'")) 'the main window should have a Connect/Reconnect... button'
    Assert-That ($source -match '(?s)btnConnectVibepollo\.Add_Click\(\{.*?Show-VibepolloConnectDialog') 'the Connect/Reconnect... button should invoke Show-VibepolloConnectDialog'
} | Out-Null

Invoke-Scenario -Name 'Vibepollo connect: Show-VibepolloConnectDialog and Show-WizardVibepolloStep''s Connect handler share Invoke-VibepolloConnectAction (one code path, not two copies)' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $callSites = @([regex]::Matches($source, 'Invoke-VibepolloConnectAction\s+-ManagerScriptPath'))
    Assert-That (@($callSites).Count -ge 2) "expected at least two call sites sharing Invoke-VibepolloConnectAction (wizard step + main window dialog), found $(@($callSites).Count)"
} | Out-Null

# ===========================================================================
# Shortcuts: definition builder, paths, create (shimmed), remove
# ===========================================================================

Invoke-Scenario -Name 'Shortcuts: Get-ManagerShortcutDefinition targets wscript.exe/launch.vbs (not powershell.exe directly), quoting a PROGRAM path with spaces, and sets WindowStyle 7' -Body {
    # Plain (non "C:\"-drive-letter) fake paths: Join-Path on a
    # non-Windows PowerShell host tries to resolve a leading "C:" against
    # a real PSDrive named C and throws "Cannot find drive" when none
    # exists (this test suite runs on Linux/pwsh in CI) -- an
    # implementation/test-host detail with no bearing on what this
    # scenario actually verifies (quoting a spaced path correctly).
    #
    # The shortcut's TARGET is deliberately wscript.exe "<PROGRAM>\
    # launch.vbs", NOT powershell.exe directly -- see
    # Get-ManagerLaunchVbsContent's own comment: Windows Terminal (the
    # default Windows 11 console host) does not reliably honor
    # -WindowStyle Hidden for a console it hosts, so a shortcut that
    # launches powershell.exe directly can still flash a visible console
    # window alongside the GUI even with -WindowStyle Hidden AND a
    # minimized .lnk WindowStyle. wscript.exe never allocates a console at
    # all, sidestepping that bug entirely. The .lnk's own WindowStyle=7
    # (minimized) is kept as cheap belt-and-suspenders.
    $programDir = '/fake/Users/John Doe/AppData/Local/Programs/stream-config-profiles'
    $def = Get-ManagerShortcutDefinition -ProgramDir $programDir -SystemRoot '/fake/Windows'

    $expectedExe = Get-WscriptExePath -SystemRoot '/fake/Windows'
    $expectedLaunchVbsPath = Join-Path $programDir 'launch.vbs'

    Assert-That ($def.Name -eq 'Stream Config Profiles') "expected shortcut Name 'Stream Config Profiles', got '$($def.Name)'"
    Assert-That ($def.TargetPath -eq $expectedExe) "expected TargetPath '$expectedExe' (wscript.exe), got '$($def.TargetPath)'"
    Assert-That ($def.WorkingDirectory -eq $programDir) 'WorkingDirectory should be PROGRAM, so a relative reference from manager.ps1 still resolves'
    Assert-That ($def.Arguments -eq ('"' + $expectedLaunchVbsPath + '"')) "expected Arguments to be the quoted launch.vbs path '$expectedLaunchVbsPath', got '$($def.Arguments)'"
    Assert-That ($def.WindowStyle -eq 7) "expected the .lnk's own WindowStyle to be 7 (minimized), got '$($def.WindowStyle)'"
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: Get-ManagerLaunchVbsContent embeds a correctly VBScript-quoted, spaced powershell.exe/manager.ps1 command line and runs it hidden (window style 0)' -Body {
    # Plain fake paths for the same Join-Path/PSDrive reason as the
    # shortcut-definition scenario above.
    $programDir = '/fake/Users/John Doe/AppData/Local/Programs/stream-config-profiles'
    $content = Get-ManagerLaunchVbsContent -ProgramDir $programDir -SystemRoot '/fake/Windows'

    $expectedExe = Get-WindowsPowerShellExePath -SystemRoot '/fake/Windows'
    $expectedManagerPath = Join-Path $programDir 'manager.ps1'
    $expectedCommandLine = '"' + $expectedExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $expectedManagerPath + '"'
    # VBScript string-literal escaping doubles every embedded double quote.
    $expectedVbsLiteral = $expectedCommandLine.Replace('"', '""')

    Assert-That ($content -match [regex]::Escape('CreateObject("WScript.Shell")')) 'launch.vbs should instantiate WScript.Shell'
    Assert-That ($content -match [regex]::Escape('objShell.Run "' + $expectedVbsLiteral + '", 0, False')) "launch.vbs should Run the quoted, doubled-quote-escaped command line hidden (style 0), got:`n$content"
} | Out-Null

Invoke-Scenario -Name 'Install-App: writes launch.vbs into PROGRAM alongside manager.ps1, pointing at THIS install''s own ProgramDir/manager.ps1' -Body {
    $sbx = New-Sbx -Label 'install-launch-vbs'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'

    $result = Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot

    $expectedLaunchVbsPath = Join-Path $programDir 'launch.vbs'
    Assert-That (Test-Path -LiteralPath $expectedLaunchVbsPath) 'PROGRAM\launch.vbs should exist after install'
    Assert-That ($result.LaunchVbsPath -eq $expectedLaunchVbsPath) 'Install-App result should report the launch.vbs path it wrote'

    $expectedContent = Get-ManagerLaunchVbsContent -ProgramDir $programDir
    Assert-That ((Read-TextFile $expectedLaunchVbsPath) -eq $expectedContent) 'installed launch.vbs content should match Get-ManagerLaunchVbsContent for this exact ProgramDir'
    Assert-That ((Read-TextFile $expectedLaunchVbsPath) -match [regex]::Escape((Join-Path $programDir 'manager.ps1'))) 'installed launch.vbs should reference THIS install''s own manager.ps1 path, not a stale/different one'
} | Out-Null

Invoke-Scenario -Name 'Uninstall-App: removing PROGRAM also removes launch.vbs (it lives inside PROGRAM, deleted as part of the same recursive remove as manager.ps1)' -Body {
    $sbx = New-Sbx -Label 'uninstall-removes-launch-vbs'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null
    $launchVbsPath = Join-Path $programDir 'launch.vbs'
    Assert-That (Test-Path -LiteralPath $launchVbsPath) 'sanity: launch.vbs should exist right after install'

    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir

    Assert-That ($summary.ProgramDirRemoved) 'PROGRAM should have been removed'
    Assert-That (-not (Test-Path -LiteralPath $launchVbsPath)) 'launch.vbs must no longer exist once PROGRAM has been removed'
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: Get-ManagerShortcutPaths builds Desktop/StartMenu paths from given folders, and degrades to $null when a folder is unavailable' -Body {
    $sbx = New-Sbx -Label 'shortcut-paths'
    $desktopDir = Join-Path $sbx 'Desktop'
    $programsDir = Join-Path $sbx 'Programs'

    $paths = Get-ManagerShortcutPaths -DesktopDir $desktopDir -ProgramsDir $programsDir
    Assert-That ($paths.Desktop -eq (Join-Path $desktopDir 'Stream Config Profiles.lnk')) "unexpected Desktop path: $($paths.Desktop)"
    Assert-That ($paths.StartMenu -eq (Join-Path $programsDir 'Stream Config Profiles.lnk')) "unexpected StartMenu path: $($paths.StartMenu)"

    $blankPaths = Get-ManagerShortcutPaths -DesktopDir '' -ProgramsDir ''
    Assert-That ($null -eq $blankPaths.Desktop) 'an unavailable Desktop folder (blank, e.g. this Linux host) should degrade to $null, not a bogus relative path'
    Assert-That ($null -eq $blankPaths.StartMenu) 'an unavailable Programs folder should degrade to $null'
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: New-ManagerShortcut creates only the Start Menu shortcut by default (Desktop opt-in, off)' -Body {
    $script:ShortcutCalls.Clear()
    $sbx = New-Sbx -Label 'shortcut-default'
    $programDir = Join-Path $sbx 'program'
    $desktopDir = Join-Path $sbx 'Desktop'
    $programsDir = Join-Path $sbx 'Programs'

    $results = New-ManagerShortcut -ProgramDir $programDir -DesktopDir $desktopDir -ProgramsDir $programsDir
    Assert-That ($script:ShortcutCalls.Count -eq 1) "expected exactly 1 shortcut creation call (Start Menu only) by default, got $($script:ShortcutCalls.Count)"
    Assert-That ($script:ShortcutCalls[0].ShortcutPath -eq (Join-Path $programsDir 'Stream Config Profiles.lnk')) 'the default shortcut created should be the Start Menu one'
    Assert-That (@($results | Where-Object { $_.Location -eq 'StartMenu' -and $_.Success }).Count -eq 1) 'the result set should report a successful StartMenu creation'
    Assert-That (@($results | Where-Object { $_.Location -eq 'Desktop' }).Count -eq 0) 'Desktop must not even be attempted when not requested'
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: New-ManagerShortcut -Desktop also creates the Desktop shortcut, with the correct definition passed through' -Body {
    $script:ShortcutCalls.Clear()
    $sbx = New-Sbx -Label 'shortcut-both'
    $programDir = Join-Path $sbx 'program'
    $desktopDir = Join-Path $sbx 'Desktop'
    $programsDir = Join-Path $sbx 'Programs'

    $results = New-ManagerShortcut -ProgramDir $programDir -StartMenu -Desktop -DesktopDir $desktopDir -ProgramsDir $programsDir
    Assert-That ($script:ShortcutCalls.Count -eq 2) "expected 2 shortcut creation calls (Start Menu + Desktop), got $($script:ShortcutCalls.Count)"

    $desktopCall = @($script:ShortcutCalls | Where-Object { $_.ShortcutPath -eq (Join-Path $desktopDir 'Stream Config Profiles.lnk') })[0]
    Assert-That ($null -ne $desktopCall) 'a Desktop shortcut creation call should have been made'
    Assert-That ($desktopCall.Definition.WorkingDirectory -eq $programDir) 'the Definition passed to New-ShortcutFile should carry the correct WorkingDirectory'

    Assert-That (@($results | Where-Object { -not $_.Success }).Count -eq 0) 'both locations should report success against the shim'
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: New-ManagerShortcut reports a per-location failure without throwing or blocking the other location' -Body {
    $script:ShortcutCalls.Clear()
    $sbx = New-Sbx -Label 'shortcut-partial-failure'
    $programDir = Join-Path $sbx 'program'
    $desktopDir = Join-Path $sbx 'Desktop'
    $programsDir = Join-Path $sbx 'Programs'
    $startMenuPath = Join-Path $programsDir 'Stream Config Profiles.lnk'

    $script:ShortcutCreateShouldThrowFor = @($startMenuPath)
    try {
        $results = New-ManagerShortcut -ProgramDir $programDir -StartMenu -Desktop -DesktopDir $desktopDir -ProgramsDir $programsDir
        $startMenuResult = @($results | Where-Object { $_.Location -eq 'StartMenu' })[0]
        $desktopResult = @($results | Where-Object { $_.Location -eq 'Desktop' })[0]
        Assert-That (-not $startMenuResult.Success) 'the Start Menu location should report the simulated failure'
        Assert-That ($desktopResult.Success) 'the Desktop location must still succeed -- one location failing must never block the other'
    }
    finally {
        $script:ShortcutCreateShouldThrowFor = @()
    }
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: New-ManagerShortcut treats an unavailable folder as a reported (not thrown) per-location failure' -Body {
    $script:ShortcutCalls.Clear()
    $sbx = New-Sbx -Label 'shortcut-unavailable-folder'
    $programDir = Join-Path $sbx 'program'

    $results = New-ManagerShortcut -ProgramDir $programDir -StartMenu -Desktop -DesktopDir '' -ProgramsDir ''
    Assert-That ($script:ShortcutCalls.Count -eq 0) 'New-ShortcutFile must never even be called when the target folder is unavailable'
    Assert-That (@($results | Where-Object { -not $_.Success }).Count -eq 2) 'both locations should report failure when their folders are unavailable'
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: Uninstall-App removes existing Desktop and Start Menu shortcut files (best-effort), reporting them, without needing COM' -Body {
    $sbx = New-Sbx -Label 'uninstall-removes-shortcuts'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    $desktopDir = Join-Path $sbx 'Desktop'
    $programsDir = Join-Path $sbx 'Programs'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $desktopShortcut = Join-Path $desktopDir 'Stream Config Profiles.lnk'
    $startMenuShortcut = Join-Path $programsDir 'Stream Config Profiles.lnk'
    Write-TextFile -Path $desktopShortcut -Content 'FAKE-LNK-DESKTOP'
    Write-TextFile -Path $startMenuShortcut -Content 'FAKE-LNK-STARTMENU'

    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $null -DesktopDir $desktopDir -ProgramsDir $programsDir

    Assert-That (-not (Test-Path -LiteralPath $desktopShortcut)) 'the Desktop shortcut file should actually be deleted'
    Assert-That (-not (Test-Path -LiteralPath $startMenuShortcut)) 'the Start Menu shortcut file should actually be deleted'

    $desktopResult = @($summary.ShortcutsRemoved | Where-Object { $_.Location -eq 'Desktop' })[0]
    $startMenuResult = @($summary.ShortcutsRemoved | Where-Object { $_.Location -eq 'StartMenu' })[0]
    Assert-That ($desktopResult.Success -and $desktopResult.Message -eq 'removed') "expected Desktop removal Message 'removed', got Success=$($desktopResult.Success) Message='$($desktopResult.Message)'"
    Assert-That ($startMenuResult.Success -and $startMenuResult.Message -eq 'removed') "expected StartMenu removal Message 'removed', got Success=$($startMenuResult.Success) Message='$($startMenuResult.Message)'"
    Assert-That $summary.Success 'shortcut removal must never flip the top-level uninstall Success -- it is best-effort clutter cleanup, not a permissions hazard'
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: Uninstall-App reports "not present" (still Success) when no shortcut file exists at either location' -Body {
    $sbx = New-Sbx -Label 'uninstall-no-shortcuts-present'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    $desktopDir = Join-Path $sbx 'Desktop'
    $programsDir = Join-Path $sbx 'Programs'
    New-Item -ItemType Directory -Path $desktopDir -Force | Out-Null
    New-Item -ItemType Directory -Path $programsDir -Force | Out-Null
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $null -DesktopDir $desktopDir -ProgramsDir $programsDir

    $desktopResult = @($summary.ShortcutsRemoved | Where-Object { $_.Location -eq 'Desktop' })[0]
    Assert-That ($desktopResult.Success -and $desktopResult.Message -eq 'not present') "expected 'not present' when no shortcut exists, got Success=$($desktopResult.Success) Message='$($desktopResult.Message)'"
} | Out-Null

Invoke-Scenario -Name 'Shortcuts: Uninstall-App treats an unavailable Desktop/Start Menu folder as nothing-to-remove, never throwing' -Body {
    $sbx = New-Sbx -Label 'uninstall-shortcuts-unavailable-folder'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $null -DesktopDir '' -ProgramsDir ''

    Assert-That (@($summary.ShortcutsRemoved | Where-Object { -not $_.Success }).Count -eq 0) 'an unavailable shortcut folder must be reported as success (nothing to remove), never a failure'
    Assert-That $summary.Success 'uninstall overall must still succeed when shortcut folders are simply unavailable on this platform'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: install with no shortcut switches never touches shortcut creation (default headless behavior unchanged)' -Body {
    $script:ShortcutCalls.Clear()
    $sbx = New-Sbx -Label 'dispatch-install-no-shortcuts'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'

    $result = Invoke-ManagerAction -Action 'install' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource
    Assert-That ($script:ShortcutCalls.Count -eq 0) 'a plain headless install (no -AddStartMenuShortcut/-AddDesktopShortcut) must never attempt shortcut creation'
    Assert-That ($result.PSObject.Properties.Match('ShortcutsCreated').Count -eq 0) 'the install result must not carry a ShortcutsCreated property when no shortcut switch was passed'
} | Out-Null

Invoke-Scenario -Name 'Dispatch: install -AddStartMenuShortcut -AddDesktopShortcut invokes New-ManagerShortcut with the resolved PROGRAM dir and both locations requested' -Body {
    # Shims New-ManagerShortcut itself (not just New-ShortcutFile) for this
    # one scenario -- unlike the direct New-ManagerShortcut tests above,
    # this is purely about the CLI dispatch wiring (does -Action install
    # actually call New-ManagerShortcut with the right arguments when
    # asked), not about real Desktop/Programs folder resolution, which
    # Get-ManagerShortcutPaths and New-ManagerShortcut's own tests already
    # cover directly against sandbox folders. Captures and restores the
    # real function afterward so it stays real for any other scenario.
    $originalNewManagerShortcut = ${function:New-ManagerShortcut}
    $script:ManagerShortcutCalls = New-Object System.Collections.Generic.List[object]
    function script:New-ManagerShortcut {
        param([string]$ProgramDir, [switch]$StartMenu, [switch]$Desktop, [string]$DesktopDir, [string]$ProgramsDir)
        $script:ManagerShortcutCalls.Add([PSCustomObject]@{ ProgramDir = $ProgramDir; StartMenu = [bool]$StartMenu; Desktop = [bool]$Desktop })
        return @(
            [PSCustomObject]@{ Location = 'StartMenu'; Path = 'fake-start-menu.lnk'; Success = $true; Message = 'created' },
            [PSCustomObject]@{ Location = 'Desktop'; Path = 'fake-desktop.lnk'; Success = $true; Message = 'created' }
        )
    }
    try {
        $sbx = New-Sbx -Label 'dispatch-install-with-shortcuts'
        $programDir = Join-Path $sbx 'program'
        $dataDir = Join-Path $sbx 'data'

        $result = Invoke-ManagerAction -Action 'install' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -AddStartMenuShortcut -AddDesktopShortcut

        Assert-That ($script:ManagerShortcutCalls.Count -eq 1) "expected exactly 1 call to New-ManagerShortcut, got $($script:ManagerShortcutCalls.Count)"
        $call = $script:ManagerShortcutCalls[0]
        Assert-That ($call.ProgramDir -eq $programDir) 'New-ManagerShortcut should be called with the resolved PROGRAM dir'
        Assert-That ($call.StartMenu) 'StartMenu should be requested when -AddStartMenuShortcut is passed'
        Assert-That ($call.Desktop) 'Desktop should be requested when -AddDesktopShortcut is passed'
        Assert-That ($result.PSObject.Properties.Match('ShortcutsCreated').Count -gt 0) 'the install result should carry a ShortcutsCreated property when a shortcut switch was passed'
    }
    finally {
        ${function:New-ManagerShortcut} = $originalNewManagerShortcut
    }
} | Out-Null

# ===========================================================================
# Get-VibepolloConnectionStatus -- headless status computation extracted
# from Show-MainWindow's Sync-VibepolloStatus (previously untestable: only
# a source-regex check that the function existed)
# ===========================================================================

Invoke-Scenario -Name 'Get-VibepolloConnectionStatus: a blank/unknown conf path reports NotFound' -Body {
    $status = Get-VibepolloConnectionStatus -ConfPath $null -DataDir '/fake/data'
    Assert-That ($status.State -eq 'NotFound') "expected State 'NotFound', got '$($status.State)'"
    Assert-That ($status.Text -match 'Not connected -- no Vibepollo') 'the text should explain nothing was found automatically'

    $statusBlank = Get-VibepolloConnectionStatus -ConfPath '' -DataDir '/fake/data'
    Assert-That ($statusBlank.State -eq 'NotFound') 'a blank (not just $null) ConfPath should also report NotFound'
} | Out-Null

Invoke-Scenario -Name 'Get-VibepolloConnectionStatus: a conf with malformed global_prep_cmd JSON reports Unreadable, distinct from NotConnected' -Body {
    $sbx = New-Sbx -Label 'status-unreadable'
    $confPath = Join-Path $sbx 'sunshine.conf'
    Write-TextFile -Path $confPath -Content "global_prep_cmd = not valid json`n"

    $status = Get-VibepolloConnectionStatus -ConfPath $confPath -DataDir (Join-Path $sbx 'data')
    Assert-That ($status.State -eq 'Unreadable') "expected State 'Unreadable', got '$($status.State)'"
    Assert-That ($status.Text -match 'Conf found but unreadable') 'the text should distinguish this from a plain not-connected state'
    Assert-That ($status.Text -match [regex]::Escape($confPath)) 'the text should still name the conf path'
} | Out-Null

Invoke-Scenario -Name 'Get-VibepolloConnectionStatus: a conf with our entry reports Connected' -Body {
    $sbx = New-Sbx -Label 'status-connected'
    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "k = v`n"
    $dataDir = Join-Path $sbx 'data'

    $addResult = Add-PrepCommandEntry -ConfPath $confPath -DataDir $dataDir
    Assert-That $addResult.Success 'sanity: connecting should succeed against a clean conf'

    $status = Get-VibepolloConnectionStatus -ConfPath $confPath -DataDir $dataDir
    Assert-That ($status.State -eq 'Connected') "expected State 'Connected', got '$($status.State)'"
    Assert-That ($status.Text -match '^Connected:') 'the text should start with Connected:'
} | Out-Null

Invoke-Scenario -Name 'Get-VibepolloConnectionStatus: a valid conf with no matching entry reports NotConnected' -Body {
    $sbx = New-Sbx -Label 'status-not-connected'
    $confPath = Join-Path $sbx 'sunshine.conf'
    New-ConfFixture -Path $confPath -Content "k = v`n"

    $status = Get-VibepolloConnectionStatus -ConfPath $confPath -DataDir (Join-Path $sbx 'data')
    Assert-That ($status.State -eq 'NotConnected') "expected State 'NotConnected', got '$($status.State)'"
    Assert-That ($status.Text -match '^Not connected:') 'the text should start with Not connected:'
} | Out-Null

# ===========================================================================
# Get-HostConfRoots ordering -- ProgramW6432 must be probed BEFORE
# $env:ProgramFiles (field bug: on a 32-bit process, $env:ProgramFiles
# ALREADY points at the x86 alias, so checking it first silently prefers a
# stale/decoy x86 install over the true 64-bit one)
# ===========================================================================

Invoke-Scenario -Name 'Find-HostConf: with a decoy known-name conf under the ProgramFiles(x86) alias AND a real one under ProgramW6432, the ProgramW6432 (true 64-bit) conf wins' -Body {
    $sbxX86 = New-Sbx -Label 'root-order-x86'
    $sbxTrue = New-Sbx -Label 'root-order-true'
    $decoyPath = Join-Path (Join-Path (Join-Path $sbxX86 'Apollo') 'config') 'apollo.conf'
    $realPath = Join-Path (Join-Path (Join-Path $sbxTrue 'Apollo') 'config') 'apollo.conf'
    Write-TextFile -Path $decoyPath -Content 'sunshine_name = Decoy'
    Write-TextFile -Path $realPath -Content 'sunshine_name = RealInstall'

    $saved = Backup-ProgramFilesEnv
    try {
        # Exactly the WOW64 shape: a 32-bit process's $env:ProgramFiles IS
        # the x86 alias, which here happens to also hold a decoy conf.
        $env:ProgramFiles = $sbxX86
        $env:ProgramW6432 = $sbxTrue
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $sbxX86)

        $found = Find-HostConf
        Assert-That ($found -eq $realPath) "expected the ProgramW6432-rooted conf ($realPath) to win over the ProgramFiles(x86)-alias decoy ($decoyPath), got: $found"
    }
    finally {
        Restore-ProgramFilesEnv -Backup $saved
    }
} | Out-Null

# ===========================================================================
# Find-HostConfByWildcard -ExtraConfigDirs -- extends the wildcard fallback
# to a matching service's own binary directory (and its config\ subfolder),
# which the static candidate pass alone does not cover for a RENAMED conf
# ===========================================================================

Invoke-Scenario -Name 'Find-HostConfByWildcard: -ExtraConfigDirs scans a literal directory directly (not nested under an appDir), for a renamed conf' -Body {
    $sbx = New-Sbx -Label 'wildcard-extra-dirs'
    $serviceConfigDir = Join-Path $sbx 'config'
    $confPath = Join-Path $serviceConfigDir 'custom-name.conf'
    Write-TextFile -Path $confPath -Content 'k = v'

    $found = Find-HostConfByWildcard -Roots @() -ExtraConfigDirs @($serviceConfigDir)
    Assert-That ($found -eq $confPath) "expected the extra-config-dir conf ($confPath) to be found, got: $found"
} | Out-Null

Invoke-Scenario -Name 'Find-HostConf: the wildcard fallback also covers a matching service''s own binary directory for a renamed conf (custom-location install)' -Body {
    # Shims Get-HostServiceBinaryDir (captured/restored afterward) to
    # simulate a running Vibepollo/Apollo/Sunshine service whose binary
    # lives outside every Program Files root entirely -- the scenario
    # Get-HostServiceBinaryDir exists to hint at.
    $originalGetHostServiceBinaryDir = ${function:Get-HostServiceBinaryDir}
    $sbx = New-Sbx -Label 'find-conf-service-dir-renamed'
    $serviceBinDir = Join-Path $sbx 'D-Games-Apollo'
    $serviceConfigDir = Join-Path $serviceBinDir 'config'
    $confPath = Join-Path $serviceConfigDir 'my-renamed-install.conf'
    Write-TextFile -Path $confPath -Content 'sunshine_name = CustomLocation'

    # $script: scope, not lexical capture -- same pattern the harness
    # already uses for every other shim's configurable state
    # ($script:UnregisterShouldThrowFor, $script:ShortcutCreateShouldThrowFor,
    # ...), so the redefined function sees it reliably regardless of when
    # or from which call site it is later invoked.
    $script:FakeServiceBinDirForTest = $serviceBinDir
    function script:Get-HostServiceBinaryDir {
        param([string[]]$NamePatterns)
        return @($script:FakeServiceBinDirForTest)
    }

    $saved = Backup-ProgramFilesEnv
    try {
        $emptyRoot = New-Sbx -Label 'find-conf-service-dir-empty-root'
        $env:ProgramFiles = $emptyRoot
        $env:ProgramW6432 = $emptyRoot
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $null)

        $found = Find-HostConf
        Assert-That ($found -eq $confPath) "expected Find-HostConf to find the renamed conf under the service's own directory ($confPath), got: $found"
    }
    finally {
        Restore-ProgramFilesEnv -Backup $saved
        ${function:Get-HostServiceBinaryDir} = $originalGetHostServiceBinaryDir
    }
} | Out-Null

# ===========================================================================
# Reparse-point ancestor guard -- Test-IsReparsePoint alone only inspects
# the final path component; a junction/symlink on a PARENT directory is
# invisible to it because Get-Item transparently resolves through it
# ===========================================================================

Invoke-Scenario -Name 'Test-AnyAncestorIsReparsePoint: detects a symlinked PARENT directory, and does not false-positive on an ordinary path' -Body {
    $sbx = New-Sbx -Label 'reparse-ancestor'
    $realDir = Join-Path $sbx 'real'
    New-Item -ItemType Directory -Path $realDir -Force | Out-Null
    $ordinaryConfPath = Join-Path $realDir 'sunshine.conf'
    Write-TextFile -Path $ordinaryConfPath -Content "k = v`n"

    Assert-That (-not (Test-AnyAncestorIsReparsePoint -Path $ordinaryConfPath)) 'an ordinary (non-symlinked) parent chain must not be flagged'

    $linkDir = Join-Path $sbx 'link'
    $symlinkSupported = $true
    try {
        New-Item -ItemType SymbolicLink -Path $linkDir -Target $realDir -ErrorAction Stop | Out-Null
    }
    catch {
        $symlinkSupported = $false
    }
    if (-not $symlinkSupported) {
        # No permission to create symlinks on this host (e.g. Windows
        # without Developer Mode / admin) -- nothing more to assert here.
        return
    }

    $confPathViaLink = Join-Path $linkDir 'sunshine.conf'
    Assert-That (Test-AnyAncestorIsReparsePoint -Path $confPathViaLink) 'a symlinked parent directory must be detected even though the leaf file itself is an ordinary file'
} | Out-Null

Invoke-Scenario -Name 'New-ConfBackup / Write-ConfGlobalPrepCmd: refuse to read/write through a reparse point sitting on a PARENT directory' -Body {
    $sbx = New-Sbx -Label 'reparse-ancestor-write'
    $realDir = Join-Path $sbx 'real'
    New-Item -ItemType Directory -Path $realDir -Force | Out-Null
    $confPath = Join-Path $realDir 'sunshine.conf'
    Write-TextFile -Path $confPath -Content "k = v`n"

    $linkDir = Join-Path $sbx 'link'
    $symlinkSupported = $true
    try {
        New-Item -ItemType SymbolicLink -Path $linkDir -Target $realDir -ErrorAction Stop | Out-Null
    }
    catch {
        $symlinkSupported = $false
    }
    if (-not $symlinkSupported) {
        return
    }

    $confPathViaLink = Join-Path $linkDir 'sunshine.conf'

    $threwBackup = $false
    try {
        New-ConfBackup -ConfPath $confPathViaLink | Out-Null
    }
    catch {
        $threwBackup = $true
        Assert-That ($_.Exception.Message -match 'parent directory') 'New-ConfBackup''s error should call out a parent-directory reparse point, not just the leaf'
    }
    Assert-That $threwBackup 'New-ConfBackup must refuse to read through a reparse point on a parent directory'

    $threwWrite = $false
    try {
        Write-ConfGlobalPrepCmd -ConfPath $confPathViaLink -JsonValue '[]'
    }
    catch {
        $threwWrite = $true
        Assert-That ($_.Exception.Message -match 'parent directory') 'Write-ConfGlobalPrepCmd''s error should call out a parent-directory reparse point, not just the leaf'
    }
    Assert-That $threwWrite 'Write-ConfGlobalPrepCmd must refuse to write through a reparse point on a parent directory'
} | Out-Null

# ===========================================================================
# Get-SettleAction: same double-quote guard Add-PrepCommandEntry already has
# ===========================================================================

Invoke-Scenario -Name 'Get-SettleAction: rejects a DataDir containing a double-quote character' -Body {
    $threw = $false
    try {
        Get-SettleAction -DataDir 'C:\x" -foo bar' | Out-Null
    }
    catch {
        $threw = $true
        Assert-That ($_.Exception.Message -match 'double-quote') 'the error should explain the double-quote is the problem'
    }
    Assert-That $threw 'Get-SettleAction must reject a DataDir containing a double-quote, mirroring Add-PrepCommandEntry''s own guard'
} | Out-Null

# ===========================================================================
# Uninstall-App: CWD safety + corrected skip-reason wording
# ===========================================================================

Invoke-Scenario -Name 'Uninstall-App: moves the process current directory away before deleting ProgramDir (Windows cannot delete a directory that is any process''s CWD)' -Body {
    $sbx = New-Sbx -Label 'uninstall-cwd-safety'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $originalLocation = (Get-Location).Path
    try {
        Set-Location -LiteralPath $programDir
        $summary = Uninstall-App -ProgramDir $programDir -DataDir $dataDir -ConfPath $null
        Assert-That $summary.ProgramDirRemoved 'ProgramDir should still be removed even though it was the process''s current directory'
        Assert-That ((Get-Location).Path -ne $programDir) 'Uninstall-App should move the current directory away from ProgramDir before attempting to delete it'
    }
    finally {
        Set-Location -LiteralPath $originalLocation
    }
} | Out-Null

Invoke-Scenario -Name 'Uninstall-App: skip-reason wording describes the real marker-file condition, not a leaf-name expectation Test-LooksLikeOurInstallDirectory does not enforce' -Body {
    $sbx = New-Sbx -Label 'uninstall-skip-wording'
    $bogusProgramDir = Join-Path $sbx 'not-our-program-dir'
    New-Item -ItemType Directory -Path $bogusProgramDir -Force | Out-Null
    Write-TextFile -Path (Join-Path $bogusProgramDir 'unrelated.txt') -Content 'not manager.ps1'

    $summary = Uninstall-App -ProgramDir $bogusProgramDir -DataDir (Join-Path $sbx 'data') -ConfPath $null
    Assert-That (-not [string]::IsNullOrWhiteSpace($summary.ProgramDirSkipReason)) 'a skip reason should be set'
    Assert-That ($summary.ProgramDirSkipReason -match 'marker files') 'the message should describe the real condition (missing marker files)'
    Assert-That ($summary.ProgramDirSkipReason -notmatch "expected leaf name") 'the message must not claim a leaf-name requirement Test-LooksLikeOurInstallDirectory deliberately does not check'
} | Out-Null

# ===========================================================================
# Invoke-ManagerAction 'uninstall': -DesktopDir/-ProgramsDir threaded through
# (same over-the-shoulder-admin hazard -UserId already guards against,
# applied to shortcut removal on an elevated re-entry)
# ===========================================================================

Invoke-Scenario -Name 'Dispatch: uninstall threads -DesktopDir/-ProgramsDir through to Uninstall-App' -Body {
    $sbx = New-Sbx -Label 'dispatch-uninstall-desktopdir'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    $desktopDir = Join-Path $sbx 'CustomDesktop'
    $programsDir = Join-Path $sbx 'CustomPrograms'
    New-Item -ItemType Directory -Path $desktopDir -Force | Out-Null
    New-Item -ItemType Directory -Path $programsDir -Force | Out-Null
    Install-App -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -ScriptDir $script:RepoRoot | Out-Null

    $desktopShortcut = Join-Path $desktopDir 'Stream Config Profiles.lnk'
    Write-TextFile -Path $desktopShortcut -Content 'FAKE-LNK'

    Invoke-ManagerAction -Action 'uninstall' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource -DesktopDir $desktopDir -ProgramsDir $programsDir | Out-Null

    Assert-That (-not (Test-Path -LiteralPath $desktopShortcut)) 'the explicitly-passed -DesktopDir should actually be the one Uninstall-App used to find and remove the shortcut'
} | Out-Null

# ===========================================================================
# Test-PathUnderTrustedProgramRoot -- registry-backed (GetFolderPath), not
# $env:ProgramFiles/$env:ProgramW6432/$env:ProgramFiles(x86)-based, so an
# unprivileged HKCU\Environment override cannot make an untrusted path
# report as trusted
# ===========================================================================

Invoke-Scenario -Name 'Test-PathUnderTrustedProgramRoot: an arbitrary/blank path is never trusted' -Body {
    Assert-That (-not (Test-PathUnderTrustedProgramRoot -Path '/some/random/untrusted/path/apollo.conf')) 'an arbitrary path unrelated to any resolvable Program Files root should not be trusted'
    Assert-That (-not (Test-PathUnderTrustedProgramRoot -Path '')) 'a blank path should never be trusted'
} | Out-Null

# ===========================================================================
# Uninstall discards the connected conf (BUG A, critical): the wizard's
# connected conf path must flow through to Show-MainWindow and be preferred
# over a fresh Find-HostConf guess in both the status display and the
# Disconnect/Uninstall handler
# ===========================================================================

Invoke-Scenario -Name 'Show-VibepolloConnectDialog returns the connected ConfPath alongside Connected, not just a bare bool' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $dialogBody = [regex]::Match($source, '(?s)function Show-VibepolloConnectDialog \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $dialogBody.Success 'sanity: should be able to locate Show-VibepolloConnectDialog''s body'
    Assert-That ($dialogBody.Value -match [regex]::Escape('$outcomeState.ConfPath = $confPath')) 'a successful Connect should record the conf path on the returned object'
    Assert-That ($dialogBody.Value -match 'return \$outcomeState\r?\n') 'the dialog should return the whole outcome object (Connected + ConfPath), not just a bare bool'
} | Out-Null

Invoke-Scenario -Name 'Show-MainWindow accepts a -ConfPath and tracks it (via $vibepolloConnection) instead of only ever re-guessing with Find-HostConf' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $windowBody = [regex]::Match($source, '(?s)function Show-MainWindow \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $windowBody.Success 'sanity: should be able to locate Show-MainWindow''s body'

    Assert-That ($windowBody.Value -match '\[string\]\$ConfPath') 'Show-MainWindow should declare a -ConfPath parameter'
    Assert-That ($windowBody.Value -match [regex]::Escape('$vibepolloConnection = [PSCustomObject]@{ ConfPath = $ConfPath }')) 'Show-MainWindow should seed a tracked connection object from the incoming -ConfPath'

    # The Connect/Reconnect... handler must update the tracked object from
    # the dialog's result.
    Assert-That ($windowBody.Value -match [regex]::Escape('$vibepolloConnection.ConfPath = [string]$dialogResult.ConfPath')) 'the Connect/Reconnect... handler should update the tracked conf path on a successful connect'

    # The Disconnect/Uninstall handler must prefer the tracked path over a
    # fresh Find-HostConf guess -- this is the actual field bug: the guess
    # cannot see a portable/custom-path conf reached only via Browse.
    $disconnectHandler = [regex]::Match($windowBody.Value, '(?s)\$btnDisconnect\.Add_Click\(\{.*?\}\)\r?\n\r?\n    \$form\.ShowDialog')
    Assert-That $disconnectHandler.Success 'sanity: should be able to locate the Disconnect/Uninstall click handler'
    Assert-That ($disconnectHandler.Value -match [regex]::Escape('$vibepolloConnection.ConfPath')) 'the Disconnect/Uninstall handler should consult the tracked conf path'
    $preferIndex = $disconnectHandler.Value.IndexOf('$vibepolloConnection.ConfPath')
    $guessIndex = $disconnectHandler.Value.IndexOf('Find-HostConf')
    Assert-That ($preferIndex -ge 0 -and $guessIndex -ge 0 -and $preferIndex -lt $guessIndex) 'the tracked conf path must be checked BEFORE falling back to a fresh Find-HostConf guess'
} | Out-Null

Invoke-Scenario -Name 'Show-FirstRunWizard only hands the conf path to Show-MainWindow as "connected" when the wizard''s own Connect actually succeeded' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $wizardBody = [regex]::Match($source, '(?s)function Show-FirstRunWizard \{.*?\n\}\r?\n\r?\nfunction Show-VibepolloConnectDialog')
    Assert-That $wizardBody.Success 'sanity: should be able to locate Show-FirstRunWizard''s body'
    Assert-That ($wizardBody.Value -match '(?s)if\s*\(\[bool\]\$state\.VibepolloConnected\)\s*\{\s*\$connectedConfPathForMainWindow\s*=\s*\$state\.ConfPath') 'Show-MainWindow should only be told a conf is connected when $state.VibepolloConnected is actually true'
    Assert-That ($wizardBody.Value -match [regex]::Escape('-ConfPath $connectedConfPathForMainWindow')) 'Show-MainWindow should be called with the gated conf path'
} | Out-Null

Invoke-Scenario -Name 'Show-WizardVibepolloStep: editing the conf textbox after a successful Connect invalidates VibepolloConnected (does not silently keep gating Next as connected)' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $stepBody = [regex]::Match($source, '(?s)function Show-WizardVibepolloStep \{.*?\n\}\r?\n\r?\nfunction Show-WizardWatchdogStep')
    Assert-That $stepBody.Success 'sanity: should be able to locate Show-WizardVibepolloStep''s body'

    Assert-That ($stepBody.Value -match [regex]::Escape('$txtConf.Add_TextChanged({')) 'the conf textbox should have a TextChanged handler'
    Assert-That ($stepBody.Value -match [regex]::Escape('$State.ConnectedConfPath = $confPath')) 'a successful Connect should record which conf path it connected'
    Assert-That ($stepBody.Value -match '(?s)Add_TextChanged\(\{.*?VibepolloConnected\s*=\s*\$false') 'the TextChanged handler should reset VibepolloConnected to $false when the text no longer matches the connected conf path'
} | Out-Null

Invoke-Scenario -Name 'Show-WizardInstallStep: a successful install repoints State.ManagerScriptPath at the PROGRAM copy, not the process''s original (possibly %TEMP%-extracted) launch path' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $stepBody = [regex]::Match($source, '(?s)function Show-WizardInstallStep \{.*?\n\}\r?\n\r?\nfunction Show-WizardVibepolloStep')
    Assert-That $stepBody.Success 'sanity: should be able to locate Show-WizardInstallStep''s body'
    Assert-That ($stepBody.Value -match [regex]::Escape('$State.ManagerScriptPath = $r.ManagerPath')) 'a successful install should repoint State.ManagerScriptPath at the freshly-installed PROGRAM copy'
} | Out-Null

Invoke-Scenario -Name 'Disconnect/Uninstall success text calls out plainly when no conf was known/found, so it can never claim a disconnect that did not happen' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    Assert-That ($source -match [regex]::Escape('No Vibepollo/Apollo conf file was connected or found automatically, so no connection entry was removed.')) 'the uninstall success dialog should explicitly say when no conf was touched'
} | Out-Null

# ===========================================================================
# Show-WizardDoneStep: shortcut checkbox defaults + Finish handler wiring
# (previously zero coverage -- not even a source regex check)
# ===========================================================================

Invoke-Scenario -Name 'Show-WizardDoneStep: Start Menu checkbox defaults checked, Desktop checkbox defaults unchecked' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $stepBody = [regex]::Match($source, '(?s)function Show-WizardDoneStep \{.*?\n\}\r?\n\r?\nfunction Show-FirstRunWizard')
    Assert-That $stepBody.Success 'sanity: should be able to locate Show-WizardDoneStep''s body'

    Assert-That ($stepBody.Value -match [regex]::Escape("New-GuiCheckBox -Text 'Add to Start Menu'") + '.*-Checked \$true') 'the Start Menu shortcut checkbox should default checked'
    Assert-That ($stepBody.Value -match [regex]::Escape("New-GuiCheckBox -Text 'Create Desktop shortcut'") + '.*-Checked \$false') 'the Desktop shortcut checkbox should default unchecked'
} | Out-Null

Invoke-Scenario -Name 'Show-WizardDoneStep: the Finish handler binds New-ManagerShortcut''s -StartMenu/-Desktop to the two checkboxes'' actual Checked state' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $stepBody = [regex]::Match($source, '(?s)function Show-WizardDoneStep \{.*?\n\}\r?\n\r?\nfunction Show-FirstRunWizard')
    Assert-That $stepBody.Success 'sanity: should be able to locate Show-WizardDoneStep''s body'

    $finishHandler = [regex]::Match($stepBody.Value, '(?s)\$btnFinish\.Add_Click\(\{.*?\}\)')
    Assert-That $finishHandler.Success 'sanity: should be able to locate the Finish button''s click handler'

    Assert-That ($finishHandler.Value -match [regex]::Escape('$addStartMenu = $cbStartMenuShortcut.Checked')) 'the Finish handler should read the Start Menu checkbox''s actual Checked state'
    Assert-That ($finishHandler.Value -match [regex]::Escape('$addDesktop = $cbDesktopShortcut.Checked')) 'the Finish handler should read the Desktop checkbox''s actual Checked state'
    Assert-That ($finishHandler.Value -match [regex]::Escape('New-ManagerShortcut -ProgramDir $State.ProgramDir -StartMenu:$addStartMenu -Desktop:$addDesktop')) 'New-ManagerShortcut should be called with both switches bound to the checkboxes, not hardcoded'
    Assert-That ($finishHandler.Value -match 'Invoke-GuiSafe') 'the shortcut creation call should go through Invoke-GuiSafe (a shortcut failure must never block finishing setup)'
} | Out-Null

# ===========================================================================
# High-DPI GUI fix -- field feedback: an unaware process gets bitmap-
# stretched by Windows on a high-DPI/4K display, so its text looks blurry.
# Every scenario below is source-level (regex over the raw script text),
# same as the other GUI: scenarios above -- actual crisp-vs-blurry
# rendering can only be confirmed by eye on a real high-DPI Windows
# display, which this headless Linux harness cannot do.
# ===========================================================================

Invoke-Scenario -Name 'DPI awareness: Enable-GuiDpiAwareness is defined and is idempotent (guarded by a script-scope flag)' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    Assert-That ($source -match '(?m)^function Enable-GuiDpiAwareness\s*\{') 'manager.ps1 should define Enable-GuiDpiAwareness'

    $body = [regex]::Match($source, '(?s)function Enable-GuiDpiAwareness \{.*?\n\}\r?\n\r?\nfunction Initialize-GuiAssemblies')
    Assert-That $body.Success 'sanity: should be able to locate Enable-GuiDpiAwareness''s body'
    Assert-That ($body.Value -match [regex]::Escape('if ($script:GuiDpiAwarenessEnabled)') + '\s*\{\s*return') 'Enable-GuiDpiAwareness should return immediately (a no-op) if already applied'
    Assert-That ($body.Value -match [regex]::Escape('$script:GuiDpiAwarenessEnabled = $true')) 'Enable-GuiDpiAwareness should set its own guard flag before doing any P/Invoke work'
} | Out-Null

Invoke-Scenario -Name 'DPI awareness: Enable-GuiDpiAwareness never runs off-Windows' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Enable-GuiDpiAwareness \{.*?\n\}\r?\n\r?\nfunction Initialize-GuiAssemblies')
    Assert-That $body.Success 'sanity: should be able to locate Enable-GuiDpiAwareness''s body'

    # Same Windows-host check Test-IsAdmin already uses elsewhere in this
    # file -- Desktop edition (always Windows) or pwsh's own $IsWindows.
    Assert-That ($body.Value -match [regex]::Escape("PSVersionTable.PSEdition -eq 'Desktop'")) 'should check PSEdition -eq Desktop (Windows PowerShell 5.1 is always Windows)'
    Assert-That ($body.Value -match [regex]::Escape("Get-Variable -Name 'IsWindows'")) 'should check pwsh''s own $IsWindows (via Get-Variable, so it never throws when the variable does not exist)'
    Assert-That ($body.Value -match '(?s)if\s*\(-not\s*\(\$isDesktopEdition\s*-or\s*\$isWindowsCore\)\)\s*\{\s*return') 'should return early (no P/Invoke attempted at all) on a non-Windows host -- this is what makes the function a safe no-op under this Linux test harness'
} | Out-Null

Invoke-Scenario -Name 'DPI awareness: the fallback chain declares all three documented Windows APIs, in order, each guarded by its own try/catch' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Enable-GuiDpiAwareness \{.*?\n\}\r?\n\r?\nfunction Initialize-GuiAssemblies')
    Assert-That $body.Success 'sanity: should be able to locate Enable-GuiDpiAwareness''s body'

    Assert-That ($body.Value -match 'SetProcessDpiAwarenessContext') 'should P/Invoke SetProcessDpiAwarenessContext (user32, Windows 10 1703+, per-monitor v2)'
    Assert-That ($body.Value -match 'SetProcessDpiAwareness\b') 'should P/Invoke SetProcessDpiAwareness (shcore, Windows 8.1+, per-monitor v1)'
    Assert-That ($body.Value -match 'SetProcessDPIAware\b') 'should P/Invoke the legacy SetProcessDPIAware (user32, any Windows)'

    # Ordering: v2 context first, then the older shcore call, then the
    # legacy call last -- best-to-worst, matching the CHANGES spec. Looked
    # up as actual CALL sites ("::Name(...)"), not just any mention of the
    # name -- the P/Invoke declarations above also name all three (in
    # declaration order), which would otherwise make this assertion
    # trivially true regardless of the real fallback-attempt order below.
    $v2Index = $body.Value.IndexOf('::SetProcessDpiAwarenessContext(')
    $v1Index = $body.Value.IndexOf('::SetProcessDpiAwareness(2)')
    $legacyIndex = $body.Value.IndexOf('::SetProcessDPIAware()')
    Assert-That ($v2Index -ge 0 -and $v1Index -gt $v2Index -and $legacyIndex -gt $v1Index) "expected a SetProcessDpiAwarenessContext call, then a SetProcessDpiAwareness(2) call, then a SetProcessDPIAware() call in that order, got indices $v2Index / $v1Index / $legacyIndex"

    # Every native call site sits inside its own try/catch -- a crude but
    # effective proxy: at least three 'try {' / 'catch {' pairs inside this
    # function's body (Add-Type's own try/catch, plus one per fallback
    # step).
    $tryCount = @([regex]::Matches($body.Value, '(?m)^\s*try\s*\{')).Count
    Assert-That ($tryCount -ge 4) "expected at least 4 try/catch blocks (Add-Type + 3 fallback APIs), found $tryCount"

    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is -4; PROCESS_PER_MONITOR_
    # DPI_AWARE is 2 -- both spelled out in the CHANGES spec, so pin the
    # literal values too, not just the API names.
    Assert-That ($body.Value -match [regex]::Escape('[IntPtr]::new(-4)')) 'SetProcessDpiAwarenessContext should be called with DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (IntPtr -4)'
    Assert-That ($body.Value -match 'SetProcessDpiAwareness\(2\)') 'SetProcessDpiAwareness should be called with PROCESS_PER_MONITOR_DPI_AWARE (2)'
} | Out-Null

Invoke-Scenario -Name 'DPI awareness: Initialize-GuiAssemblies calls Enable-GuiDpiAwareness first, before System.Windows.Forms is even loaded' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Initialize-GuiAssemblies \{.*?\n\}\r?\n')
    Assert-That $body.Success 'sanity: should be able to locate Initialize-GuiAssemblies''s body'

    $callMatch = [regex]::Match($body.Value, '\r?\n {4}Enable-GuiDpiAwareness\r?\n')
    Assert-That $callMatch.Success 'Initialize-GuiAssemblies should call Enable-GuiDpiAwareness as its own statement'
    $callIndex = $callMatch.Index

    $addTypeFormsIndex = $body.Value.IndexOf('Add-Type -AssemblyName System.Windows.Forms')
    Assert-That ($addTypeFormsIndex -ge 0) 'sanity: should be able to locate the System.Windows.Forms Add-Type call'
    Assert-That ($callIndex -lt $addTypeFormsIndex) 'Enable-GuiDpiAwareness must run before System.Windows.Forms is loaded -- and therefore before any window/control/handle can possibly exist'
} | Out-Null

Invoke-Scenario -Name 'DPI awareness: Initialize-GuiAssemblies enables visual styles then disables compatible text rendering, before any control can exist' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Initialize-GuiAssemblies \{.*?\n\}\r?\n')
    Assert-That $body.Success 'sanity: should be able to locate Initialize-GuiAssemblies''s body'

    $visualIndex = $body.Value.IndexOf('[System.Windows.Forms.Application]::EnableVisualStyles()')
    $renderingIndex = $body.Value.IndexOf('[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)')
    Assert-That ($visualIndex -ge 0) 'Initialize-GuiAssemblies should call EnableVisualStyles()'
    Assert-That ($renderingIndex -ge 0) 'Initialize-GuiAssemblies should call SetCompatibleTextRenderingDefault($false)'
    Assert-That ($visualIndex -lt $renderingIndex) 'SetCompatibleTextRenderingDefault must run after EnableVisualStyles (the documented Microsoft ordering) -- and, since it throws once any control has been created, this whole function must run before any Form/control does'
} | Out-Null

Invoke-Scenario -Name 'DPI awareness: Enable-GuiDpiAwareness (and the GUI bootstrap that calls it) is never reachable from the headless Invoke-ManagerAction dispatch' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function Invoke-ManagerAction \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $body.Success 'sanity: should be able to locate Invoke-ManagerAction''s body'

    Assert-That (-not ($body.Value -match 'Enable-GuiDpiAwareness')) 'Invoke-ManagerAction (the headless -Action dispatch) must never call Enable-GuiDpiAwareness -- DPI awareness is a GUI-bootstrap-only concern'
    Assert-That (-not ($body.Value -match 'Initialize-GuiAssemblies')) 'Invoke-ManagerAction (the headless -Action dispatch) must never call Initialize-GuiAssemblies (which is what actually calls Enable-GuiDpiAwareness) either'
} | Out-Null

Invoke-Scenario -Name 'DPI awareness: New-GuiForm sets an explicit Segoe UI 9pt Font and AutoScaleMode=Font with a matching AutoScaleDimensions basis' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function New-GuiForm \{.*?\n\}\r?\n\r?\nfunction New-GuiLabel')
    Assert-That $body.Success 'sanity: should be able to locate New-GuiForm''s body'

    Assert-That ($body.Value -match [regex]::Escape("New-Object System.Drawing.Font('Segoe UI', 9)")) 'New-GuiForm should set an explicit Segoe UI, 9pt Font'
    Assert-That ($body.Value -match [regex]::Escape('$form.Font =')) 'New-GuiForm should assign that Font onto the form (not just construct it)'
    Assert-That ($body.Value -match '\$form\.AutoScaleMode\s*=\s*\[System\.Windows\.Forms\.AutoScaleMode\]::Font') 'New-GuiForm should set AutoScaleMode = Font so the pixel-designed layouts scale with the font at 150%/200%'
    Assert-That ($body.Value -match [regex]::Escape('$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(7, 15)')) 'New-GuiForm should set AutoScaleDimensions to the design-time basis matching Segoe UI 9pt, so scaling is relative to the actual designed font rather than some other default'
} | Out-Null

Invoke-Scenario -Name 'DPI awareness: every Form the app creates goes through New-GuiForm, not a bare New-Object System.Windows.Forms.Form' -Body {
    $source = Read-TextFile $script:ManagerScriptSource

    $bareFormSites = @([regex]::Matches($source, 'New-Object System\.Windows\.Forms\.Form\b'))
    Assert-That (@($bareFormSites).Count -eq 1) "expected exactly one bare 'New-Object System.Windows.Forms.Form' left in the file (inside New-GuiForm itself), found $(@($bareFormSites).Count) -- every other Form-creation site should call New-GuiForm instead so DPI/font scaling is never forgotten on a new one"

    $formFactorySites = @([regex]::Matches($source, '\$form\s*=\s*New-GuiForm\b'))
    Assert-That (@($formFactorySites).Count -ge 7) "expected at least 7 '`$form = New-GuiForm' call sites (5 wizard steps + the Connect dialog + the Main Window), found $(@($formFactorySites).Count)"
} | Out-Null

# ===========================================================================
# Adaptive/DPI-proof layout -- field feedback: fixed pixel Width boxes on
# buttons/labels/checkboxes cropped their text once DPI-scaled 9pt Segoe UI
# (see New-GuiForm) no longer fit the box ('Connect/Reconnect...' rendered
# as 'Connect/Reconne', a 'Logon/Unlock' checkbox as 'Logon/Unl', etc.), and
# only the Main Window's paths ListBox ever grew on resize/maximize (and
# only sideways), leaving every other control frozen top-left with the rest
# of the window's new space unused. Every scenario below is source-level
# (regex over the raw script text), same as the DPI-awareness scenarios
# above -- actual crisp/uncropped/reflowing rendering can only be confirmed
# by eye on a real high-DPI Windows display, which this headless Linux
# harness cannot do.
# ===========================================================================

Invoke-Scenario -Name 'Adaptive layout: New-GuiButton is AutoSize (GrowAndShrink) and never assigns a fixed .Size/.Width, so button text can never crop' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function New-GuiButton \{.*?\n\}\r?\n\r?\nfunction New-GuiFlowRow')
    Assert-That $body.Success 'sanity: should be able to locate New-GuiButton''s body'

    Assert-That ($body.Value -match [regex]::Escape('$btn.AutoSize = $true')) 'New-GuiButton should set AutoSize = $true'
    Assert-That ($body.Value -match [regex]::Escape('[System.Windows.Forms.AutoSizeMode]::GrowAndShrink')) 'New-GuiButton should set AutoSizeMode to GrowAndShrink'
    Assert-That (-not ($body.Value -match '\$btn\.Size\s*=')) 'New-GuiButton must never assign a fixed .Size -- that is exactly the field-reported crop bug (a pixel box too small for DPI-scaled text)'
    Assert-That (-not ($body.Value -match '\$btn\.Width\s*=')) 'New-GuiButton must never assign a fixed .Width'
    Assert-That (-not ($body.Value -match '(?m)^\s*param\(.*\$Width')) 'New-GuiButton should not even accept a -Width parameter any more (every call site was migrated off it)'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: no call site anywhere in the file passes -Width to New-GuiButton' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $widthCallSites = @([regex]::Matches($source, 'New-GuiButton[^\r\n]*-Width'))
    Assert-That (@($widthCallSites).Count -eq 0) "expected zero New-GuiButton call sites passing -Width, found $(@($widthCallSites).Count) -- every button now sizes itself via AutoSize instead"
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: no fixed .Width/.Size assignment remains on any button variable in the Gui region (NumericUpDown/status TextBoxes are exempt)' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    # Every button in the file is stored in a $btn*-prefixed variable
    # (btnCancel, btnConnectVibepollo, btnApplyWatchdog, ...) -- this scans
    # the WHOLE file (not just one function) for any of them being given a
    # fixed .Width or .Size afterward, which would silently reintroduce a
    # DPI crop risk even if New-GuiButton itself stays AutoSize.
    $fixedSites = @([regex]::Matches($source, '\$btn\w*\.(Width|Size)\s*='))
    Assert-That (@($fixedSites).Count -eq 0) "expected zero fixed .Width/.Size assignments on any `$btn* variable, found $(@($fixedSites).Count)"
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: New-GuiLabel and New-GuiCheckBox are AutoSize (a wrap-width ceiling, not a hard clipping box)' -Body {
    $source = Read-TextFile $script:ManagerScriptSource

    $labelBody = [regex]::Match($source, '(?s)function New-GuiLabel \{.*?\n\}\r?\n\r?\nfunction New-GuiButton')
    Assert-That $labelBody.Success 'sanity: should be able to locate New-GuiLabel''s body'
    Assert-That ($labelBody.Value -match [regex]::Escape('$lbl.AutoSize = $true')) 'New-GuiLabel should set AutoSize = $true'
    Assert-That ($labelBody.Value -match [regex]::Escape('$lbl.MaximumSize = New-Object System.Drawing.Size($Width, 0)')) 'New-GuiLabel should use -Width as a MaximumSize wrap ceiling, not a hard Size'
    Assert-That (-not ($labelBody.Value -match '\$lbl\.Size\s*=')) 'New-GuiLabel must never assign a fixed .Size any more'

    $checkboxBody = [regex]::Match($source, '(?s)function New-GuiCheckBox \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $checkboxBody.Success 'sanity: should be able to locate New-GuiCheckBox''s body'
    Assert-That ($checkboxBody.Value -match [regex]::Escape('$cb.AutoSize = $true')) 'New-GuiCheckBox should set AutoSize = $true'
    Assert-That (-not ($checkboxBody.Value -match '\$cb\.Size\s*=')) 'New-GuiCheckBox must never assign a fixed .Size any more'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: New-GuiFlowRow builds a non-wrapping, AutoSize FlowLayoutPanel shared by every button row in the app' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $body = [regex]::Match($source, '(?s)function New-GuiFlowRow \{.*?\n\}\r?\n\r?\nfunction New-GuiTextBox')
    Assert-That $body.Success 'sanity: should be able to locate New-GuiFlowRow''s body'

    Assert-That ($body.Value -match [regex]::Escape('New-Object System.Windows.Forms.FlowLayoutPanel')) 'New-GuiFlowRow should build a FlowLayoutPanel'
    Assert-That ($body.Value -match [regex]::Escape('$flow.WrapContents = $false')) 'a button row must never silently wrap a button onto an invisible second line'
    Assert-That ($body.Value -match [regex]::Escape('$flow.AutoSize = $true')) 'New-GuiFlowRow should be AutoSize'
    Assert-That ($body.Value -match [regex]::Escape('[System.Windows.Forms.AutoSizeMode]::GrowAndShrink')) 'New-GuiFlowRow should use AutoSizeMode GrowAndShrink'

    # Used by every wizard step, the Connect dialog, AND the Main Window --
    # not just a helper only the Main Window happens to call.
    $callSites = @([regex]::Matches($source, 'New-GuiFlowRow\s+-Controls'))
    Assert-That (@($callSites).Count -ge 10) "expected at least 10 New-GuiFlowRow call sites (every wizard step's nav row(s) + the Connect dialog's two rows + the Main Window's four button rows), found $(@($callSites).Count)"
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: Show-MainWindow builds a root, one-column TableLayoutPanel docked to fill the window' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $windowBody = [regex]::Match($source, '(?s)function Show-MainWindow \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $windowBody.Success 'sanity: should be able to locate Show-MainWindow''s body'

    Assert-That ($windowBody.Value -match [regex]::Escape('$root = New-Object System.Windows.Forms.TableLayoutPanel')) 'Show-MainWindow should build a root TableLayoutPanel'
    Assert-That ($windowBody.Value -match [regex]::Escape('$root.Dock = [System.Windows.Forms.DockStyle]::Fill')) 'the root TableLayoutPanel should be Dock = Fill'
    Assert-That ($windowBody.Value -match '\$root\.ColumnCount\s*=\s*1') 'the root TableLayoutPanel should be a single column'
    Assert-That ($windowBody.Value -match [regex]::Escape('$form.Controls.Add($root)')) 'the root TableLayoutPanel should actually be added to the form'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: the paths ListBox''s row is the one Percent(100) row (grows both directions); every other row is AutoSize' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $windowBody = [regex]::Match($source, '(?s)function Show-MainWindow \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $windowBody.Success 'sanity: should be able to locate Show-MainWindow''s body'

    Assert-That ($windowBody.Value -match '(?s)if\s*\(\$rowIndex\s*-eq\s*\$rowPathsList\)\s*\{\s*\$root\.RowStyles\.Add\(\(New-Object System\.Windows\.Forms\.RowStyle\(\[System\.Windows\.Forms\.SizeType\]::Percent,\s*100\)\)\)') 'the paths ListBox row should get a Percent(100) RowStyle'
    Assert-That ($windowBody.Value -match [regex]::Escape('$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))')) 'every other row should get an AutoSize RowStyle'
    Assert-That ($windowBody.Value -match [regex]::Escape('$lstPaths.Dock = [System.Windows.Forms.DockStyle]::Fill')) 'the paths ListBox itself should Dock = Fill so it actually claims the Percent row''s space in both directions'
    Assert-That (-not ($windowBody.Value -match [regex]::Escape('$lstPaths.Anchor = ''Top,Left,Right'''))) 'the old Anchor-only (width-but-not-height) growth should be gone, replaced by Dock = Fill inside a Percent row'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: every button row in the Main Window (paths/connect/watchdog/bottom) is a New-GuiFlowRow, not loose Controls.Add calls' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $windowBody = [regex]::Match($source, '(?s)function Show-MainWindow \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $windowBody.Success 'sanity: should be able to locate Show-MainWindow''s body'

    Assert-That ($windowBody.Value -match [regex]::Escape('$pathsButtonsRow = New-GuiFlowRow -Controls @($btnAddFile, $btnAddFolder, $btnRemove)')) 'the Add File/Add Folder/Remove Selected row should be one New-GuiFlowRow'
    Assert-That ($windowBody.Value -match [regex]::Escape('$connectButtonRow = New-GuiFlowRow -Controls @($btnConnectVibepollo)')) 'the Connect/Reconnect... row should be a New-GuiFlowRow'
    Assert-That ($windowBody.Value -match [regex]::Escape('$watchdogControlsRow = New-GuiFlowRow -Controls @($cbLogon2, $cbPoll2, $nudPoll2, $lblMin2, $btnApplyWatchdog, $btnUnregisterWatchdog)')) 'the watchdog checkboxes/NumericUpDown/label/buttons should be one New-GuiFlowRow'
    Assert-That ($windowBody.Value -match [regex]::Escape('$bottomButtonsRow = New-GuiFlowRow -Controls @($btnOpenData, $btnViewLog, $btnDisconnect)')) 'the bottom Open data folder/View sync.log/Disconnect row should be one New-GuiFlowRow'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: Show-MainWindow computes $form.MinimumSize from the root panel''s own PreferredSize, not a hardcoded pixel constant' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $windowBody = [regex]::Match($source, '(?s)function Show-MainWindow \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $windowBody.Success 'sanity: should be able to locate Show-MainWindow''s body'

    Assert-That ($windowBody.Value -match [regex]::Escape('$contentPreferredSize = $root.GetPreferredSize([System.Drawing.Size]::Empty)')) 'MinimumSize should be derived from the root panel''s GetPreferredSize'
    Assert-That ($windowBody.Value -match [regex]::Escape('$form.MinimumSize = New-Object System.Drawing.Size(($contentPreferredSize.Width + $chromeWidth), ($contentPreferredSize.Height + $chromeHeight))')) 'MinimumSize should combine the content''s preferred size with the form''s own chrome (title bar/borders)'
    Assert-That (-not ($windowBody.Value -match [regex]::Escape('$form.MinimumSize = New-Object System.Drawing.Size(560, 580)'))) 'the old hardcoded MinimumSize constant (a guess that only happened to fit at 96 DPI) should be gone'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout (DOUBLE-SCALING FIX): Show-MainWindow''s MinimumSize/Size measurement runs inside Add_Load, AFTER WinForms'' own PerformAutoScale pass, not inline before ShowDialog' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $windowBody = [regex]::Match($source, '(?s)function Show-MainWindow \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $windowBody.Success 'sanity: should be able to locate Show-MainWindow''s body'

    # PerformAutoScale runs during CreateControl, itself part of
    # ShowDialog()'s own handle-creation sequence -- i.e. strictly AFTER
    # this function body finishes executing and strictly BEFORE Load fires.
    # $root.GetPreferredSize() already reflects true DPI-scaled AutoSize
    # control sizes (GetPreferredSize measures actual current font metrics,
    # which the OS already renders bigger at 150%/200%); assigning that
    # straight to $form.MinimumSize/$form.Size BEFORE ShowDialog would let
    # the still-pending PerformAutoScale multiply those already-scaled
    # numbers a second time (Form.ScaleControl scales MinimumSize/
    # MaximumSize unconditionally). Add_Load is the standard WinForms
    # pattern for this precise reason: it fires after auto-scale but before
    # the form is painted, so there is no visible resize flicker either.
    Assert-That ($windowBody.Value -match [regex]::Escape('$form.Add_Load({')) 'the MinimumSize/Size measurement should be wrapped in an Add_Load handler'

    $loadHandlerMatch = [regex]::Match($windowBody.Value, '(?s)\$form\.Add_Load\(\{(.*?)\}\)\r?\n')
    Assert-That $loadHandlerMatch.Success 'sanity: should be able to isolate the Add_Load handler body'
    $loadHandlerBody = $loadHandlerMatch.Groups[1].Value
    Assert-That ($loadHandlerBody -match [regex]::Escape('$contentPreferredSize = $root.GetPreferredSize([System.Drawing.Size]::Empty)')) 'GetPreferredSize should be measured INSIDE Add_Load, not before ShowDialog'
    Assert-That ($loadHandlerBody -match [regex]::Escape('$form.MinimumSize =')) 'MinimumSize should be assigned INSIDE Add_Load'
    Assert-That ($loadHandlerBody -match [regex]::Escape('$form.Size =')) 'the default startup Size should be assigned INSIDE Add_Load too (same double-scaling risk applies to it)'

    # The Add_Load handler must be the ONLY place these get assigned --
    # nothing outside it should set $form.MinimumSize/$form.Size using the
    # panel's PreferredSize before the handle/auto-scale exist.
    $beforeLoadHandler = $windowBody.Value.Substring(0, $loadHandlerMatch.Index)
    Assert-That (-not ($beforeLoadHandler -match [regex]::Escape('$contentPreferredSize ='))) 'GetPreferredSize must not be measured anywhere before the Add_Load handler'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: the default startup Size has real headroom above the computed MinimumSize floor, not just Max(640/660, floor)' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $windowBody = [regex]::Match($source, '(?s)function Show-MainWindow \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $windowBody.Success 'sanity: should be able to locate Show-MainWindow''s body'

    # [Math]::Max(660, floor) alone degenerates to exactly the floor (zero
    # headroom for the paths ListBox's Percent row) whenever the floor
    # exceeds 660, which is the normal case at 125%+ DPI -- the height side
    # must add real headroom on top of that Max, not just take it verbatim.
    Assert-That ($windowBody.Value -match '\[Math\]::Max\(660,\s*\$form\.MinimumSize\.Height\)\s*\+\s*\d+') 'the default Size''s height should be Max(660, floor) PLUS a real headroom constant, not Max(660, floor) alone'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: wizard steps and the Connect dialog set AutoScroll, as a defensive backstop against an AutoSize label overlapping a fixed-position neighbor' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $functionNames = @('Show-WizardWelcomeStep', 'Show-WizardInstallStep', 'Show-WizardVibepolloStep', 'Show-WizardWatchdogStep', 'Show-WizardDoneStep', 'Show-VibepolloConnectDialog')
    foreach ($name in $functionNames) {
        $nextFunctionMatch = [regex]::Match($source, "(?s)function $name \{.*?\r?\n\}\r?\n\r?\nfunction ")
        Assert-That $nextFunctionMatch.Success "sanity: should be able to locate $name's body"
        Assert-That ($nextFunctionMatch.Value -match [regex]::Escape('$form.AutoScroll = $true')) "$name should set `$form.AutoScroll = `$true as a defensive backstop -- these forms position controls relative to the PREVIOUS control's own AutoSize Bottom (not a constant Y) specifically to avoid overlap, but AutoScroll is what catches the residual case of the total content still ending up taller than this FixedDialog"
    }
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: wizard/Connect-dialog labels embedding a real filesystem path are positioned off the PREVIOUS control''s own measured Bottom, not a constant Y' -Body {
    $source = Read-TextFile $script:ManagerScriptSource

    $installBody = [regex]::Match($source, '(?s)function Show-WizardInstallStep \{.*?\n\}\r?\n\r?\nfunction Show-WizardVibepolloStep')
    Assert-That $installBody.Success 'sanity: should be able to locate Show-WizardInstallStep''s body'
    Assert-That ($installBody.Value -match [regex]::Escape('$lblData = New-GuiLabel -Text (''Data folder: '' + $State.DataDir) -X 15 -Y ($lblProgramBottom + 4)')) 'Show-WizardInstallStep''s $lblData (embeds $State.DataDir, an arbitrary-length path) should be positioned off $lblProgram''s own measured Bottom, not a constant Y that a wrapped $lblProgram could grow into'

    $welcomeBody = [regex]::Match($source, '(?s)function Show-WizardWelcomeStep \{.*?\n\}\r?\n\r?\nfunction Show-WizardInstallStep')
    Assert-That $welcomeBody.Success 'sanity: should be able to locate Show-WizardWelcomeStep''s body'
    Assert-That ($welcomeBody.Value -match [regex]::Escape('$lblProgram = New-GuiLabel -Text ''Program folder (fixed):'' -X 15 -Y ($introBottom + 15)')) 'Show-WizardWelcomeStep''s $lblProgram should be positioned off $intro''s own measured Bottom'
    Assert-That ($welcomeBody.Value -match [regex]::Escape('$lblData = New-GuiLabel -Text ''Data folder (paths.txt, profiles, log -- fixed):'' -X 15 -Y ($txtProgramBottom + 10)')) 'Show-WizardWelcomeStep''s $lblData should be positioned off $txtProgram''s own measured Bottom'
} | Out-Null

Invoke-Scenario -Name 'Adaptive layout: New-GuiFlowRow supports an opt-in -VerticalCenter switch, used by the Main Window''s mixed-height watchdog controls row' -Body {
    $source = Read-TextFile $script:ManagerScriptSource
    $flowRowBody = [regex]::Match($source, '(?s)function New-GuiFlowRow \{.*?\n\}\r?\n\r?\nfunction New-GuiTextBox')
    Assert-That $flowRowBody.Success 'sanity: should be able to locate New-GuiFlowRow''s body'
    Assert-That ($flowRowBody.Value -match [regex]::Escape('[switch]$VerticalCenter')) 'New-GuiFlowRow should accept an opt-in -VerticalCenter switch'

    $windowBody = [regex]::Match($source, '(?s)function Show-MainWindow \{.*?\n\}\r?\n\r?\n# -')
    Assert-That $windowBody.Success 'sanity: should be able to locate Show-MainWindow''s body'
    Assert-That ($windowBody.Value -match [regex]::Escape('$watchdogControlsRow = New-GuiFlowRow -Controls @($cbLogon2, $cbPoll2, $nudPoll2, $lblMin2, $btnApplyWatchdog, $btnUnregisterWatchdog) -VerticalCenter')) 'the watchdog row (checkboxes/NumericUpDown/label all shorter than the AutoSize buttons) should opt into -VerticalCenter so the mixed-height controls do not all top-flush against the row''s own top edge'

    # Every all-button row (same-height children) is left at the default
    # (off) -- -VerticalCenter is a no-op there and this documents the
    # opt-in stays scoped to the one row that actually needs it.
    $otherRowMatches = @([regex]::Matches($windowBody.Value, 'New-GuiFlowRow\s+-Controls\s+@\([^)]*\)(?!\s*-VerticalCenter)'))
    Assert-That (@($otherRowMatches).Count -ge 3) "expected the paths/connect/bottom button rows (all same-height buttons) to stay without -VerticalCenter, found $(@($otherRowMatches).Count) such rows"
} | Out-Null

# ===========================================================================
# Report + cleanup
# ===========================================================================

Write-Host ''
Write-Host 'Scenario Results' -ForegroundColor Cyan
Write-Host '================' -ForegroundColor Cyan

$maxNameLen = ($script:ScenarioResults | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
foreach ($r in $script:ScenarioResults) {
    if ($r.Pass) {
        $status = 'PASS'
        $color = 'Green'
    }
    else {
        $status = 'FAIL'
        $color = 'Red'
    }
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
$passedCount = $totalCount - $failedCount

Write-Host ''
$summaryColor = 'Green'
if ($failedCount -gt 0) {
    $summaryColor = 'Red'
}
Write-Host ("TOTAL: {0} passed, {1} failed (of {2})" -f $passedCount, $failedCount, $totalCount) -ForegroundColor $summaryColor

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
