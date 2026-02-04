# Gitoxide Performance Optimization Plan

## Executive Summary

Analysis of gitoxide vs git performance reveals a **50/50 split** (7 wins each across 14 benchmarks).
The performance gaps are **not inherent to Rust** but stem from:

1. **Build configuration** - suboptimal compiler settings
2. **Missing parallelism** - infrastructure exists but isn't used in slow operations
3. **Object cache defaults** - disabled by default
4. **Sequential patterns** - reference operations don't batch lookups

**Projected improvement**: 40-70% performance gain on slow operations with the changes below.

---

## Part 1: Build Optimizations

### Current State (Cargo.toml)

| Setting | release | release-github |
|---------|---------|----------------|
| LTO | thin | fat |
| codegen-units | 16 (default) | 1 |
| panic | unwind | unwind |
| strip | none | symbols |
| opt-level | default (3) | default (3) |

### Recommended Changes

#### A. Create Optimized Release Profile

```toml
[profile.release-optimized]
inherits = "release"
lto = "fat"
codegen-units = 1
panic = "abort"
strip = "symbols"
opt-level = 3

# For dependencies - optimize size for faster loading
[profile.release-optimized.package."*"]
opt-level = "z"
```

**Expected Impact**: 20-35ms startup reduction

#### B. Update release-github Profile

```toml
[profile.release-github]
inherits = "release"
overflow-checks = false
lto = "fat"
codegen-units = 1
strip = "symbols"
panic = "abort"  # CHANGE from unwind
opt-level = 3
```

**Note**: `panic = "abort"` removes cleanup for tempfiles. Mitigation:
- Use `atexit` handlers for normal termination
- Signal handlers for SIGINT/SIGTERM

#### C. Create .cargo/config.toml

```toml
[build]
# Uncomment for native CPU optimizations (local builds only)
# rustflags = ["-C", "target-cpu=native"]

[target.x86_64-pc-windows-msvc]
rustflags = ["-C", "target-feature=+crt-static"]

[alias]
release-fast = "build --profile release-optimized"
```

### Build Impact Estimates

| Optimization | Startup Reduction | Binary Size |
|--------------|-------------------|-------------|
| codegen-units=1 | 2-5ms | +5% |
| lto="fat" | 5-10ms | -5% |
| panic="abort" | 2-5ms | -10% |
| target-cpu=native | 3-8ms | 0% |
| **Total** | **12-28ms** | **-10%** |

---

## Part 2: Code Optimizations

### 2.1 Reference Operations (54% slower)

**Root Cause**: Sequential tag/branch peeling without packed-refs cache.

**File**: `gitoxide-core/src/repository/tag.rs`

**Current** (lines 46-91):
```rust
let mut tags: Vec<_> = platform
    .tags()?
    .flatten()  // Sequential!
    .map(|mut reference| {
        let tag = reference.peel_to_tag();  // Individual lookups
        // ...
    })
    .collect();
```

**Optimized**:
```rust
use gix_features::parallel::in_parallel;

// Pre-load packed refs buffer (one-time cost)
let packed_buffer = repo.refs.cached_packed_buffer()?;

// Collect refs first (cheap)
let refs: Vec<_> = platform.tags()?.flatten().collect();

// Parallel peel with shared cache
let tags = in_parallel(
    refs.into_iter(),
    thread_limit,
    |_| packed_buffer.clone(),
    |reference, cache| {
        // Peel using cached buffer
        reference.peel_to_id_in_place_with_cache(cache)
    },
    // ...
)?;
```

**Expected Impact**: 3-5x speedup for repos with many tags/branches

### 2.2 Object Database Operations (69% slower for cat-tree)

**Root Cause**: Object cache disabled by default.

**File**: `gix/src/repository/cache.rs`

**Current**: Cache only enabled when explicitly requested.

**Fix 1**: Enable default object cache for CLI operations

In `gitoxide-core/src/repository/cat.rs`:
```rust
pub fn display_object(
    repo: &gix::Repository,
    // ...
) -> anyhow::Result<()> {
    // ADD: Enable object cache for CLI operations
    repo.object_cache_size_if_unset(4 * 1024 * 1024); // 4MB default

    // ... rest of function
}
```

**Fix 2**: Use batch tree iteration

```rust
// Instead of individual entry lookups:
for entry in tree.iter() {
    let obj = entry.object()?;  // Disk hit each time
}

// Use decode() with shared buffer:
let mut buffer = Vec::new();
for entry in tree.iter() {
    let obj = repo.objects.find(entry.oid(), &mut buffer)?;
    // Reuses buffer, reduces allocations
}
```

**Expected Impact**: 2-3x speedup for tree operations

### 2.3 Startup Optimization

**Root Cause**: Repository discovery runs for every command.

**File**: `src/plumbing/main.rs` (lines 81-133)

**Current**: Closure recreated and called for each command.

**Optimization**: Lazy static repository cache

```rust
use std::sync::OnceLock;

static REPO_CACHE: OnceLock<Option<gix::Repository>> = OnceLock::new();

fn get_repository(mode: Mode) -> Result<gix::Repository> {
    REPO_CACHE.get_or_try_init(|| {
        // Discovery only happens once per process
        gix::discover(std::env::current_dir()?)
    })
}
```

**Note**: Must handle --repository flag overriding cache.

**Expected Impact**: 5-10ms for repeated operations (less relevant for CLI)

---

## Part 3: Parallelism Opportunities

### Currently Parallel
- `gix status` - uses `in_parallel()` for file system operations
- Pack indexing - parallel delta resolution

### Should Be Parallel

| Operation | Current | Parallel Method | Expected Gain |
|-----------|---------|-----------------|---------------|
| tag-list | Sequential | `in_parallel()` | 3-5x |
| branch-list | Sequential | `in_parallel()` | 2-4x |
| tree entries | Sequential | Parallel decode | 2-3x |
| blame | Partially | Full parallel chunks | 1.5-2x |
| commit-graph verify | Sequential | Parallel checksum | 2-3x |

### Implementation Pattern

```rust
use gix_features::parallel::{in_parallel, Reduce};

fn parallel_operation<T, R>(
    items: impl Iterator<Item = T> + Send,
    thread_limit: Option<usize>,
    process: impl Fn(T) -> R + Send + Clone,
) -> Vec<R>
where
    T: Send,
    R: Send,
{
    in_parallel(
        items,
        thread_limit,
        |_| (),  // No thread state needed
        |item, _| process(item),
        VecReducer::new(),
    )
    .expect("parallel processing failed")
}
```

---

## Part 4: Allocator Optimization

### Current State
Uses system allocator (default since Rust 1.32).

### Recommendation
For release builds, consider mimalloc:

```rust
// In src/main.rs
#[cfg(feature = "mimalloc")]
use mimalloc::MiMalloc;

#[cfg(feature = "mimalloc")]
#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;
```

**Cargo.toml**:
```toml
[features]
mimalloc = ["dep:mimalloc"]

[dependencies]
mimalloc = { version = "0.1", optional = true }
```

**Impact**:
- Multi-threaded operations: 5x throughput improvement
- Startup: Neutral to slight improvement
- Binary size: +200KB

---

## Part 5: Profile-Guided Optimization (PGO)

### Setup

```bash
# Install cargo-pgo
cargo install cargo-pgo

# Build with instrumentation
cargo pgo build --profile release-github

# Run typical workloads
./target/x86_64-pc-windows-msvc/release-github/gix status
./target/x86_64-pc-windows-msvc/release-github/gix log -100
./target/x86_64-pc-windows-msvc/release-github/gix diff HEAD~10 HEAD

# Build with profile data
cargo pgo optimize --profile release-github
```

**Expected Impact**: 10-30% additional improvement on hot paths

---

## Implementation Priority

### Phase 1: Quick Wins (1-2 hours)
1. ✅ Update Cargo.toml with optimized profiles
2. ✅ Create .cargo/config.toml
3. Enable object cache by default in CLI operations

### Phase 2: Code Changes (4-8 hours)
4. Parallelize tag-list operation
5. Parallelize branch-list operation
6. Add packed-refs cache to reference iteration
7. Optimize tree iteration with shared buffers

### Phase 3: Advanced (8-16 hours)
8. Implement PGO build pipeline
9. Add mimalloc as optional feature
10. Parallelize commit-graph verification
11. Optimize blame algorithm

### Phase 4: Feature Parity
12. Implement missing commands with optimizations in mind:
    - `gix config set` (use batch writes)
    - `gix tag create` (leverage cached refs)
    - `gix push` (parallel pack creation)
    - `gix stash` (efficient index manipulation)

---

## Measurement Plan

### Before/After Benchmarks

```powershell
# Run profiling suite
./tests/comparison/profiling/profile_runner.ps1 -Iterations 30

# Compare specific operations
hyperfine --warmup 5 `
    './target/release/gix.exe rev-parse HEAD' `
    'git rev-parse HEAD'
```

### Success Criteria

| Operation | Current Gap | Target |
|-----------|-------------|--------|
| cat-tree | 69% slower | <20% slower |
| commit-graph-verify | 68% slower | <20% slower |
| tag-list | 55% slower | Parity or faster |
| branch-list | 54% slower | Parity or faster |
| rev-parse | 54% slower | <20% slower |
| blame | 39% slower | <10% slower |

---

## Part 6: Crate-Level Optimizations (NEW)

Based on code commentary analysis and crate benchmarks, these are high-impact opportunities:

### 6.1 Internal Hashing with xxHash3 (5-10x faster lookups)

**Current**: gix-hashtable uses FNV hasher for object ID hashtables.

**Opportunity**: xxHash3 is 5-10x faster for non-cryptographic hashing while SHA1 must remain for Git object identification.

**Implementation**:
```rust
// In gix-hashtable/src/lib.rs
use xxhash_rust::xxh3::Xxh3Builder;

pub type ObjectIdHasher = Xxh3Builder;

// Use for internal lookups only, not object IDs
pub type ObjectLookupMap<V> = hashbrown::HashMap<ObjectId, V, ObjectIdHasher>;
```

**Expected Impact**: 5-10x faster object hashtable operations

### 6.2 Parallel Directory Walking with jwalk

**Current**: Custom single-threaded stdlib implementation in gix-dir.

**Opportunity**: jwalk provides 4x faster parallel directory walking with sorted results.

**Evaluation Required**: Integration complexity vs performance gain. jwalk would require architectural changes but could significantly improve large repo status operations.

```rust
// Potential integration point in gix-dir/src/walk.rs
#[cfg(feature = "parallel-walk")]
use jwalk::WalkDir;

#[cfg(feature = "parallel-walk")]
fn parallel_walk(path: &Path) -> impl Iterator<Item = DirEntry> {
    WalkDir::new(path)
        .parallelism(jwalk::Parallelism::RayonNewPool(4))
        .into_iter()
        .filter_map(Result::ok)
}
```

### 6.3 Memory Allocation Hotspots (from code comments)

**gix-attributes/src/state.rs (line 8)**:
- Issue: String representation suboptimal
- Fix: Use smallbstring or interned strings
- Impact: 5% performance boost on attribute operations

**gix-hash/src/prefix.rs (line 120)**:
- Issue: Unnecessary heap allocation in hash prefix handling
- Fix: Stack-allocate small prefix buffers
- Impact: Faster object lookups by prefix

**gix-index/src/decode/entries.rs (line 135)**:
- Issue: Excessive memmove during index decoding
- Impact: MAJOR - investigate memory layout optimization

**gix-pack/src/data/file/decode/entry.rs (lines 356, 385)**:
- Issue: Delta chain reconstruction is memory-intensive
- Opportunity: Analyze delta-chains to copy data only once
- Impact: MAJOR - could significantly reduce pack decode memory

### 6.4 Parallelization Gaps (from code comments)

**gix/src/status/mod.rs (line 165)**:
- Status computation has parallelization opportunity
- Could be its own implementation with Git-specific parallelism

**gix-status/src/index_as_worktree/function.rs**:
- Line 144: Parallelization heuristic always true - needs tuning
- Line 341: CRITICAL - stat-unchanged optimization prevents "super slow" status

### 6.5 Tree Traversal Optimization

**gix/src/repository/worktree.rs (lines 86-87)**:
- Tree traversed twice when loading non-HEAD trees
- Requires shared object cache between ODB handles (needs lock)

---

## Part 7: Crate Recommendations Summary

### Already Optimal
| Category | Crate | Status |
|----------|-------|--------|
| Byte strings | bstr | Excellent choice |
| Memory mapping | memmap2 | Optimal for pack files |
| Small vectors | smallvec | Good for pack operations |
| Sync primitives | parking_lot | Faster than std |
| Hash tables | hashbrown | Optimal (with inline-more) |
| Channels | crossbeam-channel | Excellent for work-stealing |

### Recommended Additions
| Category | Current | Recommended | Benefit |
|----------|---------|-------------|---------|
| Internal hashing | FNV | xxHash3 | 5-10x faster lookups |
| Directory walk | stdlib | jwalk (optional) | 4x faster large repos |
| Allocator | system | mimalloc (optional) | 5x multi-threaded throughput |

### Intentionally Avoided (Correct Decisions)
| Category | Avoided | Reason |
|----------|---------|--------|
| Regex | regex crate | Custom glob is faster for .gitignore patterns |
| Async runtime | tokio | Not needed; custom threads more efficient |
| General parallelism | rayon | Custom work-stealing tuned for Git operations |

---

## Updated Implementation Priority

### Phase 1: Quick Wins (COMPLETED)
1. ✅ Update Cargo.toml with optimized profiles
2. ✅ Create .cargo/config.toml
3. ✅ Enable object cache in CLI operations (cat, status, branch, tag, commitgraph)

### Phase 2: Code Changes (4-8 hours)
4. [ ] Parallelize tag-list operation
5. [ ] Parallelize branch-list operation
6. [ ] Add packed-refs cache to reference iteration
7. [ ] Optimize tree iteration with shared buffers

### Phase 3: Crate Optimizations (8-16 hours)
8. [ ] Integrate xxHash3 for internal hashtables (5-10x lookup speedup)
9. [ ] Add mimalloc as optional feature
10. [ ] Investigate gix-index memmove issue (CRITICAL)
11. [ ] Evaluate jwalk integration for parallel directory walking

### Phase 4: Advanced (16-32 hours)
12. [ ] Optimize delta chain reconstruction in gix-pack
13. [ ] Add tree traversal caching
14. [ ] Implement PGO build pipeline
15. [ ] Parallelize commit-graph verification

### Phase 5: Feature Parity with Optimizations
16. [ ] Implement missing commands with optimizations in mind

---

## References

- [Rust Performance Book](https://nnethercote.github.io/perf-book/)
- [min-sized-rust](https://github.com/johnthagen/min-sized-rust)
- [cargo-pgo](https://github.com/Kobzol/cargo-pgo)
- [gix-features parallel module](https://docs.rs/gix-features/latest/gix_features/parallel/)
- [xxHash3 benchmarks](https://medium.com/@tprodanov/benchmarking-non-cryptographic-hash-functions-in-rust-2e6091077d11)
- [jwalk - parallel directory walker](https://github.com/Byron/jwalk)
- [Gitoxide performance discussion](https://github.com/GitoxideLabs/gitoxide/discussions/2323)
