<#
.SYNOPSIS
    Release build: produces a self-contained dist\manager.ps1 (payload
    slots inlined) plus dist\StreamConfigProfiles-Setup.bat, a single
    double-clickable installer that embeds that same manager.ps1 as its
    payload.

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

    dist\manager.ps1 is then wrapped into dist\StreamConfigProfiles-Setup.bat:
    a small ASCII batch header (see New-DistSetupBatHeaderText) followed by
    a unique marker line, followed by the full dist\manager.ps1 content
    verbatim as raw bytes. The header stashes its own fully-qualified path
    ("%~f0") into an SCP_SELF environment variable, then runs a short
    PowerShell -Command snippet that re-reads that same file via
    $env:SCP_SELF (an environment variable, not text spliced into the
    command line -- see New-DistSetupBatExtractCommandText for why that
    distinction matters), locates the marker, extracts everything after it
    to a fresh random folder under %TEMP% as manager.ps1, then runs that
    with -File (never Invoke-Expression) and exits with its exit code. See
    New-DistSetupBatExtractCommandText for the extraction algorithm itself,
    and Get-ExtractedSetupPayloadBytes for the byte-identical
    re-implementation this script uses to self-test it.

    Fails loudly (non-zero exit, clear message) if:
      - manager.ps1 / sync-configs.ps1 / paths.example.txt are missing
      - either marker line is missing, or appears more than once
        (ambiguous -- refuses to guess which occurrence to replace)
      - either source file contains a line that is exactly the here-string
        terminator ('@) at column 0, which would truncate the embedded
        payload silently if injected
      - the resulting dist\manager.ps1 does not parse as valid PowerShell
        (checked with the language parser, not by executing it)
      - the setup-bat payload marker text is found inside the manager.ps1
        content it is about to wrap (would make the marker ambiguous)
      - self-testing the produced dist\StreamConfigProfiles-Setup.bat --
        running the same extraction algorithm the embedded batch header
        uses, in-process, cross-platform -- does not yield a manager.ps1
        byte-identical to dist\manager.ps1, or that extracted copy does
        not parse as valid PowerShell

    Dual-compatible with Windows PowerShell 5.1 and pwsh 7: no ternary, no
    ??, no && / ||, two-argument Join-Path only, explicit -Encoding on
    every text read, StrictMode-safe.

.PARAMETER RepoRoot
    Repo root containing manager.ps1 / sync-configs.ps1 /
    paths.example.txt. Defaults to this script's parent directory (this
    script lives in <repo>\build\make-dist.ps1).

.PARAMETER OutDir
    Where dist\manager.ps1 and dist\StreamConfigProfiles-Setup.bat are
    written. Defaults to <RepoRoot>\dist.

.PARAMETER NoRun
    When set, this file only defines its functions/variables and returns
    without running the build. Used by a test harness that dot-sources
    this file to call its functions directly against sandbox/fixture
    inputs (see tests\make-dist-tests.ps1).
#>

param(
    [string]$RepoRoot,
    [string]$OutDir,

    # When set, this file only defines its functions/variables and returns
    # without running the build (or calling exit) -- exactly the same
    # -NoRun contract manager.ps1 offers, so a test harness can dot-source
    # this script and call its functions directly instead of only being
    # able to run it end-to-end.
    [switch]$NoRun
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

# ---------------------------------------------------------------------------
# StreamConfigProfiles-Setup.bat payload marker -- a plain ASCII line, unique
# enough that it will not occur inside manager.ps1's own text (verified at
# build time by Assert-NoSetupMarkerCollision below, not assumed). The batch
# header always exits before this line is reached (see
# New-DistSetupBatHeaderText), so cmd.exe never parses anything after it;
# the embedded PowerShell -Command snippet re-reads the file's raw bytes and
# finds this exact byte sequence to know where the header ends and the
# manager.ps1 payload begins. ASCII-only and free of quote characters, so it
# can be dropped straight into a single-quoted PowerShell string literal
# with no escaping.
# ---------------------------------------------------------------------------
$script:SetupPayloadMarker = '##STREAMCONFIGPROFILES_SETUP_PAYLOAD_MARKER_v1##'

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

function Test-CommandTextParsesCleanly {
    # Same idea as Test-ScriptParsesCleanly, but for a bare command-text
    # string (New-DistSetupBatExtractCommandText's minified -Command
    # snippet) rather than a file on disk -- ParseInput, not ParseFile.
    # Invoke-SetupBatSelfTest only ever exercises
    # Get-ExtractedSetupPayloadBytes, a deliberately independent
    # re-implementation of the byte-extraction half of that snippet; it
    # proves the .bat's byte layout is extractable, not that the ~900
    # character minified snippet actually embedded in the shipped .bat is
    # itself syntactically valid PowerShell. A one-character typo there
    # would otherwise only surface the first time a real user double-
    # clicks the installer.
    param(
        [Parameter(Mandatory = $true)][string]$CommandText,
        [ref]$ParseErrors
    )
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($CommandText, [ref]$tokens, [ref]$errors) | Out-Null
    if ($null -ne $ParseErrors) {
        $ParseErrors.Value = $errors
    }
    return (@($errors).Count -eq 0)
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

function New-DistSetupBatExtractCommandText {
    # The short PowerShell -Command snippet embedded in the batch header,
    # as ONE logical line (statements separated by ';', no line breaks --
    # required, since it is passed as a single -Command argument on cmd's
    # one physical header line). Built from a single-quoted here-string so
    # none of its many literal '$' variable references or single-quoted
    # string literals need any escaping in this source file, and no
    # accidental interpolation happens against make-dist.ps1's own scope.
    #
    # What it does, in order:
    #   1. Reads its own file's raw bytes via $env:SCP_SELF -- an
    #      environment variable New-DistSetupBatHeaderText's own "set
    #      "SCP_SELF=%~f0"" line populates with the setup .bat's
    #      fully-qualified path BEFORE powershell.exe is even launched.
    #      This is data, not source text: an environment variable's VALUE
    #      is never parsed as PowerShell, so it round-trips ANY legal
    #      filename character -- including a single quote -- verbatim.
    #      Splicing "%~f0"'s cmd-expanded text directly into a
    #      single-quoted PowerShell literal (the earlier approach) breaks
    #      the instant that expanded path contains an apostrophe (a
    #      perfectly legal Windows filename/folder-name character, e.g.
    #      "C:\Users\O'Brien\Downloads\...") and is a script-injection
    #      point for a deliberately renamed download besides -- the `set`
    #      indirection removes both problems at once.
    #   2. Byte-searches (no text encoding involved at all, so there is no
    #      CRLF/LF or codepage ambiguity to get wrong) for the literal
    #      marker bytes and fails loudly (Write-Error + exit 1) if they are
    #      not found -- e.g. a truncated or corrupted download.
    #   3. Skips exactly the marker's own trailing line terminator, if any
    #      -- one byte for a bare LF, two for CRLF, zero for neither --
    #      so this is robust regardless of which convention actually
    #      follows the marker line. Every byte-index read here is bounds-
    #      checked ($after -lt $b.Length) before it happens, and an empty
    #      payload (marker sits at the literal end of the file) fails
    #      loudly instead of silently mis-slicing -- matching
    #      Get-ExtractedSetupPayloadBytes, the self-test's independent
    #      re-implementation of this same algorithm.
    #   4. Writes every remaining byte, unchanged, to a fresh
    #      GUID-named folder under %TEMP% as manager.ps1. This is a raw
    #      byte copy, not a text write through any Encoding -- the payload
    #      bytes ARE dist\manager.ps1's own UTF-8-no-BOM bytes already, so
    #      copying them verbatim is what makes the extracted file
    #      byte-identical to dist\manager.ps1 (see
    #      Get-ExtractedSetupPayloadBytes, which self-tests exactly this).
    #   5. Runs that file with -ExecutionPolicy Bypass -File (never
    #      Invoke-Expression -- extract-to-file-then-run is auditable: the
    #      exact bytes about to execute can be inspected on disk first).
    #      $LASTEXITCODE is captured into a local variable and defaulted to
    #      1 if it is ever $null (e.g. the "&" invocation never actually
    #      ran -- powershell.exe missing/blocked -- which surfaces as a
    #      non-terminating CommandNotFound error that lets execution fall
    #      through to the next statement rather than stopping the script),
    #      so a launch that never happened can never be reported as a
    #      successful exit 0. The %TEMP% extraction folder is removed
    #      afterward (best-effort) so a repeated double-click does not
    #      accumulate one throwaway copy of manager.ps1 per run.
    #
    # Deliberately free of: any '%' at all (the one previously-intentional
    # "%~f0" is gone now that the path travels through $env:SCP_SELF
    # instead -- see point 1 -- so a second '%' can never risk cmd
    # re-expanding something PowerShell should own, e.g. %TEMP%, which
    # this snippet reads via $env:TEMP / $env:SystemRoot itself); any '"'
    # (every string literal here uses single quotes, so wrapping the whole
    # snippet in one pair of double quotes for the -Command argument can
    # never go unbalanced); any '^', '!', or unescaped batch-significant
    # character outside of the one intentional '&' call operator -- which
    # sits inside the -Command argument's quotes, where cmd.exe's
    # quote-parity rule (an even number of '"' seen so far means "outside
    # quotes"; odd means "inside") makes '&', '|', '(' and ')' literal text
    # handed to the child process rather than cmd metacharacters, exactly
    # the same way "powershell -Command \"a | b\"" always has, in practice,
    # passed its pipe straight through to PowerShell rather than piping cmd
    # commands.
    #
    # The marker is spliced in as two concatenated halves (__MARKER_A__ +
    # __MARKER_B__), not the single contiguous string -- deliberately, so
    # this command's OWN text never contains the marker as one unbroken
    # byte sequence. Splicing it in whole would make the marker occur
    # TWICE in the finished file (once right here, describing what to
    # search for, and once more as the actual header-ending delimiter
    # line below it), and a first-match byte search -- exactly what this
    # snippet performs -- would then find this description of the marker
    # instead of the real delimiter, extracting the tail of its own
    # command line plus the batch footer as a bogus "payload" instead of
    # manager.ps1. Splitting it here keeps the real marker line the only
    # place the full sequence appears, so first-match search is correct.
    $template = @'
$p=$env:SCP_SELF;$b=[IO.File]::ReadAllBytes($p);$mk=[Text.Encoding]::ASCII.GetBytes('__MARKER_A__'+'__MARKER_B__');$n=$mk.Length;$idx=-1;for($i=0;$i -le $b.Length-$n;$i++){if($b[$i] -eq $mk[0]){$ok=$true;for($j=1;$j -lt $n;$j++){if($b[$i+$j] -ne $mk[$j]){$ok=$false;break}};if($ok){$idx=$i;break}}};if($idx -lt 0){Write-Error 'stream-config-profiles: payload marker not found -- this setup file is corrupt or truncated.';exit 1};$after=$idx+$n;if($after -lt $b.Length -and $b[$after] -eq 13){$after++};if($after -lt $b.Length -and $b[$after] -eq 10){$after++};if($after -ge $b.Length){Write-Error 'stream-config-profiles: empty payload -- this setup file is corrupt or truncated.';exit 1};$len=$b.Length-$after;$pl=New-Object byte[] $len;[Array]::Copy($b,$after,$pl,0,$len);$dir=Join-Path $env:TEMP ('scp_'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $dir -Force | Out-Null;$mp=Join-Path $dir 'manager.ps1';[IO.File]::WriteAllBytes($mp,$pl);$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';& $psExe -NoProfile -ExecutionPolicy Bypass -File $mp;$ec=$LASTEXITCODE;if($null -eq $ec){$ec=1};Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue;exit $ec
'@
    $splitIndex = [int]([Math]::Floor($script:SetupPayloadMarker.Length / 2))
    $markerPartA = $script:SetupPayloadMarker.Substring(0, $splitIndex)
    $markerPartB = $script:SetupPayloadMarker.Substring($splitIndex)
    return $template.Replace('__MARKER_A__', $markerPartA).Replace('__MARKER_B__', $markerPartB)
}

function New-DistSetupBatHeaderText {
    # The small ASCII batch header, CRLF (native to .bat files), that
    # precedes the manager.ps1 payload in dist\StreamConfigProfiles-Setup.bat.
    # Ends with an unconditional "exit /b" BEFORE the marker line -- cmd.exe
    # executes a batch file strictly top-to-bottom (it does not pre-scan or
    # buffer the whole file), so once that exit statement runs, cmd never
    # reads -- let alone tries to parse as batch commands -- the marker
    # line or anything after it, no matter what the manager.ps1 payload
    # happens to contain (blank lines, lines that look like labels or FOR
    # loops, '%' sequences, embedded quotes, etc.).
    #
    # Deliberately does NOT request elevation, for the same reason the
    # retired Install.bat launcher didn't: manager.ps1's GUI never runs
    # elevated wholesale, only relaunching itself elevated (Start-Process
    # -Verb RunAs) for the specific headless actions that actually need
    # admin rights; see Invoke-GuiElevatable in manager.ps1.
    #
    # -ExecutionPolicy Bypass is scoped to the one extracted-and-launched
    # manager.ps1 process only; it never changes a machine- or user-level
    # policy setting. That bypass exists because a freshly downloaded
    # manager.ps1 has no Authenticode signature, so a double-click under
    # the default Windows execution policy (Restricted, or AllSigned in
    # some environments) would otherwise refuse to run it at all.
    #
    # The fully-qualified path to powershell.exe (rather than a bare
    # "powershell.exe") matters because this file is meant to be
    # double-clicked straight out of a Downloads folder: cmd.exe resolves
    # an unqualified command name from the CURRENT DIRECTORY before PATH,
    # so a bare name would run whatever powershell.exe happened to be
    # planted alongside it instead of the real shell.
    $commandText = New-DistSetupBatExtractCommandText
    $lines = @(
        '@echo off',
        'rem stream-config-profiles single-file installer.',
        'rem',
        'rem This file is a polyglot: everything from "@echo off" down to the',
        'rem "exit /b" line just below is an ordinary batch script; cmd.exe',
        'rem runs it, executes it, and stops there. Everything AFTER the',
        'rem marker line that follows is the full contents of manager.ps1,',
        'rem appended verbatim as raw bytes -- cmd.exe never reads that far,',
        'rem so it is never parsed as batch commands no matter what it',
        'rem contains. The short PowerShell command invoked below re-reads',
        'rem this same file''s raw bytes, finds the marker, and extracts',
        'rem everything after it to %TEMP% as manager.ps1, then runs that',
        'rem extracted copy with -File (never Invoke-Expression, so the',
        'rem exact bytes about to execute can always be inspected on disk',
        'rem first).',
        'rem',
        'rem manager.ps1 ships unsigned, so a fresh Windows machine''s default',
        'rem execution policy blocks it on double-click; -ExecutionPolicy',
        'rem Bypass below applies ONLY to that one extracted-and-launched',
        'rem process -- it never changes a machine- or user-level policy',
        'rem setting.',
        'rem',
        'rem SCP_SELF carries this file''s own fully-qualified path to the',
        'rem PowerShell command below as an ENVIRONMENT VARIABLE, not as text',
        'rem spliced into the command line -- %~f0''s expansion can contain a',
        'rem single quote (a perfectly legal Windows path character, e.g. a',
        'rem profile folder named O''Brien), and an environment variable''s',
        'rem VALUE is never re-parsed as PowerShell source the way a literal',
        'rem splice would be. The quotes in "SCP_SELF=%~f0" are cmd''s own --',
        'rem they protect the assignment from spaces and other special',
        'rem characters in the expanded path -- and have no bearing on the',
        'rem PowerShell command that follows.',
        ('set "SCP_SELF=%~f0"'),
        ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "' + $commandText + '"'),
        'exit /b %ERRORLEVEL%',
        $script:SetupPayloadMarker
    )
    return [string]::Join("`r`n", $lines) + "`r`n"
}

function Assert-NoSetupMarkerCollision {
    # The setup-bat payload marker must occur exactly once in the produced
    # file -- as the header's own marker line -- for the extraction
    # algorithm's first-match byte search to be unambiguously correct. This
    # checks the one variable part (manager.ps1's own text, about to become
    # the payload) does not already happen to contain the marker text
    # somewhere inside it; the header text is authored directly above and
    # provably contains it exactly once.
    param([Parameter(Mandatory = $true)][string]$ManagerText)
    if ($ManagerText.Contains($script:SetupPayloadMarker)) {
        throw "make-dist: dist\manager.ps1 content already contains the setup-bat payload marker ('$($script:SetupPayloadMarker)') -- this would make the marker ambiguous. Refusing to build; change `$script:SetupPayloadMarker in build\make-dist.ps1."
    }
}

function New-DistSetupBatBytes {
    # Assembles the full StreamConfigProfiles-Setup.bat file as a byte
    # array: the ASCII header (CRLF line endings, ending in the marker
    # line) immediately followed by the manager.ps1 payload's own bytes,
    # unchanged. Concatenating raw byte arrays -- rather than building one
    # big string and re-encoding it -- is what guarantees the payload
    # portion of the resulting file is byte-for-byte identical to
    # dist\manager.ps1 regardless of its own line-ending convention (LF,
    # per this repo's -- see Split-TextLines -- vs. the header's CRLF).
    param(
        [Parameter(Mandatory = $true)][string]$ManagerText,
        [Parameter(Mandatory = $true)][byte[]]$ManagerBytes
    )
    Assert-NoSetupMarkerCollision -ManagerText $ManagerText
    $headerBytes = $script:Utf8NoBomEncoding.GetBytes((New-DistSetupBatHeaderText))
    $combined = New-Object byte[] ($headerBytes.Length + $ManagerBytes.Length)
    [System.Array]::Copy($headerBytes, 0, $combined, 0, $headerBytes.Length)
    [System.Array]::Copy($ManagerBytes, 0, $combined, $headerBytes.Length, $ManagerBytes.Length)
    return $combined
}

function Find-ByteSequenceIndex {
    # First index of $Needle inside $Haystack, or -1. A plain byte-array
    # search (no text encoding involved anywhere), so it is exactly the
    # same kind of operation -- not merely the same result -- as the
    # embedded batch header's own marker search, just written for
    # readability here instead of being minified for a single -Command
    # line.
    param(
        [Parameter(Mandatory = $true)][byte[]]$Haystack,
        [Parameter(Mandatory = $true)][byte[]]$Needle
    )
    $n = $Needle.Length
    if ($n -eq 0) {
        return -1
    }
    for ($i = 0; $i -le ($Haystack.Length - $n); $i++) {
        if ($Haystack[$i] -eq $Needle[0]) {
            $isMatch = $true
            for ($j = 1; $j -lt $n; $j++) {
                if ($Haystack[$i + $j] -ne $Needle[$j]) {
                    $isMatch = $false
                    break
                }
            }
            if ($isMatch) {
                return $i
            }
        }
    }
    return -1
}

function Get-ExtractedSetupPayloadBytes {
    # Re-implements -- deliberately as a second, independently-written pass
    # rather than by re-using the embedded snippet's own text -- the exact
    # extraction algorithm New-DistSetupBatExtractCommandText embeds in the
    # batch header: find the marker's bytes, skip its trailing line
    # terminator (CRLF, bare LF, or neither), return everything after that
    # as the payload. Runs cross-platform in-process (no cmd.exe / no
    # Windows dependency) so make-dist.ps1's self-test can verify the
    # produced .bat's structure on any OS running pwsh.
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $markerBytes = [System.Text.Encoding]::ASCII.GetBytes($script:SetupPayloadMarker)
    $idx = Find-ByteSequenceIndex -Haystack $bytes -Needle $markerBytes
    if ($idx -lt 0) {
        throw "make-dist: self-test could not find the setup-bat payload marker in $Path -- New-DistSetupBatHeaderText and Get-ExtractedSetupPayloadBytes have drifted apart."
    }
    $after = $idx + $markerBytes.Length
    if ($after -lt $bytes.Length -and $bytes[$after] -eq 13) {
        $after++
    }
    if ($after -lt $bytes.Length -and $bytes[$after] -eq 10) {
        $after++
    }
    if ($after -ge $bytes.Length) {
        return , (New-Object byte[] 0)
    }
    $length = $bytes.Length - $after
    $payload = New-Object byte[] $length
    [System.Array]::Copy($bytes, $after, $payload, 0, $length)
    return , $payload
}

function Test-BytesEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right
    )
    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) {
            return $false
        }
    }
    return $true
}

function Invoke-SetupBatSelfTest {
    # Fails loudly if the just-produced StreamConfigProfiles-Setup.bat does
    # not actually reproduce dist\manager.ps1 byte-for-byte when extracted
    # by the same algorithm the embedded batch header uses, or if the
    # extracted copy does not parse as valid PowerShell -- a parse-check of
    # dist\manager.ps1 alone (see Test-ScriptParsesCleanly's other call
    # site in Invoke-MakeDist) proves nothing about whether the .bat
    # wrapper around it is actually extractable.
    param(
        [Parameter(Mandatory = $true)][string]$SetupBatPath,
        [Parameter(Mandatory = $true)][byte[]]$ExpectedManagerBytes
    )

    $extracted = Get-ExtractedSetupPayloadBytes -Path $SetupBatPath
    if (-not (Test-BytesEqual -Left $extracted -Right $ExpectedManagerBytes)) {
        throw "make-dist: self-test FAILED -- extracting $SetupBatPath did not reproduce dist\manager.ps1 byte-for-byte (extracted $($extracted.Length) byte(s), expected $($ExpectedManagerBytes.Length)). Refusing to release."
    }

    $tempCopyPath = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '-selftest-manager.ps1')
    try {
        [System.IO.File]::WriteAllBytes($tempCopyPath, $extracted)
        $parseErrors = $null
        $parsesCleanly = Test-ScriptParsesCleanly -Path $tempCopyPath -ParseErrors ([ref]$parseErrors)
        if (-not $parsesCleanly) {
            Write-Host 'make-dist: parse errors in the extracted setup-bat payload:' -ForegroundColor Red
            foreach ($e in @($parseErrors)) {
                Write-Host "  - $e" -ForegroundColor Red
            }
            throw "make-dist: self-test FAILED -- the manager.ps1 extracted from $SetupBatPath does not parse as valid PowerShell ($(@($parseErrors).Count) error(s)). Refusing to release."
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempCopyPath) {
            Remove-Item -LiteralPath $tempCopyPath -Force
        }
    }

    Write-Host 'make-dist: StreamConfigProfiles-Setup.bat self-test passed (extraction is byte-identical to dist\manager.ps1 and re-parses cleanly).' -ForegroundColor Green
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
    $distSetupBatPath = Join-Path $resolvedOutDir 'StreamConfigProfiles-Setup.bat'

    [System.IO.File]::WriteAllText($distManagerPath, $distManagerText, $script:Utf8NoBomEncoding)
    Write-Host "make-dist: wrote $distManagerPath ($((Get-Item -LiteralPath $distManagerPath).Length) bytes)"

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

    # dist\manager.ps1's own bytes (not re-derived from $distManagerText via
    # a fresh Encoding call) are used as both the setup-bat payload and the
    # self-test's expected value, so "byte-identical to dist\manager.ps1"
    # means literally the file on disk, not merely "encoded the same way
    # twice".
    $distManagerBytes = [System.IO.File]::ReadAllBytes($distManagerPath)

    $extractCommandText = New-DistSetupBatExtractCommandText
    $extractParseErrors = $null
    $extractParsesCleanly = Test-CommandTextParsesCleanly -CommandText $extractCommandText -ParseErrors ([ref]$extractParseErrors)
    if (-not $extractParsesCleanly) {
        Write-Host 'make-dist: parse errors in the embedded setup-bat extraction snippet:' -ForegroundColor Red
        foreach ($e in @($extractParseErrors)) {
            Write-Host "  - $e" -ForegroundColor Red
        }
        throw "make-dist: the extraction snippet embedded in StreamConfigProfiles-Setup.bat failed to parse ($(@($extractParseErrors).Count) error(s)) -- see above"
    }
    Write-Host 'make-dist: setup-bat extraction snippet parses cleanly.'

    $setupBatBytes = New-DistSetupBatBytes -ManagerText $distManagerText -ManagerBytes $distManagerBytes
    [System.IO.File]::WriteAllBytes($distSetupBatPath, $setupBatBytes)
    Write-Host "make-dist: wrote $distSetupBatPath ($((Get-Item -LiteralPath $distSetupBatPath).Length) bytes)"

    Invoke-SetupBatSelfTest -SetupBatPath $distSetupBatPath -ExpectedManagerBytes $distManagerBytes

    return [PSCustomObject]@{
        ManagerPath  = $distManagerPath
        SetupBatPath = $distSetupBatPath
        RepoRoot     = $resolvedRepoRoot
        OutDir       = $resolvedOutDir
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if (-not $NoRun) {
    try {
        Invoke-MakeDist -RepoRoot $RepoRoot -OutDir $OutDir | Out-Null
        Write-Host 'make-dist: build succeeded.' -ForegroundColor Green
        exit 0
    }
    catch {
        Write-Host "make-dist: FAILED -- $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
