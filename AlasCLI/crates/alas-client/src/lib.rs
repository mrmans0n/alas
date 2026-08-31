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
    #[serde(default)]
    pub exit_code: Option<u8>,
}

/// The parsed CLI intent, independent of transport. `Open` paths are already
/// absolutized by the caller.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    Open {
        paths: Vec<String>,
    },
    OpenAt {
        path: String,
        line: u64,
        end_line: Option<u64>,
    },
    Notify {
        body: String,
        title: Option<String>,
        level: Option<String>,
    },
    WtList,
    WtSwitch {
        target: String,
    },
    WtNew {
        branch: String,
        base: Option<String>,
    },
    WtDelete {
        target: String,
        force: bool,
        keep_branch: bool,
    },
    Review {
        target: Option<String>,
        worktree: Option<String>,
    },
    ReviewComments {
        session_id: Option<String>,
        state: Option<String>,
    },
    ReviewReply {
        comment_id: String,
        body: String,
    },
    ReviewResolve {
        comment_id: String,
        reply: Option<String>,
        reopen: bool,
    },
    ReviewCommentAdd {
        path: String,
        start_line: u64,
        end_line: Option<u64>,
        side: Option<String>,
        body: String,
        session_id: Option<String>,
    },
    ReviewFinish {
        session_id: Option<String>,
        verdict: Option<String>,
        summary: Option<String>,
    },
    SessionList,
    SessionNew {
        prompt: String,
        agent: Option<String>,
        worktree: SessionWorktreeTarget,
    },
    SessionSend {
        session_id: String,
        prompt: String,
    },
    WorkspaceList,
    WorkspaceShow {
        checkout_id: String,
    },
    WorkspaceSwitch {
        checkout_id: String,
    },
    WorkspaceFocus {
        checkout_id: String,
        member_id: String,
    },
    Resolve,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SessionWorktreeTarget {
    Current,
    Existing {
        worktree: String,
    },
    New {
        branch: String,
        base: Option<String>,
    },
}

/// Build the wire request for a command, attaching whichever addressing the
/// caller resolved (`session_id` inside Alas, else `cwd`).
pub fn build_request(
    command: &Command,
    session_id: Option<String>,
    cwd: Option<String>,
) -> Request {
    let mut req = match command {
        Command::Open { paths } => {
            let mut r = Request::new("open");
            r.paths = Some(paths.clone());
            r
        }
        Command::OpenAt {
            path,
            line,
            end_line,
        } => {
            let mut r = Request::new("open");
            r.paths = Some(vec![path.clone()]);
            let mut params = serde_json::Map::new();
            params.insert("line".into(), serde_json::Value::from(*line));
            if let Some(end_line) = end_line {
                params.insert("end_line".into(), serde_json::Value::from(*end_line));
            }
            r.params = Some(serde_json::Value::Object(params));
            r
        }
        Command::Notify { body, title, level } => {
            let mut r = Request::new("notify");
            let mut params = serde_json::Map::new();
            params.insert("body".into(), serde_json::Value::String(body.clone()));
            if let Some(title) = title {
                params.insert("title".into(), serde_json::Value::String(title.clone()));
            }
            if let Some(level) = level {
                params.insert("level".into(), serde_json::Value::String(level.clone()));
            }
            r.params = Some(serde_json::Value::Object(params));
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
        Command::WtDelete {
            target,
            force,
            keep_branch,
        } => {
            let mut r = Request::new("wt");
            r.subcommand = Some("delete".into());
            r.target = Some(target.clone());
            r.force = Some(*force);
            r.keep_branch = Some(*keep_branch);
            r
        }
        Command::Review { target, worktree } => {
            let mut r = Request::new("review");
            r.target = target.clone();
            if let Some(worktree) = worktree {
                r.params = Some(serde_json::json!({ "worktree": worktree }));
            }
            r
        }
        Command::ReviewComments { session_id, state } => {
            let mut r = Request::new("review_comments");
            let mut params = serde_json::Map::new();
            if let Some(session_id) = session_id {
                params.insert(
                    "session_id".into(),
                    serde_json::Value::String(session_id.clone()),
                );
            }
            if let Some(state) = state {
                params.insert("state".into(), serde_json::Value::String(state.clone()));
            }
            r.params = Some(serde_json::Value::Object(params));
            r
        }
        Command::ReviewReply { comment_id, body } => {
            let mut r = Request::new("review_reply");
            r.params = Some(serde_json::json!({ "comment_id": comment_id, "body": body }));
            r
        }
        Command::ReviewResolve {
            comment_id,
            reply,
            reopen,
        } => {
            let mut r = Request::new("review_resolve");
            let mut params = serde_json::Map::new();
            params.insert(
                "comment_id".into(),
                serde_json::Value::String(comment_id.clone()),
            );
            if let Some(reply) = reply {
                params.insert("reply".into(), serde_json::Value::String(reply.clone()));
            }
            if *reopen {
                params.insert("reopen".into(), serde_json::Value::Bool(true));
            }
            r.params = Some(serde_json::Value::Object(params));
            r
        }
        Command::ReviewCommentAdd {
            path,
            start_line,
            end_line,
            side,
            body,
            session_id,
        } => {
            let mut r = Request::new("review_comment_add");
            let mut params = serde_json::Map::new();
            params.insert("path".into(), serde_json::Value::String(path.clone()));
            params.insert("start_line".into(), serde_json::Value::from(*start_line));
            if let Some(end_line) = end_line {
                params.insert("end_line".into(), serde_json::Value::from(*end_line));
            }
            if let Some(side) = side {
                params.insert("side".into(), serde_json::Value::String(side.clone()));
            }
            params.insert("body".into(), serde_json::Value::String(body.clone()));
            if let Some(session_id) = session_id {
                params.insert(
                    "session_id".into(),
                    serde_json::Value::String(session_id.clone()),
                );
            }
            r.params = Some(serde_json::Value::Object(params));
            r
        }
        Command::ReviewFinish {
            session_id,
            verdict,
            summary,
        } => {
            let mut r = Request::new("review_finish");
            let mut params = serde_json::Map::new();
            if let Some(session_id) = session_id {
                params.insert(
                    "session_id".into(),
                    serde_json::Value::String(session_id.clone()),
                );
            }
            if let Some(verdict) = verdict {
                params.insert("verdict".into(), serde_json::Value::String(verdict.clone()));
            }
            if let Some(summary) = summary {
                params.insert("summary".into(), serde_json::Value::String(summary.clone()));
            }
            r.params = Some(serde_json::Value::Object(params));
            r
        }
        Command::SessionList => {
            let mut r = Request::new("session_list");
            r.params = Some(serde_json::json!({}));
            r
        }
        Command::SessionNew {
            prompt,
            agent,
            worktree,
        } => {
            let mut r = Request::new("session_new");
            let mut params = serde_json::Map::new();
            params.insert("prompt".into(), serde_json::Value::String(prompt.clone()));
            if let Some(agent) = agent {
                params.insert("agent".into(), serde_json::Value::String(agent.clone()));
            }
            match worktree {
                SessionWorktreeTarget::Current => {}
                SessionWorktreeTarget::Existing { worktree } => {
                    params.insert(
                        "worktree".into(),
                        serde_json::Value::String(worktree.clone()),
                    );
                }
                SessionWorktreeTarget::New { branch, base } => {
                    let mut target = serde_json::Map::new();
                    target.insert("branch".into(), serde_json::Value::String(branch.clone()));
                    if let Some(base) = base {
                        target.insert("base".into(), serde_json::Value::String(base.clone()));
                    }
                    params.insert("new_worktree".into(), serde_json::Value::Object(target));
                }
            }
            r.params = Some(serde_json::Value::Object(params));
            r
        }
        Command::SessionSend { session_id, prompt } => {
            let mut r = Request::new("session_send");
            r.params = Some(serde_json::json!({ "session_id": session_id, "prompt": prompt }));
            r
        }
        Command::WorkspaceList => {
            let mut r = Request::new("workspace");
            r.subcommand = Some("list".into());
            r.params = Some(serde_json::json!({}));
            r
        }
        Command::WorkspaceShow { checkout_id } => {
            let mut r = Request::new("workspace");
            r.subcommand = Some("show".into());
            r.params = Some(serde_json::json!({ "checkout_id": checkout_id }));
            r
        }
        Command::WorkspaceSwitch { checkout_id } => {
            let mut r = Request::new("workspace");
            r.subcommand = Some("switch".into());
            r.params = Some(serde_json::json!({ "checkout_id": checkout_id }));
            r
        }
        Command::WorkspaceFocus { checkout_id, member_id } => {
            let mut r = Request::new("workspace");
            r.subcommand = Some("focus".into());
            r.params = Some(serde_json::json!({ "checkout_id": checkout_id, "member_id": member_id }));
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
fn send_with_timeout(
    socket: &Path,
    req: &Request,
    read_timeout: Duration,
) -> Result<Response, TransportError> {
    let payload = serde_json::to_vec(req).map_err(|_| TransportError::Malformed)?;
    let mut stream = UnixStream::connect(socket).map_err(|_| TransportError::Connect)?;
    stream
        .set_read_timeout(Some(read_timeout))
        .map_err(|_| TransportError::Io)?;
    stream.write_all(&payload).map_err(|_| TransportError::Io)?;
    stream.flush().map_err(|_| TransportError::Io)?;
    let mut buf = Vec::new();
    stream
        .read_to_end(&mut buf)
        .map_err(|_| TransportError::Io)?;
    serde_json::from_slice(&buf).map_err(|_| TransportError::Malformed)
}

/// The one-shot registration ping `alas mcp` sends over the unix socket so
/// the app knows the server actually started (stdio) or the adapter
/// connected (http). Its own `kind`, distinct from the "cli" request path and
/// the hook-event path.
pub fn hello_payload(session_id: &str, transport: &str) -> serde_json::Value {
    serde_json::json!({
        "v": PROTOCOL_VERSION,
        "kind": "mcp_hello",
        "session_id": session_id,
        "transport": transport,
    })
}

/// Best-effort: send the hello and ignore the ack/errors — a failed hello
/// must never stop the MCP server from serving.
pub fn send_hello(socket: &Path, session_id: &str, transport: &str) {
    let payload = match serde_json::to_vec(&hello_payload(session_id, transport)) {
        Ok(p) => p,
        Err(_) => return,
    };
    if let Ok(mut stream) = UnixStream::connect(socket) {
        let _ = stream.set_read_timeout(Some(PROBE_TIMEOUT));
        let _ = stream.write_all(&payload);
        let _ = stream.flush();
        let mut buf = Vec::new();
        let _ = stream.read_to_end(&mut buf);
    }
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
    let socket = std::env::var("ALAS_SOCKET_PATH")
        .ok()
        .filter(|s| !s.is_empty());
    let session = std::env::var("ALAS_SESSION_ID")
        .ok()
        .filter(|s| !s.is_empty());
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
    fn hello_payload_shape() {
        let v = hello_payload("SID-1", "stdio");
        assert_eq!(v["v"], PROTOCOL_VERSION);
        assert_eq!(v["kind"], "mcp_hello");
        assert_eq!(v["session_id"], "SID-1");
        assert_eq!(v["transport"], "stdio");
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
    fn open_line_range_uses_params_with_legacy_paths() {
        let command = Command::OpenAt {
            path: "/tmp/a.txt".into(),
            line: 12,
            end_line: Some(15),
        };
        let request = build_request(&command, Some("s1".into()), None);
        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(
            json,
            r#"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"],"params":{"end_line":15,"line":12}}"#
        );
    }

    #[test]
    fn open_line_target_omits_absent_end_line() {
        let command = Command::OpenAt {
            path: "/tmp/a.txt".into(),
            line: 12,
            end_line: None,
        };
        let request = build_request(&command, None, None);
        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(
            json,
            r#"{"v":1,"kind":"cli","command":"open","paths":["/tmp/a.txt"],"params":{"line":12}}"#
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
    fn session_commands_use_params_and_preserve_the_injected_session_id() {
        let new = Command::SessionNew {
            prompt: "Task".into(),
            agent: Some("codex".into()),
            worktree: SessionWorktreeTarget::New {
                branch: "child".into(),
                base: Some("origin/main".into()),
            },
        };
        let request = build_request(&new, Some("acp-1".into()), None);
        assert_eq!(request.session_id.as_deref(), Some("acp-1"));
        assert_eq!(
            request.params,
            Some(serde_json::json!({
                "prompt": "Task",
                "agent": "codex",
                "new_worktree": { "branch": "child", "base": "origin/main" }
            }))
        );

        let send = build_request(
            &Command::SessionSend {
                session_id: "child".into(),
                prompt: "Follow up".into(),
            },
            Some("acp-1".into()),
            None,
        );
        assert_eq!(send.command, "session_send");
        assert_eq!(send.session_id.as_deref(), Some("acp-1"));
        assert_eq!(
            send.params,
            Some(serde_json::json!({ "session_id": "child", "prompt": "Follow up" }))
        );
    }

    #[test]
    fn response_parses_lines_and_error_defaults() {
        let ok: Response = serde_json::from_str(r#"{"ok":true}"#).unwrap();
        assert!(ok.ok && ok.lines.is_none() && ok.error.is_none() && ok.exit_code.is_none());
        let err: Response = serde_json::from_str(r#"{"ok":false,"error":"nope"}"#).unwrap();
        assert_eq!(err.error.as_deref(), Some("nope"));
        assert_eq!(err.exit_code, None);
        let coded: Response = serde_json::from_str(
            r#"{"ok":false,"error":"workspace_recovery_required: recover","exit_code":3}"#,
        )
        .unwrap();
        assert_eq!(coded.exit_code, Some(3));
    }

    #[test]
    fn builds_wt_new_with_base() {
        let cmd = Command::WtNew {
            branch: "feature".into(),
            base: Some("main".into()),
        };
        let req = build_request(&cmd, Some("s1".into()), None);
        let json = serde_json::to_string(&req).unwrap();
        assert_eq!(
            json,
            r#"{"v":1,"kind":"cli","command":"wt","session_id":"s1","subcommand":"new","branch":"feature","base":"main"}"#
        );
    }

    #[test]
    fn builds_wt_delete_flags_and_cwd() {
        let cmd = Command::WtDelete {
            target: "feature".into(),
            force: true,
            keep_branch: false,
        };
        let req = build_request(&cmd, None, Some("/repo".into()));
        assert_eq!(req.command, "wt");
        assert_eq!(req.subcommand.as_deref(), Some("delete"));
        assert_eq!(req.cwd.as_deref(), Some("/repo"));
        assert_eq!(req.force, Some(true));
        assert_eq!(req.keep_branch, Some(false));
    }

    #[test]
    fn builds_review_local_and_provider() {
        let local = build_request(&Command::Review { target: None, worktree: None }, Some("s1".into()), None);
        assert_eq!(local.command, "review");
        assert!(local.target.is_none());
        let provider = build_request(
            &Command::Review {
                target: Some("123".into()),
                worktree: None,
            },
            Some("s1".into()),
            None,
        );
        assert_eq!(provider.target.as_deref(), Some("123"));
    }

    #[test]
    fn review_worktree_travels_in_params() {
        let req = build_request(
            &Command::Review {
                target: Some("abc123".into()),
                worktree: Some("feature-x".into()),
            },
            Some("s1".into()),
            None,
        );
        assert_eq!(req.command, "review");
        assert_eq!(req.target.as_deref(), Some("abc123"));
        assert_eq!(
            req.params,
            Some(serde_json::json!({ "worktree": "feature-x" }))
        );

        let bare = build_request(
            &Command::Review {
                target: None,
                worktree: None,
            },
            Some("s1".into()),
            None,
        );
        assert_eq!(bare.params, None);
    }

    #[test]
    fn builds_notify_params() {
        let cmd = Command::Notify {
            body: "Blocked on input".into(),
            title: Some("Need input".into()),
            level: Some("attention".into()),
        };
        let req = build_request(&cmd, Some("s1".into()), None);
        assert_eq!(req.command, "notify");
        assert_eq!(
            req.params,
            Some(serde_json::json!({
                "body": "Blocked on input",
                "title": "Need input",
                "level": "attention"
            }))
        );
    }

    #[test]
    fn builds_review_comments_with_params_envelope() {
        let cmd = Command::ReviewComments {
            session_id: Some("sid".into()),
            state: Some("all".into()),
        };
        let req = build_request(&cmd, None, Some("/wt".into()));
        assert_eq!(req.command, "review_comments");
        let params = req.params.expect("params must be set");
        assert_eq!(params["session_id"], serde_json::json!("sid"));
        assert_eq!(params["state"], serde_json::json!("all"));

        let bare = build_request(
            &Command::ReviewComments {
                session_id: None,
                state: None,
            },
            None,
            Some("/wt".into()),
        );
        assert_eq!(bare.params, Some(serde_json::json!({})));
    }

    #[test]
    fn builds_review_reply_and_resolve_params() {
        let reply = build_request(
            &Command::ReviewReply {
                comment_id: "c1".into(),
                body: "done".into(),
            },
            None,
            Some("/wt".into()),
        );
        assert_eq!(reply.command, "review_reply");
        assert_eq!(
            reply.params,
            Some(serde_json::json!({"comment_id": "c1", "body": "done"}))
        );

        let resolve = build_request(
            &Command::ReviewResolve {
                comment_id: "c1".into(),
                reply: Some("fixed".into()),
                reopen: false,
            },
            None,
            Some("/wt".into()),
        );
        assert_eq!(resolve.command, "review_resolve");
        assert_eq!(
            resolve.params,
            Some(serde_json::json!({"comment_id": "c1", "reply": "fixed"}))
        );

        let reopen = build_request(
            &Command::ReviewResolve {
                comment_id: "c1".into(),
                reply: None,
                reopen: true,
            },
            None,
            Some("/wt".into()),
        );
        assert_eq!(
            reopen.params,
            Some(serde_json::json!({"comment_id": "c1", "reopen": true}))
        );
    }

    #[test]
    fn builds_review_comment_add_params() {
        let cmd = Command::ReviewCommentAdd {
            path: "src/a.swift".into(),
            start_line: 10,
            end_line: Some(12),
            side: Some("new".into()),
            body: "consider guard".into(),
            session_id: None,
        };
        let req = build_request(&cmd, None, Some("/wt".into()));
        assert_eq!(req.command, "review_comment_add");
        assert_eq!(
            req.params,
            Some(serde_json::json!({
                "path": "src/a.swift",
                "start_line": 10,
                "end_line": 12,
                "side": "new",
                "body": "consider guard"
            }))
        );
    }

    #[test]
    fn builds_review_finish_params() {
        let cmd = Command::ReviewFinish {
            session_id: Some("sid".into()),
            verdict: Some("request_changes".into()),
            summary: Some("Fix the race.".into()),
        };
        let req = build_request(&cmd, None, Some("/wt".into()));
        assert_eq!(req.command, "review_finish");
        assert_eq!(
            req.params,
            Some(serde_json::json!({
                "session_id": "sid",
                "verdict": "request_changes",
                "summary": "Fix the race."
            }))
        );
    }

    #[test]
    fn builds_resolve_with_cwd_only() {
        let req = build_request(&Command::Resolve, None, Some("/repo".into()));
        assert_eq!(req.command, "resolve");
        assert_eq!(req.cwd.as_deref(), Some("/repo"));
        assert!(req.session_id.is_none());
    }

    #[test]
    fn workspace_commands_build_versioned_requests() {
        let checkout = "7D064822-8491-4E33-BD74-355FD2AB3330".to_string();
        let member = "C2476427-94B2-423F-A490-568775E8B309".to_string();

        let list = build_request(&Command::WorkspaceList, None, Some("/repo".into()));
        assert_eq!(list.command, "workspace");
        assert_eq!(list.subcommand.as_deref(), Some("list"));
        assert_eq!(list.cwd.as_deref(), Some("/repo"));

        let show = build_request(&Command::WorkspaceShow { checkout_id: checkout.clone() }, Some("s1".into()), None);
        assert_eq!(show.command, "workspace");
        assert_eq!(show.subcommand.as_deref(), Some("show"));
        assert_eq!(show.params.as_ref().unwrap()["checkout_id"], checkout);

        let focus = build_request(
            &Command::WorkspaceFocus { checkout_id: checkout.clone(), member_id: member.clone() },
            Some("s1".into()),
            None,
        );
        assert_eq!(focus.command, "workspace");
        assert_eq!(focus.subcommand.as_deref(), Some("focus"));
        assert_eq!(focus.params.as_ref().unwrap()["checkout_id"], checkout);
        assert_eq!(focus.params.as_ref().unwrap()["member_id"], member);
    }

    #[test]
    fn discovers_only_live_pid_sockets() {
        let root = std::env::temp_dir().join(format!("alas-cli-disc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();

        // A second live process we actually own, to exercise multi-entry sort
        // order (string-sorted paths, not numeric pid order).
        let mut child = std::process::Command::new("sleep")
            .arg("5")
            .spawn()
            .unwrap();

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
        let root =
            std::env::temp_dir().join(format!("alas-cli-disc-pidguard-{}", std::process::id()));
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
