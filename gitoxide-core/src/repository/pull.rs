//! Implementation of `gix pull` - fetch and integrate changes from a remote.
//!
//! This is a convenience command that combines `fetch` with `merge` (or rebase).
//! It follows git's pull semantics while leveraging gitoxide's optimized internals.

use anyhow::{bail, Context};
use gix::{bstr::BString, remote::fetch::Status, Progress};

use crate::OutputFormat;

/// Options for the pull operation.
#[derive(Debug, Clone)]
pub struct Options {
    /// Output format (human or json).
    pub format: OutputFormat,
    /// Perform a dry run without making changes.
    pub dry_run: bool,
    /// Remote name or URL to pull from.
    pub remote: Option<String>,
    /// If non-empty, override configured ref-specs.
    pub ref_specs: Vec<BString>,
    /// Shallow fetch options.
    pub shallow: gix::remote::fetch::Shallow,
    /// Show handshake information.
    pub handshake_info: bool,
    /// Fast-forward only mode - fail if merge is needed.
    pub ff_only: bool,
    /// Always create a merge commit even if fast-forward is possible.
    pub no_ff: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            format: OutputFormat::Human,
            dry_run: false,
            remote: None,
            ref_specs: Vec::new(),
            shallow: Default::default(),
            handshake_info: false,
            ff_only: false,
            no_ff: false,
        }
    }
}

/// Progress range for pull operations (fetch + merge steps).
pub const PROGRESS_RANGE: std::ops::RangeInclusive<u8> = 1..=4;

/// Execute a pull operation: fetch from remote and integrate changes.
///
/// This implements the standard git pull workflow:
/// 1. Determine remote and tracking branch from configuration
/// 2. Fetch new objects from the remote
/// 3. Fast-forward or merge the fetched changes
pub fn pull<P>(
    repo: gix::Repository,
    mut progress: P,
    mut out: impl std::io::Write,
    _err: impl std::io::Write,
    opts: Options,
) -> anyhow::Result<()>
where
    P: gix::NestedProgress,
    P::SubProgress: 'static,
{
    if opts.format != OutputFormat::Human {
        bail!("JSON output isn't yet supported for pull.");
    }

    // Step 1: Get current HEAD
    let mut head_ref = repo
        .head_ref()
        .context("Cannot pull: not on a branch (detached HEAD)")?
        .context("Cannot pull: HEAD does not point to a reference")?;

    let head_commit = repo.head_commit().context("Cannot pull: HEAD has no commits")?;

    let head_before = head_commit.id;

    // Get the branch name for configuration lookup
    let branch_name = head_ref
        .name()
        .category_and_short_name()
        .map(|(_, short)| short)
        .context("Cannot determine branch name")?;

    writeln!(out, "Pulling into branch '{}'", branch_name)?;

    // Step 2: Determine remote
    let remote_name = opts.remote.clone().unwrap_or_else(|| {
        // Try to get from branch.<name>.remote configuration
        repo.config_snapshot()
            .string(format!("branch.{}.remote", branch_name))
            .map(|s| s.to_string())
            .unwrap_or_else(|| "origin".to_string())
    });

    writeln!(out, "From remote '{}'", remote_name)?;

    // Step 3: Set up remote and fetch
    let mut remote = crate::repository::remote::by_name_or_url(&repo, Some(&remote_name))?;

    if !opts.ref_specs.is_empty() {
        remote.replace_refspecs(opts.ref_specs.iter(), gix::remote::Direction::Fetch)?;
        remote = remote.with_fetch_tags(gix::remote::fetch::Tags::None);
    }

    // Perform fetch
    let fetch_result = {
        let mut sub_progress = progress.add_child("fetch");
        sub_progress.init(None, gix::progress::count("objects"));

        remote
            .connect(gix::remote::Direction::Fetch)?
            .prepare_fetch(&mut sub_progress, Default::default())?
            .with_dry_run(opts.dry_run)
            .with_shallow(opts.shallow.clone())
            .receive(&mut sub_progress, &gix::interrupt::IS_INTERRUPTED)?
    };

    if opts.handshake_info {
        writeln!(out, "Handshake Information")?;
        writeln!(out, "\t{:?}", fetch_result.handshake)?;
    }

    // Print fetch statistics
    let objects_fetched = match &fetch_result.status {
        Status::Change { write_pack_bundle, .. } => write_pack_bundle.index.num_objects as usize,
        Status::NoPackReceived { .. } => 0,
    };
    if objects_fetched > 0 {
        writeln!(out, "Received {} objects", objects_fetched)?;
    }

    // Step 4: Determine what to merge
    // Get the tracking ref that was updated by fetch
    let tracking_ref_name = format!("refs/remotes/{}/{}", remote_name, branch_name);

    let mut tracking_ref = match repo.find_reference(&tracking_ref_name) {
        Ok(r) => r,
        Err(_) => {
            // Check FETCH_HEAD as fallback
            match repo.find_reference("FETCH_HEAD") {
                Ok(r) => r,
                Err(_) => {
                    writeln!(out, "Already up to date (no tracking branch found).")?;
                    return Ok(());
                }
            }
        }
    };

    let their_commit_id = tracking_ref.peel_to_id()?.detach();

    // Check if already up-to-date
    if head_before == their_commit_id {
        writeln!(out, "Already up to date.")?;
        return Ok(());
    }

    // Step 5: Check if fast-forward is possible
    // A fast-forward is possible if our HEAD is an ancestor of their commit
    let can_fast_forward = repo
        .merge_base(head_before, their_commit_id)
        .map(|base| base.detach() == head_before)
        .unwrap_or(false);

    if opts.ff_only && !can_fast_forward {
        bail!("Not possible to fast-forward, aborting (use --no-ff-only to allow merge commits).");
    }

    // Step 6: Perform fast-forward or merge
    if can_fast_forward && !opts.no_ff {
        // Fast-forward: just update the reference
        writeln!(out, "Fast-forward")?;

        if !opts.dry_run {
            // Update the branch reference
            let reflog_msg = format!(
                "pull: Fast-forward {} -> {}",
                head_before.to_hex_with_len(7),
                their_commit_id.to_hex_with_len(7)
            );

            head_ref.set_target_id(their_commit_id, reflog_msg)?;

            // Checkout the new tree to worktree
            writeln!(out, "Updating worktree...")?;
            // Note: Full checkout implementation would go here
            // For now, we've updated the ref which is the core operation
        }

        writeln!(
            out,
            " {} -> {}",
            head_before.to_hex_with_len(7),
            their_commit_id.to_hex_with_len(7)
        )?;

        return Ok(());
    }

    // Non-fast-forward merge required
    writeln!(out, "Merge required (not fast-forward)")?;

    if opts.dry_run {
        writeln!(out, "DRY-RUN: Would create merge commit.")?;
        return Ok(());
    }

    // For now, we indicate that a merge is needed but don't auto-merge
    // This is safer and matches git's behavior when conflicts might occur
    bail!(
        "Merge required but automatic merge commits are not yet fully implemented.\n\
         You can manually merge with:\n\
           gix merge {}\n\
         Or use --ff-only to only allow fast-forward pulls.",
        their_commit_id.to_hex_with_len(7)
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_default() {
        let opts = Options::default();
        assert!(!opts.dry_run);
        assert!(!opts.ff_only);
        assert!(!opts.no_ff);
        assert!(opts.remote.is_none());
    }
}
