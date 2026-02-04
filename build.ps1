#Requires -Version 7.0
<#
.SYNOPSIS
    Gitoxide build script with CargoTools integration.

.DESCRIPTION
    Comprehensive build script for gitoxide that leverages CargoTools for:
    - MSVC environment setup
    - sccache acceleration
    - Preflight checks (cargo check, clippy, fmt)
    - Auto-fix for formatting issues
    - Streaming output and progress
    - LLM-friendly error diagnostics

.PARAMETER Profile
    Build profile:
    - 'debug': Fast compilation, slower runtime
    - 'release': Balanced optimization (default)
    - 'release-optimized': Maximum performance (panic=abort, fat LTO)
    - 'release-github': Distribution build (safe unwinding, fat LTO)
    Default: 'release'

.PARAMETER Features
    Feature set to enable: 'max', 'max-pure', 'lean', 'small', or custom feature string.
    Default: 'max-pure'

.PARAMETER Check
    Run cargo check only (no build).

.PARAMETER Clippy
    Run clippy linting.

.PARAMETER Fix
    Auto-fix formatting and lint issues where possible.

.PARAMETER Test
    Run tests after build.

.PARAMETER Clean
    Clean build artifacts before building.

.PARAMETER Verbose
    Enable verbose output.

.PARAMETER Quick
    Skip preflight checks for faster builds.

.PARAMETER NoAutoCopy
    Disable automatic copying of built executables to project root.

.EXAMPLE
    ./build.ps1
    # Default release build with max-pure features

.EXAMPLE
    ./build.ps1 -Profile release-github -Features max
    # Optimized distribution build with all features

.EXAMPLE
    ./build.ps1 -Fix
    # Run auto-fix for formatting and lint issues

.EXAMPLE
    ./build.ps1 -Check -Clippy
    # Run check and clippy without building

.NOTES
    Requires CargoTools module. Install with:
    Install-Module CargoTools -Scope CurrentUser
#>

[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [ValidateSet('debug', 'release', 'release-optimized', 'release-github')]
    [string]$Profile = 'release',

    [string]$Features = 'max-pure',

    [Parameter(ParameterSetName = 'Check')]
    [switch]$Check,

    [switch]$Clippy,

    [Parameter(ParameterSetName = 'Fix')]
    [switch]$Fix,

    [switch]$Test,

    [switch]$Clean,

    [switch]$Quick,

    [switch]$NoAutoCopy,

    [Alias('v')]
    [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = $PSScriptRoot

# Import CargoTools module
if (-not (Get-Module -Name CargoTools -ErrorAction SilentlyContinue)) {
    try {
        Import-Module CargoTools -ErrorAction Stop
    } catch {
        Write-Error @"
CargoTools module not found. Please install it:
    Install-Module CargoTools -Scope CurrentUser

Or ensure it's in your PSModulePath.
"@
        exit 1
    }
}

function Write-BuildHeader {
    param([string]$Message)
    Write-Host "`n" -NoNewline
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-BuildStatus {
    param(
        [string]$Phase,
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    $color = switch ($Type) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        default { 'Gray' }
    }
    Write-Host "  [$Phase] " -NoNewline -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor $color
}

function Invoke-AutoFix {
    <#
    .SYNOPSIS
        Run auto-fix for formatting and lint issues.
    #>
    Write-BuildHeader "Auto-Fix Mode"

    # Format with rustfmt
    Write-BuildStatus -Phase 'Format' -Message 'Running cargo fmt...' -Type 'Info'
    $fmtResult = & rustup run stable cargo fmt 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-BuildStatus -Phase 'Format' -Message 'Formatting complete' -Type 'Success'
    } else {
        Write-BuildStatus -Phase 'Format' -Message "Formatting failed: $fmtResult" -Type 'Warning'
    }

    # Run clippy with auto-fix
    Write-BuildStatus -Phase 'Clippy' -Message 'Running clippy --fix...' -Type 'Info'
    $clippyArgs = @(
        'clippy',
        '--features', $Features,
        '--fix',
        '--allow-dirty',
        '--allow-staged'
    )
    & rustup run stable cargo @clippyArgs 2>&1 | ForEach-Object {
        if ($_ -match 'error|warning') {
            Write-Host $_ -ForegroundColor Yellow
        } elseif ($VerboseOutput) {
            Write-Host $_ -ForegroundColor Gray
        }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-BuildStatus -Phase 'Clippy' -Message 'Lint fixes applied' -Type 'Success'
    } else {
        Write-BuildStatus -Phase 'Clippy' -Message 'Some issues could not be auto-fixed' -Type 'Warning'
    }

    return 0
}

function Invoke-Preflight {
    <#
    .SYNOPSIS
        Run preflight checks with detailed feedback.
    #>
    Write-BuildHeader "Preflight Checks"
    $allPassed = $true

    # Check formatting
    Write-BuildStatus -Phase 'Format' -Message 'Checking formatting...' -Type 'Info'
    $fmtCheck = & rustup run stable cargo fmt --check 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-BuildStatus -Phase 'Format' -Message 'OK' -Type 'Success'
    } else {
        Write-BuildStatus -Phase 'Format' -Message 'Issues found (run with -Fix to auto-fix)' -Type 'Warning'
        $allPassed = $false
    }

    # Run cargo check
    Write-BuildStatus -Phase 'Check' -Message 'Running cargo check...' -Type 'Info'
    $checkArgs = @('check', '--features', $Features)
    & rustup run stable cargo @checkArgs 2>&1 | ForEach-Object {
        if ($_ -match 'error\[') {
            Write-Host $_ -ForegroundColor Red
            $allPassed = $false
        } elseif ($_ -match 'warning:') {
            Write-Host $_ -ForegroundColor Yellow
        } elseif ($VerboseOutput) {
            Write-Host $_ -ForegroundColor Gray
        }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-BuildStatus -Phase 'Check' -Message 'OK' -Type 'Success'
    } else {
        Write-BuildStatus -Phase 'Check' -Message 'Failed' -Type 'Error'
        $allPassed = $false
    }

    # Run clippy if requested
    if ($Clippy) {
        Write-BuildStatus -Phase 'Clippy' -Message 'Running clippy...' -Type 'Info'
        $clippyArgs = @('clippy', '--features', $Features, '--', '-D', 'warnings')
        & rustup run stable cargo @clippyArgs 2>&1 | ForEach-Object {
            if ($_ -match 'error\[') {
                Write-Host $_ -ForegroundColor Red
            } elseif ($_ -match 'warning:') {
                Write-Host $_ -ForegroundColor Yellow
            } elseif ($VerboseOutput) {
                Write-Host $_ -ForegroundColor Gray
            }
        }
        if ($LASTEXITCODE -eq 0) {
            Write-BuildStatus -Phase 'Clippy' -Message 'OK' -Type 'Success'
        } else {
            Write-BuildStatus -Phase 'Clippy' -Message 'Issues found' -Type 'Warning'
            $allPassed = $false
        }
    }

    return $allPassed
}

function Invoke-Build {
    <#
    .SYNOPSIS
        Run the main build using CargoTools wrapper.
    #>
    Write-BuildHeader "Building Gitoxide"

    $buildArgs = New-Object System.Collections.Generic.List[string]
    $buildArgs.Add('build')
    $buildArgs.Add('--features')
    $buildArgs.Add($Features)

    # Add profile flag
    switch ($Profile) {
        'debug' {
            # No flag needed for debug
        }
        'release' {
            $buildArgs.Add('--release')
        }
        'release-optimized' {
            $buildArgs.Add('--profile')
            $buildArgs.Add('release-optimized')
        }
        'release-github' {
            $buildArgs.Add('--profile')
            $buildArgs.Add('release-github')
        }
    }

    # Add verbose flag if requested
    if ($VerboseOutput) {
        $buildArgs.Add('-v')
    }

    Write-BuildStatus -Phase 'Build' -Message "Profile: $Profile, Features: $Features" -Type 'Info'

    # Use CargoTools wrapper for the build
    $preflightFlags = if ($Quick) { '--preflight-nonblocking' } else { @() }
    $autoCopyFlag = if ($NoAutoCopy) { '--no-auto-copy' } else { '--auto-copy' }

    $wrapperArgs = @($preflightFlags) + @($autoCopyFlag) + $buildArgs.ToArray()

    $startTime = Get-Date
    Invoke-CargoWrapper @wrapperArgs
    $exitCode = $LASTEXITCODE
    $elapsed = (Get-Date) - $startTime

    if ($exitCode -eq 0) {
        Write-BuildStatus -Phase 'Build' -Message "Completed in $([Math]::Round($elapsed.TotalSeconds, 2))s" -Type 'Success'

        # Show build artifacts
        $targetDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $ScriptRoot 'target' }
        $profileDir = switch ($Profile) {
            'debug' { 'debug' }
            'release' { 'release' }
            'release-optimized' { 'release-optimized' }
            'release-github' { 'release-github' }
        }
        $exePath = Join-Path $targetDir $profileDir 'gix.exe'
        if (Test-Path $exePath) {
            $size = [Math]::Round((Get-Item $exePath).Length / 1MB, 2)
            Write-BuildStatus -Phase 'Output' -Message "gix.exe: $size MB at $exePath" -Type 'Info'
        }
    } else {
        Write-BuildStatus -Phase 'Build' -Message "Failed with exit code $exitCode" -Type 'Error'
    }

    return $exitCode
}

function Invoke-Tests {
    <#
    .SYNOPSIS
        Run the test suite.
    #>
    Write-BuildHeader "Running Tests"

    $testArgs = @('test', '--features', $Features)
    if ($Profile -eq 'release' -or $Profile -eq 'release-github') {
        $testArgs += '--release'
    }

    Invoke-CargoWrapper @testArgs
    return $LASTEXITCODE
}

# =============================================================================
# Main execution
# =============================================================================

Write-Host "`n" -NoNewline
Write-Host "Gitoxide Build System" -ForegroundColor Cyan
Write-Host "Using CargoTools v$((Get-Module CargoTools).Version)" -ForegroundColor DarkGray
Write-Host ""

Push-Location $ScriptRoot

try {
    # Clean if requested
    if ($Clean) {
        Write-BuildHeader "Cleaning Build Artifacts"
        & rustup run stable cargo clean
        if ($LASTEXITCODE -eq 0) {
            Write-BuildStatus -Phase 'Clean' -Message 'Done' -Type 'Success'
        }
    }

    # Handle Fix mode
    if ($Fix) {
        $result = Invoke-AutoFix
        exit $result
    }

    # Handle Check-only mode
    if ($Check) {
        $passed = Invoke-Preflight
        if ($passed) {
            Write-Host "`nAll checks passed!" -ForegroundColor Green
            exit 0
        } else {
            Write-Host "`nSome checks failed. Run with -Fix to auto-fix issues." -ForegroundColor Yellow
            exit 1
        }
    }

    # Run preflight unless Quick mode
    if (-not $Quick) {
        $preflightPassed = Invoke-Preflight
        if (-not $preflightPassed) {
            Write-Host "`nPreflight issues detected. Continuing with build..." -ForegroundColor Yellow
            Write-Host "Run with -Fix to auto-fix, or -Quick to skip preflight." -ForegroundColor DarkGray
        }
    }

    # Run build
    $buildResult = Invoke-Build
    if ($buildResult -ne 0) {
        exit $buildResult
    }

    # Run tests if requested
    if ($Test) {
        $testResult = Invoke-Tests
        if ($testResult -ne 0) {
            exit $testResult
        }
    }

    Write-Host "`n" -NoNewline
    Write-Host ("=" * 70) -ForegroundColor Green
    Write-Host " BUILD SUCCESSFUL" -ForegroundColor Green
    Write-Host ("=" * 70) -ForegroundColor Green

    exit 0

} finally {
    Pop-Location
}
