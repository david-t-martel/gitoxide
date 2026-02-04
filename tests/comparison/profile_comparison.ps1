#Requires -Version 7.0
<#
.SYNOPSIS
    Compare performance across different build profiles.

.DESCRIPTION
    Benchmarks gix across release, release-optimized, and release-github profiles
    to measure the impact of build optimizations.

.PARAMETER Iterations
    Number of benchmark iterations per operation.
    Default: 10

.EXAMPLE
    ./profile_comparison.ps1 -Iterations 20
#>

param(
    [int]$Iterations = 10,
    [string]$TestRepo = "C:\codedev\gitoxide"
)

$ErrorActionPreference = 'Continue'

# Profile paths
$Profiles = @{
    'release' = "T:\RustCache\cargo-target\release\gix.exe"
    'release-optimized' = "T:\RustCache\cargo-target\release-optimized\gix.exe"
    'release-github' = "T:\RustCache\cargo-target\release-github\gix.exe"
}

# Operations to benchmark
$Operations = @(
    @{ Name = 'startup'; Args = @('--version') },
    @{ Name = 'rev-parse'; Args = @('revision', 'parse', 'HEAD') },
    @{ Name = 'status'; Args = @('status', '--format', 'human') },
    @{ Name = 'log-50'; Args = @('log', '-50') }
)

function Measure-Operation {
    param(
        [string]$ExePath,
        [string[]]$Args,
        [int]$Iterations
    )

    if (-not (Test-Path $ExePath)) {
        return $null
    }

    $times = @()
    # Warmup
    for ($i = 0; $i -lt 3; $i++) {
        & $ExePath @Args 2>&1 | Out-Null
    }

    # Measure
    for ($i = 0; $i -lt $Iterations; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $ExePath @Args 2>&1 | Out-Null
        $sw.Stop()
        $times += $sw.Elapsed.TotalMilliseconds
    }

    $sorted = $times | Sort-Object
    return @{
        Median = $sorted[[Math]::Floor($sorted.Count / 2)]
        Min = $sorted[0]
        Max = $sorted[-1]
    }
}

Write-Host "`n=== Gitoxide Build Profile Comparison ===" -ForegroundColor Cyan
Write-Host "Iterations: $Iterations"
Write-Host "Test Repo: $TestRepo"
Write-Host ""

Push-Location $TestRepo

try {
    # Check which profiles are available
    $availableProfiles = @{}
    foreach ($profile in $Profiles.GetEnumerator()) {
        if (Test-Path $profile.Value) {
            $availableProfiles[$profile.Key] = $profile.Value
            $version = & $profile.Value --version 2>&1
            Write-Host "[$($profile.Key)] $version" -ForegroundColor Green
        } else {
            Write-Host "[$($profile.Key)] Not built" -ForegroundColor Yellow
        }
    }

    if ($availableProfiles.Count -eq 0) {
        Write-Error "No profiles available. Run build.ps1 first."
        exit 1
    }

    Write-Host ""

    # Run benchmarks
    $results = @{}
    foreach ($op in $Operations) {
        Write-Host "Benchmarking: $($op.Name)..." -ForegroundColor Gray
        $results[$op.Name] = @{}

        foreach ($profile in $availableProfiles.GetEnumerator()) {
            $result = Measure-Operation -ExePath $profile.Value -Args $op.Args -Iterations $Iterations
            if ($result) {
                $results[$op.Name][$profile.Key] = $result
            }
        }
    }

    # Display results
    Write-Host "`n" + ("=" * 80) -ForegroundColor Cyan
    Write-Host "RESULTS (median ms)" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan

    $header = "{0,-20}" -f "Operation"
    foreach ($profile in $availableProfiles.Keys | Sort-Object) {
        $header += " {0,18}" -f $profile
    }
    Write-Host $header
    Write-Host ("-" * 80)

    foreach ($op in $Operations) {
        $line = "{0,-20}" -f $op.Name
        $baseline = $null

        foreach ($profile in $availableProfiles.Keys | Sort-Object) {
            $result = $results[$op.Name][$profile]
            if ($result) {
                if ($null -eq $baseline) {
                    $baseline = $result.Median
                    $line += " {0,15:F2} ms" -f $result.Median
                } else {
                    $diff = (($result.Median - $baseline) / $baseline) * 100
                    $color = if ($diff -lt 0) { "Green" } else { "Red" }
                    $sign = if ($diff -lt 0) { "" } else { "+" }
                    $line += " {0,9:F2} ({1}{2:F0}%)" -f $result.Median, $sign, $diff
                }
            } else {
                $line += " {0,18}" -f "N/A"
            }
        }
        Write-Host $line
    }

    Write-Host ("-" * 80)

} finally {
    Pop-Location
}

Write-Host "`nTip: Build all profiles with:" -ForegroundColor Yellow
Write-Host "  ./build.ps1 -Profile release" -ForegroundColor Gray
Write-Host "  ./build.ps1 -Profile release-optimized" -ForegroundColor Gray
Write-Host "  ./build.ps1 -Profile release-github" -ForegroundColor Gray
