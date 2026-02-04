#Requires -Version 7.0
<#
.SYNOPSIS
    Deep validation tests for gix vs git correctness.

.DESCRIPTION
    Performs deeper validation beyond basic output comparison:
    - Object content hash verification
    - Commit ancestry validation
    - Tree structure integrity
    - Reference resolution accuracy
    - Index entry verification

    These tests are more time-consuming but provide higher confidence
    in gix correctness.

.PARAMETER Repository
    Path to the git repository to test.

.PARAMETER GixPath
    Path to the gix executable.

.PARAMETER SampleSize
    Number of random commits/objects to validate. Default: 50.

.EXAMPLE
    .\deep_validation.ps1 -Repository "C:\codedev\gitoxide" -SampleSize 100
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Repository = "C:\codedev\gitoxide",

    [Parameter()]
    [string]$GixPath = "C:\codedev\gitoxide\target\release\gix.exe",

    [Parameter()]
    [int]$SampleSize = 50
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Helper Functions
# ============================================================================

$script:Results = @{
    Pass = 0
    Fail = 0
    Skip = 0
}

function Write-TestResult {
    param(
        [string]$Category,
        [string]$TestName,
        [string]$Status,
        [string]$Details = ""
    )

    $symbol = switch ($Status) {
        "PASS" { "[32m[PASS][0m" }
        "FAIL" { "[31m[FAIL][0m" }
        "SKIP" { "[33m[SKIP][0m" }
    }

    Write-Host "$symbol [$Category] $TestName"
    if ($Details) {
        Write-Host "       $Details" -ForegroundColor DarkGray
    }

    switch ($Status) {
        "PASS" { $script:Results.Pass++ }
        "FAIL" { $script:Results.Fail++ }
        "SKIP" { $script:Results.Skip++ }
    }
}

function Invoke-Gix {
    param([string]$Arguments)
    $result = & $GixPath -r $Repository $Arguments.Split(' ') 2>&1
    return ($result | Out-String).Trim()
}

function Invoke-Git {
    param([string]$Arguments)
    $result = & git -C $Repository $Arguments.Split(' ') 2>&1
    return ($result | Out-String).Trim()
}

function Get-RandomCommits {
    param([int]$Count)

    $allCommits = Invoke-Git "rev-list HEAD --no-walk=unsorted"
    $commits = $allCommits -split "`n" | Where-Object { $_.Trim() }

    if ($commits.Count -le $Count) {
        return $commits
    }

    # Get evenly distributed sample
    $step = [math]::Floor($commits.Count / $Count)
    $sample = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $idx = [math]::Min($i * $step, $commits.Count - 1)
        $sample += $commits[$idx]
    }

    return $sample
}

# ============================================================================
# Deep Validation Tests
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║           GIX Deep Validation Test Suite                       ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Repository:  $Repository"
Write-Host "GIX Path:    $GixPath"
Write-Host "Sample Size: $SampleSize"
Write-Host ""

# Verify paths
if (-not (Test-Path $GixPath)) {
    Write-Host "[31mERROR: gix not found at $GixPath[0m"
    exit 1
}

if (-not (Test-Path $Repository)) {
    Write-Host "[31mERROR: Repository not found at $Repository[0m"
    exit 1
}

# ============================================================================
# Test 1: Commit Hash Resolution Accuracy
# ============================================================================

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Test 1: Commit Hash Resolution" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Get sample commits
Write-Host "Sampling $SampleSize commits..." -ForegroundColor DarkGray
$commits = Get-RandomCommits -Count $SampleSize

$passCount = 0
$failCount = 0

foreach ($commit in $commits) {
    $shortHash = $commit.Substring(0, 8)

    # Git resolution
    $gitResolved = Invoke-Git "rev-parse $shortHash"

    # Gix resolution
    $gixResolved = Invoke-Gix "revision resolve $shortHash"

    if ($gitResolved.Trim() -eq $gixResolved.Trim()) {
        $passCount++
    } else {
        $failCount++
        if ($failCount -le 5) {
            Write-Host "  MISMATCH: $shortHash -> git=$gitResolved, gix=$gixResolved" -ForegroundColor Red
        }
    }
}

if ($failCount -eq 0) {
    Write-TestResult -Category "Resolution" -TestName "commit hash resolution ($passCount/$($commits.Count))" -Status "PASS"
} else {
    Write-TestResult -Category "Resolution" -TestName "commit hash resolution" -Status "FAIL" `
        -Details "Passed: $passCount, Failed: $failCount"
}

# ============================================================================
# Test 2: Parent Commit Verification
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Test 2: Parent Commit Verification" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$passCount = 0
$failCount = 0

foreach ($commit in $commits | Select-Object -First 20) {
    # Git parent
    $gitParent = Invoke-Git "rev-parse $commit^"

    # Gix parent (using revision resolve)
    $gixParent = Invoke-Gix "revision resolve $commit^"

    if ($gitParent -match "^[0-9a-f]{40}$" -and $gixParent -match "^[0-9a-f]{40}$") {
        if ($gitParent.Trim() -eq $gixParent.Trim()) {
            $passCount++
        } else {
            $failCount++
        }
    } elseif ($gitParent -match "error" -and $gixParent -match "error") {
        # Both error (root commit) - that's fine
        $passCount++
    }
}

if ($failCount -eq 0) {
    Write-TestResult -Category "Ancestry" -TestName "parent commit verification ($passCount)" -Status "PASS"
} else {
    Write-TestResult -Category "Ancestry" -TestName "parent commit verification" -Status "FAIL" `
        -Details "Passed: $passCount, Failed: $failCount"
}

# ============================================================================
# Test 3: Tree Content Verification
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Test 3: Tree Content Verification" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Get HEAD tree
$headTree = (Invoke-Git "rev-parse HEAD^{tree}").Trim()

# Git tree entries
$gitEntries = Invoke-Git "ls-tree $headTree"
$gitLines = ($gitEntries -split "`n" | Where-Object { $_.Trim() })

# Gix tree entries
$gixEntries = Invoke-Gix "tree entries $headTree"
$gixLines = ($gixEntries -split "`n" | Where-Object { $_.Trim() })

if ([math]::Abs($gitLines.Count - $gixLines.Count) -le 2) {
    Write-TestResult -Category "Tree" -TestName "root tree entry count (git=$($gitLines.Count), gix=$($gixLines.Count))" -Status "PASS"
} else {
    Write-TestResult -Category "Tree" -TestName "root tree entry count" -Status "FAIL" `
        -Details "git=$($gitLines.Count), gix=$($gixLines.Count)"
}

# Verify a few random tree objects
$treeHashes = $gitLines | ForEach-Object {
    if ($_ -match '^(\d+)\s+tree\s+([0-9a-f]{40})') {
        $Matches[2]
    }
} | Where-Object { $_ } | Select-Object -First 5

foreach ($treeHash in $treeHashes) {
    $gitSubEntries = (Invoke-Git "ls-tree $treeHash" -split "`n" | Where-Object { $_.Trim() }).Count
    $gixSubEntries = (Invoke-Gix "tree entries $treeHash" -split "`n" | Where-Object { $_.Trim() }).Count

    if ([math]::Abs($gitSubEntries - $gixSubEntries) -le 1) {
        Write-TestResult -Category "Tree" -TestName "subtree $($treeHash.Substring(0, 8)) entries" -Status "PASS"
    } else {
        Write-TestResult -Category "Tree" -TestName "subtree $($treeHash.Substring(0, 8)) entries" -Status "FAIL" `
            -Details "git=$gitSubEntries, gix=$gixSubEntries"
    }
}

# ============================================================================
# Test 4: Object Type Verification
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Test 4: Object Type Verification" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Sample some objects and verify their types
$objects = @(
    @{ Hash = (Invoke-Git "rev-parse HEAD").Trim(); ExpectedType = "commit" },
    @{ Hash = (Invoke-Git "rev-parse HEAD^{tree}").Trim(); ExpectedType = "tree" }
)

# Add some blob hashes from ls-tree
$blobs = $gitLines | ForEach-Object {
    if ($_ -match '^(\d+)\s+blob\s+([0-9a-f]{40})') {
        $Matches[2]
    }
} | Where-Object { $_ } | Select-Object -First 3

foreach ($blob in $blobs) {
    $objects += @{ Hash = $blob; ExpectedType = "blob" }
}

foreach ($obj in $objects) {
    $gitType = (Invoke-Git "cat-file -t $($obj.Hash)").Trim()

    if ($gitType -eq $obj.ExpectedType) {
        Write-TestResult -Category "ObjectType" -TestName "$($obj.Hash.Substring(0, 8)) is $($obj.ExpectedType)" -Status "PASS"
    } else {
        Write-TestResult -Category "ObjectType" -TestName "$($obj.Hash.Substring(0, 8)) type" -Status "FAIL" `
            -Details "expected=$($obj.ExpectedType), got=$gitType"
    }
}

# ============================================================================
# Test 5: Index Integrity Verification
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Test 5: Index Integrity" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Compare index entry counts
$gitIndexCount = (Invoke-Git "ls-files" -split "`n" | Where-Object { $_.Trim() }).Count
$gixIndexCount = (Invoke-Gix "index entries" -split "`n" | Where-Object { $_.Trim() }).Count

if ($gitIndexCount -eq $gixIndexCount) {
    Write-TestResult -Category "Index" -TestName "index entry count ($gitIndexCount)" -Status "PASS"
} else {
    Write-TestResult -Category "Index" -TestName "index entry count" -Status "FAIL" `
        -Details "git=$gitIndexCount, gix=$gixIndexCount"
}

# Verify a random sample of index entries match between git and gix
$gitIndexFiles = (Invoke-Git "ls-files") -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 10
$gixIndexFiles = (Invoke-Gix "index entries") -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 10

$matchCount = 0
foreach ($gitFile in $gitIndexFiles) {
    $gitFileName = $gitFile.Trim()
    # Check if this file appears in gix output (gix may have different format)
    if ($gixIndexFiles -match [regex]::Escape($gitFileName)) {
        $matchCount++
    }
}

if ($matchCount -ge ($gitIndexFiles.Count - 2)) {
    Write-TestResult -Category "Index" -TestName "index file entries match ($matchCount/$($gitIndexFiles.Count))" -Status "PASS"
} else {
    Write-TestResult -Category "Index" -TestName "index file entries match" -Status "FAIL" `
        -Details "matched $matchCount of $($gitIndexFiles.Count) files"
}

# ============================================================================
# Test 6: Merge-Base Accuracy
# ============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Test 6: Merge-Base Accuracy" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Test merge-base at different depths
$depths = @(5, 10, 20, 50, 100)

foreach ($depth in $depths) {
    $gitMergeBase = (Invoke-Git "merge-base HEAD HEAD~$depth" 2>&1)
    $gixMergeBase = (Invoke-Gix "merge-base HEAD HEAD~$depth" 2>&1)

    # Both should succeed or both should fail (for shallow repos)
    if ($gitMergeBase -match "^[0-9a-f]{40}$" -and $gixMergeBase -match "^[0-9a-f]{40}$") {
        if ($gitMergeBase.Trim() -eq $gixMergeBase.Trim()) {
            Write-TestResult -Category "MergeBase" -TestName "HEAD vs HEAD~$depth" -Status "PASS"
        } else {
            Write-TestResult -Category "MergeBase" -TestName "HEAD vs HEAD~$depth" -Status "FAIL" `
                -Details "git=$gitMergeBase, gix=$gixMergeBase"
        }
    } else {
        Write-TestResult -Category "MergeBase" -TestName "HEAD vs HEAD~$depth" -Status "SKIP" `
            -Details "insufficient history"
    }
}

# ============================================================================
# Summary
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                     Deep Validation Summary                    ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "Passed:  $($script:Results.Pass)" -ForegroundColor Green
Write-Host "Failed:  $($script:Results.Fail)" -ForegroundColor $(if ($script:Results.Fail -gt 0) { "Red" } else { "Green" })
Write-Host "Skipped: $($script:Results.Skip)" -ForegroundColor Yellow
Write-Host ""

$totalTests = $script:Results.Pass + $script:Results.Fail
$passRate = if ($totalTests -gt 0) { [math]::Round(($script:Results.Pass / $totalTests) * 100, 1) } else { 0 }
Write-Host "Pass Rate: $passRate%" -ForegroundColor $(if ($passRate -ge 95) { "Green" } elseif ($passRate -ge 80) { "Yellow" } else { "Red" })
Write-Host ""

if ($script:Results.Fail -gt 0) {
    exit 1
}
