#Requires -Version 7.0
# Variability analysis script

param(
    [string]$GixPath = "C:\codedev\gitoxide\target\release\gix.exe",
    [int]$Iterations = 20
)

Set-Location "C:\codedev\gitoxide"

function Get-Stats($times) {
    $avg = ($times | Measure-Object -Average).Average
    $std = [Math]::Sqrt(($times | ForEach-Object { [Math]::Pow($_ - $avg, 2) } | Measure-Object -Average).Average)
    $min = ($times | Measure-Object -Minimum).Minimum
    $max = ($times | Measure-Object -Maximum).Maximum
    $cov = if ($avg -gt 0) { $std / $avg * 100 } else { 0 }
    return @{
        Avg = [Math]::Round($avg, 1)
        Std = [Math]::Round($std, 1)
        Min = [Math]::Round($min, 1)
        Max = [Math]::Round($max, 1)
        CoV = [Math]::Round($cov, 1)
    }
}

Write-Host "=== VARIABILITY ANALYSIS ($Iterations iterations each) ===" -ForegroundColor Cyan
Write-Host ""

$commands = @(
    @{ Name = "log -n10"; Gix = "$GixPath log -n 10"; Git = "git log --oneline -10" },
    @{ Name = "rev-list -100"; Gix = "$GixPath revision list HEAD --limit 100"; Git = "git rev-list HEAD -n 100" },
    @{ Name = "status"; Gix = "$GixPath status"; Git = "git status" },
    @{ Name = "branch"; Gix = "$GixPath branch"; Git = "git branch" }
)

foreach ($cmd in $commands) {
    Write-Host "Command: $($cmd.Name)" -ForegroundColor Yellow

    # Warm up
    Invoke-Expression $cmd.Gix 2>&1 | Out-Null
    Invoke-Expression $cmd.Git 2>&1 | Out-Null

    # Measure gix
    $gixTimes = @()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $gixTimes += (Measure-Command { Invoke-Expression $cmd.Gix 2>&1 | Out-Null }).TotalMilliseconds
    }
    $gixStats = Get-Stats $gixTimes

    # Measure git
    $gitTimes = @()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $gitTimes += (Measure-Command { Invoke-Expression $cmd.Git 2>&1 | Out-Null }).TotalMilliseconds
    }
    $gitStats = Get-Stats $gitTimes

    Write-Host "  gix: Avg=$($gixStats.Avg)ms, StdDev=$($gixStats.Std)ms, CoV=$($gixStats.CoV)%, Range=[$($gixStats.Min)-$($gixStats.Max)]"
    Write-Host "  git: Avg=$($gitStats.Avg)ms, StdDev=$($gitStats.Std)ms, CoV=$($gitStats.CoV)%, Range=[$($gitStats.Min)-$($gitStats.Max)]"
    Write-Host "  Ratio: $([Math]::Round($gixStats.Avg / $gitStats.Avg, 2))x, Variability ratio: $([Math]::Round($gixStats.CoV / [Math]::Max($gitStats.CoV, 0.1), 2))x"
    Write-Host ""
}

Write-Host "=== ANALYSIS ===" -ForegroundColor Cyan
Write-Host "CoV (Coefficient of Variation) measures consistency - lower is better."
Write-Host "Variability ratio shows how much more variable gix is compared to git."
