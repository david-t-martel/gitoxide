use gix::bstr::{BStr, BString, ByteSlice};
use gix::prelude::{Find, ObjectIdExt};

use crate::OutputFormat;

#[derive(Eq, PartialEq, PartialOrd, Ord)]
enum VersionPart {
    String(BString),
    Number(usize),
}

/// `Version` is used to store multi-part version numbers. It does so in a rather naive way,
/// only distinguishing between parts that can be parsed as an integer and those that cannot.
///
/// `Version` does not parse version numbers in any structure-aware way, so `v0.a` is parsed into
/// `v`, `0`, `.a`.
///
/// Comparing two `Version`s comes down to comparing their `parts`. `parts` are either compared
/// numerically or lexicographically, depending on whether they are an integer or not. That way,
/// `v0.9` sorts before `v0.10` as one would expect from a version number.
///
/// When comparing versions of different lengths, shorter versions sort before longer ones (e.g.,
/// `v1.0` < `v1.0.1`). String parts always sort before numeric parts when compared directly.
#[derive(Eq, PartialEq, Ord, PartialOrd)]
struct Version {
    parts: Vec<VersionPart>,
}

impl Version {
    fn parse(version: &BStr) -> Self {
        let parts = version
            .chunk_by(|a, b| a.is_ascii_digit() == b.is_ascii_digit())
            .map(|part| {
                if let Ok(part) = part.to_str() {
                    part.parse::<usize>()
                        .map_or_else(|_| VersionPart::String(part.into()), VersionPart::Number)
                } else {
                    VersionPart::String(part.into())
                }
            })
            .collect();

        Self { parts }
    }
}

/// Options for tag listing operations
pub struct Options {
    /// Thread limit for parallel operations. `None` uses all available threads.
    pub thread_limit: Option<usize>,
}

impl Default for Options {
    fn default() -> Self {
        Self { thread_limit: None }
    }
}

pub fn list(
    mut repo: gix::Repository,
    out: &mut dyn std::io::Write,
    format: OutputFormat,
    options: Options,
) -> anyhow::Result<()> {
    if format != OutputFormat::Human {
        anyhow::bail!("JSON output isn't supported");
    }

    // Enable object cache to accelerate tag peeling operations
    repo.object_cache_size_if_unset(4 * 1024 * 1024); // 4MB cache

    let platform = repo.references()?;

    // Phase 1: Collect reference data (sequential, cheap)
    // Using peeled() leverages the cached packed buffer for efficient iteration
    let tag_refs: Vec<_> = platform
        .tags()?
        .peeled()?
        .flatten()
        .filter_map(|reference| {
            // Only process direct references (not symbolic)
            reference.try_id().map(|id| {
                let name = reference.name().shorten().to_owned();
                (name, id.detach())
            })
        })
        .collect();

    let num_tags = tag_refs.len();

    // Phase 2: Process tags - use parallel processing for large tag sets
    let tags = if num_tags > 100 && gix::parallel::num_threads(options.thread_limit) > 1 {
        process_tags_parallel(&repo, tag_refs, options.thread_limit)?
    } else {
        process_tags_sequential(&repo, tag_refs)?
    };

    // Phase 3: Sort and output
    let mut tags = tags;
    tags.sort_by(|a, b| a.0.cmp(&b.0));

    for (_, tag) in tags {
        writeln!(out, "{tag}")?;
    }

    Ok(())
}

/// Process tags sequentially (for small tag sets)
fn process_tags_sequential(
    repo: &gix::Repository,
    tag_refs: Vec<(BString, gix::ObjectId)>,
) -> anyhow::Result<Vec<(Version, String)>> {
    let mut tags = Vec::with_capacity(tag_refs.len());

    for (name, id) in tag_refs {
        let display = format_tag_entry(repo, name.as_ref(), id)?;
        let version = Version::parse(name.as_ref());
        tags.push((version, display));
    }

    Ok(tags)
}

/// Process tags in parallel (for large tag sets)
fn process_tags_parallel(
    repo: &gix::Repository,
    tag_refs: Vec<(BString, gix::ObjectId)>,
    thread_limit: Option<usize>,
) -> anyhow::Result<Vec<(Version, String)>> {
    use gix::parallel::{in_parallel, Reduce};

    struct TagReducer {
        tags: Vec<(Version, String)>,
    }

    impl Reduce for TagReducer {
        type Input = Vec<(Version, String)>;
        type FeedProduce = ();
        type Output = Vec<(Version, String)>;
        type Error = anyhow::Error;

        fn feed(&mut self, items: Self::Input) -> Result<Self::FeedProduce, Self::Error> {
            self.tags.extend(items);
            Ok(())
        }

        fn finalize(self) -> Result<Self::Output, Self::Error> {
            Ok(self.tags)
        }
    }

    // Process in chunks for better cache locality
    let chunk_size = (tag_refs.len() / gix::parallel::num_threads(thread_limit)).max(10);
    let chunks: Vec<Vec<_>> = tag_refs.chunks(chunk_size).map(|c| c.to_vec()).collect();

    let tags = in_parallel(
        chunks.into_iter(),
        thread_limit,
        {
            let objects = repo.objects.clone();
            move |_| objects.clone().into_inner()
        },
        |chunk, odb| {
            let mut results = Vec::with_capacity(chunk.len());
            for (name, id) in chunk {
                let display = format_tag_entry_with_odb(odb, name.as_ref(), id);
                let version = Version::parse(name.as_ref());
                results.push((version, display));
            }
            results
        },
        TagReducer {
            tags: Vec::with_capacity(tag_refs.len()),
        },
    )?;

    Ok(tags)
}

/// Format a single tag entry for display
fn format_tag_entry(repo: &gix::Repository, name: &BStr, id: gix::ObjectId) -> anyhow::Result<String> {
    // Try to decode as annotated tag
    if let Ok(tag_obj) = id.attach(repo).object() {
        if tag_obj.kind == gix::object::Kind::Tag {
            if let Ok(tag) = tag_obj.try_into_tag() {
                if let Ok(tag_data) = tag.decode() {
                    let mut fields = Vec::new();
                    fields.push(format!(
                        "tag name: {}",
                        if name == tag_data.name {
                            "*".into()
                        } else {
                            tag_data.name
                        }
                    ));
                    if tag_data.pgp_signature.is_some() {
                        fields.push("signed".into());
                    }
                    return Ok(format!("{name} [{fields}]", fields = fields.join(", ")));
                }
            }
        }
    }

    // Lightweight tag or failed to decode
    Ok(name.to_string())
}

/// Format a tag entry using a raw object database handle (for parallel processing)
fn format_tag_entry_with_odb<T: Find>(odb: &T, name: &BStr, id: gix::ObjectId) -> String {
    let mut buf = Vec::new();
    // Try to decode as annotated tag
    if let Ok(Some(obj)) = odb.try_find(&id, &mut buf) {
        if obj.kind == gix::object::Kind::Tag {
            if let Ok(tag_data) = gix::objs::TagRef::from_bytes(obj.data) {
                let mut fields = Vec::new();
                fields.push(format!(
                    "tag name: {}",
                    if name == tag_data.name {
                        "*".into()
                    } else {
                        tag_data.name
                    }
                ));
                if tag_data.pgp_signature.is_some() {
                    fields.push("signed".into());
                }
                return format!("{name} [{fields}]", fields = fields.join(", "));
            }
        }
    }

    // Lightweight tag or failed to decode
    name.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cmp::Ordering;

    #[test]
    fn sorts_versions_correctly() {
        let mut actual = vec![
            "v2.0.0",
            "v1.10.0",
            "v1.2.1",
            "v1.0.0-beta",
            "v1.2",
            "v0.10.0",
            "v0.9.0",
            "v1.2.0",
            "v0.1.a",
            "v0.1.0",
            "v10.0.0",
            "1.0.0",
            "v1.0.0-alpha",
            "v1.0.0",
        ];

        actual.sort_by(|&a, &b| Version::parse(a.into()).cmp(&Version::parse(b.into())));
        let expected = [
            "v0.1.0",
            "v0.1.a",
            "v0.9.0",
            "v0.10.0",
            "v1.0.0",
            "v1.0.0-alpha",
            "v1.0.0-beta",
            "v1.2",
            "v1.2.0",
            "v1.2.1",
            "v1.10.0",
            "v2.0.0",
            "v10.0.0",
            "1.0.0",
        ];

        assert_eq!(actual, expected);
    }

    #[test]
    fn sorts_versions_with_different_lengths_correctly() {
        let v1 = Version::parse("v1.0".into());
        let v2 = Version::parse("v1.0.1".into());

        assert_eq!(v1.cmp(&v2), Ordering::Less);
        assert_eq!(v2.cmp(&v1), Ordering::Greater);
    }
}
