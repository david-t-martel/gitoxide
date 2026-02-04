# ls-files benchmark script

Set-Location "C:\codedev\gitoxide"

Write-Host "=== LS-FILES BENCHMARK ===" -ForegroundColor Cyan
Write-Host ""

# Warm up
Write-Host "Warming up..." -ForegroundColor Yellow
.\target\release\gix.exe index entries 2>&1 | Out-Null
git ls-files 2>&1 | Out-Null

Write-Host ""
Write-Host "Running 10 iterations each..." -ForegroundColor Yellow
Write-Host ""

$gixTimes = @()
$gitTimes = @()

for ($i = 1; $i -le 10; $i++) {
    $gixTimes += (Measure-Command { .\target\release\gix.exe index entries --no-attributes 2>&1 | Out-Null }).TotalMilliseconds
    $gitTimes += (Measure-Command { git ls-files 2>&1 | Out-Null }).TotalMilliseconds
}

$gixAvg = [Math]::Round(($gixTimes | Measure-Object -Average).Average, 1)
$gitAvg = [Math]::Round(($gitTimes | Measure-Object -Average).Average, 1)
$ratio = [Math]::Round($gixAvg / $gitAvg, 2)

$gixMin = [Math]::Round(($gixTimes | Measure-Object -Minimum).Minimum, 1)
$gixMax = [Math]::Round(($gixTimes | Measure-Object -Maximum).Maximum, 1)
$gitMin = [Math]::Round(($gitTimes | Measure-Object -Minimum).Minimum, 1)
$gitMax = [Math]::Round(($gitTimes | Measure-Object -Maximum).Maximum, 1)

Write-Host "gix index entries: $gixAvg ms avg (range: $gixMin - $gixMax)" -ForegroundColor Green
Write-Host "git ls-files:      $gitAvg ms avg (range: $gitMin - $gitMax)" -ForegroundColor Green
Write-Host "Ratio:             ${ratio}x" -ForegroundColor $(if ($ratio -lt 2) { "Cyan" } else { "Yellow" })

# Verify output correctness
Write-Host ""
Write-Host "=== OUTPUT CORRECTNESS CHECK ===" -ForegroundColor Cyan

$gixOutput = .\target\release\gix.exe index entries --no-attributes 2>&1
$gitOutput = git ls-files 2>&1

$gixCount = ($gixOutput | Measure-Object -Line).Lines
$gitCount = ($gitOutput | Measure-Object -Line).Lines

Write-Host "gix output lines: $gixCount"
Write-Host "git output lines: $gitCount"

if ($gixCount -eq $gitCount) {
    # Compare actual content
    $gixSorted = $gixOutput | Sort-Object
    $gitSorted = $gitOutput | Sort-Object
    $diff = Compare-Object $gixSorted $gitSorted

    if ($diff.Count -eq 0) {
        Write-Host "[OK] Outputs match exactly!" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Outputs differ!" -ForegroundColor Red
        Write-Host "Differences found: $($diff.Count)" -ForegroundColor Red
        $diff | Select-Object -First 10 | ForEach-Object {
            Write-Host "  $($_.SideIndicator): $($_.InputObject)" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "[FAIL] Line counts differ!" -ForegroundColor Red
}
