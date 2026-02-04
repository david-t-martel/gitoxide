#Requires -Version 7.0
<#
.SYNOPSIS
    Comprehensive performance benchmark of all gix commands vs git equivalents.

.DESCRIPTION
    Tests every available gix command against its git equivalent, measuring:
    - Execution time (cold and warm cache)
    - Memory usage (peak working set)
    - CPU efficiency (user vs kernel time)
    - Output correctness

    Focuses on common, regular-use git commands.

.PARAMETER Repository
    Path to the git repository to benchmark.

.PARAMETER GixPath
    Path to the gix executable.

.PARAMETER Iterations
    Number of iterations for timing measurements.

.PARAMETER WarmupIterations
    Number of warmup iterations before measurement.

.EXAMPLE
    .\full_command_benchmark.ps1 -Repository "C:\codedev\gitoxide" -Iterations 5
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Repository = "C:\codedev\gitoxide",

    [Parameter()]
    [string]$GixPath = "C:\codedev\gitoxide\target\release\gix.exe",

    [Parameter()]
    [int]$Iterations = 3,

    [Parameter()]
    [int]$WarmupIterations = 1
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Measurement Functions
# ============================================================================

function Measure-Command-Full {
    param(
        [scriptblock]$Command,
        [int]$Iterations = 3,
        [int]$Warmup = 1
    )

    # Warmup
    for ($i = 0; $i -lt $Warmup; $i++) {
        try { & $Command 2>&1 | Out-Null } catch {}
    }

    $times = @()
    $peakMemory = 0

    for ($i = 0; $i -lt $Iterations; $i++) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $output = & $Command 2>&1
        } catch {
            $output = $_.Exception.Message
        }
        $sw.Stop()

        $times += $sw.Elapsed.TotalMilliseconds
    }

    return @{
        MinMs = [math]::Round(($times | Measure-Object -Minimum).Minimum, 2)
        MaxMs = [math]::Round(($times | Measure-Object -Maximum).Maximum, 2)
        AvgMs = [math]::Round(($times | Measure-Object -Average).Average, 2)
        Output = ($output | Out-String).Trim()
    }
}

function Get-ProcessMetrics {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkDir
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = $Arguments -join ' '
    $psi.WorkingDirectory = $WorkDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $process.Start() | Out-Null

    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()

    $process.WaitForExit()
    $sw.Stop()

    try {
        $peakMem = $process.PeakWorkingSet64
        $userTime = $process.UserProcessorTime.TotalMilliseconds
        $kernelTime = $process.PrivilegedProcessorTime.TotalMilliseconds
    } catch {
        $peakMem = 0
        $userTime = 0
        $kernelTime = 0
    }

    [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr))

    return @{
        ExitCode = $process.ExitCode
        TimeMs = $sw.Elapsed.TotalMilliseconds
        PeakMemoryMB = [math]::Round($peakMem / 1MB, 2)
        UserTimeMs = [math]::Round($userTime, 2)
        KernelTimeMs = [math]::Round($kernelTime, 2)
        Output = $stdout.Result
        Stderr = $stderr.Result
    }
}

# ============================================================================
# Command Definitions
# ============================================================================

# Map of common git commands to gix equivalents with test parameters
$CommandMap = @(
    # ---- HIGH PRIORITY: Most commonly used commands ----
    @{
        Name = "status"
        Priority = "HIGH"
        GitCmd = "status --short"
        GixCmd = "status --format simplified"
        Description = "Show working tree status"
    },
    @{
        Name = "status-porcelain"
        Priority = "HIGH"
        GitCmd = "status --porcelain=v2"
        GixCmd = "status --format porcelain-v2"
        Description = "Porcelain status output"
    },
    @{
        Name = "log-10"
        Priority = "HIGH"
        GitCmd = "log --oneline -10"
        GixCmd = "log"
        Description = "Show recent commits"
    },
    @{
        Name = "diff-head"
        Priority = "HIGH"
        GitCmd = "diff HEAD~1 HEAD --stat"
        GixCmd = "diff tree HEAD~1 HEAD"
        Description = "Diff between commits"
    },
    @{
        Name = "branch-list"
        Priority = "HIGH"
        GitCmd = "branch --list"
        GixCmd = "branch list"
        Description = "List branches"
    },
    @{
        Name = "rev-parse-HEAD"
        Priority = "HIGH"
        GitCmd = "rev-parse HEAD"
        GixCmd = "revision resolve HEAD"
        Description = "Resolve HEAD to SHA"
    },

    # ---- MEDIUM PRIORITY: Regularly used commands ----
    @{
        Name = "rev-list-all"
        Priority = "MEDIUM"
        GitCmd = "rev-list HEAD"
        GixCmd = "revision list"
        Description = "List all commits"
    },
    @{
        Name = "ls-files"
        Priority = "MEDIUM"
        GitCmd = "ls-files"
        GixCmd = "index entries"
        Description = "List tracked files"
    },
    @{
        Name = "cat-file-commit"
        Priority = "MEDIUM"
        GitCmd = "cat-file -p HEAD"
        GixCmd = "cat HEAD"
        Description = "Show commit object"
    },
    @{
        Name = "blame"
        Priority = "MEDIUM"
        GitCmd = "blame Cargo.toml"
        GixCmd = "blame Cargo.toml"
        Description = "Blame a file"
    },
    @{
        Name = "merge-base"
        Priority = "MEDIUM"
        GitCmd = "merge-base HEAD HEAD~10"
        GixCmd = "merge-base HEAD HEAD~10"
        Description = "Find merge base"
    },
    @{
        Name = "config-get"
        Priority = "MEDIUM"
        GitCmd = "config --get user.name"
        GixCmd = "config"
        Description = "Get config value"
    },
    @{
        Name = "remote-list"
        Priority = "MEDIUM"
        GitCmd = "remote -v"
        GixCmd = "remote list"
        Description = "List remotes"
    },
    @{
        Name = "tag-list"
        Priority = "MEDIUM"
        GitCmd = "tag -l"
        GixCmd = "tag list"
        Description = "List tags"
    },

    # ---- LOW PRIORITY: Less frequently used commands ----
    @{
        Name = "fsck"
        Priority = "LOW"
        GitCmd = "fsck --no-progress"
        GixCmd = "fsck"
        Description = "Check repository integrity"
    },
    @{
        Name = "verify"
        Priority = "LOW"
        GitCmd = "fsck --full --no-progress"
        GixCmd = "verify"
        Description = "Full repository verification"
    },
    @{
        Name = "ls-tree"
        Priority = "LOW"
        GitCmd = "ls-tree HEAD"
        GixCmd = "tree entries HEAD"
        Description = "List tree entries"
    },
    @{
        Name = "worktree-list"
        Priority = "LOW"
        GitCmd = "worktree list"
        GixCmd = "worktree list"
        Description = "List worktrees"
    },
    @{
        Name = "submodule-status"
        Priority = "LOW"
        GitCmd = "submodule status"
        GixCmd = "submodule list"
        Description = "Submodule status"
    },
    @{
        Name = "clean-dry"
        Priority = "LOW"
        GitCmd = "clean -n -d"
        GixCmd = "clean -n"
        Description = "Clean dry run"
    },
    @{
        Name = "commit-graph-verify"
        Priority = "LOW"
        GitCmd = "commit-graph verify"
        GixCmd = "commit-graph verify"
        Description = "Verify commit graph"
    }
)

# ============================================================================
# Results Collection
# ============================================================================

$Results = @()

function Write-BenchmarkHeader {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║              GIX vs GIT Full Command Performance Benchmark                     ║" -ForegroundColor Green
    Write-Host "╚═══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "Repository:  $Repository"
    Write-Host "GIX Path:    $GixPath"
    Write-Host "Iterations:  $Iterations (+ $WarmupIterations warmup)"
    Write-Host ""
}

function Run-Benchmark {
    param(
        [hashtable]$Command
    )

    Write-Host "─────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "[$($Command.Priority)] $($Command.Name): $($Command.Description)" -ForegroundColor Cyan

    # Run git command
    $gitResult = $null
    try {
        $gitArgs = @("-C", $Repository) + $Command.GitCmd.Split(' ')
        $gitResult = Get-ProcessMetrics -Executable "git" -Arguments $gitArgs -WorkDir $Repository
    } catch {
        $gitResult = @{ TimeMs = -1; PeakMemoryMB = 0; Error = $_.Exception.Message }
    }

    # Run gix command
    $gixResult = $null
    try {
        $gixArgs = @("-r", $Repository) + $Command.GixCmd.Split(' ')
        $gixResult = Get-ProcessMetrics -Executable $GixPath -Arguments $gixArgs -WorkDir $Repository
    } catch {
        $gixResult = @{ TimeMs = -1; PeakMemoryMB = 0; Error = $_.Exception.Message }
    }

    # Calculate ratios
    $timeRatio = if ($gitResult.TimeMs -gt 0 -and $gixResult.TimeMs -gt 0) {
        [math]::Round($gixResult.TimeMs / $gitResult.TimeMs, 2)
    } else { 0 }

    $memRatio = if ($gitResult.PeakMemoryMB -gt 0 -and $gixResult.PeakMemoryMB -gt 0) {
        [math]::Round($gixResult.PeakMemoryMB / $gitResult.PeakMemoryMB, 2)
    } else { 0 }

    # Determine status
    $status = if ($gixResult.TimeMs -lt 0) { "ERROR" }
              elseif ($timeRatio -lt 0.8) { "FASTER" }
              elseif ($timeRatio -le 1.2) { "SIMILAR" }
              elseif ($timeRatio -le 2.0) { "SLOWER" }
              else { "MUCH_SLOWER" }

    $statusColor = switch ($status) {
        "FASTER" { "Green" }
        "SIMILAR" { "White" }
        "SLOWER" { "Yellow" }
        "MUCH_SLOWER" { "Red" }
        "ERROR" { "Red" }
    }

    # Output results
    Write-Host "  git:  $([math]::Round($gitResult.TimeMs, 1).ToString().PadLeft(8))ms  |  Mem: $($gitResult.PeakMemoryMB.ToString().PadLeft(6))MB  |  User: $($gitResult.UserTimeMs.ToString().PadLeft(6))ms  Kernel: $($gitResult.KernelTimeMs.ToString().PadLeft(6))ms"
    Write-Host "  gix:  $([math]::Round($gixResult.TimeMs, 1).ToString().PadLeft(8))ms  |  Mem: $($gixResult.PeakMemoryMB.ToString().PadLeft(6))MB  |  User: $($gixResult.UserTimeMs.ToString().PadLeft(6))ms  Kernel: $($gixResult.KernelTimeMs.ToString().PadLeft(6))ms"
    Write-Host "  Ratio: ${timeRatio}x time, ${memRatio}x memory  [$status]" -ForegroundColor $statusColor

    return @{
        Name = $Command.Name
        Priority = $Command.Priority
        Description = $Command.Description
        GitTimeMs = [math]::Round($gitResult.TimeMs, 2)
        GixTimeMs = [math]::Round($gixResult.TimeMs, 2)
        TimeRatio = $timeRatio
        GitMemoryMB = $gitResult.PeakMemoryMB
        GixMemoryMB = $gixResult.PeakMemoryMB
        MemoryRatio = $memRatio
        GitUserMs = $gitResult.UserTimeMs
        GixUserMs = $gixResult.UserTimeMs
        GitKernelMs = $gitResult.KernelTimeMs
        GixKernelMs = $gixResult.KernelTimeMs
        Status = $status
        GitExitCode = $gitResult.ExitCode
        GixExitCode = $gixResult.ExitCode
    }
}

# ============================================================================
# Main Execution
# ============================================================================

Write-BenchmarkHeader

# Verify paths
if (-not (Test-Path $GixPath)) {
    Write-Host "[31mERROR: gix not found at $GixPath[0m"
    exit 1
}

if (-not (Test-Path $Repository)) {
    Write-Host "[31mERROR: Repository not found at $Repository[0m"
    exit 1
}

# Get repository stats
$commitCount = (git -C $Repository rev-list HEAD --count 2>$null)
$fileCount = (git -C $Repository ls-files 2>$null | Measure-Object).Count
Write-Host "Repository Stats: $commitCount commits, $fileCount files"
Write-Host ""

# Run benchmarks by priority
$priorities = @("HIGH", "MEDIUM", "LOW")

foreach ($priority in $priorities) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $priority PRIORITY COMMANDS" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

    $commands = $CommandMap | Where-Object { $_.Priority -eq $priority }

    foreach ($cmd in $commands) {
        $result = Run-Benchmark -Command $cmd
        $Results += $result
    }
}

# ============================================================================
# Summary & Analysis
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                          PERFORMANCE SUMMARY                                   ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# Performance breakdown
$faster = $Results | Where-Object { $_.Status -eq "FASTER" }
$similar = $Results | Where-Object { $_.Status -eq "SIMILAR" }
$slower = $Results | Where-Object { $_.Status -eq "SLOWER" }
$muchSlower = $Results | Where-Object { $_.Status -eq "MUCH_SLOWER" }
$errors = $Results | Where-Object { $_.Status -eq "ERROR" }

Write-Host "Performance Breakdown:" -ForegroundColor White
Write-Host "  Faster than git:   $($faster.Count)" -ForegroundColor Green
Write-Host "  Similar to git:    $($similar.Count)" -ForegroundColor White
Write-Host "  Slower than git:   $($slower.Count)" -ForegroundColor Yellow
Write-Host "  Much slower:       $($muchSlower.Count)" -ForegroundColor Red
Write-Host "  Errors:            $($errors.Count)" -ForegroundColor Red
Write-Host ""

# Commands needing optimization (HIGH priority that are slow)
$needsOptimization = $Results | Where-Object {
    $_.Priority -eq "HIGH" -and ($_.Status -eq "SLOWER" -or $_.Status -eq "MUCH_SLOWER")
}

if ($needsOptimization.Count -gt 0) {
    Write-Host "HIGH PRIORITY Commands Needing Optimization:" -ForegroundColor Red
    foreach ($cmd in $needsOptimization) {
        Write-Host "  - $($cmd.Name): ${$cmd.TimeRatio}x slower ($($cmd.GixTimeMs)ms vs $($cmd.GitTimeMs)ms)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Memory efficiency analysis
$memoryHogs = $Results | Where-Object { $_.MemoryRatio -gt 2.0 -and $_.GixMemoryMB -gt 10 }
if ($memoryHogs.Count -gt 0) {
    Write-Host "Commands with High Memory Usage:" -ForegroundColor Yellow
    foreach ($cmd in $memoryHogs) {
        Write-Host "  - $($cmd.Name): $($cmd.GixMemoryMB)MB (${$cmd.MemoryRatio}x git)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# CPU efficiency analysis
$kernelHeavy = $Results | Where-Object {
    $_.GixKernelMs -gt 0 -and ($_.GixKernelMs / ($_.GixUserMs + $_.GixKernelMs + 0.01)) -gt 0.5
}
if ($kernelHeavy.Count -gt 0) {
    Write-Host "Commands with High Kernel Time (I/O bound):" -ForegroundColor Yellow
    foreach ($cmd in $kernelHeavy) {
        $kernelPct = [math]::Round(($cmd.GixKernelMs / ($cmd.GixUserMs + $cmd.GixKernelMs + 0.01)) * 100, 1)
        Write-Host "  - $($cmd.Name): $kernelPct% kernel time ($($cmd.GixKernelMs)ms)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Best performing commands
$bestPerformers = $Results | Where-Object { $_.Status -eq "FASTER" } | Sort-Object TimeRatio
if ($bestPerformers.Count -gt 0) {
    Write-Host "Best Performing Commands (gix faster than git):" -ForegroundColor Green
    foreach ($cmd in $bestPerformers | Select-Object -First 5) {
        Write-Host "  - $($cmd.Name): $($cmd.TimeRatio)x (gix: $($cmd.GixTimeMs)ms, git: $($cmd.GitTimeMs)ms)" -ForegroundColor Green
    }
    Write-Host ""
}

# Export results
$resultsDir = Join-Path (Split-Path $PSScriptRoot) "results"
if (-not (Test-Path $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$jsonPath = Join-Path $resultsDir "full_benchmark_$timestamp.json"

$exportData = @{
    Timestamp = (Get-Date -Format "o")
    Repository = $Repository
    GixPath = $GixPath
    RepoStats = @{
        Commits = [int]$commitCount
        Files = $fileCount
    }
    Iterations = $Iterations
    Results = $Results
    Summary = @{
        Faster = $faster.Count
        Similar = $similar.Count
        Slower = $slower.Count
        MuchSlower = $muchSlower.Count
        Errors = $errors.Count
    }
}

$exportData | ConvertTo-Json -Depth 10 | Out-File $jsonPath -Encoding UTF8
Write-Host "Results saved to: $jsonPath" -ForegroundColor DarkGray
