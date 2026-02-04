# Memory usage benchmark for gix vs git

Set-Location "C:\codedev\gitoxide"

Write-Host "=== MEMORY USAGE BENCHMARK ===" -ForegroundColor Cyan
Write-Host ""

$commands = @(
    @{ Name = "ls-files"; Gix = ".\target\release\gix.exe index entries --no-attributes"; Git = "git ls-files" },
    @{ Name = "log -n100"; Gix = ".\target\release\gix.exe log -n 100"; Git = "git log --oneline -100" },
    @{ Name = "rev-list -500"; Gix = ".\target\release\gix.exe revision list HEAD --limit 500"; Git = "git rev-list HEAD -n 500" },
    @{ Name = "status"; Gix = ".\target\release\gix.exe status"; Git = "git status" }
)

function Measure-Memory {
    param($Command, $Name)

    # Start process and measure memory
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "cmd.exe"
    $pinfo.Arguments = "/c $Command"
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo
    $process.Start() | Out-Null

    # Sample peak memory
    $peakMem = 0
    while (-not $process.HasExited) {
        try {
            $process.Refresh()
            $currentMem = $process.PeakWorkingSet64
            if ($currentMem -gt $peakMem) {
                $peakMem = $currentMem
            }
        } catch {}
        Start-Sleep -Milliseconds 10
    }

    # Final check
    try {
        $process.Refresh()
        if ($process.PeakWorkingSet64 -gt $peakMem) {
            $peakMem = $process.PeakWorkingSet64
        }
    } catch {}

    $process.WaitForExit()
    $process.Dispose()

    return [Math]::Round($peakMem / 1MB, 2)
}

Write-Host ("{0,-18} {1,12} {2,12} {3,10}" -f "Command", "gix (MB)", "git (MB)", "Ratio")
Write-Host ("{0,-18} {1,12} {2,12} {3,10}" -f "-------", "--------", "--------", "-----")

foreach ($cmd in $commands) {
    Write-Host "Measuring: $($cmd.Name)..." -ForegroundColor Gray -NoNewline

    # Measure gix
    $gixMem = Measure-Memory -Command $cmd.Gix -Name "gix"

    # Measure git
    $gitMem = Measure-Memory -Command $cmd.Git -Name "git"

    $ratio = [Math]::Round($gixMem / [Math]::Max($gitMem, 0.01), 2)

    $color = if ($ratio -lt 1.5) { "Green" } elseif ($ratio -lt 2.5) { "Cyan" } elseif ($ratio -lt 4) { "Yellow" } else { "Red" }
    $output = "{0,-18} {1,12} {2,12} {3,10}" -f $cmd.Name, $gixMem, $gitMem, "${ratio}x"
    Write-Host "`r$output" -ForegroundColor $color
}

Write-Host ""
Write-Host "Note: Memory measurements are approximate peak working set." -ForegroundColor Gray
