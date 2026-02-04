//! A file with directories of other git object databases to use when reading objects.
//!
//! This inherently makes alternates read-only.
//!
//! An alternate file in `<git-dir>/info/alternates` can look as follows:
//!
//! ```text
//! # a comment, empty lines are also allowed
//! # relative paths resolve relative to the parent git repository
//! ../path/relative/to/repo/.git
//! /absolute/path/to/repo/.git
//!
//! "/a/ansi-c-quoted/path/with/tabs\t/.git"
//!
//! # each .git directory should indeed be a directory, and not a file
//! ```
//!
//! Based on the [canonical implementation](https://github.com/git/git/blob/master/sha1-file.c#L598:L609).
use std::{
    collections::HashSet,
    fs, io,
    path::PathBuf,
};

use gix_path::realpath::MAX_SYMLINKS;

///
pub mod parse;

/// Returned by [`resolve()`]
#[derive(thiserror::Error, Debug)]
#[allow(missing_docs)]
pub enum Error {
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Realpath(#[from] gix_path::realpath::Error),
    #[error(transparent)]
    Parse(#[from] parse::Error),
    #[error("Alternates form a cycle: {} -> {}", .0.iter().map(|p| format!("'{}'", p.display())).collect::<Vec<_>>().join(" -> "), .0.first().expect("more than one directories").display())]
    Cycle(Vec<PathBuf>),
}

/// Given an `objects_directory`, try to resolve alternate object directories possibly located in the
/// `./info/alternates` file into canonical paths and resolve relative paths with the help of the `current_dir`.
/// If no alternate object database was resolved, the resulting `Vec` is empty (it is not an error
/// if there are no alternates).
/// It is an error once a repository is seen again as it would lead to a cycle.
pub fn resolve(objects_directory: PathBuf, current_dir: &std::path::Path) -> Result<Vec<PathBuf>, Error> {
    let mut dirs = vec![(0, objects_directory.clone())];
    let mut out = Vec::new();
    let first_path = gix_path::realpath_opts(&objects_directory, current_dir, MAX_SYMLINKS)?;
    // Use HashSet for O(1) cycle detection instead of O(n) Vec::contains()
    // Also keep Vec for error reporting (to show the cycle path)
    let mut seen_set: HashSet<PathBuf> = HashSet::with_capacity(8);
    let mut seen_order: Vec<PathBuf> = Vec::with_capacity(8);
    seen_set.insert(first_path.clone());
    seen_order.push(first_path);

    while let Some((depth, dir)) = dirs.pop() {
        match fs::read(dir.join("info").join("alternates")) {
            Ok(input) => {
                for path in parse::content(&input)?.into_iter() {
                    let path = objects_directory.join(path);
                    let path_canonicalized = gix_path::realpath_opts(&path, current_dir, MAX_SYMLINKS)?;
                    if !seen_set.insert(path_canonicalized.clone()) {
                        // Path was already in the set - we have a cycle
                        return Err(Error::Cycle(seen_order));
                    }
                    seen_order.push(path_canonicalized);
                    dirs.push((depth + 1, path));
                }
            }
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => return Err(err.into()),
        }
        if depth != 0 {
            out.push(dir);
        }
    }
    Ok(out)
}
