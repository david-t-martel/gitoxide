#Requires -Version 7.0
<#
.SYNOPSIS
    Post-build hook for gitoxide to run comparison tests

.DESCRIPTION
    Intended to be called after successful builds to track performance
    and detect regressions. Can be integrated into CI/CD pipelines.

.EXAMPLE
    # In build script or CI
    cargo build --profile release-github --features max-pure
    ./tests/comparison/post-build-check.ps1

.EXAMPLE
    # As part of CargoTools build
    Invoke-CargoBuild -Path . -Release -Features max-pure
    ./tests/comparison/post-build-check.ps1 -Quick
#>

param(
    [switch]$Quick,           # Skip full benchmarks, just feature check
    [switch]$UpdateBaseline,  # Update baseline after successful check
    [switch]$FailOnRegression,# Exit with error if regression detected
    [int]$RegressionThreshold = 15,  # Percent slowdown to flag
    [string]$GixPath = "C:\codedev\gitoxide\gix.exe"
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)

Write-Host "`n=== Gitoxide Post-Build Check ===" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Verify build exists
if (-not (Test-Path $GixPath)) {
    Write-Error "gix.exe not found at: $GixPath"
    exit 1
}

$version = & $GixPath --version 2>&1
Write-Host "Version: $version"

# Quick sanity checks
Write-Host "`n[Sanity Checks]" -ForegroundColor Yellow

$checks = @(
    @{ Name = "gix --version"; Cmd = { & $GixPath --version } },
    @{ Name = "gix status"; Cmd = { Push-Location $RootDir; & $GixPath status 2>&1 | Out-Null; Pop-Location } },
    @{ Name = "gix log -1"; Cmd = { Push-Location $RootDir; & $GixPath log -1 2>&1 | Out-Null; Pop-Location } }
)

$allPassed = $true
foreach ($check in $checks) {
    try {
        & $check.Cmd | Out-Null
        Write-Host "  [PASS] $($check.Name)" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $($check.Name): $_" -ForegroundColor Red
        $allPassed = $false
    }
}

if (-not $allPassed) {
    Write-Error "Sanity checks failed!"
    exit 1
}

# Run benchmarks (unless Quick mode)
if (-not $Quick) {
    Write-Host "`n[Running Benchmarks]" -ForegroundColor Yellow
    $benchScript = Join-Path $ScriptDir "benchmark_runner.ps1"

    if (Test-Path $benchScript) {
        & $benchScript -TestRepo $RootDir -Iterations 3 | Out-Null
        Write-Host "  Benchmarks completed" -ForegroundColor Green
    }
}

# Check for regressions
if ($FailOnRegression -and -not $Quick) {
    Write-Host "`n[Regression Check]" -ForegroundColor Yellow
    $tracker = Join-Path $ScriptDir "tracker.ps1"

    if (Test-Path $tracker) {
        $pass = & $tracker -CheckRegression -Threshold $RegressionThreshold
        if (-not $pass) {
            Write-Error "Performance regression detected! Threshold: $RegressionThreshold%"
            exit 1
        }
    }
}

# Update baseline if requested
if ($UpdateBaseline) {
    Write-Host "`n[Updating Baseline]" -ForegroundColor Yellow
    $tracker = Join-Path $ScriptDir "tracker.ps1"

    if (Test-Path $tracker) {
        & $tracker -UpdateBaseline
    }
}

# Show summary report
Write-Host ""
$tracker = Join-Path $ScriptDir "tracker.ps1"
if (Test-Path $tracker) {
    & $tracker -GenerateReport
}

Write-Host "`n=== Post-Build Check Complete ===" -ForegroundColor Green
exit 0
