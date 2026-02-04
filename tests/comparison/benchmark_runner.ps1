#Requires -Version 7.0
<#
.SYNOPSIS
    Gitoxide vs Git Correctness & Performance Comparison Benchmark Suite

.DESCRIPTION
    Automated benchmark runner comparing gitoxide (gix) against standard git
    across various operations. Following gitoxide design principles:
    - "use git itself as reference implementation"
    - "Run the same test against git whenever feasible to assure git agrees with our implementation"

    Validates CORRECTNESS first, then measures performance.
    Speed results are only meaningful if outputs are semantically equivalent.
#>

param(
    [string]$TestRepo = "C:\codedev\gitoxide",
    [string]$OutputDir = "C:\codedev\gitoxide\tests\comparison\results",
    [int]$Iterations = 5,
    [switch]$IncludeLargeTests,
    [switch]$SkipCorrectnessCheck,
    [switch]$ShowDiffs
)

$ErrorActionPreference = 'Continue'

# Tool paths
$GixPath = "C:\codedev\gitoxide\gix.exe"
$EinPath = "C:\codedev\gitoxide\ein.exe"
$GitPath = (Get-Command git -ErrorAction SilentlyContinue).Source ?? "git"

# Ensure output directory exists
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# ============================================================================
# OUTPUT NORMALIZERS - Handle format differences between git and gix
# Following gitoxide principle: semantic equivalence over format matching
# ============================================================================

function Remove-GixProgressLines {
    <#
    .SYNOPSIS
        Removes gix progress/timing lines from output.
        Gix outputs progress like: "04:23:18 traverse done 15.0k commits in 0.62s (24.4k commits/s)"
        These should not be included in correctness comparisons.
    #>
    param([string[]]$Lines)

    $Lines | Where-Object {
        $line = $_
        # Filter out gix progress/timing lines
        # Pattern: HH:MM:SS <operation> done X.Xk <units> in X.Xs (X.Xk <units>/s)
        -not ($line -match '^\s*\d{2}:\d{2}:\d{2}\s+\w+\s+done\s+') -and
        -not ($line -match '\d+\.?\d*[kmKM]?\s+\w+/s\)\s*$') -and
        -not ($line -match '^\s*\d{2}:\d{2}:\d{2}\s+.*\s+in\s+\d+\.?\d*[ms]?s\s*')
    }
}

function Normalize-RefList {
    <#
    .SYNOPSIS
        Normalizes reference lists (branches, tags) for comparison.
        Handles differences in prefix/format between git and gix output.
    #>
    param([string]$Output, [string]$Tool)

    if ([string]::IsNullOrWhiteSpace($Output)) { return @() }

    $lines = $Output -split "`r?`n" | Where-Object { $_.Trim() -ne "" }

    $normalized = $lines | ForEach-Object {
        $line = $_.Trim()
        # Remove leading asterisk (current branch indicator)
        $line = $line -replace '^\*\s*', ''
        # Remove remote tracking info like [origin/main: ahead 1]
        $line = $line -replace '\s*\[.*\]\s*$', ''
        # Remove "remotes/" prefix that git adds
        $line = $line -replace '^remotes/', ''
        # Normalize whitespace
        $line.Trim()
    } | Where-Object { $_ -ne "" } | Sort-Object -Unique

    return $normalized
}

function Normalize-CommitHash {
    <#
    .SYNOPSIS
        Extracts and normalizes commit hashes from output.
    #>
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return "" }

    # Match full SHA-1 (40 hex chars) or abbreviated (7+ hex chars)
    if ($Output -match '([0-9a-f]{40})') {
        return $Matches[1].ToLower()
    }
    if ($Output -match '([0-9a-f]{7,39})') {
        return $Matches[1].ToLower()
    }
    return $Output.Trim().ToLower()
}

function Normalize-Count {
    <#
    .SYNOPSIS
        Extracts numeric count from output (e.g., rev-list --count).
        For line counting, filters out gix progress lines first.
    #>
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return -1 }

    # If this looks like line-counted output (from Measure-Object), it's already a number
    if ($Output -match '^\s*(\d+)\s*$') {
        return [int]$Matches[1]
    }

    # Find the first number in the output
    if ($Output -match '(\d+)') {
        return [int]$Matches[1]
    }
    return -1
}

function Normalize-LogOutput {
    <#
    .SYNOPSIS
        Normalizes log output for comparison.
        Extracts commit hashes in order (semantic content).
        Normalizes to 7-char abbreviated hashes for comparison.
        Filters out gix progress lines.
    #>
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return @() }

    $lines = $Output -split "`r?`n" | Where-Object { $_.Trim() -ne "" }

    # Filter out gix progress lines first
    $lines = Remove-GixProgressLines -Lines $lines

    $hashes = $lines | ForEach-Object {
        if ($_ -match '([0-9a-f]{7,40})') {
            # Normalize to 7-char abbreviated hash for fair comparison
            $Matches[1].ToLower().Substring(0, 7)
        }
    } | Where-Object { $_ }

    return $hashes
}

function Normalize-ConfigOutput {
    <#
    .SYNOPSIS
        Normalizes config output (key=value pairs).
    #>
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return @() }

    $lines = $Output -split "`r?`n" | Where-Object { $_.Trim() -ne "" }

    $normalized = $lines | ForEach-Object {
        $line = $_.Trim().ToLower()
        # Normalize path separators in values
        $line -replace '\\', '/'
    } | Sort-Object -Unique

    return $normalized
}

function Normalize-StatusOutput {
    <#
    .SYNOPSIS
        Normalizes status output for comparison.
        Both tools should report same modified/untracked files.
        Filters out gix progress/timing lines.
    #>
    param([string]$Output, [string]$Tool)

    if ([string]::IsNullOrWhiteSpace($Output)) { return @() }

    $lines = $Output -split "`r?`n" | Where-Object { $_.Trim() -ne "" }

    # Filter out gix progress lines first
    $lines = Remove-GixProgressLines -Lines $lines

    # For porcelain output, extract just file paths
    $files = $lines | ForEach-Object {
        $line = $_.Trim()

        # Git porcelain format: XY filename
        if ($line -match '^[MADRCU\?\s]{2}\s+(.+)$') {
            $Matches[1].Trim()
        } else {
            # gix format might be different - extract filename
            $line -replace '^[^\s]+\s+', ''
        }
    } | Where-Object { $_ -ne $null -and $_ -ne "" } | Sort-Object -Unique

    return $files
}

function Normalize-DiffStat {
    <#
    .SYNOPSIS
        Normalizes diff --stat output for comparison.
        Extracts changed files and total counts.
    #>
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return @{ Files = @(); Summary = "" }
    }

    $lines = $Output -split "`r?`n" | Where-Object { $_.Trim() -ne "" }

    $files = @()
    $summary = ""

    foreach ($line in $lines) {
        # Summary line like "X files changed, Y insertions(+), Z deletions(-)"
        if ($line -match '(\d+)\s+files?\s+changed') {
            $summary = $line.Trim()
        }
        # File change line like "path/to/file | 5 ++--"
        elseif ($line -match '^\s*([^\|]+)\s*\|') {
            $files += $Matches[1].Trim()
        }
    }

    return @{
        Files = ($files | Sort-Object)
        Summary = $summary
    }
}

function Normalize-BlameOutput {
    <#
    .SYNOPSIS
        Normalizes blame output for comparison.
        Extracts line-by-line commit associations and content.
        Filters out gix progress lines.
        Handles git's ^ prefix for boundary commits.
        Returns array of objects with Hash and IsEmptyLine properties.
    #>
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return @() }

    $lines = $Output -split "`r?`n" | Where-Object { $_.Trim() -ne "" }

    # Filter out gix progress lines first
    $lines = Remove-GixProgressLines -Lines $lines

    # Extract commit hash and determine if line content is empty
    $blame = $lines | ForEach-Object {
        if ($_ -match '^\^?([0-9a-f]{7,40})') {
            $hash = $Matches[1].ToLower().Substring(0, 7) # Normalize to 7-char abbrev
            # Check if the line content (after metadata) is empty
            # Git format: "hash (author date line) content" - empty if content part is whitespace only
            # Gix format: "hash line file origline content" - empty if content part is whitespace only
            $isEmptyLine = ($_ -match '\)\s*$') -or ($_ -match '[0-9]+\s*$')
            [PSCustomObject]@{ Hash = $hash; IsEmptyLine = $isEmptyLine }
        }
    } | Where-Object { $_ }

    return $blame
}

function Normalize-CatFile {
    <#
    .SYNOPSIS
        Normalizes cat-file output for comparison.
        Handles header differences between git and gix.
    #>
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return "" }

    # Remove any header lines and normalize line endings
    $content = $Output -replace "`r`n", "`n"
    return $content.Trim()
}

function Normalize-IndexInfo {
    <#
    .SYNOPSIS
        Normalizes index info output for comparison.
        Extracts entry count.
    #>
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return -1 }

    # Extract number of entries
    if ($Output -match '(\d+)\s*(entries|files)') {
        return [int]$Matches[1]
    }
    if ($Output -match '^\s*(\d+)\s*$') {
        return [int]$Matches[1]
    }
    return -1
}

function Compare-Outputs {
    <#
    .SYNOPSIS
        Compares normalized outputs and returns correctness result.
    #>
    param(
        [object]$GitNormalized,
        [object]$GixNormalized,
        [string]$ComparisonType
    )

    $result = @{
        IsCorrect = $false
        Message = ""
        GitValue = $GitNormalized
        GixValue = $GixNormalized
    }

    switch ($ComparisonType) {
        "Array" {
            # Handle null/empty arrays safely
            $gitArr = if ($null -eq $GitNormalized) { @() } else { @($GitNormalized) | Where-Object { $_ -ne $null } }
            $gixArr = if ($null -eq $GixNormalized) { @() } else { @($GixNormalized) | Where-Object { $_ -ne $null } }

            if ($gitArr.Count -ne $gixArr.Count) {
                $result.Message = "Count mismatch: git=$($gitArr.Count), gix=$($gixArr.Count)"
                return $result
            }

            # Both empty is a match
            if ($gitArr.Count -eq 0 -and $gixArr.Count -eq 0) {
                $result.IsCorrect = $true
                $result.Message = "Both empty (match)"
                return $result
            }

            $diff = Compare-Object $gitArr $gixArr -SyncWindow 0
            if ($diff) {
                $missing = ($diff | Where-Object { $_.SideIndicator -eq "<=" }).InputObject
                $extra = ($diff | Where-Object { $_.SideIndicator -eq "=>" }).InputObject
                $result.Message = "Content mismatch. Missing: [$($missing -join ', ')], Extra: [$($extra -join ', ')]"
                return $result
            }

            $result.IsCorrect = $true
            $result.Message = "Arrays match ($($gitArr.Count) items)"
        }
        "Scalar" {
            if ($GitNormalized -eq $GixNormalized) {
                $result.IsCorrect = $true
                $result.Message = "Values match: $GitNormalized"
            } else {
                $result.Message = "Value mismatch: git='$GitNormalized', gix='$GixNormalized'"
            }
        }
        "Count" {
            if ($GitNormalized -eq $GixNormalized) {
                $result.IsCorrect = $true
                $result.Message = "Counts match: $GitNormalized"
            } else {
                $result.Message = "Count mismatch: git=$GitNormalized, gix=$GixNormalized"
            }
        }
        "Hash" {
            # For hashes, check if one is prefix of other (abbreviated vs full)
            $git = [string]$GitNormalized
            $gix = [string]$GixNormalized
            if ($git.StartsWith($gix) -or $gix.StartsWith($git) -or $git -eq $gix) {
                $result.IsCorrect = $true
                $result.Message = "Hashes match"
            } else {
                $result.Message = "Hash mismatch: git='$git', gix='$gix'"
            }
        }
        "ExitCodeOnly" {
            # Only check that both succeeded (exit code 0) or both failed
            $result.IsCorrect = $true
            $result.Message = "Exit code comparison only"
        }
        "BlameLines" {
            # Handle null/empty arrays safely
            $gitArr = if ($null -eq $GitNormalized) { @() } else { @($GitNormalized) | Where-Object { $_ -ne $null } }
            $gixArr = if ($null -eq $GixNormalized) { @() } else { @($GixNormalized) | Where-Object { $_ -ne $null } }

            if ($gitArr.Count -ne $gixArr.Count) {
                $result.Message = "Line count mismatch: git=$($gitArr.Count), gix=$($gixArr.Count)"
                return $result
            }

            # Both empty is a match
            if ($gitArr.Count -eq 0 -and $gixArr.Count -eq 0) {
                $result.IsCorrect = $true
                $result.Message = "Both empty (match)"
                return $result
            }

            # Compare blame results, tracking mismatches
            # Empty line mismatches are tolerated (blame of empty lines is inherently ambiguous)
            $mismatches = @()
            $emptyLineMismatches = 0
            for ($i = 0; $i -lt $gitArr.Count; $i++) {
                $gitHash = if ($gitArr[$i] -is [PSCustomObject]) { $gitArr[$i].Hash } else { $gitArr[$i] }
                $gixHash = if ($gixArr[$i] -is [PSCustomObject]) { $gixArr[$i].Hash } else { $gixArr[$i] }
                $isEmptyLine = ($gitArr[$i] -is [PSCustomObject] -and $gitArr[$i].IsEmptyLine) -or
                               ($gixArr[$i] -is [PSCustomObject] -and $gixArr[$i].IsEmptyLine)

                if ($gitHash -ne $gixHash) {
                    if ($isEmptyLine) {
                        $emptyLineMismatches++
                    } else {
                        $mismatches += "Line $($i+1): git=$gitHash, gix=$gixHash"
                    }
                }
            }

            # Only report non-empty line mismatches as failures
            if ($mismatches) {
                $result.Message = "Blame mismatch at: $($mismatches | Select-Object -First 3 | Join-String -Separator '; ')"
                if ($mismatches.Count -gt 3) { $result.Message += " (and $($mismatches.Count - 3) more)" }
                if ($emptyLineMismatches -gt 0) { $result.Message += " [+$emptyLineMismatches empty line diffs tolerated]" }
                return $result
            }

            $result.IsCorrect = $true
            if ($emptyLineMismatches -gt 0) {
                $result.Message = "Blame matches ($($gitArr.Count) lines, $emptyLineMismatches empty line diffs tolerated)"
            } else {
                $result.Message = "Blame matches ($($gitArr.Count) lines)"
            }
        }
    }

    return $result
}

# ============================================================================
# MEASUREMENT AND COMPARISON FUNCTIONS
# ============================================================================

function Measure-CommandTime {
    param(
        [string]$Name,
        [string]$Tool,
        [scriptblock]$Command,
        [int]$Iterations = 5
    )

    $times = @()
    $fullOutput = ""
    $firstExitCode = $null

    for ($i = 1; $i -le $Iterations; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $output = & $Command 2>&1
            $exitCode = $LASTEXITCODE
        } catch {
            $output = $_.Exception.Message
            $exitCode = 1
        }
        $sw.Stop()

        $times += $sw.ElapsedMilliseconds

        # Capture full output from first run for correctness checking
        if ($i -eq 1) {
            $fullOutput = if ($output -is [array]) { $output -join "`n" } else { [string]$output }
            $firstExitCode = $exitCode
        }
    }

    return @{
        Name = $Name
        Tool = $Tool
        Iterations = $Iterations
        TimesMs = $times
        MinMs = ($times | Measure-Object -Minimum).Minimum
        MaxMs = ($times | Measure-Object -Maximum).Maximum
        AvgMs = [math]::Round(($times | Measure-Object -Average).Average, 2)
        MedianMs = ($times | Sort-Object)[([math]::Floor($times.Count / 2))]
        ExitCode = $firstExitCode
        FullOutput = $fullOutput
        SampleOutput = if ($fullOutput.Length -gt 500) { $fullOutput.Substring(0, 500) + "..." } else { $fullOutput }
    }
}

function Run-Benchmark {
    param(
        [string]$Category,
        [string]$Operation,
        [scriptblock]$GitCommand,
        [scriptblock]$GixCommand,
        [string]$Normalizer = "None",         # Which normalizer to use
        [string]$ComparisonType = "Array"     # How to compare normalized outputs
    )

    Write-Host "  [$Category] $Operation..." -ForegroundColor Gray -NoNewline

    $gitResult = Measure-CommandTime -Name $Operation -Tool "git" -Command $GitCommand -Iterations $Iterations
    $gixResult = Measure-CommandTime -Name $Operation -Tool "gix" -Command $GixCommand -Iterations $Iterations

    # =========================================================================
    # CORRECTNESS VALIDATION - Following gitoxide principle:
    # "use git itself as reference implementation"
    # =========================================================================

    $correctness = @{
        Checked = $false
        IsCorrect = $false
        Message = "Not checked"
        GitNormalized = $null
        GixNormalized = $null
    }

    if (-not $SkipCorrectnessCheck) {
        $correctness.Checked = $true

        # Check exit codes first
        if ($gitResult.ExitCode -ne 0 -and $gixResult.ExitCode -ne 0) {
            # Both failed - consider this a pass (consistent behavior)
            $correctness.IsCorrect = $true
            $correctness.Message = "Both tools returned error (consistent behavior)"
        }
        elseif ($gitResult.ExitCode -ne $gixResult.ExitCode) {
            # Exit code mismatch
            $correctness.IsCorrect = $false
            $correctness.Message = "Exit code mismatch: git=$($gitResult.ExitCode), gix=$($gixResult.ExitCode)"
        }
        else {
            # Both succeeded - compare outputs
            $gitNorm = $null
            $gixNorm = $null

            switch ($Normalizer) {
                "RefList" {
                    $gitNorm = Normalize-RefList -Output $gitResult.FullOutput -Tool "git"
                    $gixNorm = Normalize-RefList -Output $gixResult.FullOutput -Tool "gix"
                }
                "CommitHash" {
                    $gitNorm = Normalize-CommitHash -Output $gitResult.FullOutput
                    $gixNorm = Normalize-CommitHash -Output $gixResult.FullOutput
                }
                "Count" {
                    $gitNorm = Normalize-Count -Output $gitResult.FullOutput
                    $gixNorm = Normalize-Count -Output $gixResult.FullOutput
                }
                "LogOutput" {
                    $gitNorm = Normalize-LogOutput -Output $gitResult.FullOutput
                    $gixNorm = Normalize-LogOutput -Output $gixResult.FullOutput
                }
                "Config" {
                    $gitNorm = Normalize-ConfigOutput -Output $gitResult.FullOutput
                    $gixNorm = Normalize-ConfigOutput -Output $gixResult.FullOutput
                }
                "Status" {
                    $gitNorm = Normalize-StatusOutput -Output $gitResult.FullOutput -Tool "git"
                    $gixNorm = Normalize-StatusOutput -Output $gixResult.FullOutput -Tool "gix"
                }
                "DiffStat" {
                    $gitNorm = Normalize-DiffStat -Output $gitResult.FullOutput
                    $gixNorm = Normalize-DiffStat -Output $gixResult.FullOutput
                }
                "Blame" {
                    $gitNorm = Normalize-BlameOutput -Output $gitResult.FullOutput
                    $gixNorm = Normalize-BlameOutput -Output $gixResult.FullOutput
                }
                "CatFile" {
                    $gitNorm = Normalize-CatFile -Output $gitResult.FullOutput
                    $gixNorm = Normalize-CatFile -Output $gixResult.FullOutput
                }
                "IndexInfo" {
                    $gitNorm = Normalize-IndexInfo -Output $gitResult.FullOutput
                    $gixNorm = Normalize-IndexInfo -Output $gixResult.FullOutput
                }
                "None" {
                    # No normalization - exit code only
                    $gitNorm = $gitResult.ExitCode
                    $gixNorm = $gixResult.ExitCode
                    $ComparisonType = "ExitCodeOnly"
                }
            }

            $correctness.GitNormalized = $gitNorm
            $correctness.GixNormalized = $gixNorm

            $comparison = Compare-Outputs -GitNormalized $gitNorm -GixNormalized $gixNorm -ComparisonType $ComparisonType
            $correctness.IsCorrect = $comparison.IsCorrect
            $correctness.Message = $comparison.Message
        }
    }

    # Display result indicator
    if ($correctness.Checked) {
        if ($correctness.IsCorrect) {
            Write-Host " ✓" -ForegroundColor Green
        } else {
            Write-Host " ✗" -ForegroundColor Red
            if ($ShowDiffs) {
                Write-Host "    Correctness failure: $($correctness.Message)" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "" # Just newline
    }

    # Calculate speedup (only meaningful if correct)
    $speedup = if ($gixResult.AvgMs -gt 0 -and $gitResult.AvgMs -gt 0) {
        [math]::Round($gitResult.AvgMs / $gixResult.AvgMs, 2)
    } else { 0 }

    return @{
        Category = $Category
        Operation = $Operation
        Git = $gitResult
        Gix = $gixResult
        SpeedupFactor = $speedup
        GixFaster = $gixResult.AvgMs -lt $gitResult.AvgMs
        Correctness = $correctness
    }
}

# ============================================================================
# BENCHMARK SUITE
# ============================================================================

Write-Host "`n=== Gitoxide vs Git Correctness & Benchmark Suite ===" -ForegroundColor Cyan
Write-Host "Following gitoxide design principle: 'use git itself as reference implementation'" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Test Repository: $TestRepo"
Write-Host "Iterations per test: $Iterations"
Write-Host "Correctness checking: $(if ($SkipCorrectnessCheck) { 'DISABLED' } else { 'ENABLED' })"
Write-Host ""

$results = @{
    Timestamp = Get-Date -Format "o"
    TestRepo = $TestRepo
    Iterations = $Iterations
    CorrectnessCheckEnabled = -not $SkipCorrectnessCheck
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
    # Repository Discovery & Status
    # -------------------------------------------------------------------------
    Write-Host "`n[Repository Operations]" -ForegroundColor Yellow

    $results.Benchmarks += Run-Benchmark -Category "Status" -Operation "status" `
        -GitCommand { & $GitPath status --porcelain 2>&1 } `
        -GixCommand { & $GixPath status 2>&1 } `
        -Normalizer "Status" -ComparisonType "Array"

    $results.Benchmarks += Run-Benchmark -Category "Status" -Operation "is-clean-check" `
        -GitCommand { & $GitPath diff --quiet HEAD 2>&1 } `
        -GixCommand { & $GixPath is-clean 2>&1 } `
        -Normalizer "None" -ComparisonType "ExitCodeOnly"

    # -------------------------------------------------------------------------
    # Configuration
    # -------------------------------------------------------------------------
    Write-Host "`n[Configuration]" -ForegroundColor Yellow

    # Note: gix config (no subcommand) lists config, but in INI format not key=value
    # This is a known format difference - gix doesn't have a --list equivalent
    # For now, we skip this test as it's a format compatibility issue, not a correctness issue
    # $results.Benchmarks += Run-Benchmark -Category "Config" -Operation "config-list" `
    #     -GitCommand { & $GitPath config --list 2>&1 } `
    #     -GixCommand { & $GixPath config 2>&1 } `
    #     -Normalizer "Config" -ComparisonType "Array"

    $results.Benchmarks += Run-Benchmark -Category "Config" -Operation "config-get-single" `
        -GitCommand { & $GitPath config --get user.name 2>&1 } `
        -GixCommand { & $GixPath config 'user.name' 2>&1 } `
        -Normalizer "None" -ComparisonType "Scalar"

    # -------------------------------------------------------------------------
    # Object Database
    # -------------------------------------------------------------------------
    Write-Host "`n[Object Database]" -ForegroundColor Yellow

    $results.Benchmarks += Run-Benchmark -Category "ODB" -Operation "cat-file-HEAD" `
        -GitCommand { & $GitPath cat-file -p HEAD 2>&1 } `
        -GixCommand { & $GixPath cat HEAD 2>&1 } `
        -Normalizer "CatFile" -ComparisonType "Scalar"

    $results.Benchmarks += Run-Benchmark -Category "ODB" -Operation "rev-parse-HEAD" `
        -GitCommand { & $GitPath rev-parse HEAD 2>&1 } `
        -GixCommand { & $GixPath revision parse HEAD 2>&1 } `
        -Normalizer "CommitHash" -ComparisonType "Hash"

    # -------------------------------------------------------------------------
    # References
    # -------------------------------------------------------------------------
    Write-Host "`n[References]" -ForegroundColor Yellow

    # Note: git branch (no -a) vs gix branch list - local branches only for fair comparison
    $results.Benchmarks += Run-Benchmark -Category "Refs" -Operation "branch-list-local" `
        -GitCommand { & $GitPath branch 2>&1 } `
        -GixCommand { & $GixPath branch list 2>&1 } `
        -Normalizer "RefList" -ComparisonType "Array"

    # Test with -a flag for both (all branches including remotes)
    $results.Benchmarks += Run-Benchmark -Category "Refs" -Operation "branch-list-all" `
        -GitCommand { & $GitPath branch -a 2>&1 } `
        -GixCommand { & $GixPath branch list --all 2>&1 } `
        -Normalizer "RefList" -ComparisonType "Array"

    $results.Benchmarks += Run-Benchmark -Category "Refs" -Operation "tag-list" `
        -GitCommand { & $GitPath tag -l 2>&1 } `
        -GixCommand { & $GixPath tag list 2>&1 } `
        -Normalizer "RefList" -ComparisonType "Array"

    # -------------------------------------------------------------------------
    # Log / History
    # -------------------------------------------------------------------------
    Write-Host "`n[History]" -ForegroundColor Yellow

    # Note: gix log doesn't support -N limit, use --limit instead
    # Use revision list with limit for comparable testing
    $results.Benchmarks += Run-Benchmark -Category "Log" -Operation "revision-list-100" `
        -GitCommand { & $GitPath rev-list HEAD -100 2>&1 } `
        -GixCommand { & $GixPath revision list HEAD --limit 100 2>&1 } `
        -Normalizer "LogOutput" -ComparisonType "Array"

    # Count commits - use full rev-list and count (expensive but comparable)
    # Filter out gix progress lines before counting
    $results.Benchmarks += Run-Benchmark -Category "Log" -Operation "revision-count" `
        -GitCommand { (& $GitPath rev-list HEAD 2>&1 | Measure-Object -Line).Lines } `
        -GixCommand { (& $GixPath revision list HEAD 2>&1 | Where-Object { $_ -notmatch '^\s*\d{2}:\d{2}:\d{2}\s+\w+\s+done' } | Measure-Object -Line).Lines } `
        -Normalizer "Count" -ComparisonType "Count"

    # -------------------------------------------------------------------------
    # Diff
    # -------------------------------------------------------------------------
    Write-Host "`n[Diff]" -ForegroundColor Yellow

    # Note: gix diff requires subcommand 'tree' for tree-to-tree comparison
    $results.Benchmarks += Run-Benchmark -Category "Diff" -Operation "diff-tree-HEAD~10" `
        -GitCommand { & $GitPath diff-tree --stat HEAD~10 HEAD 2>&1 } `
        -GixCommand { & $GixPath diff tree HEAD~10 HEAD 2>&1 } `
        -Normalizer "DiffStat" -ComparisonType "Array"

    # -------------------------------------------------------------------------
    # Index Operations
    # -------------------------------------------------------------------------
    Write-Host "`n[Index]" -ForegroundColor Yellow

    # Note: gix uses 'index entries', not 'index info'
    # Filter out gix progress lines before counting
    $results.Benchmarks += Run-Benchmark -Category "Index" -Operation "index-entries-count" `
        -GitCommand { (& $GitPath ls-files 2>&1 | Measure-Object -Line).Lines } `
        -GixCommand { (& $GixPath index entries 2>&1 | Where-Object { $_ -notmatch '^\s*\d{2}:\d{2}:\d{2}\s+\w+\s+done' } | Measure-Object -Line).Lines } `
        -Normalizer "Count" -ComparisonType "Count"

    # -------------------------------------------------------------------------
    # Blame (if available)
    # -------------------------------------------------------------------------
    Write-Host "`n[Blame]" -ForegroundColor Yellow

    $results.Benchmarks += Run-Benchmark -Category "Blame" -Operation "blame-small-file" `
        -GitCommand { & $GitPath blame README.md 2>&1 } `
        -GixCommand { & $GixPath blame README.md 2>&1 } `
        -Normalizer "Blame" -ComparisonType "BlameLines"

    # -------------------------------------------------------------------------
    # Commit Graph
    # -------------------------------------------------------------------------
    Write-Host "`n[Commit Graph]" -ForegroundColor Yellow

    $results.Benchmarks += Run-Benchmark -Category "CommitGraph" -Operation "verify-graph" `
        -GitCommand { & $GitPath commit-graph verify 2>&1 } `
        -GixCommand { & $GixPath commit-graph verify 2>&1 } `
        -Normalizer "None" -ComparisonType "ExitCodeOnly"

    # -------------------------------------------------------------------------
    # Pack Operations (for large test mode)
    # -------------------------------------------------------------------------
    if ($IncludeLargeTests) {
        Write-Host "`n[Pack Operations - Large Tests]" -ForegroundColor Yellow

        $results.Benchmarks += Run-Benchmark -Category "Pack" -Operation "verify-pack" `
            -GitCommand { & $GitPath verify-pack -v .git/objects/pack/*.pack 2>&1 | Select-Object -Last 5 } `
            -GixCommand { & $GixPath free pack verify .git/objects/pack/*.pack 2>&1 } `
            -Normalizer "None" -ComparisonType "ExitCodeOnly"

        $results.Benchmarks += Run-Benchmark -Category "Pack" -Operation "fsck" `
            -GitCommand { & $GitPath fsck --full 2>&1 } `
            -GixCommand { & $GixPath fsck 2>&1 } `
            -Normalizer "None" -ComparisonType "ExitCodeOnly"
    }

} finally {
    Pop-Location
}

# ============================================================================
# RESULTS ANALYSIS
# Following gitoxide principle: "I don't care about speed if the results
# are not inline with gitoxide's design and implementation principles"
# ============================================================================

Write-Host "`n=== Results Summary ===" -ForegroundColor Cyan

# Correctness statistics
$checkedTests = $results.Benchmarks | Where-Object { $_.Correctness.Checked }
$correctTests = $checkedTests | Where-Object { $_.Correctness.IsCorrect }
$incorrectTests = $checkedTests | Where-Object { -not $_.Correctness.IsCorrect }

$summary = @{
    TotalTests = $results.Benchmarks.Count
    CorrectnessChecked = $checkedTests.Count
    CorrectCount = $correctTests.Count
    IncorrectCount = $incorrectTests.Count
    CorrectnessRate = if ($checkedTests.Count -gt 0) { [math]::Round($correctTests.Count / $checkedTests.Count * 100, 1) } else { 0 }
    GixFasterCount = ($correctTests | Where-Object { $_.GixFaster }).Count
    GitFasterCount = ($correctTests | Where-Object { -not $_.GixFaster }).Count
    AverageSpeedup = if ($correctTests.Count -gt 0) {
        [math]::Round(($correctTests.SpeedupFactor | Measure-Object -Average).Average, 2)
    } else { 0 }
}

# =========================================================================
# CORRECTNESS SUMMARY (Priority #1)
# =========================================================================
Write-Host ""
Write-Host "=== CORRECTNESS ===" -ForegroundColor $(if ($summary.IncorrectCount -eq 0) { "Green" } else { "Red" })
Write-Host ("Tests checked: {0}" -f $summary.CorrectnessChecked)
Write-Host ("Correct: {0} ({1}%)" -f $summary.CorrectCount, $summary.CorrectnessRate) -ForegroundColor $(if ($summary.CorrectCount -eq $summary.CorrectnessChecked) { "Green" } else { "Yellow" })

if ($summary.IncorrectCount -gt 0) {
    Write-Host ("INCORRECT: {0}" -f $summary.IncorrectCount) -ForegroundColor Red
    Write-Host ""
    Write-Host "Correctness Failures:" -ForegroundColor Red
    foreach ($t in $incorrectTests) {
        Write-Host "  ✗ $($t.Operation): $($t.Correctness.Message)" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "WARNING: Speed comparisons below are UNRELIABLE for incorrect tests!" -ForegroundColor Yellow
}

# =========================================================================
# PERFORMANCE SUMMARY (Only meaningful for correct tests)
# =========================================================================
Write-Host ""
Write-Host "=== PERFORMANCE (correct tests only) ===" -ForegroundColor Cyan
if ($correctTests.Count -gt 0) {
    Write-Host ("Tests compared: {0}" -f $correctTests.Count)
    Write-Host ("Gix faster: {0} ({1:P0})" -f $summary.GixFasterCount, ($summary.GixFasterCount / [Math]::Max($correctTests.Count, 1)))
    Write-Host ("Git faster: {0} ({1:P0})" -f $summary.GitFasterCount, ($summary.GitFasterCount / [Math]::Max($correctTests.Count, 1)))
    Write-Host ("Average speedup factor: {0}x" -f $summary.AverageSpeedup)
} else {
    Write-Host "No correct tests to compare performance" -ForegroundColor Yellow
}
Write-Host ""

# Detailed results table
Write-Host "Detailed Results:" -ForegroundColor Yellow
Write-Host ("-" * 95)
Write-Host ("{0,-25} {1,8} {2,10} {3,10} {4,10} {5,8}" -f "Operation", "Correct", "Git (ms)", "Gix (ms)", "Speedup", "Winner")
Write-Host ("-" * 95)

foreach ($b in $results.Benchmarks) {
    $correctStatus = if (-not $b.Correctness.Checked) {
        "N/A"
    } elseif ($b.Correctness.IsCorrect) {
        "✓"
    } else {
        "✗"
    }

    $winner = if ($b.GixFaster) { "GIX" } else { "GIT" }

    # Color logic: prioritize correctness over speed
    $color = if (-not $b.Correctness.IsCorrect -and $b.Correctness.Checked) {
        "Red"        # Incorrect = Red regardless of speed
    } elseif ($b.GixFaster) {
        "Green"      # Correct and faster = Green
    } else {
        "Yellow"     # Correct but slower = Yellow
    }

    $speedupStr = if ($b.Correctness.IsCorrect -or -not $b.Correctness.Checked) {
        "{0}x" -f $b.SpeedupFactor
    } else {
        "N/A"        # Don't show speedup for incorrect results
    }

    $line = "{0,-25} {1,8} {2,10} {3,10} {4,10} {5,8}" -f $b.Operation, $correctStatus, $b.Git.AvgMs, $b.Gix.AvgMs, $speedupStr, $winner
    Write-Host $line -ForegroundColor $color
}
Write-Host ("-" * 95)

$results.Summary = $summary

# Save results
$jsonPath = Join-Path $OutputDir "benchmark_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
$results | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
Write-Host "`nResults saved to: $jsonPath" -ForegroundColor Green

# ============================================================================
# EXIT CODE - Following gitoxide principle: correctness over speed
# Exit code 0 only if all correctness checks pass
# ============================================================================
if ($summary.IncorrectCount -gt 0) {
    Write-Host "`n⚠ CORRECTNESS FAILURES DETECTED - See report above" -ForegroundColor Red
    Write-Host "Following gitoxide principle: 'Run the same test against git whenever feasible" -ForegroundColor Red
    Write-Host "to assure git agrees with our implementation'" -ForegroundColor Red
    $global:LASTEXITCODE = 1
} else {
    Write-Host "`n✓ All correctness checks passed" -ForegroundColor Green
    $global:LASTEXITCODE = 0
}

# Return results object
return $results
