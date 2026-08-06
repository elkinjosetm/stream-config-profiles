<#
.SYNOPSIS
    Self-contained (no Pester, no external modules/binaries) test harness
    for ..\build\make-dist.ps1.

.DESCRIPTION
    Dot-sources build\make-dist.ps1 with -NoRun (same contract as
    manager.ps1's own -NoRun) and calls its functions directly against
    sandbox directories / fixture text under the system temp directory.
    Covers marker-collision handling, the CRLF/LF/no-terminator/empty-
    payload skip logic, the apostrophe-safe SCP_SELF indirection, and an
    end-to-end Invoke-MakeDist run against tiny fixture files -- none of
    which had any test coverage before this file existed. Prints a
    PASS/FAIL table and exits non-zero if anything failed.

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
$script:MakeDistScriptSource = Join-Path (Join-Path $script:RepoRoot 'build') 'make-dist.ps1'

if (-not (Test-Path -LiteralPath $script:MakeDistScriptSource)) {
    Write-Host "FATAL: cannot find make-dist.ps1 at $script:MakeDistScriptSource" -ForegroundColor Red
    exit 1
}

. $script:MakeDistScriptSource -NoRun

# ---------------------------------------------------------------------------
# Generic helpers (same style as manager-tests.ps1 / run-tests.ps1)
# ---------------------------------------------------------------------------

function Write-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBomEncoding)
}

$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("make-dist-tests-{0}" -f ([Guid]::NewGuid().ToString('N').Substring(0, 10)))
New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

function New-Sbx {
    param([string]$Label)
    $root = Join-Path $script:TempRoot ("sbx-{0}-{1}" -f $Label, ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

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
# Marker line location
# ===========================================================================

Invoke-Scenario -Name 'Find-SingleMarkerLineIndex: throws when the marker is missing' -Body {
    $threw = $false
    try {
        Find-SingleMarkerLineIndex -Lines @('a', 'b', 'c') -MarkerText '<#MARKER#>' -MarkerName 'TEST'
    }
    catch {
        $threw = $true
        Assert-That ($_.Exception.Message -match 'not found') 'error should say the marker was not found'
    }
    Assert-That $threw 'a missing marker should throw'
} | Out-Null

Invoke-Scenario -Name 'Find-SingleMarkerLineIndex: throws when the marker appears more than once (ambiguous)' -Body {
    $threw = $false
    try {
        Find-SingleMarkerLineIndex -Lines @('a', '<#MARKER#>', 'b', '<#MARKER#>') -MarkerText '<#MARKER#>' -MarkerName 'TEST'
    }
    catch {
        $threw = $true
        Assert-That ($_.Exception.Message -match 'ambiguous') 'error should say the marker is ambiguous'
    }
    Assert-That $threw 'a duplicated marker should throw rather than guess'
} | Out-Null

Invoke-Scenario -Name 'Find-SingleMarkerLineIndex: returns the correct index, tolerating blank lines' -Body {
    $idx = Find-SingleMarkerLineIndex -Lines @('a', '', '<#MARKER#>', '', 'b') -MarkerText '<#MARKER#>' -MarkerName 'TEST'
    Assert-That ($idx -eq 2) "expected index 2, got $idx"
} | Out-Null

# ===========================================================================
# Here-string terminator collision guard
# ===========================================================================

Invoke-Scenario -Name 'Assert-NoHereStringTerminatorCollision: throws on a line starting with ''@ (even with trailing text)' -Body {
    $threw = $false
    try {
        Assert-NoHereStringTerminatorCollision -Text "line one`n'@; Write-Output 'PWNED'`nline three" -Label 'fixture'
    }
    catch {
        $threw = $true
        Assert-That ($_.Exception.Message -match 'fixture') 'error should name the offending source label'
    }
    Assert-That $threw 'a line starting with ''@ must be refused, not just an exact ''@ match'
} | Out-Null

Invoke-Scenario -Name 'Assert-NoHereStringTerminatorCollision: ordinary content (including a bare @ mid-line) passes' -Body {
    $threw = $false
    try {
        Assert-NoHereStringTerminatorCollision -Text "line one`nsomeone@example.com`nline three" -Label 'fixture'
    }
    catch {
        $threw = $true
    }
    Assert-That (-not $threw) 'a line that merely contains @ (not starting with ''@) must not be flagged'
} | Out-Null

# ===========================================================================
# New-DistManagerContent: marker substitution
# ===========================================================================

Invoke-Scenario -Name 'New-DistManagerContent: substitutes both markers with verbatim multi-line payloads' -Body {
    $managerText = "line1`n<#PAYLOAD:ENGINE#>`nline3`n<#PAYLOAD:TEMPLATE#>`nline5"
    $engineText = "engine line a`nengine line b"
    $templateText = "template line a"

    $result = New-DistManagerContent -ManagerText $managerText -EnginePayloadText $engineText -TemplatePayloadText $templateText

    Assert-That ($result -match [regex]::Escape($engineText)) 'the engine payload should appear verbatim in the result'
    Assert-That ($result -match [regex]::Escape($templateText)) 'the template payload should appear verbatim in the result'
    Assert-That ($result -notmatch '<#PAYLOAD:ENGINE#>') 'the ENGINE marker itself should no longer be present'
    Assert-That ($result -notmatch '<#PAYLOAD:TEMPLATE#>') 'the TEMPLATE marker itself should no longer be present'
    Assert-That ($result -match 'line1') 'unrelated content before the markers should survive'
    Assert-That ($result -match 'line5') 'unrelated content after the markers should survive'
} | Out-Null

# ===========================================================================
# Parse-check helpers
# ===========================================================================

Invoke-Scenario -Name 'Test-ScriptParsesCleanly / Test-CommandTextParsesCleanly: accept valid PowerShell, reject invalid' -Body {
    $sbx = New-Sbx -Label 'parse-check'
    $goodPath = Join-Path $sbx 'good.ps1'
    $badPath = Join-Path $sbx 'bad.ps1'
    Write-TextFile -Path $goodPath -Content "`$x = 1 + 1`nWrite-Output `$x"
    Write-TextFile -Path $badPath -Content "`$x = ((("

    $goodErrors = $null
    Assert-That (Test-ScriptParsesCleanly -Path $goodPath -ParseErrors ([ref]$goodErrors)) 'valid PowerShell should parse cleanly'
    $badErrors = $null
    Assert-That (-not (Test-ScriptParsesCleanly -Path $badPath -ParseErrors ([ref]$badErrors))) 'invalid PowerShell should not parse cleanly'
    Assert-That (@($badErrors).Count -gt 0) 'parse errors should be populated for invalid PowerShell'

    $goodCmdErrors = $null
    Assert-That (Test-CommandTextParsesCleanly -CommandText '$x = 1 + 1' -ParseErrors ([ref]$goodCmdErrors)) 'valid inline command text should parse cleanly'
    $badCmdErrors = $null
    Assert-That (-not (Test-CommandTextParsesCleanly -CommandText '$x = (((' -ParseErrors ([ref]$badCmdErrors))) 'invalid inline command text should not parse cleanly'
} | Out-Null

# ===========================================================================
# Setup-bat extraction snippet: parses cleanly, and is apostrophe-safe
# (BUG: the snippet used to splice cmd's %~f0 expansion directly into a
# single-quoted PowerShell literal -- $p='%~f0' -- which breaks the instant
# that expanded path contains an apostrophe, e.g. C:\Users\O'Brien\...)
# ===========================================================================

Invoke-Scenario -Name 'New-DistSetupBatExtractCommandText: the embedded snippet itself parses as valid PowerShell' -Body {
    $commandText = New-DistSetupBatExtractCommandText
    $errors = $null
    Assert-That (Test-CommandTextParsesCleanly -CommandText $commandText -ParseErrors ([ref]$errors)) "the embedded extraction snippet should parse cleanly, got errors: $(@($errors) -join '; ')"
} | Out-Null

Invoke-Scenario -Name 'New-DistSetupBatExtractCommandText: reads its own path via $env:SCP_SELF, never by splicing %~f0 into a PowerShell string literal' -Body {
    $commandText = New-DistSetupBatExtractCommandText
    Assert-That ($commandText -match [regex]::Escape('$env:SCP_SELF')) 'the snippet should read its own path from $env:SCP_SELF'
    Assert-That ($commandText -notmatch [regex]::Escape("'%~f0'")) 'the snippet must never splice a literal %~f0 into a single-quoted PowerShell string -- an apostrophe in the expanded path would terminate that literal early and let anything after it execute as PowerShell code'
    Assert-That ($commandText -notmatch '%~f0') 'the snippet''s own PowerShell text should not reference %~f0 at all -- that substitution now happens once, in cmd, before powershell.exe is even launched (see New-DistSetupBatHeaderText''s "set" line)'
} | Out-Null

Invoke-Scenario -Name 'New-DistSetupBatExtractCommandText: bounds-checks every byte read after the marker and refuses an empty payload' -Body {
    $commandText = New-DistSetupBatExtractCommandText
    Assert-That ($commandText -match [regex]::Escape('$after -lt $b.Length')) 'the CRLF/LF skip logic should bounds-check $after against the array length before indexing, matching Get-ExtractedSetupPayloadBytes'
    Assert-That ($commandText -match [regex]::Escape('$after -ge $b.Length')) 'the snippet should explicitly detect and refuse an empty payload (marker at the literal end of the file) instead of silently mis-slicing'
} | Out-Null

Invoke-Scenario -Name 'New-DistSetupBatExtractCommandText: defaults a $null $LASTEXITCODE to a nonzero exit, so a launch that never happened cannot report success' -Body {
    $commandText = New-DistSetupBatExtractCommandText
    Assert-That ($commandText -match [regex]::Escape('if($null -eq $ec){$ec=1}')) 'the snippet should default an unset $LASTEXITCODE to a nonzero exit code'
} | Out-Null

Invoke-Scenario -Name 'New-DistSetupBatHeaderText: stashes %~f0 into SCP_SELF via cmd''s own "set" before invoking PowerShell' -Body {
    $headerText = New-DistSetupBatHeaderText
    Assert-That ($headerText -match [regex]::Escape('set "SCP_SELF=%~f0"')) 'the header should set SCP_SELF from %~f0 using the quoted set "VAR=value" form (robust against spaces/special characters in the expanded path)'
    # The SCP_SELF line must appear BEFORE the powershell.exe invocation
    # line, not after -- the environment variable has to exist by the time
    # the child process is launched.
    $setIndex = $headerText.IndexOf('set "SCP_SELF=%~f0"')
    $psIndex = $headerText.IndexOf('powershell.exe')
    Assert-That ($setIndex -ge 0 -and $psIndex -ge 0 -and $setIndex -lt $psIndex) 'the SCP_SELF assignment must precede the powershell.exe invocation'
} | Out-Null

Invoke-Scenario -Name 'New-DistSetupBatHeaderText: ends with "exit /b" strictly before the marker line' -Body {
    $headerText = New-DistSetupBatHeaderText
    $lines = [regex]::Split($headerText, "`r`n")
    $nonEmptyLines = @($lines | Where-Object { $_.Length -gt 0 })
    Assert-That ($nonEmptyLines[-1] -eq $script:SetupPayloadMarker) 'the marker should be the last non-empty line of the header'
    Assert-That ($nonEmptyLines[-2] -match '^exit /b') 'the line immediately before the marker should be the unconditional exit /b, so cmd never reads the payload as batch commands'
} | Out-Null

# ===========================================================================
# Setup-bat marker collision guard
# ===========================================================================

Invoke-Scenario -Name 'Assert-NoSetupMarkerCollision: throws when the manager.ps1 payload already contains the setup-bat marker' -Body {
    $threw = $false
    try {
        Assert-NoSetupMarkerCollision -ManagerText "some text $($script:SetupPayloadMarker) more text"
    }
    catch {
        $threw = $true
        Assert-That ($_.Exception.Message -match 'ambiguous') 'error should explain the collision makes the marker ambiguous'
    }
    Assert-That $threw 'a manager.ps1 payload already containing the marker text must be refused'
} | Out-Null

Invoke-Scenario -Name 'Assert-NoSetupMarkerCollision: ordinary manager.ps1 content passes' -Body {
    $threw = $false
    try {
        Assert-NoSetupMarkerCollision -ManagerText 'perfectly ordinary manager.ps1 content, no markers here'
    }
    catch {
        $threw = $true
    }
    Assert-That (-not $threw) 'ordinary content must not be flagged as a collision'
} | Out-Null

# ===========================================================================
# Get-ExtractedSetupPayloadBytes: CRLF / LF / no-terminator / empty payload
# ===========================================================================

function New-FakeSetupBatBytes {
    # Builds a minimal "header + marker + optional line ending + payload"
    # byte sequence, exactly the shape Get-ExtractedSetupPayloadBytes reads.
    param(
        [string]$LineEnding,
        [byte[]]$PayloadBytes
    )
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("@echo off`r`nrem fixture header`r`n")
    $markerBytes = [System.Text.Encoding]::ASCII.GetBytes($script:SetupPayloadMarker)
    $endingBytes = [System.Text.Encoding]::ASCII.GetBytes($LineEnding)
    $total = New-Object byte[] ($headerBytes.Length + $markerBytes.Length + $endingBytes.Length + $PayloadBytes.Length)
    $offset = 0
    [System.Array]::Copy($headerBytes, 0, $total, $offset, $headerBytes.Length); $offset += $headerBytes.Length
    [System.Array]::Copy($markerBytes, 0, $total, $offset, $markerBytes.Length); $offset += $markerBytes.Length
    [System.Array]::Copy($endingBytes, 0, $total, $offset, $endingBytes.Length); $offset += $endingBytes.Length
    [System.Array]::Copy($PayloadBytes, 0, $total, $offset, $PayloadBytes.Length)
    return $total
}

Invoke-Scenario -Name 'Get-ExtractedSetupPayloadBytes: skips a CRLF terminator after the marker' -Body {
    $sbx = New-Sbx -Label 'extract-crlf'
    $path = Join-Path $sbx 'fixture.bat'
    $payload = [System.Text.Encoding]::UTF8.GetBytes('PAYLOAD-CONTENT')
    $bytes = New-FakeSetupBatBytes -LineEnding "`r`n" -PayloadBytes $payload
    [System.IO.File]::WriteAllBytes($path, $bytes)

    $extracted = Get-ExtractedSetupPayloadBytes -Path $path
    Assert-That (Test-BytesEqual -Left $extracted -Right $payload) 'CRLF after the marker should be skipped entirely, leaving exactly the payload bytes'
} | Out-Null

Invoke-Scenario -Name 'Get-ExtractedSetupPayloadBytes: skips a bare LF terminator after the marker' -Body {
    $sbx = New-Sbx -Label 'extract-lf'
    $path = Join-Path $sbx 'fixture.bat'
    $payload = [System.Text.Encoding]::UTF8.GetBytes('PAYLOAD-CONTENT')
    $bytes = New-FakeSetupBatBytes -LineEnding "`n" -PayloadBytes $payload
    [System.IO.File]::WriteAllBytes($path, $bytes)

    $extracted = Get-ExtractedSetupPayloadBytes -Path $path
    Assert-That (Test-BytesEqual -Left $extracted -Right $payload) 'a bare LF after the marker should be skipped, leaving exactly the payload bytes'
} | Out-Null

Invoke-Scenario -Name 'Get-ExtractedSetupPayloadBytes: no terminator at all -- payload starts immediately after the marker' -Body {
    $sbx = New-Sbx -Label 'extract-none'
    $path = Join-Path $sbx 'fixture.bat'
    $payload = [System.Text.Encoding]::UTF8.GetBytes('PAYLOAD-CONTENT')
    $bytes = New-FakeSetupBatBytes -LineEnding '' -PayloadBytes $payload
    [System.IO.File]::WriteAllBytes($path, $bytes)

    $extracted = Get-ExtractedSetupPayloadBytes -Path $path
    Assert-That (Test-BytesEqual -Left $extracted -Right $payload) 'with no terminator, the payload should start immediately after the marker bytes'
} | Out-Null

Invoke-Scenario -Name 'Get-ExtractedSetupPayloadBytes: an empty payload (marker at the literal end of the file) returns a zero-length array without throwing' -Body {
    $sbx = New-Sbx -Label 'extract-empty'
    $path = Join-Path $sbx 'fixture.bat'
    $bytes = New-FakeSetupBatBytes -LineEnding '' -PayloadBytes (New-Object byte[] 0)
    [System.IO.File]::WriteAllBytes($path, $bytes)

    $extracted = $null
    $threw = $false
    try {
        $extracted = Get-ExtractedSetupPayloadBytes -Path $path
    }
    catch {
        $threw = $true
    }
    Assert-That (-not $threw) 'an empty payload must not throw'
    Assert-That ($null -ne $extracted -and @($extracted).Count -eq 0) 'an empty payload should extract to a zero-length byte array'
} | Out-Null

Invoke-Scenario -Name 'Get-ExtractedSetupPayloadBytes: throws a clear error when the marker is missing entirely (corrupt/truncated file)' -Body {
    $sbx = New-Sbx -Label 'extract-no-marker'
    $path = Join-Path $sbx 'fixture.bat'
    [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::ASCII.GetBytes('@echo off`r`nno marker here'))

    $threw = $false
    try {
        Get-ExtractedSetupPayloadBytes -Path $path | Out-Null
    }
    catch {
        $threw = $true
        Assert-That ($_.Exception.Message -match 'could not find') 'error should say the marker could not be found'
    }
    Assert-That $threw 'a file with no marker at all should throw, not silently return something'
} | Out-Null

# ===========================================================================
# End-to-end: Invoke-MakeDist against tiny fixture files
# ===========================================================================

Invoke-Scenario -Name 'Invoke-MakeDist: end-to-end against fixture files produces a self-consistent dist\manager.ps1 + Setup.bat' -Body {
    $sbx = New-Sbx -Label 'make-dist-e2e'
    $repoRoot = Join-Path $sbx 'repo'
    $outDir = Join-Path $sbx 'dist'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

    $managerFixture = "# fixture manager.ps1`n`$script:EnginePayload = @'`n<#PAYLOAD:ENGINE#>`n'@`n`$script:TemplatePayload = @'`n<#PAYLOAD:TEMPLATE#>`n'@`nWrite-Output 'fixture manager loaded'`n"
    Write-TextFile -Path (Join-Path $repoRoot 'manager.ps1') -Content $managerFixture
    Write-TextFile -Path (Join-Path $repoRoot 'sync-configs.ps1') -Content "# fixture engine`nWrite-Output 'engine'`n"
    Write-TextFile -Path (Join-Path $repoRoot 'paths.example.txt') -Content "# fixture template`n"

    $result = Invoke-MakeDist -RepoRoot $repoRoot -OutDir $outDir

    Assert-That (Test-Path -LiteralPath $result.ManagerPath) 'dist\manager.ps1 should have been written'
    Assert-That (Test-Path -LiteralPath $result.SetupBatPath) 'dist\StreamConfigProfiles-Setup.bat should have been written'

    $managerBytes = [System.IO.File]::ReadAllBytes($result.ManagerPath)
    $extracted = Get-ExtractedSetupPayloadBytes -Path $result.SetupBatPath
    Assert-That (Test-BytesEqual -Left $extracted -Right $managerBytes) 'the Setup.bat payload should extract byte-identical to dist\manager.ps1, exactly what Invoke-SetupBatSelfTest already asserts during the build'

    $distManagerContent = Read-RequiredTextFile -Path $result.ManagerPath
    Assert-That ($distManagerContent -match 'fixture engine') 'the built manager.ps1 should contain the inlined engine payload'
    Assert-That ($distManagerContent -match 'fixture template') 'the built manager.ps1 should contain the inlined template payload'
    Assert-That ($distManagerContent -notmatch '<#PAYLOAD:ENGINE#>') 'the ENGINE marker should be gone from the built output'
} | Out-Null

Invoke-Scenario -Name 'Invoke-MakeDist: refuses to build when a marker is missing from manager.ps1' -Body {
    $sbx = New-Sbx -Label 'make-dist-missing-marker'
    $repoRoot = Join-Path $sbx 'repo'
    $outDir = Join-Path $sbx 'dist'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

    Write-TextFile -Path (Join-Path $repoRoot 'manager.ps1') -Content "# no markers at all here`n"
    Write-TextFile -Path (Join-Path $repoRoot 'sync-configs.ps1') -Content "# fixture engine`n"
    Write-TextFile -Path (Join-Path $repoRoot 'paths.example.txt') -Content "# fixture template`n"

    $threw = $false
    try {
        Invoke-MakeDist -RepoRoot $repoRoot -OutDir $outDir | Out-Null
    }
    catch {
        $threw = $true
        Assert-That ($_.Exception.Message -match 'not found') 'error should say the marker was not found'
    }
    Assert-That $threw 'a manager.ps1 fixture with no ENGINE/TEMPLATE marker should fail the build loudly, not silently produce a broken dist file'
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
