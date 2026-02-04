#Requires -Version 7.0
<#
.SYNOPSIS
    Multi-repository test runner for gix vs git correctness validation.

.DESCRIPTION
    Runs the comprehensive gix vs git test suite across multiple repositories
    to validate cross-repository generalizability. Aggregates results and identifies
    patterns in failures or performance differences.

    Features:
    - Auto-discovers git repositories in specified directories
    - Runs comprehensive tests on each repository
    - Aggregates and summarizes results
    - Identifies common failures across repos
    - Performance comparison across repo sizes

.PARAMETER SearchPaths
    Paths to search for git repositories. Default: common development directories.

.PARAMETER MaxRepos
    Maximum number of repositories to test. Default: 10.

.PARAMETER GixPath
    Path to the gix executable.

.PARAMETER MinCommits
    Minimum number of commits required for a repo to be included. Default: 100.

.PARAMETER Categories
    Specific test categories to run (1-6). Run all if not specified.

.EXAMPLE
    .\multi_repo_test_runner.ps1 -SearchPaths "C:\codedev" -MaxRepos 5

.EXAMPLE
    .\multi_repo_test_runner.ps1 -GixPath "C:\custom\gix.exe" -MinCommits 500
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SearchPaths = @("C:\codedev", "C:\Users\david\source\repos"),

    [Parameter()]
    [int]$MaxRepos = 10,

    [Parameter()]
    [string]$GixPath = "C:\codedev\gitoxide\target\release\gix.exe",

    [Parameter()]
    [int]$MinCommits = 100,

    [Parameter()]
    [int[]]$Categories = @()
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Repository Discovery
# ============================================================================

function Find-GitRepositories {
    param(
        [string[]]$Paths,
        [int]$MaxCount,
        [int]$MinCommits
    )

    $repos = @()

    foreach ($basePath in $Paths) {
        if (-not (Test-Path $basePath)) {
            Write-Host "  Skipping non-existent path: $basePath" -ForegroundColor DarkGray
            continue
        }

        Write-Host "  Scanning: $basePath" -ForegroundColor DarkGray

        # Find .git directories
        $gitDirs = Get-ChildItem -Path $basePath -Directory -Recurse -Filter ".git" -ErrorAction SilentlyContinue |
            Where-Object { $_.Parent.FullName -notmatch '\\node_modules\\|\\vendor\\|\\.cargo\\' } |
            Select-Object -First ($MaxCount * 2)  # Get extra in case some don't meet criteria

        foreach ($gitDir in $gitDirs) {
            if ($repos.Count -ge $MaxCount) { break }

            $repoPath = $gitDir.Parent.FullName

            # Check commit count
            try {
                $commitCount = (git -C $repoPath rev-list HEAD --count 2>$null)
                if ($commitCount -and [int]$commitCount -ge $MinCommits) {
                    # Get repo stats
                    $fileCount = (git -C $repoPath ls-files 2>$null | Measure-Object).Count

                    $repos += @{
                        Path = $repoPath
                        Name = Split-Path $repoPath -Leaf
                        Commits = [int]$commitCount
                        Files = $fileCount
                    }

                    Write-Host "    Found: $($repos[-1].Name) ($commitCount commits, $fileCount files)" -ForegroundColor Green
                }
            } catch {
                # Skip repos that can't be accessed
            }
        }
    }

    return $repos | Sort-Object -Property Commits -Descending
}

# ============================================================================
# Test Execution
# ============================================================================

function Invoke-RepoTests {
    param(
        [hashtable]$Repo,
        [string]$GixPath,
        [int[]]$Categories
    )

    $testScript = Join-Path $PSScriptRoot "gix_git_comprehensive.ps1"

    if (-not (Test-Path $testScript)) {
        Write-Error "Test script not found: $testScript"
        return $null
    }

    $catParam = if ($Categories.Count -gt 0) { "-Category $($Categories[0])" } else { "" }

    try {
        $result = & pwsh.exe -Command "
            . '$testScript' -Repository '$($Repo.Path)' -GixPath '$GixPath' $catParam 2>&1
        "

        # Parse results from output
        $passCount = 0
        $failCount = 0
        $skipCount = 0
        $duration = 0

        foreach ($line in $result) {
            if ($line -match 'Passed:\s+(\d+)') { $passCount = [int]$Matches[1] }
            if ($line -match 'Failed:\s+(\d+)') { $failCount = [int]$Matches[1] }
            if ($line -match 'Skipped:\s+(\d+)') { $skipCount = [int]$Matches[1] }
            if ($line -match 'Duration:\s+([\d.]+)s') { $duration = [double]$Matches[1] }
        }

        # Look for test results JSON
        $resultsDir = Join-Path (Split-Path $testScript) "..\results"
        $latestJson = Get-ChildItem $resultsDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        $testDetails = @()
        if ($latestJson) {
            $jsonData = Get-Content $latestJson.FullName | ConvertFrom-Json
            $testDetails = $jsonData.Tests
        }

        return @{
            RepoName = $Repo.Name
            RepoPath = $Repo.Path
            Commits = $Repo.Commits
            Files = $Repo.Files
            Passed = $passCount
            Failed = $failCount
            Skipped = $skipCount
            Duration = $duration
            PassRate = if (($passCount + $failCount) -gt 0) {
                [math]::Round($passCount / ($passCount + $failCount) * 100, 1)
            } else { 0 }
            Tests = $testDetails
        }
    } catch {
        Write-Warning "Failed to test $($Repo.Name): $_"
        return @{
            RepoName = $Repo.Name
            RepoPath = $Repo.Path
            Error = $_.Exception.Message
        }
    }
}

# ============================================================================
# Results Analysis
# ============================================================================

function Show-AggregateResults {
    param(
        [array]$Results
    )

    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              Cross-Repository Results Summary                  ║" -ForegroundColor Cyan
    Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # Summary table
    Write-Host "Repository Results:" -ForegroundColor White
    Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $totalPass = 0
    $totalFail = 0
    $totalSkip = 0
    $totalDuration = 0

    foreach ($r in $Results) {
        if ($r.Error) {
            Write-Host "  $($r.RepoName.PadRight(25)) ERROR: $($r.Error)" -ForegroundColor Red
        } else {
            $status = if ($r.PassRate -ge 100) { "[32m✓[0m" }
                      elseif ($r.PassRate -ge 90) { "[33m~[0m" }
                      else { "[31m✗[0m" }

            $line = "  $status $($r.RepoName.PadRight(22)) " +
                    "Pass: $($r.Passed.ToString().PadLeft(3)) " +
                    "Fail: $($r.Failed.ToString().PadLeft(2)) " +
                    "Skip: $($r.Skipped.ToString().PadLeft(2)) " +
                    "Rate: $($r.PassRate.ToString().PadLeft(5))% " +
                    "Time: $([math]::Round($r.Duration, 1).ToString().PadLeft(6))s"
            Write-Host $line

            $totalPass += $r.Passed
            $totalFail += $r.Failed
            $totalSkip += $r.Skipped
            $totalDuration += $r.Duration
        }
    }

    Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $totalTests = $totalPass + $totalFail
    $overallRate = if ($totalTests -gt 0) { [math]::Round($totalPass / $totalTests * 100, 1) } else { 0 }

    Write-Host ""
    Write-Host "Overall Statistics:" -ForegroundColor White
    Write-Host "  Repositories tested: $($Results.Count)"
    Write-Host "  Total tests:         $totalTests"
    Write-Host "  Total passed:        $totalPass" -ForegroundColor Green
    Write-Host "  Total failed:        $totalFail" -ForegroundColor $(if ($totalFail -gt 0) { "Red" } else { "Green" })
    Write-Host "  Total skipped:       $totalSkip" -ForegroundColor Yellow
    Write-Host "  Overall pass rate:   $overallRate%" -ForegroundColor $(if ($overallRate -ge 95) { "Green" } else { "Yellow" })
    Write-Host "  Total duration:      $([math]::Round($totalDuration, 1))s"

    # Identify common failures
    $allFailures = @{}
    foreach ($r in $Results) {
        if ($r.Tests) {
            foreach ($t in $r.Tests) {
                if ($t.Status -eq "FAIL") {
                    $key = "$($t.Category)::$($t.Test)"
                    if (-not $allFailures.ContainsKey($key)) {
                        $allFailures[$key] = @{
                            Test = $t.Test
                            Category = $t.Category
                            Repos = @()
                        }
                    }
                    $allFailures[$key].Repos += $r.RepoName
                }
            }
        }
    }

    if ($allFailures.Count -gt 0) {
        Write-Host ""
        Write-Host "Common Failures (tests failing across repos):" -ForegroundColor Red
        foreach ($failure in $allFailures.Values | Sort-Object { $_.Repos.Count } -Descending) {
            Write-Host "  [$($failure.Category)] $($failure.Test)"
            Write-Host "    Failed in: $($failure.Repos -join ', ')" -ForegroundColor DarkGray
        }
    } else {
        Write-Host ""
        Write-Host "No common failures detected across repositories!" -ForegroundColor Green
    }
}

# ============================================================================
# Main Execution
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     GIX Multi-Repository Correctness Test Runner              ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# Verify gix exists
if (-not (Test-Path $GixPath)) {
    Write-Host "[31mERROR: gix not found at $GixPath[0m"
    exit 1
}

Write-Host "Configuration:" -ForegroundColor White
Write-Host "  GIX Path:    $GixPath"
Write-Host "  Max Repos:   $MaxRepos"
Write-Host "  Min Commits: $MinCommits"
Write-Host "  Categories:  $(if ($Categories.Count -gt 0) { $Categories -join ',' } else { 'All' })"
Write-Host ""

# Discover repositories
Write-Host "Discovering git repositories..." -ForegroundColor White
$repos = Find-GitRepositories -Paths $SearchPaths -MaxCount $MaxRepos -MinCommits $MinCommits

if ($repos.Count -eq 0) {
    Write-Host "[31mNo repositories found matching criteria[0m"
    exit 1
}

Write-Host ""
Write-Host "Found $($repos.Count) repositories to test" -ForegroundColor Green
Write-Host ""

# Run tests on each repository
$results = @()
$repoIndex = 1

foreach ($repo in $repos) {
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Testing [$repoIndex/$($repos.Count)]: $($repo.Name)" -ForegroundColor Cyan
    Write-Host "  Path: $($repo.Path)" -ForegroundColor DarkGray
    Write-Host "  Commits: $($repo.Commits), Files: $($repo.Files)" -ForegroundColor DarkGray
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $result = Invoke-RepoTests -Repo $repo -GixPath $GixPath -Categories $Categories
    $results += $result

    $repoIndex++
    Write-Host ""
}

# Show aggregate results
Show-AggregateResults -Results $results

# Export aggregate results
$resultsDir = Join-Path $PSScriptRoot "..\results"
if (-not (Test-Path $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$jsonPath = Join-Path $resultsDir "multi_repo_test_$timestamp.json"

$exportData = @{
    Timestamp = (Get-Date -Format "o")
    GixPath = $GixPath
    RepoCount = $repos.Count
    Results = $results
}

$exportData | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding UTF8
Write-Host ""
Write-Host "Results saved to: $jsonPath" -ForegroundColor DarkGray
