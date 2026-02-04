# Full gix vs git benchmark suite

Set-Location "C:\codedev\gitoxide"

Write-Host "=== FULL GIX VS GIT BENCHMARK ===" -ForegroundColor Cyan
Write-Host "Repository: $(Get-Location)" -ForegroundColor Gray
Write-Host "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""

$iterations = 10

function Measure-Command-Avg {
    param($Command, $Iterations)
    $times = @()
    for ($i = 0; $i -lt $Iterations; $i++) {
        $times += (Measure-Command { Invoke-Expression $Command 2>&1 | Out-Null }).TotalMilliseconds
    }
    return @{
        Avg = [Math]::Round(($times | Measure-Object -Average).Average, 1)
        Min = [Math]::Round(($times | Measure-Object -Minimum).Minimum, 1)
        Max = [Math]::Round(($times | Measure-Object -Maximum).Maximum, 1)
    }
}

$commands = @(
    @{ Name = "ls-files"; Gix = ".\target\release\gix.exe index entries --no-attributes"; Git = "git ls-files" },
    @{ Name = "log -n10"; Gix = ".\target\release\gix.exe log -n 10"; Git = "git log --oneline -10" },
    @{ Name = "rev-list -100"; Gix = ".\target\release\gix.exe revision list HEAD --limit 100"; Git = "git rev-list HEAD -n 100" },
    @{ Name = "status"; Gix = ".\target\release\gix.exe status"; Git = "git status" },
    @{ Name = "branch list"; Gix = ".\target\release\gix.exe branch"; Git = "git branch" },
    @{ Name = "rev-parse HEAD"; Gix = ".\target\release\gix.exe rev-parse HEAD"; Git = "git rev-parse HEAD" },
    @{ Name = "diff tree"; Gix = ".\target\release\gix.exe diff tree HEAD~1 HEAD"; Git = "git diff-tree -r HEAD~1 HEAD" }
)

Write-Host "Warming up..." -ForegroundColor Yellow
foreach ($cmd in $commands) {
    Invoke-Expression $cmd.Gix 2>&1 | Out-Null
    Invoke-Expression $cmd.Git 2>&1 | Out-Null
}

Write-Host ""
Write-Host "Running $iterations iterations per command..." -ForegroundColor Yellow
Write-Host ""

$results = @()
foreach ($cmd in $commands) {
    Write-Host "Testing: $($cmd.Name)..." -ForegroundColor Gray
    $gixStats = Measure-Command-Avg -Command $cmd.Gix -Iterations $iterations
    $gitStats = Measure-Command-Avg -Command $cmd.Git -Iterations $iterations
    $ratio = [Math]::Round($gixStats.Avg / $gitStats.Avg, 2)

    $results += @{
        Name = $cmd.Name
        GixAvg = $gixStats.Avg
        GitAvg = $gitStats.Avg
        Ratio = $ratio
    }
}

Write-Host ""
Write-Host "=== RESULTS ===" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-18} {1,10} {2,10} {3,10} {4,15}" -f "Command", "gix (ms)", "git (ms)", "Ratio", "Status")
Write-Host ("{0,-18} {1,10} {2,10} {3,10} {4,15}" -f "-------", "--------", "--------", "-----", "------")

foreach ($r in $results | Sort-Object { $_.Ratio }) {
    $status = if ($r.Ratio -lt 1) { "FASTER" } elseif ($r.Ratio -lt 2) { "Good" } elseif ($r.Ratio -lt 3) { "OK" } else { "Needs work" }
    $color = if ($r.Ratio -lt 1) { "Green" } elseif ($r.Ratio -lt 2) { "Cyan" } elseif ($r.Ratio -lt 3) { "Yellow" } else { "Red" }
    Write-Host ("{0,-18} {1,10} {2,10} {3,10} {4,15}" -f $r.Name, $r.GixAvg, $r.GitAvg, "${ratio}x".Replace("$ratio", $r.Ratio), $status) -ForegroundColor $color
}

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
$avgRatio = [Math]::Round(($results | Measure-Object -Property Ratio -Average).Average, 2)
$minRatio = ($results | Measure-Object -Property Ratio -Minimum).Minimum
$maxRatio = ($results | Measure-Object -Property Ratio -Maximum).Maximum
Write-Host "Average ratio: ${avgRatio}x"
Write-Host "Best ratio: ${minRatio}x ($($results | Where-Object { $_.Ratio -eq $minRatio } | Select-Object -First 1 -ExpandProperty Name))"
Write-Host "Worst ratio: ${maxRatio}x ($($results | Where-Object { $_.Ratio -eq $maxRatio } | Select-Object -First 1 -ExpandProperty Name))"
