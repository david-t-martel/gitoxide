# Gitoxide Development Environment

## Build System

**Always use `build.ps1` for all build operations.** This script properly configures the MSVC environment through CargoTools.

### Quick Reference

```powershell
# Standard release build (max-pure features)
./build.ps1

# Optimized distribution build
./build.ps1 -Profile release-github

# Check compilation only
./build.ps1 -Check

# Run with clippy linting
./build.ps1 -Check -Clippy

# Auto-fix formatting and lint issues
./build.ps1 -Fix

# Full build with tests
./build.ps1 -Test

# Clean rebuild
./build.ps1 -Clean -Profile release

# Quick build (skip preflight checks)
./build.ps1 -Quick
```

### Build Profiles

| Profile | Description | Use Case |
|---------|-------------|----------|
| `debug` | Fast compilation, slower runtime | Development |
| `release` | Balanced optimization (thin LTO) | Local testing |
| `release-optimized` | Maximum performance (fat LTO, panic=abort) | Benchmarking |
| `release-github` | Distribution build (fat LTO, safe unwinding) | Releases |

**Performance Tip**: Use `-Profile release-optimized` for benchmarking - it provides 20-35ms faster startup than standard release.

### Feature Sets

| Feature | Description |
|---------|-------------|
| `max-pure` | All features with pure Rust HTTP (default) |
| `max` | All features with curl/openssl HTTP |
| `lean` | Smaller build, line progress only |
| `small` | Minimal single-core optimized |

## CargoTools Integration

The build.ps1 script uses the CargoTools PowerShell module for:
- Automatic MSVC environment setup
- sccache acceleration
- Preflight checks (cargo check, clippy, fmt)
- Build output auto-copy to local target directory

### Direct CargoTools Usage

```powershell
# If you need direct cargo access with proper environment
Import-Module CargoTools
Invoke-CargoWrapper check --features max-pure
Invoke-CargoWrapper build --release --features max-pure
```

## Project Structure

- `gix/` - Main git library
- `gix-*/` - Component crates (64+ crates)
- `gitoxide-core/` - CLI core functionality
- `src/` - Binary entry points (gix, ein)
- `tests/comparison/` - Performance benchmarks vs git

## Testing

```powershell
# Run all tests
./build.ps1 -Test

# Run specific test
cargo test -p gix-ref test_name
```

## Performance Benchmarks

```powershell
# Run benchmark suite
./tests/comparison/benchmark_runner.ps1 -TestRepo .

# Advanced profiling with statistics
./tests/comparison/profiling/profile_runner.ps1 -Iterations 30

# Track performance over time
./tests/comparison/tracker.ps1 -GenerateReport
```

## Performance Optimization Guidelines

When implementing new commands or modifying existing ones, follow these optimization patterns:

### Object Cache
Always enable object cache for CLI operations:
```rust
repo.object_cache_size_if_unset(4 * 1024 * 1024); // 4MB minimum, 8MB for tree operations
```

### Reference Operations
Use `.peeled()` for efficient reference iteration:
```rust
let refs = platform.tags()?.peeled()?.flatten();
// Leverages cached packed buffer automatically
```

### Parallelism Pattern
Use `gix::parallel::in_parallel()` with thread-local ODB handles:
```rust
use gix::parallel::{in_parallel, Reduce};

// Clone ODB for thread-local access
let objects = repo.objects.clone();
in_parallel(
    items.into_iter(),
    thread_limit,
    move |_| objects.clone().into_inner(), // Thread-local state
    |item, odb| process_item(item, odb),    // Consume function
    reducer,
)?;
```

### Memory Allocation
For batch operations, pre-allocate with safety margin:
```rust
let capacity = estimate + (estimate * 10 / 100); // 10% margin
let mut buffer = Vec::with_capacity(capacity);
```

### Current Performance Status (vs git)

**Gix Wins (8x-2x faster)**:
- log-count-all (8.4x), diff (3.7x), log-100 (2.3x), index-info (1.9x)

**Near Parity** (startup-dominated):
- rev-parse, config, cat-file, branch-list, tag-list

**Optimization Targets**:
- commit-graph-verify - needs parallelism
- blame - partially parallel, room for improvement

See `docs/OPTIMIZATION_PLAN.md` for detailed analysis.

## Common Development Tasks

### Adding New Commands

1. Add options struct in `src/plumbing/options/mod.rs`
2. Add subcommand variant to `Subcommands` enum
3. Implement handler in `src/plumbing/main.rs`
4. Add core logic in `gitoxide-core/src/repository/`

### Feature Flags

Commands behind `blocking-client` feature:
- fetch, clone, pull, remote

Enable with `--features gitoxide-core-blocking-client` or use `max-pure`/`max` feature sets.
