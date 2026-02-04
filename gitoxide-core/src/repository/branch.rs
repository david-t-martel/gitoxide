use crate::OutputFormat;

pub mod list {
    pub enum Kind {
        Local,
        All,
    }

    pub struct Options {
        pub kind: Kind,
    }
}

/// Format a branch reference for display.
/// For symbolic refs (like origin/HEAD), show as "name -> target" like git does.
fn format_branch_ref(reference: &gix::Reference<'_>) -> String {
    let name = reference.name().shorten().to_string();

    // Check if this is a symbolic reference
    if let Some(target_name) = reference.target().try_name() {
        // Format like git: "origin/HEAD -> origin/main"
        let target = target_name.shorten().to_string();
        format!("{name} -> {target}")
    } else {
        name
    }
}

pub fn list(
    repo: gix::Repository,
    out: &mut dyn std::io::Write,
    format: OutputFormat,
    options: list::Options,
) -> anyhow::Result<()> {
    if format != OutputFormat::Human {
        anyhow::bail!("JSON output isn't supported");
    }

    let platform = repo.references()?;

    let (show_local, show_remotes) = match options.kind {
        list::Kind::Local => (true, false),
        list::Kind::All => (true, true),
    };

    if show_local {
        // Don't use peeled() to preserve symbolic reference information
        let mut branch_names: Vec<String> = platform
            .local_branches()?
            .flatten()
            .map(|branch| format_branch_ref(&branch))
            .collect();

        branch_names.sort();

        for branch_name in branch_names {
            writeln!(out, "{branch_name}")?;
        }
    }

    if show_remotes {
        // Don't use peeled() to preserve symbolic reference information
        let mut branch_names: Vec<String> = platform
            .remote_branches()?
            .flatten()
            .map(|branch| format_branch_ref(&branch))
            .collect();

        branch_names.sort();

        for branch_name in branch_names {
            writeln!(out, "{branch_name}")?;
        }
    }

    Ok(())
}
