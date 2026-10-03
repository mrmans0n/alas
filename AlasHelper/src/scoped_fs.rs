//! Worktree-scoped file operations for plugins (`fs/scoped-read`,
//! `fs/scoped-list`, `fs/scoped-write`). Each call takes the worktree root with
//! a path relative to it and checks containment in the same call as the
//! operation: the path is walked from a directory descriptor one component at
//! a time with `O_NOFOLLOW`, so the kernel never follows a symlink on our
//! behalf. A symlink met on the way is read and resolved against the
//! descriptors already held, and followed only while it stays inside the
//! worktree. Nothing named `.git`, compared case-folded, is ever entered.
//! Limits and messages match the plugin API's local `file/*` (API 6).

use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_FILE_BYTES: usize = 512 * 1024;
pub const MAX_LIST_ENTRIES: usize = 2000;
/// A folder past this many names lists a sorted sample of the first ones read, as on this Mac.
pub const MAX_LIST_READ: usize = 20_000;
/// Symlinks followed in one walk before it is treated as a loop.
const MAX_SYMLINK_HOPS: usize = 40;
/// Every refusal; the message says why.
pub const REFUSED: i64 = -32027;

#[derive(Debug, PartialEq)]
pub struct ScopedFsError {
    pub code: i64,
    pub message: String,
}

type Outcome<T> = Result<T, ScopedFsError>;

fn refuse<T>(message: impl Into<String>) -> Outcome<T> {
    Err(ScopedFsError {
        code: REFUSED,
        message: message.into(),
    })
}

fn not_found<T>(path: &str) -> Outcome<T> {
    refuse(format!(
        "{} does not exist",
        if path.is_empty() { "." } else { path }
    ))
}

#[derive(Deserialize)]
struct ReadParams {
    root: String,
    path: String,
}

#[derive(Deserialize)]
struct ListParams {
    root: String,
    #[serde(default)]
    dir: String,
}

#[derive(Deserialize)]
struct WriteParams {
    root: String,
    path: String,
    content: String,
}

pub fn handle_request(method: &str, params: Option<Value>) -> Outcome<Value> {
    match method {
        "fs/scoped-read" => {
            let params: ReadParams = decode(params)?;
            Ok(json!({ "content": read(&params.root, &params.path)? }))
        }
        "fs/scoped-list" => {
            let params: ListParams = decode(params)?;
            let (entries, truncated) = list(&params.root, &params.dir)?;
            let entries: Vec<Value> = entries
                .into_iter()
                .map(|(name, kind)| json!({ "name": name, "kind": kind }))
                .collect();
            Ok(json!({ "entries": entries, "truncated": truncated }))
        }
        "fs/scoped-write" => {
            let params: WriteParams = decode(params)?;
            write(&params.root, &params.path, &params.content)?;
            Ok(json!({}))
        }
        _ => Err(ScopedFsError {
            code: -32601,
            message: format!("method not found: {method}"),
        }),
    }
}

fn decode<T: for<'de> Deserialize<'de>>(params: Option<Value>) -> Outcome<T> {
    serde_json::from_value(params.unwrap_or(Value::Null)).map_err(|error| ScopedFsError {
        code: -32602,
        message: format!("invalid params: {error}"),
    })
}

/// UTF-8 text of up to 512 KiB.
pub fn read(root: &str, path: &str) -> Outcome<String> {
    let Reached::File(file) = walk(root, path, Want::File, &mut |_| {})? else {
        return not_found(path);
    };
    read_text(file, path)
}

fn read_text(file: File, path: &str) -> Outcome<String> {
    let metadata = file.metadata().or_else(|_| not_found(path))?;
    if !metadata.is_file() {
        return not_found(path);
    }
    if metadata.len() > MAX_FILE_BYTES as u64 {
        return refuse(format!("{path} is larger than 512 KiB"));
    }
    let mut bytes = Vec::new();
    // One byte past the limit, in case the file grew since the check.
    file.take(MAX_FILE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .or_else(|error| refuse(format!("could not read {path}: {error}")))?;
    if bytes.len() > MAX_FILE_BYTES {
        return refuse(format!("{path} is larger than 512 KiB"));
    }
    String::from_utf8(bytes).or_else(|_| refuse(format!("{path} is not UTF-8 text")))
}

/// Up to 2000 entries sorted by name, fewer when their names would not fit in
/// one reply, without `.git`; `true` when some were left out.
pub fn list(root: &str, dir: &str) -> Outcome<(Vec<(String, &'static str)>, bool)> {
    list_reading(root, dir, MAX_LIST_READ)
}

fn list_reading(
    root: &str,
    dir: &str,
    read_limit: usize,
) -> Outcome<(Vec<(String, &'static str)>, bool)> {
    let Reached::Directory(fd) = walk(root, dir, Want::Directory, &mut |_| {})? else {
        return not_found(dir);
    };
    let (mut visible, unread) = directory_names(&fd, read_limit)
        .or_else(|error| refuse(format!("could not list {dir}: {error}")))?;
    visible.sort();
    let mut budget = MAX_FILE_BYTES as isize;
    let mut entries = Vec::new();
    for name in visible.iter().take(MAX_LIST_ENTRIES) {
        budget -= serde_json::to_string(name).map_or(name.len() * 6, |encoded| encoded.len())
            as isize
            + 32;
        if budget < 0 {
            break;
        }
        let kind = match CString::new(name.as_bytes())
            .ok()
            .and_then(|c| lstat_at(fd.as_raw_fd(), &c).ok())
        {
            Some(info) if is_kind(&info, libc::S_IFDIR) => "directory",
            Some(info) if is_kind(&info, libc::S_IFLNK) => "symlink",
            _ => "file",
        };
        entries.push((name.clone(), kind));
    }
    let truncated = unread || visible.len() > entries.len();
    Ok((entries, truncated))
}

/// Replaces the file atomically, creating missing folders inside the worktree.
pub fn write(root: &str, path: &str, content: &str) -> Outcome<()> {
    if content.len() > MAX_FILE_BYTES {
        return refuse("content is larger than 512 KiB");
    }
    let Reached::Slot(parent, name, mode) = walk(root, path, Want::Write, &mut |_| {})? else {
        return refuse(format!("{path} is a folder"));
    };
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let temp =
        CString::new(format!(".alas-plugin-write-{}-{nonce}", std::process::id())).expect("no NUL");
    let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            temp.as_ptr(),
            flags,
            0o666 as libc::c_uint,
        )
    };
    if fd < 0 {
        return refuse(format!(
            "could not write {path}: {}",
            io::Error::last_os_error()
        ));
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    let written = file.write_all(content.as_bytes()).and_then(|_| match mode {
        // A replaced file keeps its permissions.
        Some(mode) if unsafe { libc::fchmod(fd, mode & 0o7777) } != 0 => {
            Err(io::Error::last_os_error())
        }
        _ => Ok(()),
    });
    drop(file);
    // `renameat` replaces the name itself: a symlink swapped in meanwhile is replaced, not followed.
    let renamed = written.and_then(|_| {
        if unsafe {
            libc::renameat(
                parent.as_raw_fd(),
                temp.as_ptr(),
                parent.as_raw_fd(),
                name.as_ptr(),
            )
        } == 0
        {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    });
    if let Err(error) = renamed {
        unsafe { libc::unlinkat(parent.as_raw_fd(), temp.as_ptr(), 0) };
        return refuse(format!("could not write {path}: {error}"));
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq)]
enum Want {
    Directory,
    File,
    Write,
}

enum Reached {
    Directory(OwnedFd),
    File(File),
    /// Where a write goes: the folder, the name in it, and the mode of the file it replaces, if any.
    Slot(OwnedFd, CString, Option<libc::mode_t>),
}

/// Resolves `path` from the worktree's descriptor. `after_enter` runs after
/// each directory is entered, with the depth, so tests can swap what comes next.
fn walk(
    root: &str,
    path: &str,
    want: Want,
    after_enter: &mut dyn FnMut(usize),
) -> Outcome<Reached> {
    if path.starts_with('/') {
        return refuse(format!("{path} is not relative"));
    }
    let parts: Vec<&str> = path
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect();
    if parts.contains(&"..") {
        return refuse(format!("{path} uses .."));
    }
    let root_path = Path::new(root);
    // Alas sends the worktree's real path; it is opened one component at a time without following symlinks,
    // so a root swapped for a symlink is refused rather than adopted as the boundary.
    let Some(root_fd) = open_root(root_path) else {
        return refuse("the worktree does not exist");
    };
    let canonical_root = root_path.to_path_buf();
    let mut stack = vec![root_fd];
    // Each name, and whether it came from a symlink's target, where a missing name means a broken link.
    let mut queue: VecDeque<(Vec<u8>, bool)> = parts
        .iter()
        .map(|part| (part.as_bytes().to_vec(), false))
        .collect();
    let mut hops = 0;
    while let Some((name, from_link)) = queue.pop_front() {
        match name.as_slice() {
            b"" | b"." => continue,
            // Only a symlink's target can hold `..`, and it may not climb above the worktree.
            b".." => {
                if stack.len() == 1 {
                    return refuse(format!("{path} leaves the worktree"));
                }
                stack.pop();
                continue;
            }
            _ => {}
        }
        if String::from_utf8_lossy(&name).to_lowercase() == ".git" {
            return refuse(format!("{path} is inside .git"));
        }
        let Ok(cname) = CString::new(name.clone()) else {
            return refuse(format!("{path} is not a valid path"));
        };
        let last = queue.is_empty();
        let dir = stack.last().expect("the root stays").as_raw_fd();
        let info = match lstat_at(dir, &cname) {
            Ok(info) => Some(info),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) if error.raw_os_error() == Some(libc::ENOTDIR) => None,
            Err(error) => return refuse(format!("could not read {path}: {error}")),
        };
        let Some(info) = info else {
            if from_link {
                return refuse(format!("{path} has a broken symlink"));
            }
            match (want, last) {
                (Want::Write, true) => {
                    return Ok(Reached::Slot(
                        stack.pop().expect("the root stays"),
                        cname,
                        None,
                    ));
                }
                (Want::Write, false) => {
                    if unsafe { libc::mkdirat(dir, cname.as_ptr(), 0o777) } != 0 {
                        let error = io::Error::last_os_error();
                        if error.kind() != io::ErrorKind::AlreadyExists {
                            return refuse(format!("could not write {path}: {error}"));
                        }
                    }
                    // Entered on the next pass, through the same checks as any other folder.
                    queue.push_front((name, from_link));
                    hops += 1;
                    if hops > MAX_SYMLINK_HOPS {
                        return refuse(format!("{path} keeps changing"));
                    }
                    continue;
                }
                _ => return not_found(path),
            }
        };
        if is_kind(&info, libc::S_IFLNK) {
            hops += 1;
            if hops > MAX_SYMLINK_HOPS {
                return refuse(format!("{path} has a broken symlink"));
            }
            let target = read_link_at(dir, &cname)
                .or_else(|_| refuse(format!("{path} has a broken symlink")))?;
            let target_path = Path::new(std::ffi::OsStr::from_bytes(&target));
            let relative: PathBuf = if target_path.is_absolute() {
                // An absolute target is followed only into this worktree, from its own descriptor.
                let Some(inside) = target_path
                    .strip_prefix(&canonical_root)
                    .ok()
                    .or_else(|| target_path.strip_prefix(root_path).ok())
                else {
                    return refuse(format!("{path} leaves the worktree"));
                };
                stack.truncate(1);
                inside.to_path_buf()
            } else {
                target_path.to_path_buf()
            };
            for part in relative
                .as_os_str()
                .as_bytes()
                .split(|byte| *byte == b'/')
                .rev()
            {
                queue.push_front((part.to_vec(), true));
            }
            continue;
        }
        if is_kind(&info, libc::S_IFDIR) {
            if last && want == Want::Write {
                return refuse(format!("{path} is a folder"));
            }
            let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
            match open_at(dir, &cname, flags) {
                Ok(fd) => {
                    stack.push(fd);
                    after_enter(stack.len() - 1);
                }
                // Swapped since the check (for a symlink, say): look again rather than follow it.
                Err(_) => {
                    queue.push_front((name, from_link));
                    hops += 1;
                    if hops > MAX_SYMLINK_HOPS {
                        return refuse(format!("{path} keeps changing"));
                    }
                }
            }
            continue;
        }
        // A file, or anything else that is not a folder.
        if !last {
            return match want {
                Want::Write => refuse(format!("could not write {path}: a parent is not a folder")),
                _ => not_found(path),
            };
        }
        match want {
            Want::Directory => return not_found(path),
            Want::Write => {
                let parent = stack.pop().expect("the root stays");
                return Ok(Reached::Slot(parent, cname, Some(info.st_mode)));
            }
            Want::File => {
                // Non-blocking, so a FIFO swapped in does not hang the helper.
                let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
                match open_at(dir, &cname, flags) {
                    Ok(fd) => return Ok(Reached::File(File::from(fd))),
                    Err(_) => {
                        queue.push_front((name, from_link));
                        hops += 1;
                        if hops > MAX_SYMLINK_HOPS {
                            return refuse(format!("{path} keeps changing"));
                        }
                    }
                }
            }
        }
    }
    match want {
        Want::Directory => Ok(Reached::Directory(stack.pop().expect("the root stays"))),
        Want::File => not_found(path),
        Want::Write => refuse(format!("{path} is a folder")),
    }
}

fn open_root(root: &Path) -> Option<OwnedFd> {
    if !root.is_absolute() {
        return None;
    }
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let mut fd = open_at(libc::AT_FDCWD, c"/", flags).ok()?;
    for component in root.components().skip(1) {
        let std::path::Component::Normal(name) = component else {
            return None;
        };
        let name = CString::new(name.as_bytes()).ok()?;
        fd = open_at(fd.as_raw_fd(), &name, flags).ok()?;
    }
    Some(fd)
}

fn open_at(dir: RawFd, name: &CStr, flags: libc::c_int) -> io::Result<OwnedFd> {
    let fd = unsafe { libc::openat(dir, name.as_ptr(), flags) };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}

fn lstat_at(dir: RawFd, name: &CStr) -> io::Result<libc::stat> {
    let mut info: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatat(dir, name.as_ptr(), &mut info, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(info)
}

fn is_kind(info: &libc::stat, kind: libc::mode_t) -> bool {
    info.st_mode & libc::S_IFMT == kind
}

fn read_link_at(dir: RawFd, name: &CStr) -> io::Result<Vec<u8>> {
    let mut buffer = vec![0u8; libc::PATH_MAX as usize];
    let length =
        unsafe { libc::readlinkat(dir, name.as_ptr(), buffer.as_mut_ptr().cast(), buffer.len()) };
    if length < 0 {
        return Err(io::Error::last_os_error());
    }
    buffer.truncate(length as usize);
    Ok(buffer)
}

/// Up to `limit` names other than `.git`, and whether more were left unread.
fn directory_names(dir: &OwnedFd, limit: usize) -> io::Result<(Vec<String>, bool)> {
    // `fdopendir` takes the descriptor it is given, so it gets its own copy.
    let copy = unsafe { libc::dup(dir.as_raw_fd()) };
    if copy < 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = unsafe { libc::fdopendir(copy) };
    if stream.is_null() {
        let error = io::Error::last_os_error();
        unsafe { libc::close(copy) };
        return Err(error);
    }
    let mut names = Vec::new();
    let mut unread = false;
    loop {
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        let name = String::from_utf8_lossy(name).into_owned();
        if name == "." || name == ".." || name.to_lowercase() == ".git" {
            continue;
        }
        if names.len() == limit {
            unread = true;
            break;
        }
        names.push(name);
    }
    unsafe { libc::closedir(stream) };
    Ok((names, unread))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    struct Fixture {
        base: PathBuf,
        root: PathBuf,
        outside: PathBuf,
    }

    impl Fixture {
        /// A worktree with `a.txt`, `sub/b.txt` and a `.git` file, next to a folder outside it holding `secret.txt`.
        fn new(name: &str) -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let base = std::env::temp_dir().join(format!(
                "alas-scoped-fs-{name}-{}-{nonce}",
                std::process::id()
            ));
            std::fs::create_dir_all(&base).unwrap();
            // The real path, as Alas sends it: the root is opened without following symlinks (`/var` is one on macOS).
            let base = std::fs::canonicalize(&base).unwrap();
            let root = base.join("wt");
            let outside = base.join("outside");
            std::fs::create_dir_all(root.join("sub")).unwrap();
            std::fs::create_dir_all(&outside).unwrap();
            std::fs::write(root.join("a.txt"), "hello").unwrap();
            std::fs::write(root.join("sub/b.txt"), "inside").unwrap();
            std::fs::write(root.join(".git"), "gitdir: elsewhere").unwrap();
            std::fs::write(outside.join("secret.txt"), "secret").unwrap();
            Self {
                base,
                root,
                outside,
            }
        }

        fn root(&self) -> &str {
            self.root.to_str().unwrap()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.base);
        }
    }

    fn message<T: std::fmt::Debug>(outcome: Outcome<T>) -> String {
        outcome.expect_err("refused").message
    }

    #[test]
    fn a_root_reached_through_a_symlink_is_refused() {
        let f = Fixture::new("root-link");
        let alias = f.base.join("alias");
        symlink(&f.outside, &alias).unwrap();
        assert_eq!(
            message(read(alias.to_str().unwrap(), "secret.txt")),
            "the worktree does not exist"
        );
        let nested = f.base.join("via");
        symlink(&f.base, &nested).unwrap();
        assert_eq!(
            message(read(nested.join("wt").to_str().unwrap(), "a.txt")),
            "the worktree does not exist"
        );
        assert_eq!(read(f.root(), "a.txt").unwrap(), "hello");
    }

    #[test]
    fn paths_that_climb_or_are_absolute_are_refused() {
        let f = Fixture::new("climb");
        assert_eq!(
            message(read(f.root(), "../outside/secret.txt")),
            "../outside/secret.txt uses .."
        );
        assert_eq!(
            message(read(f.root(), "sub/../../x")),
            "sub/../../x uses .."
        );
        let absolute = f.outside.join("secret.txt");
        assert!(message(read(f.root(), absolute.to_str().unwrap())).ends_with("is not relative"));
        assert!(message(write(f.root(), "/tmp/x", "x")).ends_with("is not relative"));
    }

    #[test]
    fn symlinks_out_of_the_worktree_are_refused_and_contained_ones_followed() {
        let f = Fixture::new("links");
        symlink(&f.outside, f.root.join("out-abs")).unwrap();
        symlink("../outside", f.root.join("out-rel")).unwrap();
        symlink("sub", f.root.join("in-rel")).unwrap();
        symlink(f.root.join("sub/b.txt"), f.root.join("in-abs.txt")).unwrap();
        symlink("sub/../a.txt", f.root.join("in-dotdot.txt")).unwrap();
        symlink("nowhere", f.root.join("dangling")).unwrap();
        for path in ["out-abs/secret.txt", "out-rel/secret.txt"] {
            assert_eq!(
                message(read(f.root(), path)),
                format!("{path} leaves the worktree")
            );
        }
        assert_eq!(
            message(write(f.root(), "out-rel/new.txt", "x")),
            "out-rel/new.txt leaves the worktree"
        );
        assert!(!f.outside.join("new.txt").exists());
        assert_eq!(read(f.root(), "in-rel/b.txt").unwrap(), "inside");
        assert_eq!(read(f.root(), "in-abs.txt").unwrap(), "inside");
        assert_eq!(read(f.root(), "in-dotdot.txt").unwrap(), "hello");
        assert_eq!(
            list(f.root(), "in-rel").unwrap().0,
            vec![("b.txt".to_string(), "file")]
        );
        write(f.root(), "in-rel/c.txt", "via link").unwrap();
        assert_eq!(
            std::fs::read_to_string(f.root.join("sub/c.txt")).unwrap(),
            "via link"
        );
        // A link that leads nowhere is refused: writing through it would land wherever it points.
        assert_eq!(
            message(write(f.root(), "dangling", "x")),
            "dangling has a broken symlink"
        );
        assert!(!f.root.join("nowhere").exists());
    }

    #[test]
    fn git_is_refused_in_any_case_and_through_links_and_left_out_of_lists() {
        let f = Fixture::new("git");
        std::fs::create_dir_all(f.root.join("sub/.Git")).unwrap();
        symlink(".git", f.root.join("to-git")).unwrap();
        for path in [".git", ".GIT/config", "sub/.gIt/HEAD", "to-git"] {
            assert_eq!(
                message(read(f.root(), path)),
                format!("{path} is inside .git")
            );
        }
        assert_eq!(
            message(write(f.root(), ".GIT/config", "x")),
            ".GIT/config is inside .git"
        );
        assert_eq!(
            message(list(f.root(), "sub/.GIT")),
            "sub/.GIT is inside .git"
        );
        let (entries, truncated) = list(f.root(), "").unwrap();
        let names: Vec<&str> = entries.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(names, ["a.txt", "sub", "to-git"]);
        assert_eq!(entries[2].1, "symlink");
        assert!(!truncated);
        assert_eq!(
            list(f.root(), "sub").unwrap().0,
            vec![("b.txt".to_string(), "file")]
        );
        assert_eq!(
            std::fs::read_to_string(f.root.join(".git")).unwrap(),
            "gitdir: elsewhere"
        );
    }

    /// The walk holds each folder it entered, so swapping a component for a
    /// symlink once it was checked does not lead the rest of the walk out.
    #[test]
    fn a_symlink_swapped_in_mid_walk_does_not_escape() {
        let f = Fixture::new("swap");
        std::fs::create_dir_all(f.outside.join("deep")).unwrap();
        std::fs::write(f.outside.join("deep/b.txt"), "secret").unwrap();
        std::fs::create_dir_all(f.root.join("sub/deep")).unwrap();
        std::fs::write(f.root.join("sub/deep/b.txt"), "inside").unwrap();
        // `sub` is swapped for a link out right after the walk entered it: the walk goes on in the folder it holds.
        let root = f.root.clone();
        let outside = f.outside.clone();
        let reached = walk(f.root(), "sub/deep/b.txt", Want::File, &mut |depth| {
            if depth == 1 {
                std::fs::rename(root.join("sub"), root.join("sub-old")).unwrap();
                symlink(&outside, root.join("sub")).unwrap();
            }
        });
        let Ok(Reached::File(file)) = reached else {
            panic!("expected the file")
        };
        assert_eq!(read_text(file, "sub/deep/b.txt").unwrap(), "inside");
        // `deep` is swapped for a link out after `sub` was entered and before `deep` is: the link is seen, not followed.
        let reached = walk(f.root(), "sub-old/deep/b.txt", Want::File, &mut |depth| {
            if depth == 1 {
                std::fs::rename(root.join("sub-old/deep"), root.join("sub-old/deep-old")).unwrap();
                symlink(outside.join("deep"), root.join("sub-old/deep")).unwrap();
            }
        });
        assert_eq!(
            message(reached.map(|_| ())),
            "sub-old/deep/b.txt leaves the worktree"
        );
    }

    #[test]
    fn reads_are_utf8_text_up_to_the_limit() {
        let f = Fixture::new("read");
        std::fs::write(f.root.join("edge.txt"), vec![b'a'; MAX_FILE_BYTES]).unwrap();
        std::fs::write(f.root.join("big.txt"), vec![b'a'; MAX_FILE_BYTES + 1]).unwrap();
        std::fs::write(f.root.join("bin.dat"), [0xFF, 0xFE]).unwrap();
        assert_eq!(read(f.root(), "edge.txt").unwrap().len(), MAX_FILE_BYTES);
        assert_eq!(
            message(read(f.root(), "big.txt")),
            "big.txt is larger than 512 KiB"
        );
        assert_eq!(
            message(read(f.root(), "bin.dat")),
            "bin.dat is not UTF-8 text"
        );
        assert_eq!(
            message(read(f.root(), "missing.txt")),
            "missing.txt does not exist"
        );
        assert_eq!(message(read(f.root(), "sub")), "sub does not exist");
        assert_eq!(
            message(write(f.root(), "x.txt", &"a".repeat(MAX_FILE_BYTES + 1))),
            "content is larger than 512 KiB"
        );
    }

    #[test]
    fn lists_stop_at_the_entry_cap() {
        let f = Fixture::new("list");
        let many = f.root.join("many");
        std::fs::create_dir_all(&many).unwrap();
        for index in 0..=MAX_LIST_ENTRIES {
            std::fs::write(many.join(format!("{index:05}")), "").unwrap();
        }
        let (entries, truncated) = list(f.root(), "many").unwrap();
        assert_eq!(entries.len(), MAX_LIST_ENTRIES);
        assert_eq!(entries[0].0, "00000");
        assert!(truncated);
        // Past the read bound, a sorted sample of the names read, still truncated.
        let (entries, truncated) = list_reading(f.root(), "many", 3).unwrap();
        assert_eq!(entries.len(), 3);
        assert!(truncated);
        assert_eq!(message(list(f.root(), "a.txt")), "a.txt does not exist");
    }

    #[test]
    fn writes_create_folders_replace_files_and_refuse_folders() {
        let f = Fixture::new("write");
        write(f.root(), "new/dir/b.txt", "hi").unwrap();
        assert_eq!(
            std::fs::read_to_string(f.root.join("new/dir/b.txt")).unwrap(),
            "hi"
        );
        write(f.root(), "a.txt", "replaced").unwrap();
        assert_eq!(
            std::fs::read_to_string(f.root.join("a.txt")).unwrap(),
            "replaced"
        );
        assert_eq!(message(write(f.root(), "sub", "x")), "sub is a folder");
        assert_eq!(message(write(f.root(), "", "x")), " is a folder");
        assert_eq!(
            message(write(f.root(), "a.txt/c.txt", "x")),
            "could not write a.txt/c.txt: a parent is not a folder"
        );
        // No temporary file is left behind.
        let leftovers = std::fs::read_dir(&f.root)
            .unwrap()
            .filter(|entry| {
                entry
                    .as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".alas-plugin-write")
            })
            .count();
        assert_eq!(leftovers, 0);
    }
}
