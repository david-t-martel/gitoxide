# Output correctness verification for gix vs git

Set-Location "C:\codedev\gitoxide"

Write-Host "=== OUTPUT CORRECTNESS VERIFICATION ===" -ForegroundColor Cyan
Write-Host ""

$tests = @(
    @{
        Name = "ls-files"
        Gix = ".\target\release\gix.exe index entries --no-attributes"
        Git = "git ls-files"
        Compare = "exact"
    },
    @{
        Name = "rev-parse HEAD"
        Gix = ".\target\release\gix.exe rev-parse HEAD"
        Git = "git rev-parse HEAD"
        Compare = "exact"
    },
    @{
        Name = "branch list"
        Gix = ".\target\release\gix.exe branch"
        Git = "git branch --format='%(refname:short)'"
        Compare = "sorted"
    },
    @{
        Name = "rev-list HEAD -10"
        Gix = ".\target\release\gix.exe revision list HEAD --limit 10"
        Git = "git rev-list HEAD -n 10"
        Compare = "first-column"  # gix outputs additional info
    }
)

$passed = 0
$failed = 0

foreach ($test in $tests) {
    Write-Host "Testing: $($test.Name)..." -ForegroundColor Yellow -NoNewline

    $gixOutput = Invoke-Expression $test.Gix 2>&1
    $gitOutput = Invoke-Expression $test.Git 2>&1

    $match = $false

    switch ($test.Compare) {
        "exact" {
            $gixSorted = $gixOutput | Sort-Object
            $gitSorted = $gitOutput | Sort-Object
            $diff = Compare-Object $gixSorted $gitSorted
            $match = ($diff.Count -eq 0)
        }
        "sorted" {
            $gixSorted = $gixOutput | Sort-Object
            $gitSorted = $gitOutput | Sort-Object
            $diff = Compare-Object $gixSorted $gitSorted
            $match = ($diff.Count -eq 0)
        }
        "first-column" {
            # Compare only the first column (commit hash)
            $gixHashes = $gixOutput | ForEach-Object { ($_ -split '\s+')[0] }
            $gitHashes = $gitOutput | ForEach-Object { ($_ -split '\s+')[0] }

            # Handle short vs full hashes
            $minLen = 8
            $gixShort = $gixHashes | ForEach-Object { $_.Substring(0, [Math]::Min($_.Length, $minLen)) }
            $gitShort = $gitHashes | ForEach-Object { $_.Substring(0, [Math]::Min($_.Length, $minLen)) }

            $diff = Compare-Object $gixShort $gitShort
            $match = ($diff.Count -eq 0)
        }
    }

    if ($match) {
        Write-Host " PASS" -ForegroundColor Green
        $passed++
    } else {
        Write-Host " FAIL" -ForegroundColor Red
        $failed++

        # Show details
        Write-Host "  gix lines: $($gixOutput.Count)" -ForegroundColor Gray
        Write-Host "  git lines: $($gitOutput.Count)" -ForegroundColor Gray

        if ($gixOutput.Count -gt 0 -and $gitOutput.Count -gt 0) {
            Write-Host "  gix first: $($gixOutput[0])" -ForegroundColor Gray
            Write-Host "  git first: $($gitOutput[0])" -ForegroundColor Gray
        }
    }
}

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "Passed: $passed / $($passed + $failed)" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
if ($failed -gt 0) {
    Write-Host "Failed: $failed" -ForegroundColor Red
}
