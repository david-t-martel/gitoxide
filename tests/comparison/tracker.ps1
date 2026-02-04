#Requires -Version 7.0
<#
.SYNOPSIS
    Gitoxide Feature & Performance Tracker

.DESCRIPTION
    Tracks feature implementation progress and performance trends over time.
    Designed to be run as part of CI/CD or post-build hooks.

.EXAMPLE
    ./tracker.ps1 -UpdateBaseline
    ./tracker.ps1 -GenerateReport
    ./tracker.ps1 -CheckRegression -Threshold 10
#>

param(
    [switch]$UpdateBaseline,
    [switch]$GenerateReport,
    [switch]$CheckRegression,
    [int]$Threshold = 15,  # Percentage regression threshold
    [string]$BaselineFile = "baseline.json",
    [string]$ResultsDir = "results"
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Paths
$FeatureMatrixPath = Join-Path $ScriptDir "feature_matrix.json"
$BaselinePath = Join-Path $ScriptDir $BaselineFile
$ResultsPath = Join-Path $ScriptDir $ResultsDir

function Get-FeatureStats {
    $matrix = Get-Content $FeatureMatrixPath | ConvertFrom-Json

    $stats = @{
        TotalFeatures = 0
        GixImplemented = 0
        GixPartial = 0
        GixMissing = 0
        GixUnique = 0
        Categories = @{}
    }

    foreach ($category in $matrix.categories.PSObject.Properties) {
        $catStats = @{ Total = 0; Implemented = 0; Partial = 0; Missing = 0 }

        foreach ($feature in $category.Value.features.PSObject.Properties) {
            $catStats.Total++
            $stats.TotalFeatures++

            $gixStatus = $feature.Value.gix

            if ($gixStatus -eq $true) {
                $catStats.Implemented++
                $stats.GixImplemented++
            } elseif ($gixStatus -eq "partial") {
                $catStats.Partial++
                $stats.GixPartial++
            } elseif ($gixStatus -eq $false) {
                $catStats.Missing++
                $stats.GixMissing++
            }
        }

        $stats.Categories[$category.Name] = $catStats
    }

    # Count unique features
    if ($matrix.categories.unique_gix_features) {
        $stats.GixUnique = $matrix.categories.unique_gix_features.features.PSObject.Properties.Count
    }

    return $stats
}

function Get-LatestBenchmark {
    if (-not (Test-Path $ResultsPath)) {
        return $null
    }

    $latest = Get-ChildItem $ResultsPath -Filter "benchmark_*.json" |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1

    if ($latest) {
        return Get-Content $latest.FullName | ConvertFrom-Json
    }
    return $null
}

function Update-Baseline {
    Write-Host "Updating baseline..." -ForegroundColor Yellow

    # Run benchmark
    $benchmarkScript = Join-Path $ScriptDir "benchmark_runner.ps1"
    $results = & $benchmarkScript -TestRepo (Get-Location) -Iterations 5

    # Get feature stats
    $features = Get-FeatureStats

    $baseline = @{
        Timestamp = Get-Date -Format "o"
        GitoxideVersion = (& "C:\codedev\gitoxide\gix.exe" --version 2>&1) -join ""
        Features = $features
        Benchmarks = @{}
    }

    # Store benchmark averages
    $latest = Get-LatestBenchmark
    if ($latest) {
        foreach ($b in $latest.Benchmarks) {
            $baseline.Benchmarks[$b.Operation] = @{
                GitAvgMs = $b.Git.AvgMs
                GixAvgMs = $b.Gix.AvgMs
                SpeedupFactor = $b.SpeedupFactor
            }
        }
    }

    $baseline | ConvertTo-Json -Depth 10 | Set-Content $BaselinePath -Encoding UTF8
    Write-Host "Baseline updated: $BaselinePath" -ForegroundColor Green

    return $baseline
}

function Test-Regression {
    param([int]$ThresholdPercent)

    if (-not (Test-Path $BaselinePath)) {
        Write-Warning "No baseline found. Run with -UpdateBaseline first."
        return $true  # No regression without baseline
    }

    $baseline = Get-Content $BaselinePath | ConvertFrom-Json
    $current = Get-LatestBenchmark

    if (-not $current) {
        Write-Warning "No benchmark results found."
        return $true
    }

    $regressions = @()

    foreach ($b in $current.Benchmarks) {
        $baselineOp = $baseline.Benchmarks.($b.Operation)
        if ($baselineOp) {
            $baselineGix = $baselineOp.GixAvgMs
            $currentGix = $b.Gix.AvgMs

            if ($baselineGix -gt 0) {
                $change = (($currentGix - $baselineGix) / $baselineGix) * 100

                if ($change -gt $ThresholdPercent) {
                    $regressions += @{
                        Operation = $b.Operation
                        BaselineMs = $baselineGix
                        CurrentMs = $currentGix
                        ChangePercent = [math]::Round($change, 1)
                    }
                }
            }
        }
    }

    if ($regressions.Count -gt 0) {
        Write-Host "`nPerformance Regressions Detected!" -ForegroundColor Red
        Write-Host ("-" * 60)
        foreach ($r in $regressions) {
            Write-Host ("{0}: {1}ms -> {2}ms (+{3}%)" -f $r.Operation, $r.BaselineMs, $r.CurrentMs, $r.ChangePercent) -ForegroundColor Red
        }
        return $false
    }

    Write-Host "No performance regressions detected." -ForegroundColor Green
    return $true
}

function Write-Report {
    $features = Get-FeatureStats
    $latest = Get-LatestBenchmark
    $baseline = if (Test-Path $BaselinePath) { Get-Content $BaselinePath | ConvertFrom-Json } else { $null }

    Write-Host "`n" + ("=" * 70) -ForegroundColor Cyan
    Write-Host "GITOXIDE STATUS REPORT" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan

    # Feature Progress
    Write-Host "`n[Feature Implementation Progress]" -ForegroundColor Yellow
    $parity = [math]::Round(($features.GixImplemented / $features.TotalFeatures) * 100, 1)
    $parityWithPartial = [math]::Round((($features.GixImplemented + $features.GixPartial) / $features.TotalFeatures) * 100, 1)

    Write-Host "  Total Features Tracked: $($features.TotalFeatures)"
    Write-Host "  Fully Implemented:      $($features.GixImplemented) ($parity%)"
    Write-Host "  Partially Implemented:  $($features.GixPartial)"
    Write-Host "  Missing:                $($features.GixMissing)"
    Write-Host "  Unique to Gix:          $($features.GixUnique)"
    Write-Host "  Overall Parity:         $parityWithPartial% (including partial)" -ForegroundColor $(if ($parityWithPartial -gt 50) { "Green" } else { "Yellow" })

    # Category breakdown
    Write-Host "`n[Category Breakdown]" -ForegroundColor Yellow
    foreach ($cat in $features.Categories.GetEnumerator() | Sort-Object { $_.Value.Implemented / [math]::Max(1, $_.Value.Total) } -Descending) {
        $catParity = [math]::Round(($cat.Value.Implemented / [math]::Max(1, $cat.Value.Total)) * 100)
        $bar = "[" + ("#" * [math]::Floor($catParity / 5)) + ("-" * (20 - [math]::Floor($catParity / 5))) + "]"
        Write-Host ("  {0,-30} {1} {2,3}%" -f $cat.Key, $bar, $catParity)
    }

    # Performance Summary
    if ($latest) {
        Write-Host "`n[Performance Summary]" -ForegroundColor Yellow
        Write-Host "  Benchmarks Run: $($latest.Benchmarks.Count)"

        $gixWins = ($latest.Benchmarks | Where-Object { $_.GixFaster }).Count
        $gitWins = $latest.Benchmarks.Count - $gixWins

        Write-Host "  Gix Faster: $gixWins operations"
        Write-Host "  Git Faster: $gitWins operations"

        # Best and worst
        $best = $latest.Benchmarks | Sort-Object SpeedupFactor -Descending | Select-Object -First 1
        $worst = $latest.Benchmarks | Sort-Object SpeedupFactor | Select-Object -First 1

        Write-Host "  Best:  $($best.Operation) ($($best.SpeedupFactor)x faster)"
        Write-Host "  Worst: $($worst.Operation) ($($worst.SpeedupFactor)x)"
    }

    # Trend (if baseline exists)
    if ($baseline) {
        Write-Host "`n[Trend vs Baseline]" -ForegroundColor Yellow
        Write-Host "  Baseline Date: $($baseline.Timestamp)"
        Write-Host "  Baseline Version: $($baseline.GitoxideVersion)"

        # Compare features
        $baselineFeatures = $baseline.Features.GixImplemented
        $currentFeatures = $features.GixImplemented
        $featureDiff = $currentFeatures - $baselineFeatures

        if ($featureDiff -gt 0) {
            Write-Host "  Features Added: +$featureDiff" -ForegroundColor Green
        } elseif ($featureDiff -lt 0) {
            Write-Host "  Features Changed: $featureDiff" -ForegroundColor Yellow
        }
    }

    Write-Host "`n" + ("=" * 70) -ForegroundColor Cyan
}

# Main execution
if ($UpdateBaseline) {
    Update-Baseline
}

if ($GenerateReport) {
    Write-Report
}

if ($CheckRegression) {
    $pass = Test-Regression -ThresholdPercent $Threshold
    if (-not $pass) {
        exit 1
    }
}

# Default: show report
if (-not $UpdateBaseline -and -not $GenerateReport -and -not $CheckRegression) {
    Write-Report
}
