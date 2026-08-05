<#
.SYNOPSIS
    Release build: produces a self-contained dist\manager.ps1 (payload
    slots inlined) plus dist\Install.bat.

.DESCRIPTION
    Reads manager.ps1 from the repo root and replaces its two
    #region EmbeddedPayload here-string marker lines -- the single-line
    ENGINE and TEMPLATE payload markers, each wrapped in the PowerShell
    "PAYLOAD" comment-marker syntax used by manager.ps1's here-string
    slots (see $script:EngineMarker / $script:TemplateMarker below for
    the literal text; not reproduced here verbatim so this help block
    does not itself contain a comment-closing sequence) -- with the full,
    verbatim contents of sync-configs.ps1 and paths.example.txt. The
    marker text below MUST match manager.ps1's own
    $script:EnginePayloadMarker / $script:TemplatePayloadMarker literals
    exactly; that equality is exactly what lets manager.ps1 tell dev mode
    (marker still present) apart from a release build (real content
    present) at runtime -- see Test-PayloadEmpty in manager.ps1.

    Fails loudly (non-zero exit, clear message) if:
      - manager.ps1 / sync-configs.ps1 / paths.example.txt are missing
      - either marker line is missing, or appears more than once
        (ambiguous -- refuses to guess which occurrence to replace)
      - either source file contains a line that is exactly the here-string
        terminator ('@) at column 0, which would truncate the embedded
        payload silently if injected
      - the resulting dist\manager.ps1 does not parse as valid PowerShell
        (checked with the language parser, not by executing it)

    Dual-compatible with Windows PowerShell 5.1 and pwsh 7: no ternary, no
    ??, no && / ||, two-argument Join-Path only, explicit -Encoding on
    every text read, StrictMode-safe.

.PARAMETER RepoRoot
    Repo root containing manager.ps1 / sync-configs.ps1 /
    paths.example.txt. Defaults to this script's parent directory (this
    script lives in <repo>\build\make-dist.ps1).

.PARAMETER OutDir
    Where dist\manager.ps1 and dist\Install.bat are written. Defaults to
    <RepoRoot>\dist.
#>

param(
    [string]$RepoRoot,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# BOM-less UTF-8, matching manager.ps1 / sync-configs.ps1's own writers, so
# the dist file has the same byte shape as everything else in the repo.
$script:Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# Marker literals -- MUST match manager.ps1's $script:EnginePayloadMarker /
# $script:TemplatePayloadMarker exactly. Not read out of manager.ps1 itself
# (that would let a silently-edited marker in one place still "match" the
# other); kept here as an explicit, independently-typed contract so a drift
# between the two shows up as this build failing loudly instead of quietly
# shipping a dist file manager.ps1 will treat as still-empty (dev mode) in
# production.
# ---------------------------------------------------------------------------

$script:EngineMarker = '<#PAYLOAD:ENGINE#>'
$script:TemplateMarker = '<#PAYLOAD:TEMPLATE#>'

function Get-RepoRootResolved {
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return $RepoRoot
    }
    $buildDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($buildDir)) {
        $buildDir = (Get-Location).Path
    }
    return Split-Path -Path $buildDir -Parent
}

function Get-OutDirResolved {
    param([string]$OutDir, [string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
        return $OutDir
    }
    return Join-Path $RepoRoot 'dist'
}

function Read-RequiredTextFile {
    # Get-Content -Raw -Encoding UTF8, but throws a clear, path-specific
    # error instead of a generic "cannot find path" if it is missing.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "make-dist: required source file not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function Split-TextLines {
    # Splits on CRLF/CR/LF uniformly so this works even if a source file
    # ever picks up CRLF line endings (e.g. a Windows-side git checkout).
    # Output is always rejoined with bare "`n" -- matching the LF-only
    # convention already used by manager.ps1 / sync-configs.ps1 in this
    # repo -- so the dist file's line endings are deterministic regardless
    # of what the inputs happened to use.
    param([string]$Text)
    return [regex]::Split($Text, "\r\n|\r|\n")
}

function Assert-NoHereStringTerminatorCollision {
    # A single-quoted here-string ( @' ... '@ ) ends at the first line that
    # STARTS WITH "'@" at column 0 -- PowerShell does not require the rest
    # of that line to be empty; "'@; Write-Output 'PWNED'" both ends the
    # here-string AND executes everything after the terminator as ordinary
    # code. An exact-equality check (`$line -eq "'@"`) misses every such
    # line, so this checks StartsWith instead -- verified experimentally:
    # a payload line beginning with "'@" followed by more text produced a
    # dist file that parsed with zero errors, executed injected code at
    # load, and silently truncated the embedded payload, i.e. exactly what
    # this guard exists to catch, sailing straight through the old check
    # and through release.yml's parse-only verification.
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $lines = Split-TextLines -Text $Text
    foreach ($line in $lines) {
        if ($line.StartsWith("'@")) {
            throw "make-dist: $Label contains a line starting with ''@' -- this would prematurely terminate manager.ps1's embedded here-string (and execute anything after the terminator on that same line). Refusing to build."
        }
    }
}

function Find-SingleMarkerLineIndex {
    # Locates the one-and-only line in $Lines that is exactly $MarkerText,
    # throwing a clear error if it is missing or ambiguous (appears more
    # than once). Never guesses.
    param(
        # Deliberately NOT [Parameter(Mandatory = $true)]: PowerShell's
        # Mandatory-parameter binder validates array parameters
        # element-wise, rejecting the whole array if ANY element is an
        # empty string -- and manager.ps1's own source has plenty of blank
        # lines. A plain (non-Mandatory) array parameter does not get that
        # per-element check, so blank lines pass through fine.
        [string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$MarkerText,
        [Parameter(Mandatory = $true)][string]$MarkerName
    )
    # Named $markerIndexes, not $matches: PowerShell variable names are
    # case-insensitive, so $matches here would be the very same variable
    # as the automatic $Matches populated by -match -- currently harmless
    # (nothing in this function's scope uses -match afterwards) but a
    # PSAvoidAssignmentToAutomaticVariable footgun one refactor away from a
    # silent wrong-value bug.
    $markerIndexes = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Lines.Length; $i++) {
        if ($Lines[$i] -eq $MarkerText) {
            $markerIndexes.Add($i)
        }
    }
    if ($markerIndexes.Count -eq 0) {
        throw "make-dist: marker $MarkerName ('$MarkerText') not found in manager.ps1 -- has the #region EmbeddedPayload contract changed? Refusing to guess."
    }
    if ($markerIndexes.Count -gt 1) {
        throw "make-dist: marker $MarkerName ('$MarkerText') appears $($markerIndexes.Count) times in manager.ps1 -- ambiguous, refusing to guess which one to replace."
    }
    return $markerIndexes[0]
}

function New-DistManagerContent {
    # Returns manager.ps1's text with both payload marker lines replaced by
    # the verbatim contents of EnginePayloadText / TemplatePayloadText. See
    # the header comment for why a bare line-for-line-content substitution
    # (rather than a whole-file string Replace() of the marker text)
    # reproduces the injected file's content byte-for-byte once the
    # resulting here-string is parsed, and why it is also the only safe
    # way to do this -- $script:EnginePayloadMarker / TemplateMarker in
    # manager.ps1 are non-here-string lines that merely *contain* the
    # marker text as a substring; a blind global Replace() would corrupt
    # those single-quoted string literals (and, for the engine payload in
    # particular, almost certainly break on an unescaped embedded quote).
    param(
        [Parameter(Mandatory = $true)][string]$ManagerText,
        [Parameter(Mandatory = $true)][string]$EnginePayloadText,
        [Parameter(Mandatory = $true)][string]$TemplatePayloadText
    )

    Assert-NoHereStringTerminatorCollision -Text $EnginePayloadText -Label 'sync-configs.ps1'
    Assert-NoHereStringTerminatorCollision -Text $TemplatePayloadText -Label 'paths.example.txt'

    $lines = Split-TextLines -Text $ManagerText

    $engineIndex = Find-SingleMarkerLineIndex -Lines $lines -MarkerText $script:EngineMarker -MarkerName 'ENGINE'
    $templateIndex = Find-SingleMarkerLineIndex -Lines $lines -MarkerText $script:TemplateMarker -MarkerName 'TEMPLATE'

    # Copy to a generic list of [object] so a single element can hold a
    # whole multi-line payload string without PowerShell trying to flatten
    # it back into the string[] array.
    $result = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($i -eq $engineIndex) {
            $result.Add($EnginePayloadText)
        }
        elseif ($i -eq $templateIndex) {
            $result.Add($TemplatePayloadText)
        }
        else {
            $result.Add($lines[$i])
        }
    }

    return [string]::Join("`n", $result.ToArray())
}

function Test-ScriptParsesCleanly {
    # Parses (does not execute) the given script text with the PowerShell
    # language parser -- available in both Windows PowerShell 5.1 and
    # pwsh 7 -- and returns $true only if there are zero parse errors.
    # Errors, if any, are written to $ParseErrors.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ref]$ParseErrors
    )
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($null -ne $ParseErrors) {
        $ParseErrors.Value = $errors
    }
    return (@($errors).Count -eq 0)
}

function New-DistInstallBatContent {
    # Tiny launcher, CRLF (native to .bat files). Deliberately does NOT
    # request elevation: manager.ps1's GUI never runs elevated wholesale --
    # it only relaunches itself elevated (Start-Process -Verb RunAs) for
    # the specific headless actions that actually need admin rights (conf
    # under Program Files, service restart, and the uninstall paths that
    # touch protected locations -- watchdog registration/unregistration is
    # user-level and never elevates, CONTRACT B). -ExecutionPolicy Bypass
    # here is scoped to this one child
    # process only; it never changes a machine- or user-level policy
    # setting. That bypass exists because a freshly downloaded manager.ps1
    # has no Authenticode signature, so a double-click under the default
    # Windows execution policy (Restricted, or AllSigned in some
    # environments) would otherwise refuse to run it at all.
    $lines = @(
        '@echo off',
        'rem stream-config-profiles installer launcher.',
        'rem',
        'rem manager.ps1 ships unsigned, so a fresh Windows machine''s default',
        'rem execution policy blocks it on double-click. -ExecutionPolicy Bypass',
        'rem below applies ONLY to this one launched process -- it does not',
        'rem change any machine or user policy setting. manager.ps1 itself',
        'rem elevates (via a separate, explicit relaunch) only the specific',
        'rem operations that actually need admin rights; this launcher never',
        'rem requests elevation.',
        'rem',
        'rem The fully-qualified path below (rather than a bare "powershell.exe")',
        'rem matters because this file is meant to be double-clicked straight out',
        'rem of a Downloads folder: cmd.exe resolves an unqualified command name',
        'rem from the CURRENT DIRECTORY before PATH, so a bare name would run',
        'rem whatever powershell.exe happened to be planted alongside it instead',
        'rem of the real shell.',
        '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0manager.ps1"'
    )
    return [string]::Join("`r`n", $lines) + "`r`n"
}

function Invoke-MakeDist {
    param(
        [string]$RepoRoot,
        [string]$OutDir
    )

    $resolvedRepoRoot = Get-RepoRootResolved -RepoRoot $RepoRoot
    $resolvedOutDir = Get-OutDirResolved -OutDir $OutDir -RepoRoot $resolvedRepoRoot

    $managerSource = Join-Path $resolvedRepoRoot 'manager.ps1'
    $engineSource = Join-Path $resolvedRepoRoot 'sync-configs.ps1'
    $templateSource = Join-Path $resolvedRepoRoot 'paths.example.txt'

    Write-Host "make-dist: repo root  = $resolvedRepoRoot"
    Write-Host "make-dist: output dir = $resolvedOutDir"

    $managerText = Read-RequiredTextFile -Path $managerSource
    $engineText = Read-RequiredTextFile -Path $engineSource
    $templateText = Read-RequiredTextFile -Path $templateSource

    $distManagerText = New-DistManagerContent -ManagerText $managerText -EnginePayloadText $engineText -TemplatePayloadText $templateText

    if (-not (Test-Path -LiteralPath $resolvedOutDir)) {
        New-Item -ItemType Directory -Path $resolvedOutDir -Force | Out-Null
    }

    $distManagerPath = Join-Path $resolvedOutDir 'manager.ps1'
    $distInstallBatPath = Join-Path $resolvedOutDir 'Install.bat'

    [System.IO.File]::WriteAllText($distManagerPath, $distManagerText, $script:Utf8NoBomEncoding)
    [System.IO.File]::WriteAllText($distInstallBatPath, (New-DistInstallBatContent), $script:Utf8NoBomEncoding)

    Write-Host "make-dist: wrote $distManagerPath ($((Get-Item -LiteralPath $distManagerPath).Length) bytes)"
    Write-Host "make-dist: wrote $distInstallBatPath ($((Get-Item -LiteralPath $distInstallBatPath).Length) bytes)"

    $parseErrors = $null
    $parsesCleanly = Test-ScriptParsesCleanly -Path $distManagerPath -ParseErrors ([ref]$parseErrors)
    if (-not $parsesCleanly) {
        Write-Host 'make-dist: parse errors in dist\manager.ps1:' -ForegroundColor Red
        foreach ($e in @($parseErrors)) {
            Write-Host "  - $e" -ForegroundColor Red
        }
        throw "make-dist: dist\manager.ps1 failed to parse ($(@($parseErrors).Count) error(s)) -- see above"
    }
    Write-Host 'make-dist: dist\manager.ps1 parses cleanly.'

    return [PSCustomObject]@{
        ManagerPath   = $distManagerPath
        InstallBatPath = $distInstallBatPath
        RepoRoot      = $resolvedRepoRoot
        OutDir        = $resolvedOutDir
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

try {
    Invoke-MakeDist -RepoRoot $RepoRoot -OutDir $OutDir | Out-Null
    Write-Host 'make-dist: build succeeded.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "make-dist: FAILED -- $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
