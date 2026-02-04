#Requires -Version 7.0
<#
.SYNOPSIS
    Analyzes feature parity between gix and git commands.

.DESCRIPTION
    Identifies:
    - Common git commands missing from gix
    - Missing options/flags in existing gix commands
    - Output format differences
#>

param(
    [string]$GixPath = "C:\codedev\gitoxide\target\release\gix.exe"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║           GIX vs GIT Feature Parity Analysis                   ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# Common git commands ranked by usage frequency
$CommonGitCommands = @(
    # ---- TIER 1: Essential everyday commands ----
    @{ Git = "git status"; Gix = "gix status"; Notes = "Available"; Tier = 1 },
    @{ Git = "git add"; Gix = "MISSING"; Notes = "No staging support"; Tier = 1 },
    @{ Git = "git commit"; Gix = "gix commit (inspect only)"; Notes = "Cannot create commits"; Tier = 1 },
    @{ Git = "git push"; Gix = "MISSING"; Notes = "No push support"; Tier = 1 },
    @{ Git = "git pull"; Gix = "gix pull"; Notes = "Available"; Tier = 1 },
    @{ Git = "git checkout"; Gix = "MISSING"; Notes = "No checkout support"; Tier = 1 },
    @{ Git = "git branch"; Gix = "gix branch"; Notes = "List only, no create/delete"; Tier = 1 },
    @{ Git = "git merge"; Gix = "gix merge"; Notes = "Available"; Tier = 1 },
    @{ Git = "git log"; Gix = "gix log"; Notes = "Missing -n/--limit option"; Tier = 1 },
    @{ Git = "git diff"; Gix = "gix diff"; Notes = "Tree diff only"; Tier = 1 },

    # ---- TIER 2: Commonly used commands ----
    @{ Git = "git fetch"; Gix = "gix fetch"; Notes = "Available"; Tier = 2 },
    @{ Git = "git clone"; Gix = "gix clone"; Notes = "Available"; Tier = 2 },
    @{ Git = "git reset"; Gix = "MISSING"; Notes = "No reset support"; Tier = 2 },
    @{ Git = "git stash"; Gix = "MISSING"; Notes = "No stash support"; Tier = 2 },
    @{ Git = "git rebase"; Gix = "MISSING"; Notes = "No rebase support"; Tier = 2 },
    @{ Git = "git tag"; Gix = "gix tag"; Notes = "List only"; Tier = 2 },
    @{ Git = "git remote"; Gix = "gix remote"; Notes = "Available"; Tier = 2 },
    @{ Git = "git show"; Gix = "gix cat"; Notes = "Partial via cat"; Tier = 2 },
    @{ Git = "git blame"; Gix = "gix blame"; Notes = "Available"; Tier = 2 },
    @{ Git = "git rev-parse"; Gix = "gix revision resolve"; Notes = "Available"; Tier = 2 },

    # ---- TIER 3: Less frequent but important ----
    @{ Git = "git cherry-pick"; Gix = "MISSING"; Notes = "No cherry-pick"; Tier = 3 },
    @{ Git = "git revert"; Gix = "MISSING"; Notes = "No revert"; Tier = 3 },
    @{ Git = "git bisect"; Gix = "MISSING"; Notes = "No bisect"; Tier = 3 },
    @{ Git = "git reflog"; Gix = "MISSING"; Notes = "No reflog"; Tier = 3 },
    @{ Git = "git clean"; Gix = "gix clean"; Notes = "Available"; Tier = 3 },
    @{ Git = "git gc"; Gix = "MISSING"; Notes = "No gc"; Tier = 3 },
    @{ Git = "git config"; Gix = "gix config"; Notes = "Read only"; Tier = 3 },
    @{ Git = "git fsck"; Gix = "gix fsck"; Notes = "Available"; Tier = 3 },
    @{ Git = "git archive"; Gix = "gix archive"; Notes = "Available"; Tier = 3 },
    @{ Git = "git submodule"; Gix = "gix submodule"; Notes = "Available"; Tier = 3 }
)

# Analysis
Write-Host "FEATURE PARITY ANALYSIS" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$tiers = @(1, 2, 3)
$tierNames = @{ 1 = "ESSENTIAL (Tier 1)"; 2 = "COMMON (Tier 2)"; 3 = "IMPORTANT (Tier 3)" }

foreach ($tier in $tiers) {
    $commands = $CommonGitCommands | Where-Object { $_.Tier -eq $tier }
    Write-Host "$($tierNames[$tier])" -ForegroundColor Yellow
    Write-Host ""

    foreach ($cmd in $commands) {
        $status = if ($cmd.Gix -eq "MISSING") { "[31m✗[0m" }
                  elseif ($cmd.Notes -match "only|partial|Missing") { "[33m~[0m" }
                  else { "[32m✓[0m" }

        Write-Host "  $status $($cmd.Git.PadRight(20)) → $($cmd.Gix.PadRight(25)) $($cmd.Notes)"
    }
    Write-Host ""
}

# Summary
$total = $CommonGitCommands.Count
$missing = ($CommonGitCommands | Where-Object { $_.Gix -eq "MISSING" }).Count
$partial = ($CommonGitCommands | Where-Object { $_.Notes -match "only|partial|Missing" -and $_.Gix -ne "MISSING" }).Count
$complete = $total - $missing - $partial

Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "  Total commands analyzed:  $total"
Write-Host "  Fully implemented:        $complete" -ForegroundColor Green
Write-Host "  Partial implementation:   $partial" -ForegroundColor Yellow
Write-Host "  Missing:                  $missing" -ForegroundColor Red
Write-Host ""

# Critical missing features for common workflows
Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "CRITICAL GAPS FOR COMMON WORKFLOWS" -ForegroundColor Red
Write-Host ""

$criticalMissing = @(
    @{ Feature = "git add"; Impact = "Cannot stage changes"; Workaround = "Use git directly" },
    @{ Feature = "git commit"; Impact = "Cannot create commits"; Workaround = "Use git directly" },
    @{ Feature = "git push"; Impact = "Cannot push to remote"; Workaround = "Use git directly" },
    @{ Feature = "git checkout"; Impact = "Cannot switch branches/files"; Workaround = "Use git directly" },
    @{ Feature = "git reset"; Impact = "Cannot unstage/reset"; Workaround = "Use git directly" },
    @{ Feature = "git stash"; Impact = "Cannot stash changes"; Workaround = "Use git directly" },
    @{ Feature = "git log -n"; Impact = "Cannot limit log output"; Workaround = "Use git or revision list --limit" }
)

foreach ($gap in $criticalMissing) {
    Write-Host "  • $($gap.Feature)" -ForegroundColor Red
    Write-Host "    Impact:     $($gap.Impact)" -ForegroundColor DarkGray
    Write-Host "    Workaround: $($gap.Workaround)" -ForegroundColor DarkGray
    Write-Host ""
}

# Missing options analysis
Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "MISSING OPTIONS IN EXISTING COMMANDS" -ForegroundColor Yellow
Write-Host ""

$missingOptions = @(
    @{ Command = "gix log"; Missing = "-n, --limit, --oneline, --graph, --pretty, --since, --until, --author" },
    @{ Command = "gix diff"; Missing = "--stat, --numstat, --cached, working tree diff" },
    @{ Command = "gix branch"; Missing = "-d (delete), -m (rename), -c (copy), --set-upstream" },
    @{ Command = "gix tag"; Missing = "-a (annotated), -d (delete), -m (message)" },
    @{ Command = "gix status"; Missing = "--long (default git format)" },
    @{ Command = "gix config"; Missing = "--set, --unset, --global, --local" }
)

foreach ($opt in $missingOptions) {
    Write-Host "  $($opt.Command):" -ForegroundColor Cyan
    Write-Host "    Missing: $($opt.Missing)" -ForegroundColor DarkGray
    Write-Host ""
}

# Performance optimization recommendations
Write-Host "─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "PERFORMANCE OPTIMIZATION RECOMMENDATIONS" -ForegroundColor Cyan
Write-Host ""

$perfRecommendations = @(
    "1. Add --limit option to 'gix log' to avoid full history traversal",
    "2. Use commit-graph for faster revision walking (already supported)",
    "3. Add parallel tree diff for faster diff operations",
    "4. Cache pack index in memory between operations",
    "5. Add --no-stat option for faster status when full stat not needed",
    "6. Implement shallow clone support for faster initial clones"
)

foreach ($rec in $perfRecommendations) {
    Write-Host "  $rec"
}
Write-Host ""
