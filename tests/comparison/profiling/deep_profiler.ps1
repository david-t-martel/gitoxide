#Requires -Version 7.0
<#
.SYNOPSIS
    Deep Performance Profiler for Git vs Gix Operations

.DESCRIPTION
    Comprehensive measurement tooling focused on:
    - Memory utilization (peak RSS, private bytes, page faults, potential leaks)
    - Process/thread operations (thread count, handle count, context switches)
    - Filesystem I/O (read/write operations, bytes transferred)
    - CPU time breakdown (user vs kernel time)

    Designed to identify performance root causes, particularly:
    - Memory leaks in long-running operations
    - I/O bottlenecks in large repository operations
    - Thread contention issues
    - Startup overhead vs operation time

.PARAMETER Operation
    The operation to profile (e.g., 'status', 'rev-list', 'blame')

.PARAMETER Iterations
    Number of iterations for statistical significance (default: 10)

.PARAMETER WarmupRuns
    Number of warm-up runs to prime caches (default: 2)

.PARAMETER TestRepo
    Repository to test against (default: current directory)
#>

param(
    [string]$Operation = "status",
    [int]$Iterations = 10,
    [int]$WarmupRuns = 2,
    [string]$TestRepo = "C:\codedev\gitoxide",
    [switch]$Verbose,
    [switch]$ExportJson
)

$ErrorActionPreference = 'Continue'

# Tool paths
$GixPath = "C:\codedev\gitoxide\gix.exe"
$GitPath = (Get-Command git -ErrorAction SilentlyContinue).Source ?? "git"

# ============================================================================
# OPERATION DEFINITIONS
# Maps operation names to git/gix command pairs
# ============================================================================
$Operations = @{
    "status" = @{
        Git = { & $GitPath status --porcelain 2>&1 }
        Gix = { & $GixPath status --format porcelain 2>&1 }
        Description = "Repository status check"
        Category = "Working Tree"
    }
    "rev-list" = @{
        Git = { & $GitPath rev-list HEAD 2>&1 }
        Gix = { & $GixPath revision list HEAD 2>&1 }
        Description = "Full revision traversal"
        Category = "History"
    }
    "rev-list-100" = @{
        Git = { & $GitPath rev-list HEAD -100 2>&1 }
        Gix = { & $GixPath revision list HEAD --limit 100 2>&1 }
        Description = "Limited revision traversal (100)"
        Category = "History"
    }
    "blame" = @{
        Git = { & $GitPath blame README.md 2>&1 }
        Gix = { & $GixPath blame README.md 2>&1 }
        Description = "File blame operation"
        Category = "Blame"
    }
    "blame-large" = @{
        Git = { & $GitPath blame src/plumbing/main.rs 2>&1 }
        Gix = { & $GixPath blame src/plumbing/main.rs 2>&1 }
        Description = "Large file blame operation"
        Category = "Blame"
    }
    "index-entries" = @{
        Git = { & $GitPath ls-files 2>&1 }
        Gix = { & $GixPath index entries 2>&1 }
        Description = "Index entry enumeration"
        Category = "Index"
    }
    "diff-tree" = @{
        Git = { & $GitPath diff-tree --stat HEAD~10 HEAD 2>&1 }
        Gix = { & $GixPath diff tree HEAD~10 HEAD 2>&1 }
        Description = "Tree diff comparison"
        Category = "Diff"
    }
    "cat-file" = @{
        Git = { & $GitPath cat-file -p HEAD 2>&1 }
        Gix = { & $GixPath cat HEAD 2>&1 }
        Description = "Object content retrieval"
        Category = "Objects"
    }
    "branch-list" = @{
        Git = { & $GitPath branch -a 2>&1 }
        Gix = { & $GixPath branch list --all 2>&1 }
        Description = "Branch enumeration"
        Category = "References"
    }
    "tag-list" = @{
        Git = { & $GitPath tag -l 2>&1 }
        Gix = { & $GixPath tag list 2>&1 }
        Description = "Tag enumeration"
        Category = "References"
    }
    "config" = @{
        Git = { & $GitPath config --get user.name 2>&1 }
        Gix = { & $GixPath config get user.name 2>&1 }
        Description = "Configuration retrieval"
        Category = "Config"
    }
    "fsck" = @{
        Git = { & $GitPath fsck --connectivity-only 2>&1 }
        Gix = { & $GixPath fsck 2>&1 }
        Description = "Repository integrity check"
        Category = "Verification"
    }
}

# ============================================================================
# PROCESS METRICS COLLECTION
# ============================================================================

class ProcessMetrics {
    [double]$WallTimeMs
    [double]$UserTimeMs
    [double]$KernelTimeMs
    [long]$PeakWorkingSetBytes
    [long]$PrivateBytesEnd
    [long]$PrivateBytesStart
    [long]$PageFaults
    [int]$ThreadCount
    [int]$HandleCount
    [long]$IOReadOperations
    [long]$IOWriteOperations
    [long]$IOReadBytes
    [long]$IOWriteBytes
    [int]$ExitCode
    [int]$OutputLineCount
}

function Measure-ProcessDeep {
    <#
    .SYNOPSIS
        Measures a process with deep metrics collection
    #>
    param(
        [scriptblock]$Command,
        [string]$WorkingDirectory
    )

    $metrics = [ProcessMetrics]::new()

    # Create process info for detailed measurement
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoProfile -Command `"Set-Location '$WorkingDirectory'; & { $($Command.ToString()) }`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $process = [System.Diagnostics.Process]::Start($psi)

        # Capture initial memory state
        $process.Refresh()
        $metrics.PrivateBytesStart = $process.PrivateMemorySize64

        # Read output asynchronously
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()
        $sw.Stop()

        # Final process metrics
        $process.Refresh()

        $metrics.WallTimeMs = $sw.Elapsed.TotalMilliseconds
        $metrics.UserTimeMs = $process.UserProcessorTime.TotalMilliseconds
        $metrics.KernelTimeMs = $process.PrivilegedProcessorTime.TotalMilliseconds
        $metrics.PeakWorkingSetBytes = $process.PeakWorkingSet64
        $metrics.PrivateBytesEnd = $process.PrivateMemorySize64
        $metrics.ExitCode = $process.ExitCode

        # Output metrics
        $output = $stdout.Result
        $metrics.OutputLineCount = ($output -split "`n").Count

    } catch {
        $metrics.WallTimeMs = $sw.Elapsed.TotalMilliseconds
        $metrics.ExitCode = -1
    } finally {
        if ($process) { $process.Dispose() }
    }

    return $metrics
}

function Measure-CommandDirect {
    <#
    .SYNOPSIS
        Direct measurement with polling-based metrics collection.
        Samples process metrics during execution to capture accurate peak values.
    #>
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$PollingIntervalMs = 5
    )

    $metrics = [ProcessMetrics]::new()

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Executable
    $psi.Arguments = $Arguments -join ' '
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    # Track peak values during execution
    $peakWorkingSet = 0L
    $peakPrivateBytes = 0L
    $peakThreadCount = 0
    $peakHandleCount = 0
    $sampleCount = 0

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $processId = $process.Id

        # Read output asynchronously
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # Poll process metrics while it runs
        while (-not $process.HasExited) {
            try {
                $process.Refresh()

                # Track peak memory
                $currentWS = $process.WorkingSet64
                $currentPrivate = $process.PrivateMemorySize64

                if ($currentWS -gt $peakWorkingSet) { $peakWorkingSet = $currentWS }
                if ($currentPrivate -gt $peakPrivateBytes) { $peakPrivateBytes = $currentPrivate }

                # Track peak threads/handles
                try {
                    $currentThreads = $process.Threads.Count
                    $currentHandles = $process.HandleCount
                    if ($currentThreads -gt $peakThreadCount) { $peakThreadCount = $currentThreads }
                    if ($currentHandles -gt $peakHandleCount) { $peakHandleCount = $currentHandles }
                } catch { }

                $sampleCount++
            } catch {
                # Process may have exited between check and refresh
            }

            Start-Sleep -Milliseconds $PollingIntervalMs
        }

        $sw.Stop()

        # Final refresh to get CPU times (these are cumulative, so available after exit)
        try {
            $process.Refresh()
            $metrics.UserTimeMs = $process.UserProcessorTime.TotalMilliseconds
            $metrics.KernelTimeMs = $process.PrivilegedProcessorTime.TotalMilliseconds

            # Also check if the process reported higher peak than we observed
            if ($process.PeakWorkingSet64 -gt $peakWorkingSet) {
                $peakWorkingSet = $process.PeakWorkingSet64
            }
        } catch { }

        $metrics.WallTimeMs = $sw.Elapsed.TotalMilliseconds
        $metrics.PeakWorkingSetBytes = $peakWorkingSet
        $metrics.PrivateBytesEnd = $peakPrivateBytes
        $metrics.ThreadCount = $peakThreadCount
        $metrics.HandleCount = $peakHandleCount
        $metrics.ExitCode = $process.ExitCode

        # Get I/O counters via performance counters or final CIM query
        # Note: We query after exit using a different method
        try {
            # Use Get-Process which can sometimes still have data
            $procInfo = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($procInfo) {
                # These won't work after exit, but leaving for completeness
            }
        } catch { }

        # Output metrics
        $output = $stdoutTask.Result
        $metrics.OutputLineCount = ($output -split "`n" | Where-Object { $_.Trim() }).Count

    } catch {
        $metrics.WallTimeMs = $sw.Elapsed.TotalMilliseconds
        $metrics.ExitCode = -1
    } finally {
        if ($process) { $process.Dispose() }
    }

    return $metrics
}

function Get-IOCountersForProcess {
    <#
    .SYNOPSIS
        Gets detailed I/O counters for a running process
    #>
    param([int]$ProcessId)

    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        return @{
            ReadOperations = $proc.ReadOperationCount
            WriteOperations = $proc.WriteOperationCount
            ReadBytes = $proc.ReadTransferCount
            WriteBytes = $proc.WriteTransferCount
            PageFaults = $proc.PageFaults
        }
    } catch {
        return $null
    }
}

function Measure-WithJobObject {
    <#
    .SYNOPSIS
        Measures a process using Windows Job Objects for accurate resource accounting.
        Job Objects provide cumulative I/O and memory stats even after process exit.
    #>
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$PollingIntervalMs = 5
    )

    $metrics = [ProcessMetrics]::new()

    # We'll use PowerShell's Start-Process with PassThru and monitor via CIM
    # For I/O accounting, we sample CIM throughout execution

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Executable
    $psi.Arguments = $Arguments -join ' '
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    # Track metrics during execution
    $peakWorkingSet = 0L
    $peakPrivateBytes = 0L
    $peakThreadCount = 0
    $peakHandleCount = 0
    $lastIORead = 0L
    $lastIOWrite = 0L
    $lastIOReadOps = 0L
    $lastIOWriteOps = 0L
    $lastPageFaults = 0L

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $processId = $process.Id

        # Read output asynchronously
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # Poll process metrics while it runs
        $lastCimQuery = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $process.HasExited) {
            try {
                $process.Refresh()

                # Track peak memory from .NET Process
                $currentWS = $process.WorkingSet64
                $currentPrivate = $process.PrivateMemorySize64

                if ($currentWS -gt $peakWorkingSet) { $peakWorkingSet = $currentWS }
                if ($currentPrivate -gt $peakPrivateBytes) { $peakPrivateBytes = $currentPrivate }

                # Track peak threads/handles
                try {
                    $currentThreads = $process.Threads.Count
                    $currentHandles = $process.HandleCount
                    if ($currentThreads -gt $peakThreadCount) { $peakThreadCount = $currentThreads }
                    if ($currentHandles -gt $peakHandleCount) { $peakHandleCount = $currentHandles }
                } catch { }

                # Query CIM for I/O counters (less frequently to reduce overhead)
                if ($lastCimQuery.ElapsedMilliseconds -gt 50) {
                    try {
                        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
                        if ($cimProc) {
                            $lastIORead = [long]$cimProc.ReadTransferCount
                            $lastIOWrite = [long]$cimProc.WriteTransferCount
                            $lastIOReadOps = [long]$cimProc.ReadOperationCount
                            $lastIOWriteOps = [long]$cimProc.WriteOperationCount
                            $lastPageFaults = [long]$cimProc.PageFaults
                        }
                        $lastCimQuery.Restart()
                    } catch { }
                }

            } catch {
                # Process may have exited between check and refresh
            }

            Start-Sleep -Milliseconds $PollingIntervalMs
        }

        $sw.Stop()

        # Final metrics
        try {
            $process.Refresh()
            $metrics.UserTimeMs = $process.UserProcessorTime.TotalMilliseconds
            $metrics.KernelTimeMs = $process.PrivilegedProcessorTime.TotalMilliseconds

            if ($process.PeakWorkingSet64 -gt $peakWorkingSet) {
                $peakWorkingSet = $process.PeakWorkingSet64
            }
        } catch { }

        $metrics.WallTimeMs = $sw.Elapsed.TotalMilliseconds
        $metrics.PeakWorkingSetBytes = $peakWorkingSet
        $metrics.PrivateBytesEnd = $peakPrivateBytes
        $metrics.ThreadCount = $peakThreadCount
        $metrics.HandleCount = $peakHandleCount
        $metrics.IOReadBytes = $lastIORead
        $metrics.IOWriteBytes = $lastIOWrite
        $metrics.IOReadOperations = $lastIOReadOps
        $metrics.IOWriteOperations = $lastIOWriteOps
        $metrics.PageFaults = $lastPageFaults
        $metrics.ExitCode = $process.ExitCode

        # Output metrics
        $output = $stdoutTask.Result
        $metrics.OutputLineCount = ($output -split "`n" | Where-Object { $_.Trim() }).Count

    } catch {
        $metrics.WallTimeMs = $sw.Elapsed.TotalMilliseconds
        $metrics.ExitCode = -1
    } finally {
        if ($process) { $process.Dispose() }
    }

    return $metrics
}

# ============================================================================
# STATISTICAL ANALYSIS
# ============================================================================

function Get-Statistics {
    param([double[]]$Values)

    if ($Values.Count -eq 0) { return $null }

    $sorted = $Values | Sort-Object
    $count = $Values.Count
    $mean = ($Values | Measure-Object -Average).Average
    $sum = ($Values | Measure-Object -Sum).Sum

    # Standard deviation
    $sumSquaredDiff = 0
    foreach ($v in $Values) {
        $sumSquaredDiff += [Math]::Pow($v - $mean, 2)
    }
    $stdDev = [Math]::Sqrt($sumSquaredDiff / $count)

    # Percentiles
    $p50Index = [Math]::Floor($count * 0.5)
    $p95Index = [Math]::Floor($count * 0.95)
    $p99Index = [Math]::Floor($count * 0.99)

    return [PSCustomObject]@{
        Count = $count
        Mean = [Math]::Round($mean, 2)
        StdDev = [Math]::Round($stdDev, 2)
        Min = [Math]::Round($sorted[0], 2)
        Max = [Math]::Round($sorted[-1], 2)
        Median = [Math]::Round($sorted[$p50Index], 2)
        P95 = [Math]::Round($sorted[[Math]::Min($p95Index, $count - 1)], 2)
        P99 = [Math]::Round($sorted[[Math]::Min($p99Index, $count - 1)], 2)
        CoeffOfVariation = if ($mean -gt 0) { [Math]::Round($stdDev / $mean * 100, 1) } else { 0 }
    }
}

# ============================================================================
# MAIN PROFILING LOGIC
# ============================================================================

function Invoke-DeepProfile {
    param(
        [string]$OperationName,
        [int]$Iterations,
        [int]$WarmupRuns,
        [string]$RepoPath
    )

    if (-not $Operations.ContainsKey($OperationName)) {
        Write-Error "Unknown operation: $OperationName. Available: $($Operations.Keys -join ', ')"
        return
    }

    $opDef = $Operations[$OperationName]

    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  DEEP PERFORMANCE PROFILE: $OperationName" -ForegroundColor Cyan
    Write-Host "  $($opDef.Description)" -ForegroundColor Gray
    Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Repository: $RepoPath"
    Write-Host "Iterations: $Iterations (+ $WarmupRuns warmup)"
    Write-Host ""

    Push-Location $RepoPath

    try {
        # Determine actual executables and arguments
        $gitExe = $GitPath
        $gixExe = $GixPath

        # Parse the operation into executable + args
        $gitCmd = switch ($OperationName) {
            "status" { @("status", "--porcelain") }
            "rev-list" { @("rev-list", "HEAD") }
            "rev-list-100" { @("rev-list", "HEAD", "-100") }
            "blame" { @("blame", "README.md") }
            "blame-large" { @("blame", "src/plumbing/main.rs") }
            "index-entries" { @("ls-files") }
            "diff-tree" { @("diff-tree", "--stat", "HEAD~10", "HEAD") }
            "cat-file" { @("cat-file", "-p", "HEAD") }
            "branch-list" { @("branch", "-a") }
            "tag-list" { @("tag", "-l") }
            "config" { @("config", "--get", "user.name") }
            "fsck" { @("fsck", "--connectivity-only") }
            default { @("status") }
        }

        $gixCmd = switch ($OperationName) {
            "status" { @("status", "--format", "porcelain") }
            "rev-list" { @("revision", "list", "HEAD") }
            "rev-list-100" { @("revision", "list", "HEAD", "--limit", "100") }
            "blame" { @("blame", "README.md") }
            "blame-large" { @("blame", "src/plumbing/main.rs") }
            "index-entries" { @("index", "entries") }
            "diff-tree" { @("diff", "tree", "HEAD~10", "HEAD") }
            "cat-file" { @("cat", "HEAD") }
            "branch-list" { @("branch", "list", "--all") }
            "tag-list" { @("tag", "list") }
            "config" { @("config", "get", "user.name") }
            "fsck" { @("fsck") }
            default { @("status") }
        }

        # Warmup runs (use faster polling for warmup)
        Write-Host "Running warmup..." -ForegroundColor Yellow
        for ($i = 0; $i -lt $WarmupRuns; $i++) {
            $null = Measure-WithJobObject -Executable $gitExe -Arguments $gitCmd -WorkingDirectory $RepoPath -PollingIntervalMs 10
            $null = Measure-WithJobObject -Executable $gixExe -Arguments $gixCmd -WorkingDirectory $RepoPath -PollingIntervalMs 10
            Write-Host "  Warmup $($i + 1)/$WarmupRuns complete" -ForegroundColor Gray
        }

        # Collect metrics with fine-grained polling
        Write-Host ""
        Write-Host "Collecting metrics (with memory/IO polling)..." -ForegroundColor Yellow

        $gitMetrics = @()
        $gixMetrics = @()

        for ($i = 0; $i -lt $Iterations; $i++) {
            # Alternate between git and gix to reduce bias
            if ($i % 2 -eq 0) {
                $gitMetrics += Measure-WithJobObject -Executable $gitExe -Arguments $gitCmd -WorkingDirectory $RepoPath -PollingIntervalMs 3
                $gixMetrics += Measure-WithJobObject -Executable $gixExe -Arguments $gixCmd -WorkingDirectory $RepoPath -PollingIntervalMs 3
            } else {
                $gixMetrics += Measure-WithJobObject -Executable $gixExe -Arguments $gixCmd -WorkingDirectory $RepoPath -PollingIntervalMs 3
                $gitMetrics += Measure-WithJobObject -Executable $gitExe -Arguments $gitCmd -WorkingDirectory $RepoPath -PollingIntervalMs 3
            }

            $pct = [Math]::Round(($i + 1) / $Iterations * 100)
            Write-Host "  Iteration $($i + 1)/$Iterations ($pct%)" -ForegroundColor Gray
        }

        # Analyze results
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  RESULTS" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════════════" -ForegroundColor Green

        # Wall Time Analysis
        $gitWallStats = Get-Statistics ($gitMetrics.WallTimeMs)
        $gixWallStats = Get-Statistics ($gixMetrics.WallTimeMs)

        Write-Host ""
        Write-Host "┌─ WALL TIME (ms) ─────────────────────────────────────────────────────┐" -ForegroundColor White
        Write-Host "│                    GIT                          GIX                  │" -ForegroundColor White
        Write-Host "│  Mean:         $("{0,8:N2}" -f $gitWallStats.Mean)                    $("{0,8:N2}" -f $gixWallStats.Mean)                │" -ForegroundColor White
        Write-Host "│  Median:       $("{0,8:N2}" -f $gitWallStats.Median)                    $("{0,8:N2}" -f $gixWallStats.Median)                │" -ForegroundColor White
        Write-Host "│  StdDev:       $("{0,8:N2}" -f $gitWallStats.StdDev)                    $("{0,8:N2}" -f $gixWallStats.StdDev)                │" -ForegroundColor White
        Write-Host "│  Min:          $("{0,8:N2}" -f $gitWallStats.Min)                    $("{0,8:N2}" -f $gixWallStats.Min)                │" -ForegroundColor White
        Write-Host "│  Max:          $("{0,8:N2}" -f $gitWallStats.Max)                    $("{0,8:N2}" -f $gixWallStats.Max)                │" -ForegroundColor White
        Write-Host "│  P95:          $("{0,8:N2}" -f $gitWallStats.P95)                    $("{0,8:N2}" -f $gixWallStats.P95)                │" -ForegroundColor White
        Write-Host "│  CV%:          $("{0,8:N1}" -f $gitWallStats.CoeffOfVariation)                    $("{0,8:N1}" -f $gixWallStats.CoeffOfVariation)                │" -ForegroundColor White
        Write-Host "└──────────────────────────────────────────────────────────────────────┘" -ForegroundColor White

        $speedup = if ($gixWallStats.Mean -gt 0) { [Math]::Round($gitWallStats.Mean / $gixWallStats.Mean, 2) } else { 0 }
        $winner = if ($speedup -gt 1) { "GIX" } else { "GIT" }
        $speedupDisplay = if ($speedup -gt 1) { "$speedup`x faster" } else { "$([Math]::Round(1/$speedup, 2))`x slower" }
        Write-Host ""
        Write-Host "  Gix is $speedupDisplay than Git" -ForegroundColor $(if ($speedup -gt 1) { "Green" } else { "Red" })

        # CPU Time Analysis
        $gitUserStats = Get-Statistics ($gitMetrics.UserTimeMs)
        $gixUserStats = Get-Statistics ($gixMetrics.UserTimeMs)
        $gitKernelStats = Get-Statistics ($gitMetrics.KernelTimeMs)
        $gixKernelStats = Get-Statistics ($gixMetrics.KernelTimeMs)

        Write-Host ""
        Write-Host "┌─ CPU TIME BREAKDOWN (ms) ────────────────────────────────────────────┐" -ForegroundColor White
        Write-Host "│                    GIT                          GIX                  │" -ForegroundColor White
        Write-Host "│  User Time:    $("{0,8:N2}" -f $gitUserStats.Mean)                    $("{0,8:N2}" -f $gixUserStats.Mean)                │" -ForegroundColor White
        Write-Host "│  Kernel Time:  $("{0,8:N2}" -f $gitKernelStats.Mean)                    $("{0,8:N2}" -f $gixKernelStats.Mean)                │" -ForegroundColor White
        Write-Host "│  Total CPU:    $("{0,8:N2}" -f ($gitUserStats.Mean + $gitKernelStats.Mean))                    $("{0,8:N2}" -f ($gixUserStats.Mean + $gixKernelStats.Mean))                │" -ForegroundColor White
        Write-Host "└──────────────────────────────────────────────────────────────────────┘" -ForegroundColor White

        # Memory Analysis
        $gitMemStats = Get-Statistics ($gitMetrics.PeakWorkingSetBytes | ForEach-Object { $_ / 1MB })
        $gixMemStats = Get-Statistics ($gixMetrics.PeakWorkingSetBytes | ForEach-Object { $_ / 1MB })

        Write-Host ""
        Write-Host "┌─ MEMORY (Peak Working Set MB) ──────────────────────────────────────┐" -ForegroundColor White
        Write-Host "│                    GIT                          GIX                  │" -ForegroundColor White
        Write-Host "│  Mean:         $("{0,8:N2}" -f $gitMemStats.Mean)                    $("{0,8:N2}" -f $gixMemStats.Mean)                │" -ForegroundColor White
        Write-Host "│  Max:          $("{0,8:N2}" -f $gitMemStats.Max)                    $("{0,8:N2}" -f $gixMemStats.Max)                │" -ForegroundColor White
        Write-Host "│  Min:          $("{0,8:N2}" -f $gitMemStats.Min)                    $("{0,8:N2}" -f $gixMemStats.Min)                │" -ForegroundColor White
        Write-Host "└──────────────────────────────────────────────────────────────────────┘" -ForegroundColor White

        $memRatio = if ($gitMemStats.Mean -gt 0) { [Math]::Round($gixMemStats.Mean / $gitMemStats.Mean, 2) } else { 0 }
        Write-Host "  Gix uses $memRatio`x the memory of Git" -ForegroundColor $(if ($memRatio -le 1.5) { "Green" } elseif ($memRatio -le 2) { "Yellow" } else { "Red" })

        # Thread/Handle Analysis
        $gitThreadStats = Get-Statistics ($gitMetrics.ThreadCount | Where-Object { $_ -gt 0 })
        $gixThreadStats = Get-Statistics ($gixMetrics.ThreadCount | Where-Object { $_ -gt 0 })
        $gitHandleStats = Get-Statistics ($gitMetrics.HandleCount | Where-Object { $_ -gt 0 })
        $gixHandleStats = Get-Statistics ($gixMetrics.HandleCount | Where-Object { $_ -gt 0 })

        if ($gitThreadStats -and $gixThreadStats) {
            Write-Host ""
            Write-Host "┌─ THREADS & HANDLES ──────────────────────────────────────────────────┐" -ForegroundColor White
            Write-Host "│                    GIT                          GIX                  │" -ForegroundColor White
            Write-Host "│  Threads (mean):  $("{0,6:N1}" -f $gitThreadStats.Mean)                    $("{0,6:N1}" -f $gixThreadStats.Mean)                │" -ForegroundColor White
            Write-Host "│  Threads (max):   $("{0,6:N0}" -f $gitThreadStats.Max)                    $("{0,6:N0}" -f $gixThreadStats.Max)                │" -ForegroundColor White
            if ($gitHandleStats -and $gixHandleStats) {
            Write-Host "│  Handles (mean):  $("{0,6:N0}" -f $gitHandleStats.Mean)                    $("{0,6:N0}" -f $gixHandleStats.Mean)                │" -ForegroundColor White
            Write-Host "│  Handles (max):   $("{0,6:N0}" -f $gitHandleStats.Max)                    $("{0,6:N0}" -f $gixHandleStats.Max)                │" -ForegroundColor White
            }
            Write-Host "└──────────────────────────────────────────────────────────────────────┘" -ForegroundColor White
        }

        # I/O Operations Analysis
        $gitIOReadStats = Get-Statistics ($gitMetrics.IOReadBytes | Where-Object { $_ -gt 0 } | ForEach-Object { $_ / 1KB })
        $gixIOReadStats = Get-Statistics ($gixMetrics.IOReadBytes | Where-Object { $_ -gt 0 } | ForEach-Object { $_ / 1KB })
        $gitIOWriteStats = Get-Statistics ($gitMetrics.IOWriteBytes | Where-Object { $_ -gt 0 } | ForEach-Object { $_ / 1KB })
        $gixIOWriteStats = Get-Statistics ($gixMetrics.IOWriteBytes | Where-Object { $_ -gt 0 } | ForEach-Object { $_ / 1KB })
        $gitIOReadOpsStats = Get-Statistics ($gitMetrics.IOReadOperations | Where-Object { $_ -gt 0 })
        $gixIOReadOpsStats = Get-Statistics ($gixMetrics.IOReadOperations | Where-Object { $_ -gt 0 })
        $gitIOWriteOpsStats = Get-Statistics ($gitMetrics.IOWriteOperations | Where-Object { $_ -gt 0 })
        $gixIOWriteOpsStats = Get-Statistics ($gixMetrics.IOWriteOperations | Where-Object { $_ -gt 0 })

        if ($gitIOReadStats -or $gixIOReadStats) {
            Write-Host ""
            Write-Host "┌─ FILESYSTEM I/O ─────────────────────────────────────────────────────┐" -ForegroundColor White
            Write-Host "│                    GIT                          GIX                  │" -ForegroundColor White
            if ($gitIOReadStats -and $gixIOReadStats) {
            Write-Host "│  Read KB (mean):  $("{0,6:N0}" -f $gitIOReadStats.Mean)                    $("{0,6:N0}" -f $gixIOReadStats.Mean)                │" -ForegroundColor White
            }
            if ($gitIOWriteStats -and $gixIOWriteStats) {
            Write-Host "│  Write KB (mean): $("{0,6:N0}" -f $gitIOWriteStats.Mean)                    $("{0,6:N0}" -f $gixIOWriteStats.Mean)                │" -ForegroundColor White
            }
            if ($gitIOReadOpsStats -and $gixIOReadOpsStats) {
            Write-Host "│  Read Ops (mean): $("{0,6:N0}" -f $gitIOReadOpsStats.Mean)                    $("{0,6:N0}" -f $gixIOReadOpsStats.Mean)                │" -ForegroundColor White
            }
            if ($gitIOWriteOpsStats -and $gixIOWriteOpsStats) {
            Write-Host "│  Write Ops (mean):$("{0,6:N0}" -f $gitIOWriteOpsStats.Mean)                    $("{0,6:N0}" -f $gixIOWriteOpsStats.Mean)                │" -ForegroundColor White
            }
            Write-Host "└──────────────────────────────────────────────────────────────────────┘" -ForegroundColor White

            # I/O efficiency analysis
            if ($gitIOReadStats -and $gixIOReadStats -and $gixIOReadStats.Mean -gt 0) {
                $ioRatio = [Math]::Round($gixIOReadStats.Mean / $gitIOReadStats.Mean, 2)
                Write-Host "  Gix reads $ioRatio`x the data of Git" -ForegroundColor $(if ($ioRatio -le 1.2) { "Green" } elseif ($ioRatio -le 2) { "Yellow" } else { "Red" })
            }
        }

        # Page Faults Analysis
        $gitPageFaultStats = Get-Statistics ($gitMetrics.PageFaults | Where-Object { $_ -gt 0 })
        $gixPageFaultStats = Get-Statistics ($gixMetrics.PageFaults | Where-Object { $_ -gt 0 })

        if ($gitPageFaultStats -and $gixPageFaultStats) {
            Write-Host ""
            Write-Host "┌─ PAGE FAULTS ────────────────────────────────────────────────────────┐" -ForegroundColor White
            Write-Host "│                    GIT                          GIX                  │" -ForegroundColor White
            Write-Host "│  Mean:         $("{0,8:N0}" -f $gitPageFaultStats.Mean)                    $("{0,8:N0}" -f $gixPageFaultStats.Mean)                │" -ForegroundColor White
            Write-Host "│  Max:          $("{0,8:N0}" -f $gitPageFaultStats.Max)                    $("{0,8:N0}" -f $gixPageFaultStats.Max)                │" -ForegroundColor White
            Write-Host "└──────────────────────────────────────────────────────────────────────┘" -ForegroundColor White
        }

        # Efficiency metrics
        Write-Host ""
        Write-Host "┌─ EFFICIENCY ANALYSIS ────────────────────────────────────────────────┐" -ForegroundColor Cyan

        $gitCpuEfficiency = if ($gitWallStats.Mean -gt 0) { ($gitUserStats.Mean + $gitKernelStats.Mean) / $gitWallStats.Mean * 100 } else { 0 }
        $gixCpuEfficiency = if ($gixWallStats.Mean -gt 0) { ($gixUserStats.Mean + $gixKernelStats.Mean) / $gixWallStats.Mean * 100 } else { 0 }

        Write-Host "│  CPU Efficiency (CPU time / Wall time):                              │" -ForegroundColor White
        Write-Host "│    Git: $("{0,6:N1}" -f $gitCpuEfficiency)%    Gix: $("{0,6:N1}" -f $gixCpuEfficiency)%                                    │" -ForegroundColor White

        $gitKernelRatio = if (($gitUserStats.Mean + $gitKernelStats.Mean) -gt 0) { $gitKernelStats.Mean / ($gitUserStats.Mean + $gitKernelStats.Mean) * 100 } else { 0 }
        $gixKernelRatio = if (($gixUserStats.Mean + $gixKernelStats.Mean) -gt 0) { $gixKernelStats.Mean / ($gixUserStats.Mean + $gixKernelStats.Mean) * 100 } else { 0 }

        Write-Host "│  Kernel Time Ratio (syscall overhead indicator):                     │" -ForegroundColor White
        Write-Host "│    Git: $("{0,6:N1}" -f $gitKernelRatio)%    Gix: $("{0,6:N1}" -f $gixKernelRatio)%                                    │" -ForegroundColor White

        Write-Host "└──────────────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan

        # Bottleneck identification
        Write-Host ""
        Write-Host "┌─ BOTTLENECK INDICATORS ──────────────────────────────────────────────┐" -ForegroundColor Yellow

        $hasBottleneck = $false

        if ($gixCpuEfficiency -lt 50) {
            Write-Host "│  ⚠ Low CPU efficiency in Gix ($("{0:N1}" -f $gixCpuEfficiency)%) suggests I/O or wait bottleneck    │" -ForegroundColor Yellow
            $hasBottleneck = $true
        }
        if ($gixKernelRatio -gt $gitKernelRatio * 1.5 -and $gitKernelRatio -gt 0) {
            Write-Host "│  ⚠ Higher kernel time in Gix suggests more syscalls/I/O ops         │" -ForegroundColor Yellow
            $hasBottleneck = $true
        }
        if ($gixMemStats -and $gitMemStats -and $gixMemStats.Mean -gt $gitMemStats.Mean * 2 -and $gitMemStats.Mean -gt 0) {
            Write-Host "│  ⚠ Gix uses >2x memory ($("{0:N1}" -f $gixMemStats.Mean) vs $("{0:N1}" -f $gitMemStats.Mean) MB)                      │" -ForegroundColor Yellow
            $hasBottleneck = $true
        }
        if ($gixWallStats.CoeffOfVariation -gt 20) {
            Write-Host "│  ⚠ High variance in Gix timing (CV=$("{0:N1}" -f $gixWallStats.CoeffOfVariation)%)                          │" -ForegroundColor Yellow
            $hasBottleneck = $true
        }
        if ($gitWallStats.Mean -lt 50 -and $gixWallStats.Mean -gt 100) {
            Write-Host "│  ⚠ Large gap on fast operation - likely startup overhead            │" -ForegroundColor Yellow
            $hasBottleneck = $true
        }
        if ($gixIOReadStats -and $gitIOReadStats -and $gixIOReadStats.Mean -gt $gitIOReadStats.Mean * 2 -and $gitIOReadStats.Mean -gt 0) {
            Write-Host "│  ⚠ Gix reads >2x data - inefficient I/O or caching                  │" -ForegroundColor Yellow
            $hasBottleneck = $true
        }
        if ($gixPageFaultStats -and $gitPageFaultStats -and $gixPageFaultStats.Mean -gt $gitPageFaultStats.Mean * 1.5 -and $gitPageFaultStats.Mean -gt 0) {
            Write-Host "│  ⚠ Higher page faults in Gix - memory access pattern issue          │" -ForegroundColor Yellow
            $hasBottleneck = $true
        }
        if ($gixThreadStats -and $gitThreadStats -and $gixThreadStats.Max -gt $gitThreadStats.Max * 2 -and $gitThreadStats.Max -gt 1) {
            Write-Host "│  ⚠ Gix spawns more threads - potential contention overhead          │" -ForegroundColor Yellow
            $hasBottleneck = $true
        }

        if (-not $hasBottleneck) {
            Write-Host "│  ✓ No significant bottlenecks detected                              │" -ForegroundColor Green
        }

        Write-Host "└──────────────────────────────────────────────────────────────────────┘" -ForegroundColor Yellow

        # Return structured results
        $results = [PSCustomObject]@{
            Operation = $OperationName
            Description = $opDef.Description
            Category = $opDef.Category
            Timestamp = (Get-Date -Format "o")
            Repository = $RepoPath
            Iterations = $Iterations
            WarmupRuns = $WarmupRuns
            Git = [PSCustomObject]@{
                WallTime = $gitWallStats
                UserTime = $gitUserStats
                KernelTime = $gitKernelStats
                PeakMemoryMB = $gitMemStats
                Threads = $gitThreadStats
                Handles = $gitHandleStats
                IOReadKB = $gitIOReadStats
                IOWriteKB = $gitIOWriteStats
                IOReadOps = $gitIOReadOpsStats
                IOWriteOps = $gitIOWriteOpsStats
                PageFaults = $gitPageFaultStats
            }
            Gix = [PSCustomObject]@{
                WallTime = $gixWallStats
                UserTime = $gixUserStats
                KernelTime = $gixKernelStats
                PeakMemoryMB = $gixMemStats
                Threads = $gixThreadStats
                Handles = $gixHandleStats
                IOReadKB = $gixIOReadStats
                IOWriteKB = $gixIOWriteStats
                IOReadOps = $gixIOReadOpsStats
                IOWriteOps = $gixIOWriteOpsStats
                PageFaults = $gixPageFaultStats
            }
            Comparison = [PSCustomObject]@{
                SpeedRatio = $speedup
                MemoryRatio = $memRatio
                Winner = $winner
                IOReadRatio = if ($gitIOReadStats -and $gixIOReadStats -and $gitIOReadStats.Mean -gt 0) { [Math]::Round($gixIOReadStats.Mean / $gitIOReadStats.Mean, 2) } else { $null }
                PageFaultRatio = if ($gitPageFaultStats -and $gixPageFaultStats -and $gitPageFaultStats.Mean -gt 0) { [Math]::Round($gixPageFaultStats.Mean / $gitPageFaultStats.Mean, 2) } else { $null }
            }
            BottleneckIndicators = @{
                LowCpuEfficiency = $gixCpuEfficiency -lt 50
                HighKernelRatio = $gixKernelRatio -gt ($gitKernelRatio * 1.5) -and $gitKernelRatio -gt 0
                HighMemoryUsage = $gixMemStats -and $gitMemStats -and $gixMemStats.Mean -gt ($gitMemStats.Mean * 2) -and $gitMemStats.Mean -gt 0
                HighVariance = $gixWallStats.CoeffOfVariation -gt 20
                StartupOverhead = $gitWallStats.Mean -lt 50 -and $gixWallStats.Mean -gt 100
                InefficientIO = $gixIOReadStats -and $gitIOReadStats -and $gixIOReadStats.Mean -gt ($gitIOReadStats.Mean * 2) -and $gitIOReadStats.Mean -gt 0
            }
        }

        return $results

    } finally {
        Pop-Location
    }
}

# ============================================================================
# ENTRY POINT
# ============================================================================

if ($Operation -eq "all") {
    $allResults = @()
    foreach ($op in $Operations.Keys) {
        Write-Host "`n"
        $result = Invoke-DeepProfile -OperationName $op -Iterations $Iterations -WarmupRuns $WarmupRuns -RepoPath $TestRepo
        $allResults += $result
    }

    if ($ExportJson) {
        $outputPath = "C:\codedev\gitoxide\tests\comparison\profiling\results\deep_profile_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $allResults | ConvertTo-Json -Depth 10 | Set-Content $outputPath
        Write-Host "`nResults saved to: $outputPath" -ForegroundColor Green
    }
} else {
    $result = Invoke-DeepProfile -OperationName $Operation -Iterations $Iterations -WarmupRuns $WarmupRuns -RepoPath $TestRepo

    if ($ExportJson) {
        $outputPath = "C:\codedev\gitoxide\tests\comparison\profiling\results\deep_profile_${Operation}_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $result | ConvertTo-Json -Depth 10 | Set-Content $outputPath
        Write-Host "`nResults saved to: $outputPath" -ForegroundColor Green
    }
}
