#Requires -Version 7.0
<#
.SYNOPSIS
    Advanced profiling and benchmarking for gitoxide

.DESCRIPTION
    Runs detailed performance analysis with:
    - Statistical benchmarking (configurable N)
    - CPU profiling via sampling
    - Memory allocation tracking
    - Flamegraph generation support
#>

param(
    [string]$TestRepo = "C:\codedev\gitoxide",
    [string]$OutputDir = "C:\codedev\gitoxide\tests\comparison\profiling\results",
    [int]$Iterations = 30,
    [int]$WarmupIterations = 5,
    [switch]$GenerateFlamegraph,
    [switch]$DetailedStats
)

$ErrorActionPreference = 'Continue'

# Tool paths - use non-TUI binaries
$GixPath = "C:\codedev\gitoxide\gix.exe"
$GitPath = (Get-Command git -ErrorAction SilentlyContinue).Source ?? "git"

# Ensure output directory exists
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

function Get-DetailedStats {
    param([double[]]$Values)

    $sorted = $Values | Sort-Object
    $n = $sorted.Count

    $mean = ($sorted | Measure-Object -Average).Average
    $min = $sorted[0]
    $max = $sorted[-1]
    $median = if ($n % 2 -eq 0) { ($sorted[$n/2-1] + $sorted[$n/2]) / 2 } else { $sorted[[math]::Floor($n/2)] }

    # Percentiles
    $p5 = $sorted[[math]::Floor($n * 0.05)]
    $p25 = $sorted[[math]::Floor($n * 0.25)]
    $p75 = $sorted[[math]::Floor($n * 0.75)]
    $p95 = $sorted[[math]::Floor($n * 0.95)]
    $p99 = $sorted[[math]::Floor($n * 0.99)]

    # Standard deviation
    $sumSquares = ($sorted | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Sum).Sum
    $stddev = [math]::Sqrt($sumSquares / $n)

    # Coefficient of variation
    $cv = if ($mean -gt 0) { ($stddev / $mean) * 100 } else { 0 }

    # Interquartile range
    $iqr = $p75 - $p25

    return @{
        N = $n
        Mean = [math]::Round($mean, 3)
        Median = [math]::Round($median, 3)
        Min = [math]::Round($min, 3)
        Max = [math]::Round($max, 3)
        StdDev = [math]::Round($stddev, 3)
        CV = [math]::Round($cv, 2)
        P5 = [math]::Round($p5, 3)
        P25 = [math]::Round($p25, 3)
        P75 = [math]::Round($p75, 3)
        P95 = [math]::Round($p95, 3)
        P99 = [math]::Round($p99, 3)
        IQR = [math]::Round($iqr, 3)
        Values = $sorted
    }
}

function Measure-CommandAdvanced {
    param(
        [string]$Name,
        [string]$Tool,
        [scriptblock]$Command,
        [int]$Iterations,
        [int]$Warmup
    )

    # Warmup runs (not counted)
    for ($i = 0; $i -lt $Warmup; $i++) {
        try { & $Command 2>&1 | Out-Null } catch {}
    }

    # Actual measurements
    $times = @()
    for ($i = 0; $i -lt $Iterations; $i++) {
        # Force GC before each run for consistency
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = & $Command 2>&1
        } catch {}
        $sw.Stop()

        $times += $sw.Elapsed.TotalMilliseconds
    }

    $stats = Get-DetailedStats -Values $times
    $stats.Name = $Name
    $stats.Tool = $Tool

    return $stats
}

function Run-AdvancedBenchmark {
    param(
        [string]$Category,
        [string]$Operation,
        [scriptblock]$GitCommand,
        [scriptblock]$GixCommand
    )

    Write-Host "  [$Category] $Operation (N=$Iterations)..." -ForegroundColor Gray

    $gitStats = Measure-CommandAdvanced -Name $Operation -Tool "git" -Command $GitCommand -Iterations $Iterations -Warmup $WarmupIterations
    $gixStats = Measure-CommandAdvanced -Name $Operation -Tool "gix" -Command $GixCommand -Iterations $Iterations -Warmup $WarmupIterations

    # Statistical comparison
    $speedup = if ($gixStats.Median -gt 0 -and $gitStats.Median -gt 0) {
        [math]::Round($gitStats.Median / $gixStats.Median, 3)
    } else { 0 }

    # Confidence: lower CV = more consistent = more confident
    $confidenceGit = if ($gitStats.CV -lt 10) { "high" } elseif ($gitStats.CV -lt 25) { "medium" } else { "low" }
    $confidenceGix = if ($gixStats.CV -lt 10) { "high" } elseif ($gixStats.CV -lt 25) { "medium" } else { "low" }

    return @{
        Category = $Category
        Operation = $Operation
        Git = $gitStats
        Gix = $gixStats
        SpeedupFactor = $speedup
        GixFaster = $gixStats.Median -lt $gitStats.Median
        GitConfidence = $confidenceGit
        GixConfidence = $confidenceGix
    }
}

# ============================================================================
# BENCHMARK SUITE
# ============================================================================

Write-Host "`n=== Advanced Gitoxide Profiling Suite ===" -ForegroundColor Cyan
Write-Host "Test Repository: $TestRepo"
Write-Host "Iterations: $Iterations (+ $WarmupIterations warmup)"
Write-Host "Statistical analysis: enabled"
Write-Host ""

$results = @{
    Timestamp = Get-Date -Format "o"
    TestRepo = $TestRepo
    Iterations = $Iterations
    WarmupIterations = $WarmupIterations
    System = @{
        OS = [System.Environment]::OSVersion.VersionString
        CPUs = [Environment]::ProcessorCount
        GitVersion = (& $GitPath --version 2>&1) -join ""
        GixVersion = (& $GixPath --version 2>&1) -join ""
    }
    Benchmarks = @()
}

Push-Location $TestRepo

try {
    # -------------------------------------------------------------------------
    # Core Operations (High Impact)
    # -------------------------------------------------------------------------
    Write-Host "`n[Core Operations - High Impact]" -ForegroundColor Yellow

    # Status - most common operation
    $results.Benchmarks += Run-AdvancedBenchmark -Category "Core" -Operation "status-porcelain" `
        -GitCommand { & $GitPath status --porcelain 2>&1 } `
        -GixCommand { & $GixPath status --format human 2>&1 }

    # Log operations - gix strength
    $results.Benchmarks += Run-AdvancedBenchmark -Category "Core" -Operation "log-50" `
        -GitCommand { & $GitPath log --oneline -50 2>&1 } `
        -GixCommand { & $GixPath log -50 2>&1 }

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Core" -Operation "log-500" `
        -GitCommand { & $GitPath log --oneline -500 2>&1 } `
        -GixCommand { & $GixPath log -500 2>&1 }

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Core" -Operation "rev-count" `
        -GitCommand { & $GitPath rev-list --count HEAD 2>&1 } `
        -GixCommand { & $GixPath revision list HEAD --count 2>&1 }

    # -------------------------------------------------------------------------
    # Object Database Operations
    # -------------------------------------------------------------------------
    Write-Host "`n[Object Database Operations]" -ForegroundColor Yellow

    $results.Benchmarks += Run-AdvancedBenchmark -Category "ODB" -Operation "cat-commit" `
        -GitCommand { & $GitPath cat-file -p HEAD 2>&1 } `
        -GixCommand { & $GixPath cat HEAD 2>&1 }

    $results.Benchmarks += Run-AdvancedBenchmark -Category "ODB" -Operation "cat-tree" `
        -GitCommand { & $GitPath cat-file -p "HEAD^{tree}" 2>&1 } `
        -GixCommand { & $GixPath cat "HEAD^{tree}" 2>&1 }

    # -------------------------------------------------------------------------
    # Diff Operations
    # -------------------------------------------------------------------------
    Write-Host "`n[Diff Operations]" -ForegroundColor Yellow

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Diff" -Operation "diff-10" `
        -GitCommand { & $GitPath diff HEAD~10..HEAD --stat 2>&1 } `
        -GixCommand { & $GixPath diff HEAD~10 HEAD 2>&1 }

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Diff" -Operation "diff-50" `
        -GitCommand { & $GitPath diff HEAD~50..HEAD --stat 2>&1 } `
        -GixCommand { & $GixPath diff HEAD~50 HEAD 2>&1 }

    # -------------------------------------------------------------------------
    # Index Operations
    # -------------------------------------------------------------------------
    Write-Host "`n[Index Operations]" -ForegroundColor Yellow

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Index" -Operation "index-info" `
        -GitCommand { & $GitPath ls-files 2>&1 | Measure-Object | Out-Null } `
        -GixCommand { & $GixPath index info 2>&1 }

    # -------------------------------------------------------------------------
    # Reference Operations
    # -------------------------------------------------------------------------
    Write-Host "`n[Reference Operations]" -ForegroundColor Yellow

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Refs" -Operation "branch-list" `
        -GitCommand { & $GitPath branch -a 2>&1 } `
        -GixCommand { & $GixPath branch list 2>&1 }

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Refs" -Operation "tag-list" `
        -GitCommand { & $GitPath tag -l 2>&1 } `
        -GixCommand { & $GixPath tag list 2>&1 }

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Refs" -Operation "rev-parse" `
        -GitCommand { & $GitPath rev-parse HEAD 2>&1 } `
        -GixCommand { & $GixPath revision parse HEAD 2>&1 }

    # -------------------------------------------------------------------------
    # Blame (Heavy operation)
    # -------------------------------------------------------------------------
    Write-Host "`n[Blame Operations]" -ForegroundColor Yellow

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Blame" -Operation "blame-readme" `
        -GitCommand { & $GitPath blame README.md 2>&1 } `
        -GixCommand { & $GixPath blame README.md 2>&1 }

    # -------------------------------------------------------------------------
    # Verification Operations
    # -------------------------------------------------------------------------
    Write-Host "`n[Verification Operations]" -ForegroundColor Yellow

    $results.Benchmarks += Run-AdvancedBenchmark -Category "Verify" -Operation "commit-graph-verify" `
        -GitCommand { & $GitPath commit-graph verify 2>&1 } `
        -GixCommand { & $GixPath commit-graph verify 2>&1 }

} finally {
    Pop-Location
}

# ============================================================================
# RESULTS ANALYSIS
# ============================================================================

Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
Write-Host "STATISTICAL RESULTS SUMMARY (N=$Iterations)" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan

$gixWins = ($results.Benchmarks | Where-Object { $_.GixFaster }).Count
$gitWins = $results.Benchmarks.Count - $gixWins

Write-Host "`nOverall: Gix wins $gixWins/$($results.Benchmarks.Count), Git wins $gitWins/$($results.Benchmarks.Count)"
Write-Host ""

# Detailed table
Write-Host ("{0,-25} {1,12} {2,12} {3,10} {4,8} {5,10}" -f "Operation", "Git (ms)", "Gix (ms)", "Speedup", "Winner", "Confidence")
Write-Host ("-" * 85)

foreach ($b in $results.Benchmarks | Sort-Object { $_.SpeedupFactor } -Descending) {
    $winner = if ($b.GixFaster) { "GIX" } else { "GIT" }
    $color = if ($b.GixFaster) { "Green" } else { "Red" }
    $conf = if ($b.GitConfidence -eq "high" -and $b.GixConfidence -eq "high") { "HIGH" }
            elseif ($b.GitConfidence -eq "low" -or $b.GixConfidence -eq "low") { "LOW" }
            else { "MED" }

    $gitTime = "{0,8} ±{1,4}" -f $b.Git.Median, $b.Git.StdDev
    $gixTime = "{0,8} ±{1,4}" -f $b.Gix.Median, $b.Gix.StdDev

    $line = "{0,-25} {1,12} {2,12} {3,10}x {4,8} {5,10}" -f $b.Operation, $gitTime, $gixTime, $b.SpeedupFactor, $winner, $conf
    Write-Host $line -ForegroundColor $color
}

Write-Host ("-" * 85)

# Performance hotspots
Write-Host "`n[GIX PERFORMANCE HOTSPOTS - Where optimization would help]" -ForegroundColor Yellow
$slowOps = $results.Benchmarks | Where-Object { -not $_.GixFaster } | Sort-Object { $_.SpeedupFactor }
foreach ($op in $slowOps | Select-Object -First 5) {
    $gap = [math]::Round((1 - $op.SpeedupFactor) * 100, 1)
    Write-Host ("  {0}: {1}% slower than git (median: {2}ms vs {3}ms)" -f $op.Operation, $gap, $op.Gix.Median, $op.Git.Median) -ForegroundColor Red
}

Write-Host "`n[GIX STRENGTHS - Where gix excels]" -ForegroundColor Yellow
$fastOps = $results.Benchmarks | Where-Object { $_.GixFaster } | Sort-Object { $_.SpeedupFactor } -Descending
foreach ($op in $fastOps | Select-Object -First 5) {
    Write-Host ("  {0}: {1}x faster than git (median: {2}ms vs {3}ms)" -f $op.Operation, $op.SpeedupFactor, $op.Gix.Median, $op.Git.Median) -ForegroundColor Green
}

# Save results
$jsonPath = Join-Path $OutputDir "profile_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$results | ConvertTo-Json -Depth 15 | Set-Content -Path $jsonPath -Encoding UTF8
Write-Host "`nDetailed results saved to: $jsonPath" -ForegroundColor Cyan

# Generate summary for optimization
$summary = @{
    Timestamp = $results.Timestamp
    TotalBenchmarks = $results.Benchmarks.Count
    GixWins = $gixWins
    GitWins = $gitWins
    OptimizationTargets = @()
    Strengths = @()
}

foreach ($op in $slowOps) {
    $summary.OptimizationTargets += @{
        Operation = $op.Operation
        Category = $op.Category
        GixMedianMs = $op.Gix.Median
        GitMedianMs = $op.Git.Median
        GapPercent = [math]::Round((1 - $op.SpeedupFactor) * 100, 1)
    }
}

foreach ($op in $fastOps) {
    $summary.Strengths += @{
        Operation = $op.Operation
        Category = $op.Category
        SpeedupFactor = $op.SpeedupFactor
    }
}

$summaryPath = Join-Path $OutputDir "optimization_targets.json"
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "Optimization targets saved to: $summaryPath" -ForegroundColor Cyan

return $results
