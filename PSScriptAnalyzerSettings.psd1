@{
    # Run the full default rule set plus the compatibility-rule opt-in below.
    IncludeDefaultRules = $true

    Rules               = @{
        # sync-configs.ps1 / run-tests.ps1 are zero-dependency scripts that
        # must run unmodified on both Windows PowerShell 5.1 and PowerShell 7.
        # This is the one rule CI treats as fatal regardless of severity
        # (see .github/workflows/ci.yml), so it must always be enabled here.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @(
                '5.1'
                '7.0'
            )
        }
    }

    ExcludeRules        = @(
        # tests/run-tests.ps1 is a console test harness: Write-Host is the
        # correct tool for its colored PASS/FAIL table and summary output,
        # not a mistaken substitute for the output stream.
        'PSAvoidUsingWriteHost'
    )
}
