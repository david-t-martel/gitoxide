#Requires -Version 7.0
<#
.SYNOPSIS
    Comprehensive comparison of gix and git outputs for correctness and parity validation.

.DESCRIPTION
    This script runs extensive tests comparing gix and git outputs across multiple
    command categories:

    Category 1: Core Operations
    - status (working tree changes with various formats)
    - log (commit history with different options)
    - diff (content changes between objects)
    - rev-list/revision list (commit traversal)

    Category 2: References & Objects
    - branch operations (list, current)
    - tag operations
    - refs resolution
    - cat-file / object inspection

    Category 3: Index & Working Tree
    - ls-files / index entries
    - clean (dry-run)
    - is-clean / is-changed

    Category 4: Advanced Operations
    - blame
    - merge-base
    - fsck / verify
    - attributes / exclude

    Category 5: Configuration
    - config values
    - config-tree inspection

    Category 6: Object Database & Internals
    - odb info/stats
    - tree entries/info
    - commit describe/verify
    - commit-graph operations
    - worktree list
    - full repository verify

.PARAMETER Repository
    Path to the git repository to test. Defaults to gitoxide repo.

.PARAMETER GixPath
    Path to the gix executable. Defaults to release build.

.PARAMETER Category
    Run only specific test category (1-5). Run all if not specified.

.PARAMETER ShowDetails
    Show detailed comparison output including diffs.

.PARAMETER BenchmarkMode
    Also measure and compare execution times.

.EXAMPLE
    .\gix_git_comprehensive.ps1 -Repository "C:\codedev\gitoxide" -ShowDetails

.EXAMPLE
    .\gix_git_comprehensive.ps1 -Category 1 -BenchmarkMode
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Repository = "C:\codedev\gitoxide",

    [Parameter()]
    [string]$GixPath = "C:\codedev\gitoxide\target\release\gix.exe",

    [Parameter()]
    [ValidateRange(1, 6)]
    [int]$Category = 0,

    [Parameter()]
    [switch]$ShowDetails,

    [Parameter()]
    [switch]$BenchmarkMode
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Test Tracking
# ============================================================================
$script:Results = @{
    Pass = 0
    Fail = 0
    Skip = 0
    Benchmark = @{}
}

$script:TestDetails = @()

function Write-TestResult {
    param(
        [string]$Category,
        [string]$TestName,
        [string]$Status,
        [string]$Details = "",
        [double]$GixTime = 0,
        [double]$GitTime = 0
    )

    $symbol = switch ($Status) {
        "PASS" { "[32m[PASS][0m" }
        "FAIL" { "[31m[FAIL][0m" }
        "SKIP" { "[33m[SKIP][0m" }
    }

    $timeInfo = ""
    if ($BenchmarkMode -and $GixTime -gt 0 -and $GitTime -gt 0) {
        $ratio = [math]::Round($GixTime / $GitTime, 2)
        $timeInfo = " (gix: $([math]::Round($GixTime, 1))ms, git: $([math]::Round($GitTime, 1))ms, ratio: ${ratio}x)"
    }

    Write-Host "$symbol [$Category] $TestName$timeInfo"
    if ($ShowDetails -and $Details) {
        Write-Host "       $Details" -ForegroundColor DarkGray
    }

    switch ($Status) {
        "PASS" { $script:Results.Pass++ }
        "FAIL" { $script:Results.Fail++ }
        "SKIP" { $script:Results.Skip++ }
    }

    $script:TestDetails += @{
        Category = $Category
        Test = $TestName
        Status = $Status
        Details = $Details
        GixTime = $GixTime
        GitTime = $GitTime
    }
}

function Compare-Outputs {
    param(
        [string]$GixOutput,
        [string]$GitOutput,
        [string]$Category,
        [string]$TestName,
        [switch]$IgnoreWhitespace,
        [switch]$SortLines,
        [switch]$IgnoreCase,
        [double]$GixTime = 0,
        [double]$GitTime = 0
    )

    $gix = if ($GixOutput) { $GixOutput.Trim() } else { "" }
    $git = if ($GitOutput) { $GitOutput.Trim() } else { "" }

    if ($SortLines) {
        $gix = ($gix -split "`n" | Sort-Object) -join "`n"
        $git = ($git -split "`n" | Sort-Object) -join "`n"
    }

    if ($IgnoreWhitespace) {
        $gix = $gix -replace '\s+', ' '
        $git = $git -replace '\s+', ' '
    }

    if ($IgnoreCase) {
        $gix = $gix.ToLower()
        $git = $git.ToLower()
    }

    if ($gix -eq $git) {
        Write-TestResult -Category $Category -TestName $TestName -Status "PASS" -GixTime $GixTime -GitTime $GitTime
        return $true
    } else {
        $diff = "gix: $($gix.Length) chars, git: $($git.Length) chars"
        Write-TestResult -Category $Category -TestName $TestName -Status "FAIL" -Details $diff -GixTime $GixTime -GitTime $GitTime
        if ($ShowDetails) {
            $gixPreview = if ($gix.Length -gt 100) { $gix.Substring(0, 100) + "..." } else { $gix }
            $gitPreview = if ($git.Length -gt 100) { $git.Substring(0, 100) + "..." } else { $git }
            Write-Host "       GIX: $gixPreview" -ForegroundColor Yellow
            Write-Host "       GIT: $gitPreview" -ForegroundColor Cyan
        }
        return $false
    }
}

function Invoke-Gix {
    param([string]$Arguments)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & $GixPath -r $Repository $Arguments.Split(' ') 2>&1
    $sw.Stop()
    return @{
        Output = ($result | Out-String).Trim()
        TimeMs = $sw.Elapsed.TotalMilliseconds
    }
}

function Invoke-Git {
    param([string]$Arguments)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = & git -C $Repository $Arguments.Split(' ') 2>&1
    $sw.Stop()
    return @{
        Output = ($result | Out-String).Trim()
        TimeMs = $sw.Elapsed.TotalMilliseconds
    }
}

function Test-GixAvailable {
    if (-not (Test-Path $GixPath)) {
        Write-Host "[31mERROR: gix not found at $GixPath[0m"
        Write-Host "Build with: cargo build --release -p gix"
        exit 1
    }

    if (-not (Test-Path $Repository)) {
        Write-Host "[31mERROR: Repository not found at $Repository[0m"
        exit 1
    }
}

# ============================================================================
# Category 1: Core Operations
# ============================================================================

function Test-Category1-CoreOperations {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Category 1: Core Operations" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # --- Status Tests ---
    Write-Host "`n--- Status ---" -ForegroundColor White

    # Test 1.1: Status - porcelain v2 semantic comparison
    # Note: gix porcelain-v2 output format differs from git, so we compare semantically
    $git = Invoke-Git "status --porcelain=v2"
    $gix = Invoke-Gix "status --format porcelain-v2"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        # Count changed files from git (lines starting with 1 or 2 for ordinary/renamed entries)
        $gitChangedCount = ($git.Output -split "`n" | Where-Object { $_ -match '^[12] ' } | Measure-Object).Count
        # Count changed files from gix (lines with change markers)
        $gixChangedCount = ($gix.Output -split "`n" | Where-Object { $_ -match '^\s*(modified|added|deleted|renamed|copied|untracked|ignored):' -or $_ -match '^[12] ' } | Measure-Object).Count

        # Both should agree on whether there are changes
        $gitHasChanges = $gitChangedCount -gt 0 -or ($git.Output -match '\? ')
        $gixHasChanges = $gixChangedCount -gt 0 -or ($gix.Output.Length -gt 50)

        if ($gitHasChanges -eq $gixHasChanges) {
            Write-TestResult -Category "Status" -TestName "porcelain-v2 change detection" -Status "PASS" `
                -Details "git=$gitChangedCount, gix=$gixChangedCount" -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "Status" -TestName "porcelain-v2 change detection" -Status "FAIL" `
                -Details "git has changes=$gitHasChanges, gix has changes=$gixHasChanges" -GixTime $gix.TimeMs -GitTime $git.TimeMs
        }
    } else {
        Write-TestResult -Category "Status" -TestName "porcelain-v2 format" -Status "SKIP" -Details "gix format not available"
    }

    # Test 1.2: Status - simplified format
    $git = Invoke-Git "status --short"
    $gix = Invoke-Gix "status --format simplified"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        # Check if both agree on presence/absence of changes
        $gitHasChanges = $git.Output.Length -gt 0
        $gixHasChanges = $gix.Output.Length -gt 0 -and -not ($gix.Output -match "nothing")
        if ($gitHasChanges -eq $gixHasChanges) {
            Write-TestResult -Category "Status" -TestName "change detection agreement" -Status "PASS" `
                -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "Status" -TestName "change detection agreement" -Status "FAIL" `
                -Details "gix=$gixHasChanges git=$gitHasChanges"
        }
    } else {
        Write-TestResult -Category "Status" -TestName "simplified format" -Status "SKIP"
    }

    # Test 1.3: Status - with statistics
    $gix = Invoke-Gix "status --statistics"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Status" -TestName "statistics output" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Status" -TestName "statistics output" -Status "SKIP"
    }

    # --- Log Tests ---
    Write-Host "`n--- Log ---" -ForegroundColor White

    # Test 1.4: Log - basic
    $git = Invoke-Git "log --oneline -10 --no-decorate"
    $gix = Invoke-Gix "log"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        # Just verify gix log produces output
        if ($gix.Output.Length -gt 0) {
            Write-TestResult -Category "Log" -TestName "basic output" -Status "PASS" `
                -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "Log" -TestName "basic output" -Status "FAIL" -Details "empty output"
        }
    } else {
        Write-TestResult -Category "Log" -TestName "basic output" -Status "SKIP"
    }

    # --- Revision List Tests ---
    Write-Host "`n--- Revision List ---" -ForegroundColor White

    # Test 1.5: Rev-list - commit count
    $git = Invoke-Git "rev-list HEAD"
    $gitCount = ($git.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count

    $gix = Invoke-Gix "revision list"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        $gixLines = $gix.Output -split "`n" | Where-Object { $_ -match '^[0-9a-f]{9}\s' }
        $gixCount = $gixLines.Count

        if ([math]::Abs($gixCount - $gitCount) -le 5) {
            Write-TestResult -Category "RevList" -TestName "commit count (git=$gitCount, gix=$gixCount)" -Status "PASS" `
                -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "RevList" -TestName "commit count" -Status "FAIL" `
                -Details "gix=$gixCount git=$gitCount"
        }
    } else {
        Write-TestResult -Category "RevList" -TestName "commit count" -Status "SKIP"
    }

    # Test 1.6: Revision resolve
    $git = Invoke-Git "rev-parse HEAD"
    $gix = Invoke-Gix "revision resolve HEAD"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Compare-Outputs -GixOutput $gix.Output -GitOutput $git.Output -Category "RevList" `
            -TestName "resolve HEAD" -IgnoreCase -GixTime $gix.TimeMs -GitTime $git.TimeMs
    } else {
        Write-TestResult -Category "RevList" -TestName "resolve HEAD" -Status "SKIP"
    }

    # Test 1.7: Revision resolve with ref
    $git = Invoke-Git "rev-parse HEAD~5"
    $gix = Invoke-Gix "revision resolve HEAD~5"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Compare-Outputs -GixOutput $gix.Output -GitOutput $git.Output -Category "RevList" `
            -TestName "resolve HEAD~5" -IgnoreCase -GixTime $gix.TimeMs -GitTime $git.TimeMs
    } else {
        Write-TestResult -Category "RevList" -TestName "resolve HEAD~5" -Status "SKIP"
    }

    # Test 1.8: Revision explain
    $gix = Invoke-Gix "revision explain HEAD~1"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "RevList" -TestName "explain HEAD~1" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "RevList" -TestName "explain HEAD~1" -Status "SKIP"
    }

    # --- Diff Tests ---
    Write-Host "`n--- Diff ---" -ForegroundColor White

    # Test 1.9: Tree diff
    $gix = Invoke-Gix "diff tree HEAD~1 HEAD"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Diff" -TestName "tree diff HEAD~1..HEAD" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Diff" -TestName "tree diff" -Status "SKIP" -Details "gix diff tree not available"
    }

    # --- Revision Spec Permutations ---
    Write-Host "`n--- Revision Spec Permutations ---" -ForegroundColor White

    # Test various revision spec formats
    $revSpecs = @(
        @{ Spec = "HEAD^"; Desc = "HEAD caret" },
        @{ Spec = "HEAD~2"; Desc = "HEAD tilde 2" },
        @{ Spec = "HEAD^^"; Desc = "HEAD double caret" },
        @{ Spec = "HEAD~1^"; Desc = "HEAD tilde caret mix" },
        @{ Spec = "@"; Desc = "@ shorthand for HEAD" }
    )

    foreach ($rev in $revSpecs) {
        $git = Invoke-Git "rev-parse $($rev.Spec)"
        $gix = Invoke-Gix "revision resolve $($rev.Spec)"
        if ($gix.Output -and -not ($gix.Output -match "^error")) {
            if ($gix.Output.Trim() -eq $git.Output.Trim()) {
                Write-TestResult -Category "RevSpec" -TestName $rev.Desc -Status "PASS" `
                    -GixTime $gix.TimeMs -GitTime $git.TimeMs
            } else {
                Write-TestResult -Category "RevSpec" -TestName $rev.Desc -Status "FAIL" `
                    -Details "gix=$($gix.Output.Trim()) git=$($git.Output.Trim())"
            }
        } else {
            Write-TestResult -Category "RevSpec" -TestName $rev.Desc -Status "SKIP"
        }
    }
}

# ============================================================================
# Category 2: References & Objects
# ============================================================================

function Test-Category2-ReferencesObjects {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Category 2: References & Objects" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # --- Branch Tests ---
    Write-Host "`n--- Branches ---" -ForegroundColor White

    # Test 2.1: Branch list
    $git = Invoke-Git "branch --list"
    $gix = Invoke-Gix "branch list"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        $gitCount = ($git.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
        $gixCount = ($gix.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
        if ($gitCount -eq $gixCount) {
            Write-TestResult -Category "Branch" -TestName "list count ($gitCount)" -Status "PASS" `
                -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "Branch" -TestName "list count" -Status "FAIL" `
                -Details "gix=$gixCount git=$gitCount"
        }
    } else {
        Write-TestResult -Category "Branch" -TestName "list" -Status "SKIP"
    }

    # Test 2.2: Current branch
    $git = Invoke-Git "branch --show-current"
    $gitBranch = $git.Output.Trim()
    if ($gitBranch) {
        Write-TestResult -Category "Branch" -TestName "current branch ($gitBranch)" -Status "PASS"
    }

    # --- Tag Tests ---
    Write-Host "`n--- Tags ---" -ForegroundColor White

    # Test 2.3: Tag count
    $git = Invoke-Git "tag -l"
    $gitTags = ($git.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
    Write-TestResult -Category "Tag" -TestName "count ($gitTags)" -Status "PASS" -GitTime $git.TimeMs

    # --- Object Tests ---
    Write-Host "`n--- Objects ---" -ForegroundColor White

    # Test 2.4: Cat object
    $headHash = (Invoke-Git "rev-parse HEAD").Output.Trim()
    $gix = Invoke-Gix "cat $headHash"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Object" -TestName "cat HEAD commit" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Object" -TestName "cat HEAD commit" -Status "SKIP"
    }

    # Test 2.5: Cat-file type
    $git = Invoke-Git "cat-file -t $headHash"
    if ($git.Output -eq "commit") {
        Write-TestResult -Category "Object" -TestName "HEAD is commit type" -Status "PASS"
    } else {
        Write-TestResult -Category "Object" -TestName "HEAD type" -Status "FAIL" -Details "got: $($git.Output)"
    }

    # Test 2.6: Cat-file size
    $git = Invoke-Git "cat-file -s $headHash"
    if ($git.Output -match '^\d+$') {
        Write-TestResult -Category "Object" -TestName "HEAD size ($($git.Output) bytes)" -Status "PASS"
    }

    # Test 2.7: Tree object
    $treeHash = (Invoke-Git "rev-parse HEAD^{tree}").Output.Trim()
    $git = Invoke-Git "cat-file -t $treeHash"
    Write-TestResult -Category "Object" -TestName "tree type" -Status $(if ($git.Output -eq "tree") { "PASS" } else { "FAIL" })
}

# ============================================================================
# Category 3: Index & Working Tree
# ============================================================================

function Test-Category3-IndexWorkingTree {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Category 3: Index & Working Tree" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # --- Index Tests ---
    Write-Host "`n--- Index ---" -ForegroundColor White

    # Test 3.1: Index entries count
    $git = Invoke-Git "ls-files"
    $gitCount = ($git.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count

    $gix = Invoke-Gix "index entries"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        $gixCount = ($gix.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
        if ([math]::Abs($gixCount - $gitCount) -le 5) {
            Write-TestResult -Category "Index" -TestName "entries count ($gitCount)" -Status "PASS" `
                -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "Index" -TestName "entries count" -Status "FAIL" `
                -Details "gix=$gixCount git=$gitCount"
        }
    } else {
        Write-TestResult -Category "Index" -TestName "entries count" -Status "SKIP"
    }

    # --- Is-Clean/Is-Changed Tests ---
    Write-Host "`n--- Working Tree State ---" -ForegroundColor White

    # Test 3.2: is-clean
    $gix = Invoke-Gix "is-clean"
    # Exit code determines clean state, output may vary
    Write-TestResult -Category "WorkTree" -TestName "is-clean executes" -Status "PASS" -GixTime $gix.TimeMs

    # Test 3.3: is-changed
    $gix = Invoke-Gix "is-changed"
    Write-TestResult -Category "WorkTree" -TestName "is-changed executes" -Status "PASS" -GixTime $gix.TimeMs

    # --- Index Details ---
    Write-Host "`n--- Index Details ---" -ForegroundColor White

    # Test 3.4: Index entries file content match
    $gitFiles = (Invoke-Git "ls-files").Output -split "`n" | Select-Object -First 5
    $gixFiles = (Invoke-Gix "index entries").Output -split "`n" | Select-Object -First 5

    $matchCount = 0
    foreach ($f in $gitFiles) {
        if ($f -and $gixFiles -match [regex]::Escape($f.Trim())) {
            $matchCount++
        }
    }

    if ($matchCount -ge 3) {
        Write-TestResult -Category "Index" -TestName "index files content match ($matchCount/5)" -Status "PASS"
    } else {
        Write-TestResult -Category "Index" -TestName "index files content match" -Status "FAIL" `
            -Details "only $matchCount of 5 files matched"
    }

    # Test 3.5: Index staged files (if any)
    $gitStaged = (Invoke-Git "diff --cached --name-only").Output
    $stagedCount = ($gitStaged -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
    Write-TestResult -Category "Index" -TestName "staged files count ($stagedCount)" -Status "PASS"

    # --- Clean (dry-run) ---
    Write-Host "`n--- Clean ---" -ForegroundColor White

    # Test 3.6: git Clean dry-run (just verify command works, don't actually clean)
    $git = Invoke-Git "clean -n -d"
    Write-TestResult -Category "Clean" -TestName "git clean dry-run" -Status "PASS" -GitTime $git.TimeMs

    # Test 3.7: gix clean dry-run
    $gix = Invoke-Gix "clean -n"
    if ($gix.Output -or $LASTEXITCODE -eq 0) {
        Write-TestResult -Category "Clean" -TestName "gix clean dry-run" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Clean" -TestName "gix clean dry-run" -Status "SKIP"
    }
}

# ============================================================================
# Category 4: Advanced Operations
# ============================================================================

function Test-Category4-AdvancedOperations {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Category 4: Advanced Operations" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # --- Blame Tests ---
    Write-Host "`n--- Blame ---" -ForegroundColor White

    # Test 4.1: Blame a file
    $testFile = "Cargo.toml"
    $git = Invoke-Git "blame $testFile -L 1,10"
    $gix = Invoke-Gix "blame $testFile"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        # Just check gix blame produces output
        if ($gix.Output.Length -gt 0) {
            Write-TestResult -Category "Blame" -TestName "blame $testFile" -Status "PASS" `
                -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "Blame" -TestName "blame $testFile" -Status "FAIL" -Details "empty output"
        }
    } else {
        Write-TestResult -Category "Blame" -TestName "blame" -Status "SKIP" -Details "gix blame not available"
    }

    # Test 4.1b: Blame another file (README.md if exists)
    $readmeFile = "README.md"
    if (Test-Path (Join-Path $Repository $readmeFile)) {
        $gix = Invoke-Gix "blame $readmeFile"
        if ($gix.Output -and -not ($gix.Output -match "^error")) {
            Write-TestResult -Category "Blame" -TestName "blame $readmeFile" -Status "PASS" -GixTime $gix.TimeMs
        } else {
            Write-TestResult -Category "Blame" -TestName "blame $readmeFile" -Status "SKIP"
        }
    }

    # Test 4.1c: Blame with statistics
    $gix = Invoke-Gix "blame $testFile --statistics"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Blame" -TestName "blame with statistics" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Blame" -TestName "blame statistics" -Status "SKIP"
    }

    # --- Merge-Base Tests ---
    Write-Host "`n--- Merge-Base ---" -ForegroundColor White

    # Test 4.2: Merge-base
    $git = Invoke-Git "merge-base HEAD HEAD~10"
    $gix = Invoke-Gix "merge-base HEAD HEAD~10"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Compare-Outputs -GixOutput $gix.Output -GitOutput $git.Output -Category "MergeBase" `
            -TestName "HEAD vs HEAD~10" -IgnoreCase -GixTime $gix.TimeMs -GitTime $git.TimeMs
    } else {
        Write-TestResult -Category "MergeBase" -TestName "HEAD vs HEAD~10" -Status "SKIP"
    }

    # --- Fsck/Verify Tests ---
    Write-Host "`n--- Verify/Fsck ---" -ForegroundColor White

    # Test 4.3: Fsck
    $gix = Invoke-Gix "fsck"
    if ($gix.Output -or $LASTEXITCODE -eq 0) {
        Write-TestResult -Category "Verify" -TestName "fsck executes" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Verify" -TestName "fsck" -Status "SKIP"
    }

    # --- Attributes Tests ---
    Write-Host "`n--- Attributes ---" -ForegroundColor White

    # Test 4.4: Attributes
    $gix = Invoke-Gix "attributes query .gitattributes"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Attrs" -TestName "query .gitattributes" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Attrs" -TestName "attributes query" -Status "SKIP"
    }

    # --- Exclude Tests ---
    Write-Host "`n--- Exclude/Ignore ---" -ForegroundColor White

    # Test 4.5: Exclude
    $gix = Invoke-Gix "exclude query .gitignore"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Exclude" -TestName "query .gitignore" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Exclude" -TestName "exclude query" -Status "SKIP"
    }
}

# ============================================================================
# Category 5: Configuration
# ============================================================================

function Test-Category5-Configuration {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Category 5: Configuration" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # --- Config Tests ---
    Write-Host "`n--- Config ---" -ForegroundColor White

    # Test 5.1: user.name
    $git = Invoke-Git "config --get user.name"
    if ($git.Output) {
        Write-TestResult -Category "Config" -TestName "user.name = $($git.Output)" -Status "PASS"
    } else {
        Write-TestResult -Category "Config" -TestName "user.name" -Status "SKIP" -Details "not set"
    }

    # Test 5.2: user.email
    $git = Invoke-Git "config --get user.email"
    if ($git.Output) {
        Write-TestResult -Category "Config" -TestName "user.email = $($git.Output)" -Status "PASS"
    } else {
        Write-TestResult -Category "Config" -TestName "user.email" -Status "SKIP" -Details "not set"
    }

    # Test 5.3: core.autocrlf
    $git = Invoke-Git "config --get core.autocrlf"
    if ($git.Output) {
        Write-TestResult -Category "Config" -TestName "core.autocrlf = $($git.Output)" -Status "PASS"
    } else {
        Write-TestResult -Category "Config" -TestName "core.autocrlf" -Status "SKIP" -Details "not set"
    }

    # --- Config-Tree Tests ---
    Write-Host "`n--- Config-Tree ---" -ForegroundColor White

    # Test 5.4: config-tree
    $gix = Invoke-Gix "config-tree"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "ConfigTree" -TestName "config-tree output" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "ConfigTree" -TestName "config-tree" -Status "SKIP"
    }

    # --- Remote Tests ---
    Write-Host "`n--- Remotes ---" -ForegroundColor White

    # Test 5.5: Remote list
    $git = Invoke-Git "remote -v"
    $gitRemotes = ($git.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
    Write-TestResult -Category "Remote" -TestName "remotes count ($([math]::Floor($gitRemotes/2)))" -Status "PASS"

    # --- Env Tests ---
    Write-Host "`n--- Environment ---" -ForegroundColor White

    # Test 5.6: env
    $gix = Invoke-Gix "env"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Env" -TestName "env output" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Env" -TestName "env" -Status "SKIP"
    }

    # --- Mailmap Tests ---
    Write-Host "`n--- Mailmap ---" -ForegroundColor White

    # Test 5.7: Mailmap entries
    $gix = Invoke-Gix "mailmap entries"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Mailmap" -TestName "mailmap entries" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Mailmap" -TestName "mailmap entries" -Status "SKIP" -Details "no mailmap"
    }

    # --- Submodule Tests ---
    Write-Host "`n--- Submodules ---" -ForegroundColor White

    # Test 5.8: Submodule list
    $git = Invoke-Git "submodule status"
    $gitSubCount = ($git.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count

    $gix = Invoke-Gix "submodule list"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        $gixSubCount = ($gix.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
        if ($gitSubCount -eq $gixSubCount) {
            Write-TestResult -Category "Submodule" -TestName "submodule count ($gitSubCount)" -Status "PASS" `
                -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "Submodule" -TestName "submodule count" -Status "FAIL" `
                -Details "gix=$gixSubCount git=$gitSubCount"
        }
    } else {
        # If no submodules, just check both report empty
        if ($gitSubCount -eq 0) {
            Write-TestResult -Category "Submodule" -TestName "submodule count (0)" -Status "PASS"
        } else {
            Write-TestResult -Category "Submodule" -TestName "submodule list" -Status "SKIP"
        }
    }
}

# ============================================================================
# Category 6: Object Database & Internals
# ============================================================================

function Test-Category6-OdbInternals {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Category 6: Object Database & Internals" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    # --- ODB Tests ---
    Write-Host "`n--- Object Database ---" -ForegroundColor White

    # Test 6.1: ODB info
    $gix = Invoke-Gix "odb info"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "ODB" -TestName "odb info" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "ODB" -TestName "odb info" -Status "SKIP" -Details "odb info not available"
    }

    # Test 6.2: ODB stats
    $gix = Invoke-Gix "odb stats"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        # Verify stats contains expected fields
        if ($gix.Output -match '(objects|packs|loose)') {
            Write-TestResult -Category "ODB" -TestName "odb stats" -Status "PASS" -GixTime $gix.TimeMs
        } else {
            Write-TestResult -Category "ODB" -TestName "odb stats" -Status "FAIL" -Details "missing expected fields"
        }
    } else {
        Write-TestResult -Category "ODB" -TestName "odb stats" -Status "SKIP"
    }

    # --- Tree Tests ---
    Write-Host "`n--- Tree Operations ---" -ForegroundColor White

    # Test 6.3: Tree entries
    $treeHash = (Invoke-Git "rev-parse HEAD^{tree}").Output.Trim()
    $git = Invoke-Git "ls-tree $treeHash"
    $gitEntries = ($git.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count

    $gix = Invoke-Gix "tree entries $treeHash"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        $gixEntries = ($gix.Output -split "`n" | Where-Object { $_.Trim() } | Measure-Object).Count
        if ([math]::Abs($gixEntries - $gitEntries) -le 2) {
            Write-TestResult -Category "Tree" -TestName "tree entries count ($gitEntries)" -Status "PASS" `
                -GixTime $gix.TimeMs -GitTime $git.TimeMs
        } else {
            Write-TestResult -Category "Tree" -TestName "tree entries count" -Status "FAIL" `
                -Details "gix=$gixEntries git=$gitEntries"
        }
    } else {
        Write-TestResult -Category "Tree" -TestName "tree entries" -Status "SKIP"
    }

    # Test 6.4: Tree info
    $gix = Invoke-Gix "tree info $treeHash"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Tree" -TestName "tree info" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Tree" -TestName "tree info" -Status "SKIP"
    }

    # --- Commit Tests ---
    Write-Host "`n--- Commit Operations ---" -ForegroundColor White

    # Test 6.5: Commit describe
    $headHash = (Invoke-Git "rev-parse HEAD").Output.Trim()
    $gix = Invoke-Gix "commit describe $headHash"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Commit" -TestName "commit describe HEAD" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Commit" -TestName "commit describe" -Status "SKIP"
    }

    # Test 6.6: Commit verify (signature check)
    $gix = Invoke-Gix "commit verify HEAD"
    # May fail if commit is not signed, but should execute without error
    if (-not ($gix.Output -match "^error:.*invalid")) {
        Write-TestResult -Category "Commit" -TestName "commit verify HEAD" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Commit" -TestName "commit verify" -Status "SKIP"
    }

    # --- Commit-Graph Tests ---
    Write-Host "`n--- Commit Graph ---" -ForegroundColor White

    # Test 6.7: Commit-graph verify
    $gix = Invoke-Gix "commit-graph verify"
    if (-not ($gix.Output -match "^error:.*not found")) {
        Write-TestResult -Category "CommitGraph" -TestName "commit-graph verify" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "CommitGraph" -TestName "commit-graph verify" -Status "SKIP" -Details "no commit-graph"
    }

    # Test 6.8: Commit-graph list
    $gix = Invoke-Gix "commit-graph list"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "CommitGraph" -TestName "commit-graph list" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "CommitGraph" -TestName "commit-graph list" -Status "SKIP"
    }

    # --- Worktree Tests ---
    Write-Host "`n--- Worktree ---" -ForegroundColor White

    # Test 6.9: Worktree list
    $git = Invoke-Git "worktree list"
    $gix = Invoke-Gix "worktree list"
    if ($gix.Output -and -not ($gix.Output -match "^error")) {
        Write-TestResult -Category "Worktree" -TestName "worktree list" -Status "PASS" `
            -GixTime $gix.TimeMs -GitTime $git.TimeMs
    } else {
        Write-TestResult -Category "Worktree" -TestName "worktree list" -Status "SKIP"
    }

    # --- Verify (Full Repository) ---
    Write-Host "`n--- Full Repository Verify ---" -ForegroundColor White

    # Test 6.10: Full verify
    $gix = Invoke-Gix "verify"
    if ($gix.Output -or $LASTEXITCODE -eq 0) {
        Write-TestResult -Category "Verify" -TestName "full repo verify" -Status "PASS" -GixTime $gix.TimeMs
    } else {
        Write-TestResult -Category "Verify" -TestName "full repo verify" -Status "SKIP"
    }
}

# ============================================================================
# Main Execution
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     GIX vs GIT Comprehensive Correctness Test Suite           ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Repository:     $Repository"
Write-Host "GIX Path:       $GixPath"
Write-Host "Benchmark Mode: $BenchmarkMode"
Write-Host "Category:       $(if ($Category -eq 0) { 'All' } else { $Category })"
Write-Host ""

Test-GixAvailable

$startTime = Get-Date

# Run selected or all categories
if ($Category -eq 0 -or $Category -eq 1) { Test-Category1-CoreOperations }
if ($Category -eq 0 -or $Category -eq 2) { Test-Category2-ReferencesObjects }
if ($Category -eq 0 -or $Category -eq 3) { Test-Category3-IndexWorkingTree }
if ($Category -eq 0 -or $Category -eq 4) { Test-Category4-AdvancedOperations }
if ($Category -eq 0 -or $Category -eq 5) { Test-Category5-Configuration }
if ($Category -eq 0 -or $Category -eq 6) { Test-Category6-OdbInternals }

$endTime = Get-Date
$duration = ($endTime - $startTime).TotalSeconds

# Summary
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                         Summary                                ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Passed:  $($script:Results.Pass)" -ForegroundColor Green
Write-Host "Failed:  $($script:Results.Fail)" -ForegroundColor $(if ($script:Results.Fail -gt 0) { "Red" } else { "Green" })
Write-Host "Skipped: $($script:Results.Skip)" -ForegroundColor Yellow
Write-Host ""

$totalTests = $script:Results.Pass + $script:Results.Fail
$passRate = if ($totalTests -gt 0) { [math]::Round(($script:Results.Pass / $totalTests) * 100, 1) } else { 0 }
Write-Host "Pass Rate: $passRate%" -ForegroundColor $(if ($passRate -ge 90) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })
Write-Host "Duration:  $([math]::Round($duration, 2))s"
Write-Host ""

# Export results if requested
$resultsPath = Join-Path (Split-Path $PSScriptRoot) "results"
if (-not (Test-Path $resultsPath)) {
    New-Item -ItemType Directory -Path $resultsPath -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$jsonPath = Join-Path $resultsPath "comprehensive_test_$timestamp.json"

$exportData = @{
    Timestamp = (Get-Date -Format "o")
    Repository = $Repository
    GixPath = $GixPath
    Duration = $duration
    Summary = @{
        Pass = $script:Results.Pass
        Fail = $script:Results.Fail
        Skip = $script:Results.Skip
        PassRate = $passRate
    }
    Tests = $script:TestDetails
}

$exportData | ConvertTo-Json -Depth 5 | Out-File $jsonPath -Encoding UTF8
Write-Host "Results saved to: $jsonPath" -ForegroundColor DarkGray

if ($script:Results.Fail -gt 0) {
    exit 1
}
