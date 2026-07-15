use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

pub const PROTOCOL_VERSION: u32 = 1;

/// The base directory `open`/`cwd` paths resolve against. Prefers the logical
/// `$PWD` (which preserves the symlinked path the user `cd`'d through) and
/// falls back to the process working directory, matching the old sh script.
pub fn logical_base() -> PathBuf {
    if let Some(pwd) = std::env::var_os("PWD") {
        let p = PathBuf::from(pwd);
        if p.is_absolute() {
            return p;
        }
    }
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"))
}

/// Absolute, lexically-normalized path for `input` resolved against `base`.
/// Collapses `.`/`..`/repeated separators and strips a trailing slash. Does not
/// touch the filesystem, so symlinks in `base` are preserved.
pub fn absolutize(base: &Path, input: &str) -> String {
    let joined = if Path::new(input).is_absolute() {
        PathBuf::from(input)
    } else {
        base.join(input)
    };

    let mut out: Vec<std::ffi::OsString> = Vec::new();
    for component in joined.components() {
        match component {
            Component::RootDir | Component::Prefix(_) => {}
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(part) => out.push(part.to_os_string()),
        }
    }

    let mut result = String::from("/");
    for (i, part) in out.iter().enumerate() {
        if i > 0 {
            result.push('/');
        }
        result.push_str(&part.to_string_lossy());
    }
    result
}

/// One CLI request over the Alas Unix socket. `session_id` and `cwd` are both
/// optional on the wire, but a valid request always carries at least one; the
/// app prefers `session_id`. Fields serialize only when present so an older app
/// that ignores unknown keys stays compatible.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Request {
    pub v: u32,
    pub kind: &'static str,
    pub command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subcommand: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub force: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keep_branch: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub paths: Option<Vec<String>>,
    /// Command-specific arguments for commands added after the flat fields
    /// above. New commands put ALL their arguments here; the flat fields
    /// stay for wire compatibility with the original six commands.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

impl Request {
    /// A request with all optional fields cleared and `v`/`kind` fixed.
    pub fn new(command: impl Into<String>) -> Self {
        Request {
            v: PROTOCOL_VERSION,
            kind: "cli",
            command: command.into(),
            session_id: None,
            cwd: None,
            subcommand: None,
            target: None,
            branch: None,
            base: None,
            force: None,
            keep_branch: None,
            paths: None,
            params: None,
        }
    }
}

/// The app's reply. `ok` is authoritative; `lines` is present for list-style
/// output, `error` for failures.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Response {
    pub ok: bool,
    #[serde(default)]
    pub lines: Option<Vec<String>>,
    #[serde(default)]
    pub error: Option<String>,
}

/// The parsed CLI intent, independent of transport. `Open` paths are already
/// absolutized by the caller.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    Open { paths: Vec<String> },
    WtList,
    WtSwitch { target: String },
    WtNew { branch: String, base: Option<String> },
    WtDelete { target: String, force: bool, keep_branch: bool },
    Review { target: Option<String> },
    Resolve,
}

/// Build the wire request for a command, attaching whichever addressing the
/// caller resolved (`session_id` inside Alas, else `cwd`).
pub fn build_request(command: &Command, session_id: Option<String>, cwd: Option<String>) -> Request {
    let mut req = match command {
        Command::Open { paths } => {
            let mut r = Request::new("open");
            r.paths = Some(paths.clone());
            r
        }
        Command::WtList => {
            let mut r = Request::new("wt");
            r.subcommand = Some("list".into());
            r
        }
        Command::WtSwitch { target } => {
            let mut r = Request::new("wt");
            r.subcommand = Some("switch".into());
            r.target = Some(target.clone());
            r
        }
        Command::WtNew { branch, base } => {
            let mut r = Request::new("wt");
            r.subcommand = Some("new".into());
            r.branch = Some(branch.clone());
            r.base = base.clone();
            r
        }
        Command::WtDelete { target, force, keep_branch } => {
            let mut r = Request::new("wt");
            r.subcommand = Some("delete".into());
            r.target = Some(target.clone());
            r.force = Some(*force);
            r.keep_branch = Some(*keep_branch);
            r
        }
        Command::Review { target } => {
            let mut r = Request::new("review");
            r.target = target.clone();
            r
        }
        Command::Resolve => Request::new("resolve"),
    };
    req.session_id = session_id;
    req.cwd = cwd;
    req
}

/// The per-user socket directory Alas binds its `pid-<pid>` sockets under.
pub fn socket_dir() -> PathBuf {
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/alas-{}", uid))
}

/// True if a process with `pid` exists and we may signal it. Same-uid callers
/// get `0` for a live process; a missing process yields `ESRCH`.
fn process_alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

/// True if `dir` is safe to trust for socket discovery: a real directory (not
/// a symlink), owned by the current uid, with no group/other permission
/// bits. Mirrors the app's own guard
/// (`AgentHookSocketServer.prepareSocketDirectory`) — another local user
/// could otherwise pre-create a permissive `/tmp/alas-<uid>` at our
/// predictable path and plant sockets we'd trust.
fn socket_dir_is_safe(dir: &Path) -> bool {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    let Ok(c_path) = CString::new(dir.as_os_str().as_bytes()) else {
        return false;
    };
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::lstat(c_path.as_ptr(), &mut st) } != 0 {
        return false;
    }
    let is_dir = (st.st_mode & libc::S_IFMT) == libc::S_IFDIR;
    let owned_by_us = st.st_uid == unsafe { libc::getuid() };
    let no_group_or_other_bits = (st.st_mode as u32 & 0o777) & 0o077 == 0;
    is_dir && owned_by_us && no_group_or_other_bits
}

/// Live `pid-<pid>` sockets in `dir`, filtering out entries whose process has
/// exited. Non-`pid-` entries (e.g. per-leaf `sock-` symlinks) are ignored.
/// Refuses to trust `dir` at all unless it passes [`socket_dir_is_safe`].
pub fn discover_live_sockets_in(dir: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    if !socket_dir_is_safe(dir) {
        return result;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return result;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Some(pid_str) = name.strip_prefix("pid-") else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<i32>() else {
            continue;
        };
        if pid > 0 && process_alive(pid) {
            result.push(entry.path());
        }
    }
    result.sort();
    result
}

/// Live Alas sockets under the standard per-user directory.
pub fn discover_live_sockets() -> Vec<PathBuf> {
    discover_live_sockets_in(&socket_dir())
}

#[derive(Debug)]
pub enum TransportError {
    Connect,
    Io,
    Malformed,
}

/// Bound on how long `send` will wait for a reply. Comfortably covers the
/// slowest CLI operations (`wt new`, `review`), which the old shell script
/// bounded the same way, while keeping a wedged app from hanging the shell
/// forever.
const READ_TIMEOUT: Duration = Duration::from_secs(30);

/// Bound on how long a single non-mutating `resolve` probe (used to find the
/// owning instance among several live sockets) may take. Kept short and
/// applied in parallel across sockets so a wedged, unrelated Alas instance
/// cannot stall directory dispatch by anywhere near [`READ_TIMEOUT`].
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Send one request over `socket` and return the parsed reply. Writes the JSON
/// bytes (the app parses as soon as the object is complete), then reads to EOF
/// (bounded by [`READ_TIMEOUT`]).
pub fn send(socket: &Path, req: &Request) -> Result<Response, TransportError> {
    send_with_timeout(socket, req, READ_TIMEOUT)
}

/// `send`, parameterized on the read timeout so tests can exercise the
/// timeout behavior without waiting on the real [`READ_TIMEOUT`].
fn send_with_timeout(socket: &Path, req: &Request, read_timeout: Duration) -> Result<Response, TransportError> {
    let payload = serde_json::to_vec(req).map_err(|_| TransportError::Malformed)?;
    let mut stream = UnixStream::connect(socket).map_err(|_| TransportError::Connect)?;
    stream
        .set_read_timeout(Some(read_timeout))
        .map_err(|_| TransportError::Io)?;
    stream.write_all(&payload).map_err(|_| TransportError::Io)?;
    stream.flush().map_err(|_| TransportError::Io)?;
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).map_err(|_| TransportError::Io)?;
    serde_json::from_slice(&buf).map_err(|_| TransportError::Malformed)
}

/// How the CLI addresses the app: an exact pane (inside Alas) or a directory
/// (anywhere else).
#[derive(Debug, Clone, PartialEq)]
pub enum Target {
    Session { socket: String, session_id: String },
    Directory { cwd: String },
}

/// Resolve the target from the environment. Inside Alas both vars are set and
/// we address the exact session; otherwise we address the logical directory.
pub fn resolve_target() -> Target {
    let socket = std::env::var("ALAS_SOCKET_PATH").ok().filter(|s| !s.is_empty());
    let session = std::env::var("ALAS_SESSION_ID").ok().filter(|s| !s.is_empty());
    if let (Some(socket), Some(session_id)) = (socket, session) {
        return Target::Session { socket, session_id };
    }
    let cwd = absolutize(&logical_base(), ".");
    Target::Directory { cwd }
}

#[derive(Debug)]
pub enum DispatchError {
    NoAlas,
    NotInWorktree,
    Ambiguous,
    Transport(TransportError),
}

/// Send `command` to the right app. Session targets go straight to their
/// socket. Directory targets discover live sockets and pick the unique owner
/// (via a non-mutating `resolve` probe) before sending the real command.
pub fn dispatch(command: &Command, target: &Target) -> Result<Response, DispatchError> {
    match target {
        Target::Session { socket, session_id } => {
            let req = build_request(command, Some(session_id.clone()), None);
            send(Path::new(socket), &req).map_err(DispatchError::Transport)
        }
        Target::Directory { .. } => {
            let sockets = discover_live_sockets();
            dispatch_to_sockets(command, target, &sockets)
        }
    }
}

/// Directory-mode dispatch against an explicit socket list (separated out so it
/// is testable without touching `/tmp`).
pub fn dispatch_to_sockets(
    command: &Command,
    target: &Target,
    sockets: &[PathBuf],
) -> Result<Response, DispatchError> {
    let Target::Directory { cwd } = target else {
        unreachable!("dispatch_to_sockets is directory-only");
    };
    if sockets.is_empty() {
        return Err(DispatchError::NoAlas);
    }

    // Probe every live socket with a non-mutating resolve first, then send
    // the real command only to the unique owner. This applies uniformly
    // regardless of socket count (even a single running app is probed) so
    // "not inside an Alas worktree" maps to the same DispatchError, and thus
    // the same exit code, whether one or many instances are running.
    //
    // Probes run in parallel with a short [`PROBE_TIMEOUT`] rather than
    // sequentially with the normal (30s) timeout, so a single wedged,
    // unrelated Alas instance cannot stall dispatch for everyone else.
    let probe = build_request(&Command::Resolve, None, Some(cwd.clone()));
    let mut owners = Vec::new();
    std::thread::scope(|scope| {
        let handles: Vec<_> = sockets
            .iter()
            .map(|socket| {
                let probe = &probe;
                scope.spawn(move || {
                    let ok = matches!(
                        send_with_timeout(socket, probe, PROBE_TIMEOUT),
                        Ok(resp) if resp.ok
                    );
                    (socket, ok)
                })
            })
            .collect();
        for handle in handles {
            let (socket, ok) = handle.join().expect("probe thread should not panic");
            if ok {
                owners.push(socket.clone());
            }
        }
    });
    match owners.len() {
        0 => Err(DispatchError::NotInWorktree),
        1 => {
            let req = build_request(command, None, Some(cwd.clone()));
            send(&owners[0], &req).map_err(DispatchError::Transport)
        }
        _ => Err(DispatchError::Ambiguous),
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;

    #[test]
    fn absolutize_joins_relative_against_base_without_resolving_symlinks() {
        let base = Path::new("/logical/dir with spaces");
        assert_eq!(
            absolutize(base, "sub/file.txt"),
            "/logical/dir with spaces/sub/file.txt"
        );
    }

    #[test]
    fn absolutize_normalizes_dot_and_dotdot_lexically() {
        let base = Path::new("/a/b");
        assert_eq!(absolutize(base, "../c/./d"), "/a/c/d");
        assert_eq!(absolutize(base, "/x//y/"), "/x/y");
    }

    #[test]
    fn absolutize_keeps_absolute_input() {
        let base = Path::new("/a/b");
        assert_eq!(absolutize(base, "/etc/hosts"), "/etc/hosts");
    }

    #[test]
    fn open_request_omits_absent_fields() {
        let mut req = Request::new("open");
        req.session_id = Some("s1".into());
        req.paths = Some(vec!["/tmp/a.txt".into()]);
        let json = serde_json::to_string(&req).unwrap();
        assert_eq!(
            json,
            r#"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"]}"#
        );
    }

    #[test]
    fn params_envelope_serializes_only_when_present() {
        let mut req = Request::new("review_comments");
        req.session_id = Some("s1".into());
        req.params = Some(serde_json::json!({ "state": "all" }));
        let json = serde_json::to_string(&req).unwrap();
        assert_eq!(
            json,
            r#"{"v":1,"kind":"cli","command":"review_comments","session_id":"s1","params":{"state":"all"}}"#
        );

        let bare = serde_json::to_string(&Request::new("resolve")).unwrap();
        assert!(!bare.contains("params"), "absent params must not serialize");
    }

    #[test]
    fn response_parses_lines_and_error_defaults() {
        let ok: Response = serde_json::from_str(r#"{"ok":true}"#).unwrap();
        assert!(ok.ok && ok.lines.is_none() && ok.error.is_none());
        let err: Response = serde_json::from_str(r#"{"ok":false,"error":"nope"}"#).unwrap();
        assert_eq!(err.error.as_deref(), Some("nope"));
    }

    #[test]
    fn builds_wt_new_with_base() {
        let cmd = Command::WtNew { branch: "feature".into(), base: Some("main".into()) };
        let req = build_request(&cmd, Some("s1".into()), None);
        let json = serde_json::to_string(&req).unwrap();
        assert_eq!(
            json,
            r#"{"v":1,"kind":"cli","command":"wt","session_id":"s1","subcommand":"new","branch":"feature","base":"main"}"#
        );
    }

    #[test]
    fn builds_wt_delete_flags_and_cwd() {
        let cmd = Command::WtDelete { target: "feature".into(), force: true, keep_branch: false };
        let req = build_request(&cmd, None, Some("/repo".into()));
        assert_eq!(req.command, "wt");
        assert_eq!(req.subcommand.as_deref(), Some("delete"));
        assert_eq!(req.cwd.as_deref(), Some("/repo"));
        assert_eq!(req.force, Some(true));
        assert_eq!(req.keep_branch, Some(false));
    }

    #[test]
    fn builds_review_local_and_provider() {
        let local = build_request(&Command::Review { target: None }, Some("s1".into()), None);
        assert_eq!(local.command, "review");
        assert!(local.target.is_none());
        let provider = build_request(&Command::Review { target: Some("123".into()) }, Some("s1".into()), None);
        assert_eq!(provider.target.as_deref(), Some("123"));
    }

    #[test]
    fn builds_resolve_with_cwd_only() {
        let req = build_request(&Command::Resolve, None, Some("/repo".into()));
        assert_eq!(req.command, "resolve");
        assert_eq!(req.cwd.as_deref(), Some("/repo"));
        assert!(req.session_id.is_none());
    }

    #[test]
    fn discovers_only_live_pid_sockets() {
        let root = std::env::temp_dir().join(format!("alas-cli-disc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();

        // A second live process we actually own, to exercise multi-entry sort
        // order (string-sorted paths, not numeric pid order).
        let mut child = std::process::Command::new("sleep").arg("5").spawn().unwrap();

        // Live: our own pid and the spawned child. Dead: pid 999999999 (out of
        // range, guaranteed absent). Junk: non-`pid-` entry and a non-numeric
        // pid suffix, both ignored.
        let live_a = root.join(format!("pid-{}", std::process::id()));
        let live_b = root.join(format!("pid-{}", child.id()));
        let dead = root.join("pid-999999999");
        let junk = root.join("sock-abc"); // symlink-style entry, ignored by prefix
        let non_numeric = root.join("pid-abc"); // unparsable pid, skipped
        std::fs::write(&live_a, b"").unwrap();
        std::fs::write(&live_b, b"").unwrap();
        std::fs::write(&dead, b"").unwrap();
        std::fs::write(&junk, b"").unwrap();
        std::fs::write(&non_numeric, b"").unwrap();

        let found = discover_live_sockets_in(&root);
        let mut expected = vec![live_a, live_b];
        expected.sort();
        assert_eq!(found, expected);

        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn discover_live_sockets_in_skips_non_positive_pids() {
        let root = std::env::temp_dir().join(format!("alas-cli-disc-pidguard-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();

        let live = root.join(format!("pid-{}", std::process::id()));
        let zero = root.join("pid-0");
        let negative = root.join("pid--5");
        std::fs::write(&live, b"").unwrap();
        std::fs::write(&zero, b"").unwrap();
        std::fs::write(&negative, b"").unwrap();

        let found = discover_live_sockets_in(&root);
        assert_eq!(found, vec![live]);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn discover_live_sockets_in_rejects_dir_with_group_or_other_bits() {
        let root = std::env::temp_dir().join(format!("alas-cli-disc-perm-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
        let live = root.join(format!("pid-{}", std::process::id()));
        std::fs::write(&live, b"").unwrap();

        let found = discover_live_sockets_in(&root);
        assert!(
            found.is_empty(),
            "a dir with group/other permission bits must not be trusted"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn send_times_out_instead_of_hanging_forever() {
        // A stub server that accepts the connection but never replies,
        // modeling a wedged app. `send_with_timeout` must give up instead of
        // blocking the caller forever.
        let path = std::env::temp_dir().join(format!(
            "alas-cli-timeout-{}-{}.sock",
            std::process::id(),
            line!()
        ));
        let _ = std::fs::remove_file(&path);
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let handle = std::thread::spawn(move || {
            let (_stream, _) = listener.accept().unwrap();
            // Hold the connection open without ever writing a reply.
            std::thread::sleep(std::time::Duration::from_secs(2));
        });

        let req = Request::new("resolve");
        let started = std::time::Instant::now();
        let result = send_with_timeout(&path, &req, Duration::from_millis(200));
        assert!(matches!(result, Err(TransportError::Io)));
        assert!(
            started.elapsed() < std::time::Duration::from_secs(1),
            "send_with_timeout should give up around the configured timeout, not hang"
        );

        let _ = handle.join();
        let _ = std::fs::remove_file(&path);
    }
}
