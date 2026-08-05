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

Invoke-Scenario -Name 'Watchdog: Register-Watchdog never needs elevation -- Logon and Poll are both Interactive/resolved user, never admin' -Body {
    # Contract B: registering/unregistering the watchdog never needs
    # elevation. Every real task definition today is user-level; there is
    # no admin-principal path left to exercise.
    $script:WatchdogCalls.Clear()
    Register-Watchdog -DataDir '/fake/data' -UserId 'ExplicitUser' -IncludePoll -PollMinutes 10 | Out-Null

    $registerCalls = @($script:WatchdogCalls | Where-Object { $_.Op -eq 'Register' })
    $logon = @($registerCalls | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Logon' })[0]
    $poll = @($registerCalls | Where-Object { $_.Name -eq 'StreamConfigProfiles-Settle-Poll' })[0]

    Assert-That (-not $logon.NeedsAdmin) 'Logon task should not need admin'
    Assert-That ($logon.LogonType -eq 'Interactive') "Logon task LogonType should be Interactive, got '$($logon.LogonType)'"
    Assert-That ($logon.UserId -eq 'ExplicitUser') "Logon task UserId should be the resolved caller-supplied UserId, got '$($logon.UserId)'"
    Assert-That (-not $poll.NeedsAdmin) 'Poll task should not need admin'
    Assert-That ($poll.LogonType -eq 'Interactive') "Poll task LogonType should be Interactive, got '$($poll.LogonType)'"
    Assert-That ($poll.UserId -eq 'ExplicitUser') "Poll task UserId should be the resolved caller-supplied UserId, got '$($poll.UserId)'"
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
    $argString = ConvertTo-ElevatedArgumentString -ManagerScriptPath '/m.ps1' -Action 'register-watchdog' -Parameters @{ RemoveData = [switch]$true; IncludePoll = [switch]$false; PollMinutes = 10 }
    Assert-That ($argString -match '-RemoveData(?!\S)') 'a present switch should appear as a bare -Name'
    Assert-That (-not ($argString -match '-IncludePoll')) 'an absent switch should not appear at all'
    Assert-That ($argString -match '-PollMinutes "10"') 'a non-string value should still be quoted'
} | Out-Null

Invoke-Scenario -Name 'GUI: watchdog register/unregister never route through Invoke-GuiElevatable -- no elevation path exists for the watchdog' -Body {
    # Contract B: registering/unregistering the watchdog never needs
    # elevation any more (only conf editing/service restart and uninstall
    # still do). A source-level regression guard, since the GUI region
    # itself is not exercised by this headless harness.
    $source = Read-TextFile $script:ManagerScriptSource
    Assert-That (-not ($source -match "(?s)Invoke-GuiElevatable.{0,300}-Action\s+'register-watchdog'")) "register-watchdog must never be dispatched through Invoke-GuiElevatable (the elevation-retry path)"
    Assert-That (-not ($source -match "(?s)Invoke-GuiElevatable.{0,300}-Action\s+'unregister-watchdog'")) "unregister-watchdog must never be dispatched through Invoke-GuiElevatable either"

    $registerWatchdogGuiCallSites = @([regex]::Matches($source, 'Register-Watchdog -DataDir \$\w+ -UserId'))
    Assert-That ($registerWatchdogGuiCallSites.Count -ge 2) 'sanity: expected at least two GUI call sites for Register-Watchdog (wizard + main window)'
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

Invoke-Scenario -Name 'Dispatch: uninstall action tears down a dispatched install' -Body {
    $sbx = New-Sbx -Label 'dispatch-uninstall'
    $programDir = Join-Path $sbx 'program'
    $dataDir = Join-Path $sbx 'data'
    Invoke-ManagerAction -Action 'install' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource | Out-Null

    $result = Invoke-ManagerAction -Action 'uninstall' -ScriptDir $script:RepoRoot -ProgramDir $programDir -DataDir $dataDir -ManagerScriptPath $script:ManagerScriptSource

    Assert-That (-not (Test-Path -LiteralPath $programDir)) 'dispatched uninstall should remove PROGRAM'
    Assert-That (-not (Test-ManagerResultIndicatesFailure -Result $result)) 'a clean uninstall should not look like a failure'
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
