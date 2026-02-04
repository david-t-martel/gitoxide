use anyhow::bail;
use gix::bstr::{BString, ByteSlice};
use std::io::BufWriter;

pub fn log(
    mut repo: gix::Repository,
    out: &mut dyn std::io::Write,
    path: Option<BString>,
    limit: Option<usize>,
) -> anyhow::Result<()> {
    if let Some(path) = path {
        // Path-based log needs tree diffs, so use larger cache
        repo.object_cache_size_if_unset(repo.compute_object_cache_size_for_tree_diffs(&**repo.index_or_empty()?));
        log_file(repo, out, path)
    } else {
        // Simple log only needs commits - use fixed 4MB cache for recent commits
        // This avoids loading the index unnecessarily
        repo.object_cache_size_if_unset(4 * 1024 * 1024);
        log_all(repo, out, limit)
    }
}

fn log_all(repo: gix::Repository, out: &mut dyn std::io::Write, limit: Option<usize>) -> Result<(), anyhow::Error> {
    let head = repo.head()?.peel_to_commit()?;

    // Use commit-graph if available for faster traversal (avoids decompressing commits for metadata)
    let commit_graph = repo.commit_graph_if_enabled().ok().flatten();

    let topo = gix::traverse::commit::topo::Builder::from_iters(&repo.objects, [head.id], None::<Vec<gix::ObjectId>>)
        .with_commit_graph(commit_graph)
        .build()?;

    let iter: Box<dyn Iterator<Item = _>> = match limit {
        Some(n) => Box::new(topo.take(n)),
        None => Box::new(topo),
    };

    // Use buffered output to reduce syscalls
    let mut out = BufWriter::with_capacity(32 * 1024, out);

    for info in iter {
        let info = info?;
        write_info(&repo, &mut out, &info)?;
    }

    Ok(())
}

fn log_file(_repo: gix::Repository, _out: &mut dyn std::io::Write, _path: BString) -> anyhow::Result<()> {
    bail!("File-based lookup isn't yet implemented in a way that is competitively fast");
}

fn write_info(
    repo: &gix::Repository,
    mut out: impl std::io::Write,
    info: &gix::traverse::commit::Info,
) -> Result<(), std::io::Error> {
    let commit = repo.find_commit(info.id).unwrap();

    let message = commit.message_raw_sloppy();
    let title = message.lines().next();

    writeln!(
        out,
        "{} {}",
        info.id.to_hex_with_len(8),
        title.map_or_else(|| "<no message>".into(), BString::from)
    )?;

    Ok(())
}
