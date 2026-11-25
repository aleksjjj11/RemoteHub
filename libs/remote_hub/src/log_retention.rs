//! Local diagnostic log retention (plan 18.3): at most 5 files of 5 MiB each,
//! kept for at most 7 days. Nothing is uploaded.
//!
//! The logger rotates by size and keeps a bounded number of files; this module
//! enforces the age target and the file count on what is already on disk, at
//! start-up and periodically while the app runs. The file currently written
//! (`*_rCURRENT.log`) is never removed.

use std::{
    fs, io,
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

/// Log files kept, the one being written included.
pub const MAX_LOG_FILES: usize = 5;
/// Size at which the current log file is rotated.
pub const MAX_LOG_FILE_BYTES: u64 = 5 * 1024 * 1024;
/// Rotated files older than this are deleted.
pub const LOG_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// Infix of the file the logger currently writes.
pub const CURRENT_INFIX: &str = "_rCURRENT";

fn is_log_file(path: &Path) -> bool {
    path.is_file() && path.extension().map_or(false, |e| e == "log")
}

fn is_current(path: &Path) -> bool {
    path.file_name()
        .and_then(|n| n.to_str())
        .map_or(false, |n| n.contains(CURRENT_INFIX))
}

/// Deletes the log files in `dir` that are older than [`LOG_RETENTION`] at
/// `now`, then the oldest ones beyond [`MAX_LOG_FILES`]. Only `*.log` files
/// directly in `dir` are considered; the current file is kept and counts
/// toward the limit. Returns the deleted paths. A missing `dir` is not an
/// error.
pub fn prune_logs(dir: &Path, now: SystemTime) -> io::Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let mut current = 0usize;
    let mut rotated: Vec<(SystemTime, PathBuf)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !is_log_file(&path) {
            continue;
        }
        if is_current(&path) {
            current += 1;
            continue;
        }
        let modified = entry
            .metadata()
            .and_then(|m| m.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH);
        rotated.push((modified, path));
    }
    // Newest first.
    rotated.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    let keep = MAX_LOG_FILES.saturating_sub(current);
    let mut deleted = Vec::new();
    for (i, (modified, path)) in rotated.into_iter().enumerate() {
        let expired = now
            .duration_since(modified)
            .map_or(false, |age| age > LOG_RETENTION);
        if expired || i >= keep {
            match fs::remove_file(&path) {
                Ok(()) => deleted.push(path),
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => log::warn!("Remote Hub: could not delete an old log file: {e}"),
            }
        }
    }
    Ok(deleted)
}

/// Deletes the diagnostic logs in `root` and in its direct subdirectories
/// (one per process name), on the owner's request (plan 18.3). Rotated
/// `*.log` files are removed; a file the logger is still writing
/// (`*_rCURRENT.log`) is emptied instead, since the logger keeps it open and
/// appends to it. Other files are left alone. Returns the number of files
/// removed or emptied; the first error is returned after everything else was
/// tried. A missing `root` is not an error.
pub fn delete_logs(root: &Path) -> io::Result<usize> {
    let mut dirs = vec![root.to_path_buf()];
    match fs::read_dir(root) {
        Ok(entries) => dirs.extend(entries.flatten().map(|e| e.path()).filter(|p| p.is_dir())),
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(e) => return Err(e),
    }
    let mut done = 0usize;
    let mut first_error = None;
    for dir in dirs {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !is_log_file(&path) {
                continue;
            }
            let result = if is_current(&path) {
                fs::OpenOptions::new()
                    .write(true)
                    .open(&path)
                    .and_then(|f| f.set_len(0))
            } else {
                fs::remove_file(&path)
            };
            match result {
                Ok(()) => done += 1,
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => {
                    first_error.get_or_insert(e);
                }
            }
        }
    }
    match first_error {
        Some(e) => Err(e),
        None => Ok(done),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(PathBuf);
    impl TempDir {
        fn new(tag: &str) -> Self {
            let p = std::env::temp_dir().join(format!(
                "remote_hub_logs_{tag}_{}_{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir_all(&p).unwrap();
            Self(p)
        }
    }
    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn file(dir: &Path, name: &str, modified: SystemTime) -> PathBuf {
        let p = dir.join(name);
        fs::write(&p, b"x").unwrap();
        fs::File::options()
            .write(true)
            .open(&p)
            .unwrap()
            .set_modified(modified)
            .unwrap();
        p
    }

    const DAY: Duration = Duration::from_secs(24 * 60 * 60);

    #[test]
    fn keeps_at_most_five_files_including_the_current_one() {
        let d = TempDir::new("count");
        let now = SystemTime::now();
        let current = file(&d.0, "app_rCURRENT.log", now);
        let rotated: Vec<_> = (0..7)
            .map(|i| {
                file(
                    &d.0,
                    &format!("app_r{i}.log"),
                    now - Duration::from_secs(60 * (i + 1)),
                )
            })
            .collect();
        let deleted = prune_logs(&d.0, now).unwrap();
        assert_eq!(deleted.len(), 3);
        assert!(current.exists());
        for (i, p) in rotated.iter().enumerate() {
            assert_eq!(p.exists(), i < 4, "{p:?}");
        }
    }

    #[test]
    fn deletes_files_older_than_seven_days_but_never_the_current_one() {
        let d = TempDir::new("age");
        let now = SystemTime::now();
        let current = file(&d.0, "app_rCURRENT.log", now - 30 * DAY);
        let fresh = file(&d.0, "app_r1.log", now - 6 * DAY);
        let old = file(&d.0, "app_r2.log", now - 8 * DAY);
        let deleted = prune_logs(&d.0, now).unwrap();
        assert_eq!(deleted, vec![old.clone()]);
        assert!(current.exists() && fresh.exists() && !old.exists());
    }

    #[test]
    fn leaves_other_files_and_a_missing_directory_alone() {
        let d = TempDir::new("other");
        let now = SystemTime::now();
        let other = file(&d.0, "notes.txt", now - 30 * DAY);
        fs::create_dir(d.0.join("sub.log")).unwrap();
        assert!(prune_logs(&d.0, now).unwrap().is_empty());
        assert!(other.exists());
        assert!(prune_logs(&d.0.join("missing"), now).unwrap().is_empty());
    }

    #[test]
    fn deleting_logs_removes_rotated_files_and_empties_the_current_one() {
        let d = TempDir::new("delete");
        let now = SystemTime::now();
        let root_rotated = file(&d.0, "app_r1.log", now);
        let sub = d.0.join("server");
        fs::create_dir(&sub).unwrap();
        let current = file(&sub, "server_rCURRENT.log", now);
        fs::write(&current, b"secret line").unwrap();
        let sub_rotated = file(&sub, "server_r2.log", now);
        let other = file(&sub, "notes.txt", now);
        let deeper = d.0.join("server").join("nested");
        fs::create_dir(&deeper).unwrap();
        let untouched = file(&deeper, "x_r1.log", now);

        // The logger keeps the current file open in append mode.
        let mut writer = fs::OpenOptions::new().append(true).open(&current).unwrap();

        assert_eq!(delete_logs(&d.0).unwrap(), 3);
        assert!(!root_rotated.exists() && !sub_rotated.exists());
        assert_eq!(fs::read(&current).unwrap(), b"", "emptied, not removed");
        assert!(other.exists(), "only log files are deleted");
        assert!(untouched.exists(), "only one level of process directories");

        // What the logger writes next starts the file over.
        use std::io::Write;
        writer.write_all(b"next").unwrap();
        assert_eq!(fs::read(&current).unwrap(), b"next");

        assert_eq!(delete_logs(&d.0.join("missing")).unwrap(), 0);
    }
}
