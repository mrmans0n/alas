//! Plugin processes (plugin API 11): `process/run` and `process/start` for a
//! worktree on this host.
//!
//! Separate from `proc/*`, which carries newline-framed ACP traffic and must
//! not change. A plugin process is:
//!
//! - started from a raw argv, without a shell, in the worktree, with the login
//!   environment of the user's shell captured once per helper;
//! - fed its one-shot `stdin` payload and then EOF, or `/dev/null`;
//! - recorded as one journal of stdout and stderr chunks in arrival order,
//!   capped like the plugin host caps it (the head for runs, the tail for
//!   long-running processes), with logical offsets and a retained base;
//! - owned by the lease of the plugin instance that started it: every call
//!   names that lease, and a call for another lease's process is refused;
//! - stopped with everything it started, by a supervisor that leads nothing
//!   itself but holds a pidfd for every process it owns (see `linux`).
//!
//! Only Linux hosts with pidfds qualify. macOS has no subreaper, so a
//! double-forked daemon could escape, and API 6 promises none does.

use crate::{HelperError, ServerMessage, decode_params, jsonrpc_error, validate_proc_id};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashSet, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_ARGS: usize = 64;
const MAX_ARG_BYTES: usize = 4096;
const MAX_STDIN_BYTES: usize = 256 * 1024;
const MAX_OUTPUT_BYTES: usize = 4 * 1024 * 1024;
const MAX_LEASE_MS: u64 = 10 * 60 * 1000;
const DEFAULT_LEASE_MS: u64 = 60 * 1000;
const STOP_GRACE_MS: u64 = 5000;
/// API 6's 10 minutes; the kill grace follows it.
const MAX_TIMEOUT_MS: u64 = 10 * 60 * 1000;
/// What a process leaves running when it exits on its own gets this long
/// after `SIGTERM`, as API 6 says.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
const LEFTOVER_GRACE_MS: u64 = 1000;
const ENV_BEGIN: &str = "__ALAS_ENV_BEGIN__";
const ENV_END: &str = "__ALAS_ENV_END__";

// MARK: - Requests

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpawnParams {
    proc_id: String,
    lease: String,
    argv: Vec<String>,
    cwd: String,
    #[serde(default)]
    long_running: bool,
    stdin_base64: Option<String>,
    output_limit: usize,
    lease_ms: Option<u64>,
    /// Run mode only: the helper stops the run at this limit even if Alas is
    /// gone. Defaults to (and is capped at) API 6's 10 minutes.
    timeout_ms: Option<u64>,
    kill_grace_ms: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnedParams {
    proc_id: String,
    lease: String,
    #[serde(default)]
    offset: u64,
    lease_ms: Option<u64>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Launch {
    executable: String,
    argv: Vec<String>,
    cwd: String,
    env: Vec<(String, String)>,
    long_running: bool,
    stdin_base64: Option<String>,
    output_limit: usize,
    timeout_ms: Option<u64>,
    kill_grace_ms: u64,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ExitRecord {
    exit: i32,
    timed_out: bool,
}

pub(crate) fn handle(
    method: &str,
    params: Option<Value>,
    events: Option<Sender<ServerMessage>>,
) -> Result<Value, HelperError> {
    match method {
        "pproc/spawn" => spawn(params),
        "pproc/attach" => attach(params, events),
        "pproc/renew" => renew(params),
        "pproc/kill" => kill(params),
        "pproc/release" => release(params),
        _ => Err(jsonrpc_error(-32601, format!("method not found: {method}"))),
    }
}

/// Why this host can't run plugin processes, if it can't.
pub(crate) fn unsupported_reason() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        if linux::pidfd_supported() {
            None
        } else {
            Some("this host's Linux kernel lacks pidfd_open and pidfd_send_signal (Linux 5.3 or later is required to stop everything a command starts)".into())
        }
    }
    #[cfg(target_os = "macos")]
    {
        Some("plugin commands can't run on macOS SSH hosts: macOS can't guarantee that everything a command starts is stopped".into())
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        Some("plugin commands can't run on this host's operating system".into())
    }
}

fn root_dir() -> Result<PathBuf, HelperError> {
    let state =
        alas_helper::helper_state_dir().ok_or_else(|| jsonrpc_error(-32050, "HOME is not set"))?;
    Ok(state.join("plugin-procs"))
}

fn proc_dir(proc_id: &str) -> Result<PathBuf, HelperError> {
    validate_proc_id(proc_id)?;
    Ok(root_dir()?.join(proc_id))
}

/// The directory of a process this lease owns. A missing one is `None`; one
/// owned by another lease is refused rather than reported missing, so a
/// caller can't mistake it for a process that ended.
fn owned_dir(proc_id: &str, lease: &str) -> Result<Option<PathBuf>, HelperError> {
    let dir = proc_dir(proc_id)?;
    match std::fs::read_to_string(dir.join("owner")) {
        Ok(owner) if owner == lease => Ok(Some(dir)),
        Ok(_) => Err(jsonrpc_error(
            -32054,
            "process belongs to another plugin instance",
        )),
        Err(_) => Ok(None),
    }
}

fn validate_lease(lease: &str) -> Result<(), HelperError> {
    if lease.is_empty() || lease.len() > 128 || !lease.bytes().all(|b| b.is_ascii_graphic()) {
        return Err(jsonrpc_error(-32602, "invalid lease"));
    }
    Ok(())
}

fn spawn(params: Option<Value>) -> Result<Value, HelperError> {
    let params: SpawnParams = decode_params(params)?;
    if let Some(reason) = unsupported_reason() {
        return Err(jsonrpc_error(-32003, reason));
    }
    validate_proc_id(&params.proc_id)?;
    validate_lease(&params.lease)?;
    if params.argv.is_empty()
        || params.argv[0].is_empty()
        || params.argv.len() > MAX_ARGS
        || params
            .argv
            .iter()
            .any(|arg| arg.len() > MAX_ARG_BYTES || arg.contains('\0'))
    {
        return Err(jsonrpc_error(-32602, "invalid argv"));
    }
    let stdin = params
        .stdin_base64
        .as_deref()
        .map(|data| base64::engine::general_purpose::STANDARD.decode(data))
        .transpose()
        .map_err(|_| jsonrpc_error(-32602, "invalid stdin"))?;
    if stdin
        .as_ref()
        .is_some_and(|data| data.len() > MAX_STDIN_BYTES)
        || (params.long_running && stdin.is_some())
    {
        return Err(jsonrpc_error(
            -32602,
            "stdin is up to 256 KiB, and only for runs",
        ));
    }
    if params.output_limit == 0 || params.output_limit > MAX_OUTPUT_BYTES {
        return Err(jsonrpc_error(-32602, "invalid outputLimit"));
    }
    let cwd = std::fs::canonicalize(&params.cwd)
        .ok()
        .filter(|path| path.is_dir())
        .ok_or_else(|| jsonrpc_error(-32003, format!("worktree {} does not exist", params.cwd)))?;

    if owned_dir(&params.proc_id, &params.lease)?.is_some() {
        // A retried spawn: the first one went through.
        return Ok(json!({ "procId": params.proc_id, "spawned": false }));
    }

    let env = login_env();
    let path = env
        .iter()
        .find(|(key, _)| key == "PATH")
        .map(|(_, value)| value.as_str());
    let executable = resolve_executable(&params.argv[0], &cwd, path.unwrap_or(""))
        .ok_or_else(|| jsonrpc_error(-32003, format!("command not found: {}", params.argv[0])))?;

    let root = root_dir()?;
    create_private_dir_all(&root)?;
    let dir = root.join(&params.proc_id);
    // `create_dir` fails if it exists, so two racing spawns can't share it.
    std::fs::create_dir(&dir)
        .map_err(|error| jsonrpc_error(-32050, format!("process directory failed: {error}")))?;
    let launch = Launch {
        executable: executable.display().to_string(),
        argv: params.argv,
        cwd: cwd.display().to_string(),
        env: env.to_vec(),
        long_running: params.long_running,
        stdin_base64: params.stdin_base64,
        output_limit: params.output_limit,
        timeout_ms: (!params.long_running).then(|| {
            params
                .timeout_ms
                .unwrap_or(MAX_TIMEOUT_MS)
                .min(MAX_TIMEOUT_MS)
        }),
        kill_grace_ms: params
            .kill_grace_ms
            .unwrap_or(STOP_GRACE_MS)
            .min(STOP_GRACE_MS),
    };
    let result = (|| {
        write_atomic(&dir.join("owner"), params.lease.as_bytes())?;
        write_lease(&dir, params.lease_ms)?;
        write_atomic(
            &dir.join("launch.json"),
            &serde_json::to_vec(&launch).expect("launch serializes"),
        )?;
        start_supervisor(&dir)
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_dir_all(&dir);
        return Err(error);
    }
    Ok(json!({ "procId": params.proc_id, "spawned": true }))
}

fn start_supervisor(dir: &Path) -> Result<(), HelperError> {
    let exe = std::env::current_exe()
        .map_err(|error| jsonrpc_error(-32050, format!("helper path failed: {error}")))?;
    let mut command = Command::new(exe);
    command
        .arg("plugin-proc-supervise")
        .arg(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut supervisor = command
        .spawn()
        .map_err(|error| jsonrpc_error(-32050, format!("supervisor spawn failed: {error}")))?;
    thread::spawn(move || {
        let _ = supervisor.wait();
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if dir.join("started").is_file() {
            return Ok(());
        }
        if let Ok(message) = std::fs::read_to_string(dir.join("error")) {
            return Err(jsonrpc_error(-32003, message));
        }
        thread::sleep(Duration::from_millis(10));
    }
    let _ = std::fs::write(dir.join("stop"), b"");
    Err(jsonrpc_error(
        -32050,
        "supervisor did not start the process",
    ))
}

/// Replays the journal from `offset`, or from its retained base when `offset`
/// fell below it, and streams what follows as `pproc/output` notifications
/// until `pproc/exit`.
fn attach(
    params: Option<Value>,
    events: Option<Sender<ServerMessage>>,
) -> Result<Value, HelperError> {
    let params: OwnedParams = decode_params(params)?;
    let dir = owned_dir(&params.proc_id, &params.lease)?
        .ok_or_else(|| jsonrpc_error(-32051, "process not found"))?;
    let exit = read_exit(&dir);
    let journal = Journal::read(&dir.join("journal"));
    let chunks = journal.replay(params.offset);
    if let (None, Some(events)) = (exit, events) {
        start_tailer(params.proc_id.clone(), dir, journal.end, events);
    }
    let mut result = json!({
        "procId": params.proc_id,
        "running": exit.is_none(),
        "base": journal.base(),
        "end": journal.end,
        "truncated": journal.truncated,
        "chunks": chunks.iter().map(chunk_json).collect::<Vec<_>>(),
    });
    if let Some(exit) = exit {
        result["exit"] = json!(exit.exit);
        result["timedOut"] = json!(exit.timed_out);
    }
    Ok(result)
}

fn chunk_json(chunk: &Chunk) -> Value {
    json!({
        "seq": chunk.seq,
        "stream": if chunk.stream == 0 { "stdout" } else { "stderr" },
        "offset": chunk.offset,
        "dataBase64": base64::engine::general_purpose::STANDARD.encode(&chunk.data),
    })
}

fn start_tailer(proc_id: String, dir: PathBuf, mut next: u64, events: Sender<ServerMessage>) {
    static TAILERS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    let tailers = TAILERS.get_or_init(Default::default);
    if !tailers
        .lock()
        .expect("tailers lock")
        .insert(proc_id.clone())
    {
        return;
    }
    thread::spawn(move || {
        let notify = |method: &str, params: Value| {
            events
                .send(ServerMessage::Response(
                    json!({ "jsonrpc": "2.0", "method": method, "params": params }).to_string(),
                ))
                .is_ok()
        };
        loop {
            // Read the exit first: a journal read after it holds everything.
            let exit = read_exit(&dir);
            let journal = Journal::read(&dir.join("journal"));
            let mut alive = true;
            for chunk in journal.replay(next) {
                next = chunk.offset + chunk.data.len() as u64;
                let mut params = chunk_json(&chunk);
                params["procId"] = json!(proc_id);
                alive &= notify("pproc/output", params);
            }
            if let Some(exit) = exit {
                notify(
                    "pproc/exit",
                    json!({
                        "procId": proc_id,
                        "exit": exit.exit,
                        "timedOut": exit.timed_out,
                        "truncated": journal.truncated,
                    }),
                );
                break;
            }
            if !alive || !dir.is_dir() {
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        tailers.lock().expect("tailers lock").remove(&proc_id);
    });
}

fn renew(params: Option<Value>) -> Result<Value, HelperError> {
    let params: OwnedParams = decode_params(params)?;
    let dir = owned_dir(&params.proc_id, &params.lease)?
        .ok_or_else(|| jsonrpc_error(-32051, "process not found"))?;
    write_lease(&dir, params.lease_ms)?;
    Ok(json!({ "ok": true }))
}

/// Asks the supervisor to stop the process and everything it started. Answers
/// at once; `pproc/exit` follows when nothing is left. Works whether or not
/// the process itself is still running.
fn kill(params: Option<Value>) -> Result<Value, HelperError> {
    let params: OwnedParams = decode_params(params)?;
    if let Some(dir) = owned_dir(&params.proc_id, &params.lease)? {
        request_stop(&dir);
    }
    Ok(json!({ "ok": true }))
}

/// Stops the process if it still runs and forgets it.
fn release(params: Option<Value>) -> Result<Value, HelperError> {
    let params: OwnedParams = decode_params(params)?;
    if let Some(dir) = owned_dir(&params.proc_id, &params.lease)? {
        // The supervisor finishes stopping from memory and leaves when it
        // sees its directory gone.
        request_stop(&dir);
        std::fs::remove_dir_all(&dir)
            .map_err(|error| jsonrpc_error(-32050, format!("release failed: {error}")))?;
    }
    Ok(json!({ "ok": true }))
}

fn request_stop(dir: &Path) {
    if read_exit(dir).is_none() {
        let _ = std::fs::write(dir.join("stop"), b"");
    }
}

fn read_exit(dir: &Path) -> Option<ExitRecord> {
    serde_json::from_slice(&std::fs::read(dir.join("exit.json")).ok()?).ok()
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

fn write_lease(dir: &Path, lease_ms: Option<u64>) -> Result<(), HelperError> {
    let until = now_ms() + lease_ms.unwrap_or(DEFAULT_LEASE_MS).clamp(1, MAX_LEASE_MS);
    write_atomic(&dir.join("lease-until"), until.to_string().as_bytes())
}

/// A lease file that can't be read counts as lapsed: nobody can renew it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn lease_lapsed(dir: &Path) -> bool {
    std::fs::read_to_string(dir.join("lease-until"))
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .is_none_or(|until| now_ms() > until)
}

fn create_private_dir_all(path: &Path) -> Result<(), HelperError> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder
        .create(path)
        .map_err(|error| jsonrpc_error(-32050, format!("process root failed: {error}")))
}

/// Readers see the old file or the new one, never half of one.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), HelperError> {
    let temp = path.with_extension("tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let fail = |error: std::io::Error| jsonrpc_error(-32050, format!("write failed: {error}"));
    let mut file = options.open(&temp).map_err(fail)?;
    file.write_all(bytes).map_err(fail)?;
    drop(file);
    std::fs::rename(&temp, path).map_err(fail)
}

// MARK: - Executable and environment

/// An absolute path as it is, a path with a slash relative to the worktree,
/// and a bare name on `path`, as the local launcher resolves it.
fn resolve_executable(name: &str, cwd: &Path, path: &str) -> Option<PathBuf> {
    let candidates: Vec<PathBuf> = if name.starts_with('/') {
        vec![PathBuf::from(name)]
    } else if name.contains('/') {
        vec![cwd.join(name)]
    } else {
        path.split(':')
            .filter(|dir| !dir.is_empty())
            .map(|dir| Path::new(dir).join(name))
            .collect()
    };
    candidates
        .into_iter()
        .find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// The user's login environment, captured once per helper. Falls back to the
/// helper's own environment, which also came from this host, when the login
/// shell fails.
fn login_env() -> &'static [(String, String)] {
    static ENV: OnceLock<Vec<(String, String)>> = OnceLock::new();
    ENV.get_or_init(|| {
        let shell = std::env::var("SHELL")
            .ok()
            .filter(|shell| shell.starts_with('/'));
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
        let captured = capture_login_env(
            Path::new(shell.as_deref().unwrap_or("/bin/sh")),
            Path::new(&home),
        );
        scrub_env(captured.unwrap_or_else(|| std::env::vars().collect()))
    })
}

/// Runs `shell -l -c` around `env -0` between sentinels, so a profile's banner
/// and values holding newlines can't corrupt what's read back.
fn capture_login_env(shell: &Path, home: &Path) -> Option<Vec<(String, String)>> {
    use std::io::Read;
    let script = format!("printf '%s' '{ENV_BEGIN}'; env -0; printf '%s' '{ENV_END}'");
    let mut child = Command::new(shell)
        .args(["-l", "-c", &script])
        .current_dir(home)
        .env("HOME", home)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.read_to_end(&mut bytes);
        bytes
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    parse_env_block(&reader.join().ok()?)
}

fn parse_env_block(bytes: &[u8]) -> Option<Vec<(String, String)>> {
    let find = |needle: &[u8], from: usize| {
        bytes[from..]
            .windows(needle.len())
            .position(|window| window == needle)
            .map(|index| index + from)
    };
    let start = find(ENV_BEGIN.as_bytes(), 0)? + ENV_BEGIN.len();
    let end = bytes
        .windows(ENV_END.len())
        .rposition(|window| window == ENV_END.as_bytes())
        .filter(|&end| end >= start)?;
    // ponytail: entries that aren't UTF-8 are dropped; carry OsStrings if a
    // host ever needs them.
    Some(
        bytes[start..end]
            .split(|&byte| byte == 0)
            .filter_map(|entry| std::str::from_utf8(entry).ok())
            .filter_map(|entry| entry.split_once('='))
            .filter(|(key, _)| !key.is_empty())
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect(),
    )
}

/// Alas's own variables and the markers of an agent session the helper may
/// have been started from are not the user's.
fn scrub_env(env: Vec<(String, String)>) -> Vec<(String, String)> {
    env.into_iter()
        .filter(|(key, _)| {
            !key.starts_with("ALAS_") && !crate::ACP_REMOTE_MARKER_SCRUB.contains(&key.as_str())
        })
        .collect()
}

// MARK: - Journal

/// stdout and stderr in the order they were written, with logical offsets:
/// byte counts over both streams that never go back, so a reader that
/// remembers one resumes exactly, or at the retained base when the cap
/// dropped what it remembered.
#[derive(Debug, Default, PartialEq)]
struct Journal {
    keep_tail: bool,
    limit: usize,
    chunks: VecDeque<Chunk>,
    retained: usize,
    end: u64,
    next_seq: u64,
    truncated: bool,
    /// Counts changes, so the supervisor writes the file only after one.
    version: u64,
}

#[derive(Debug, Clone, PartialEq)]
struct Chunk {
    seq: u64,
    /// 0 is stdout, 1 is stderr.
    stream: u8,
    offset: u64,
    data: Vec<u8>,
}

const JOURNAL_MAGIC: &[u8; 4] = b"APJ1";

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
impl Journal {
    fn new(keep_tail: bool, limit: usize) -> Self {
        Self {
            keep_tail,
            limit,
            ..Self::default()
        }
    }

    fn base(&self) -> u64 {
        self.chunks.front().map_or(self.end, |chunk| chunk.offset)
    }

    /// Keeps the first `limit` bytes for a run, the latest for a long-running
    /// process. Joins a run of one stream into one chunk.
    fn append(&mut self, stream: u8, data: &[u8]) {
        let data = if self.keep_tail {
            data
        } else {
            let room = self.limit.saturating_sub(self.retained);
            if data.len() > room && !self.truncated {
                self.truncated = true;
                self.version += 1;
            }
            &data[..data.len().min(room)]
        };
        if data.is_empty() {
            return;
        }
        self.version += 1;
        match self.chunks.back_mut() {
            Some(last) if last.stream == stream => last.data.extend_from_slice(data),
            _ => {
                self.chunks.push_back(Chunk {
                    seq: self.next_seq,
                    stream,
                    offset: self.end,
                    data: data.to_vec(),
                });
                self.next_seq += 1;
            }
        }
        self.end += data.len() as u64;
        self.retained += data.len();
        while self.retained > self.limit {
            self.truncated = true;
            let excess = self.retained - self.limit;
            let front = self
                .chunks
                .front_mut()
                .expect("retained bytes live in chunks");
            if front.data.len() <= excess {
                self.retained -= front.data.len();
                self.chunks.pop_front();
            } else {
                front.data.drain(..excess);
                front.offset += excess as u64;
                self.retained -= excess;
            }
        }
    }

    /// What follows `offset`, or everything retained when `offset` fell below
    /// the base, in the original order.
    fn replay(&self, offset: u64) -> Vec<Chunk> {
        let from = offset.max(self.base());
        self.chunks
            .iter()
            .filter(|chunk| chunk.offset + chunk.data.len() as u64 > from)
            .map(|chunk| {
                let skip = from.saturating_sub(chunk.offset) as usize;
                Chunk {
                    offset: chunk.offset + skip as u64,
                    data: chunk.data[skip..].to_vec(),
                    ..chunk.clone()
                }
            })
            .collect()
    }

    fn encode(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(self.retained + 32 + self.chunks.len() * 21);
        bytes.extend_from_slice(JOURNAL_MAGIC);
        bytes.extend_from_slice(&self.end.to_le_bytes());
        bytes.push(u8::from(self.truncated));
        for chunk in &self.chunks {
            bytes.push(chunk.stream);
            bytes.extend_from_slice(&chunk.seq.to_le_bytes());
            bytes.extend_from_slice(&chunk.offset.to_le_bytes());
            bytes.extend_from_slice(&(chunk.data.len() as u32).to_le_bytes());
            bytes.extend_from_slice(&chunk.data);
        }
        bytes
    }

    fn decode(bytes: &[u8]) -> Option<Self> {
        fn take<'a>(bytes: &mut &'a [u8], count: usize) -> Option<&'a [u8]> {
            let (head, tail) = bytes.split_at_checked(count)?;
            *bytes = tail;
            Some(head)
        }
        let mut rest = bytes;
        if take(&mut rest, 4)? != JOURNAL_MAGIC {
            return None;
        }
        let mut journal = Journal {
            end: u64::from_le_bytes(take(&mut rest, 8)?.try_into().ok()?),
            truncated: take(&mut rest, 1)?[0] != 0,
            ..Journal::default()
        };
        while !rest.is_empty() {
            let stream = take(&mut rest, 1)?[0];
            let seq = u64::from_le_bytes(take(&mut rest, 8)?.try_into().ok()?);
            let offset = u64::from_le_bytes(take(&mut rest, 8)?.try_into().ok()?);
            let len = u32::from_le_bytes(take(&mut rest, 4)?.try_into().ok()?) as usize;
            let data = take(&mut rest, len)?.to_vec();
            journal.retained += data.len();
            journal.chunks.push_back(Chunk {
                seq,
                stream,
                offset,
                data,
            });
        }
        Some(journal)
    }

    /// A missing or unreadable journal reads as empty.
    fn read(path: &Path) -> Self {
        std::fs::read(path)
            .ok()
            .and_then(|bytes| Self::decode(&bytes))
            .unwrap_or_default()
    }
}

// MARK: - Supervisor

pub(crate) fn supervise_main(dir: Option<String>) -> ! {
    let Some(dir) = dir else {
        eprintln!("usage: alas-helper plugin-proc-supervise <dir>");
        std::process::exit(2);
    };
    #[cfg(target_os = "linux")]
    {
        linux::supervise(PathBuf::from(dir));
        std::process::exit(0);
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = std::fs::write(
            Path::new(&dir).join("error"),
            unsupported_reason().unwrap_or_default(),
        );
        std::process::exit(1);
    }
}

/// Leads the process group a plugin process runs in, so its id can't be
/// reused while cleanup signals it. Ignores every signal it can and dies with
/// its supervisor.
pub(crate) fn anchor_main() -> ! {
    #[cfg(target_os = "linux")]
    linux::anchor();
    #[cfg(not(target_os = "linux"))]
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::collections::HashMap;
    use std::io::Read;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::sync::Arc;
    use std::sync::mpsc;

    pub(super) fn pidfd_open(pid: i32) -> Option<OwnedFd> {
        // SAFETY: a plain syscall; a non-negative result is a new fd we own.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd as i32) })
    }

    pub(super) fn pidfd_signal(fd: &OwnedFd, signal: i32) -> bool {
        // SAFETY: a plain syscall on an fd we hold, without siginfo.
        unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                fd.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            ) == 0
        }
    }

    pub(super) fn pidfd_supported() -> bool {
        pidfd_open(std::process::id() as i32).is_some_and(|fd| pidfd_signal(&fd, 0))
    }

    #[derive(Debug, Clone, Copy, PartialEq)]
    pub(super) struct Stat {
        pub ppid: i32,
        pub pgrp: i32,
        pub start: u64,
        pub dead: bool,
    }

    /// Fields of `/proc/<pid>/stat` after the command name, which may itself
    /// hold spaces and parentheses.
    pub(super) fn parse_stat(text: &str) -> Option<Stat> {
        let fields: Vec<&str> = text[text.rfind(')')? + 1..].split_whitespace().collect();
        Some(Stat {
            dead: matches!(*fields.first()?, "Z" | "X"),
            ppid: fields.get(1)?.parse().ok()?,
            pgrp: fields.get(2)?.parse().ok()?,
            start: fields.get(19)?.parse().ok()?,
        })
    }

    pub(super) fn stat(pid: i32) -> Option<Stat> {
        parse_stat(&std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)
    }

    /// Every live process below `ancestor`, with its identity.
    pub(super) fn descendants(ancestor: i32) -> Vec<(i32, Stat)> {
        let all: Vec<(i32, Stat)> = std::fs::read_dir("/proc")
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|entry| entry.file_name().to_str()?.parse::<i32>().ok())
            .filter_map(|pid| Some((pid, stat(pid)?)))
            .collect();
        let mut below = HashSet::from([ancestor]);
        let mut found = Vec::new();
        // Parents may be listed after their children; repeat until stable.
        loop {
            let before = found.len();
            for (pid, stat) in &all {
                if !below.contains(pid) && below.contains(&stat.ppid) {
                    below.insert(*pid);
                    found.push((*pid, *stat));
                }
            }
            if found.len() == before {
                break;
            }
        }
        found.retain(|(_, stat)| !stat.dead);
        found
    }

    /// A pidfd for `pid` only while it is still the process sampled with
    /// `start`: the fd is opened first and the identity checked while it is
    /// held, so a pid reused in between is closed, never signalled.
    pub(super) fn open_validated(pid: i32, start: u64) -> Option<OwnedFd> {
        let fd = pidfd_open(pid)?;
        stat(pid)
            .filter(|stat| stat.start == start && !stat.dead)
            .map(|_| fd)
    }

    fn exit_code(status: i32) -> i32 {
        if libc::WIFEXITED(status) {
            libc::WEXITSTATUS(status)
        } else if libc::WIFSIGNALED(status) {
            128 + libc::WTERMSIG(status)
        } else {
            -1
        }
    }

    /// Ignores every signal it can and dies with `parent`. Async-signal-safe,
    /// so the anchor runs it between fork and exec: ignored dispositions and
    /// the parent-death signal survive exec, so the anchor is never without
    /// them, however soon the command signals its group.
    fn guard_anchor(parent: i32) -> std::io::Result<()> {
        // SAFETY: sigaction and prctl only, both async-signal-safe.
        unsafe {
            for signal in 1..=64 {
                if signal != libc::SIGKILL && signal != libc::SIGSTOP {
                    libc::signal(signal, libc::SIG_IGN);
                }
            }
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            // The supervisor may have died before the line above took effect.
            if libc::getppid() != parent {
                libc::_exit(0);
            }
        }
        Ok(())
    }

    pub(super) fn anchor() -> ! {
        loop {
            // SAFETY: waiting for a signal; every catchable one is ignored.
            unsafe { libc::pause() };
        }
    }

    struct Supervisor {
        dir: PathBuf,
        me: i32,
        anchor: i32,
        anchor_fd: Option<OwnedFd>,
        root: i32,
        root_status: Option<i32>,
        owned: HashMap<(i32, u64), OwnedFd>,
        log: Option<std::fs::File>,
    }

    impl Supervisor {
        fn log(&mut self, line: &str) {
            if let Some(log) = self.log.as_mut() {
                let _ = writeln!(log, "{line}");
            }
        }

        /// Reaps everything that ended, the root and adopted orphans alike.
        fn reap(&mut self) {
            loop {
                let mut status = 0;
                // SAFETY: waitpid with a valid out pointer.
                let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
                if pid <= 0 {
                    break;
                }
                if pid == self.root {
                    self.root_status = Some(exit_code(status));
                } else if pid == self.anchor && self.anchor_fd.take().is_some() {
                    self.log("anchor-dead");
                }
            }
        }

        /// The processes this run still owns, each with a validated pidfd,
        /// the anchor aside.
        fn sample(&mut self) -> Vec<(i32, u64)> {
            let found = descendants(self.me);
            let live: HashSet<(i32, u64)> = found
                .iter()
                .filter(|(pid, _)| *pid != self.anchor)
                .map(|(pid, stat)| (*pid, stat.start))
                .collect();
            self.owned.retain(|key, _| live.contains(key));
            for &(pid, start) in &live {
                if self.owned.contains_key(&(pid, start)) {
                    continue;
                }
                match open_validated(pid, start) {
                    Some(fd) => {
                        self.owned.insert((pid, start), fd);
                    }
                    None => self.log(&format!("mismatch {pid}")),
                }
            }
            self.owned.keys().copied().collect()
        }

        fn signal_owned(&mut self, key: (i32, u64), signal: i32) {
            if let Some(fd) = self.owned.get(&key) {
                pidfd_signal(fd, signal);
                self.log(&format!("pid {} {signal}", key.0));
            }
        }

        /// `SIGTERM` to the group while its anchor lives, and to every owned
        /// process by its pidfd, newcomers included, until none is left or
        /// the grace ends; then `SIGKILL` passes until none is left; then the
        /// anchor, last.
        fn stop(&mut self, grace: Duration) {
            let term_until = Instant::now() + grace;
            let mut termed = HashSet::new();
            let mut group_termed = false;
            loop {
                self.reap();
                let owned = self.sample();
                if owned.is_empty() || Instant::now() >= term_until {
                    break;
                }
                if !group_termed && self.anchor_fd.is_some() {
                    group_termed = true;
                    // SAFETY: plain kill; the live anchor keeps the group id ours.
                    unsafe { libc::kill(-self.anchor, libc::SIGTERM) };
                    self.log(&format!("group {}", libc::SIGTERM));
                }
                for key in owned {
                    if termed.insert(key) {
                        self.signal_owned(key, libc::SIGTERM);
                    }
                }
                thread::sleep(Duration::from_millis(10));
            }
            // ponytail: a process stuck in uninterruptible sleep outlasting
            // 30 s of SIGKILL passes is given up on; the anchor still goes.
            let kill_until = Instant::now() + Duration::from_secs(30);
            loop {
                self.reap();
                let owned = self.sample();
                if owned.is_empty() || Instant::now() >= kill_until {
                    break;
                }
                for key in owned {
                    self.signal_owned(key, libc::SIGKILL);
                }
                thread::sleep(Duration::from_millis(5));
            }
            if let Some(fd) = self.anchor_fd.take() {
                pidfd_signal(&fd, libc::SIGKILL);
                self.log("anchor-removed");
                let mut status = 0;
                // SAFETY: waitpid on our own child.
                unsafe { libc::waitpid(self.anchor, &mut status, 0) };
            }
            self.reap();
        }
    }

    fn fail(dir: &Path, message: String) {
        let _ = write_atomic(&dir.join("error"), message.as_bytes());
    }

    pub(super) fn supervise(dir: PathBuf) {
        // SAFETY: plain prctl. Orphans of the run reparent here, so they stay
        // findable however they detach.
        unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1) };
        let launch: Launch = match std::fs::read(dir.join("launch.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        {
            Some(launch) => launch,
            None => return fail(&dir, "launch file unreadable".into()),
        };
        let _ = std::fs::remove_file(dir.join("launch.json"));
        let stdin = launch
            .stdin_base64
            .as_deref()
            .and_then(|data| base64::engine::general_purpose::STANDARD.decode(data).ok());

        let (anchor, anchor_fd) = match spawn_anchor() {
            Ok(anchor) => anchor,
            Err(message) => return fail(&dir, message),
        };
        let _ = write_atomic(&dir.join("anchor"), anchor.to_string().as_bytes());

        use std::os::unix::process::CommandExt;
        let mut command = Command::new(&launch.executable);
        command
            .arg0(&launch.argv[0])
            .args(&launch.argv[1..])
            .current_dir(&launch.cwd)
            .env_clear()
            .envs(launch.env.iter().map(|(key, value)| (key, value)))
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(anchor);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                pidfd_signal(&anchor_fd, libc::SIGKILL);
                // SAFETY: waitpid on our own child.
                unsafe { libc::waitpid(anchor, &mut 0, 0) };
                return fail(&dir, format!("could not start {}: {error}", launch.argv[0]));
            }
        };
        let root = child.id() as i32;
        let mut supervisor = Supervisor {
            dir: dir.clone(),
            me: std::process::id() as i32,
            anchor,
            anchor_fd: Some(anchor_fd),
            root,
            root_status: None,
            owned: HashMap::new(),
            log: std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("cleanup.log"))
                .ok(),
        };
        // The root is our unreaped child, so its pid is still its own here.
        if let (Some(fd), Some(stat)) = (pidfd_open(root), stat(root)) {
            supervisor.owned.insert((root, stat.start), fd);
        }

        let journal = Arc::new(Mutex::new(Journal::new(
            launch.long_running,
            launch.output_limit,
        )));
        let (done_tx, done_rx) = mpsc::channel();
        let mut readers = 0;
        for (stream, pipe) in [
            (
                0_u8,
                child
                    .stdout
                    .take()
                    .map(|pipe| Box::new(pipe) as Box<dyn Read + Send>),
            ),
            (
                1_u8,
                child
                    .stderr
                    .take()
                    .map(|pipe| Box::new(pipe) as Box<dyn Read + Send>),
            ),
        ] {
            let Some(mut pipe) = pipe else { continue };
            let journal = journal.clone();
            let done = done_tx.clone();
            readers += 1;
            thread::spawn(move || {
                let mut buffer = [0_u8; 16 * 1024];
                while let Ok(read) = pipe.read(&mut buffer) {
                    if read == 0 {
                        break;
                    }
                    journal
                        .lock()
                        .expect("journal lock")
                        .append(stream, &buffer[..read]);
                }
                let _ = done.send(());
            });
        }
        if let (Some(mut input), Some(stdin)) = (child.stdin.take(), stdin) {
            // Written, then closed, so the process sees EOF.
            thread::spawn(move || {
                let _ = input.write_all(&stdin);
            });
        }
        // Never waited through `Child`: `reap` collects every status.
        drop(child);
        let _ = write_atomic(&dir.join("root"), root.to_string().as_bytes());
        let _ = write_atomic(&dir.join("started"), b"");

        let started = Instant::now();
        let deadline = launch
            .timeout_ms
            .map(|ms| started + Duration::from_millis(ms));
        let grace = Duration::from_millis(launch.kill_grace_ms);
        let mut timed_out = false;
        let mut flushed = 0;
        let mut last_flush = Instant::now();
        loop {
            supervisor.reap();
            if supervisor.root_status.is_some() {
                supervisor.stop(grace.min(Duration::from_millis(LEFTOVER_GRACE_MS)));
                break;
            }
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                timed_out = true;
                supervisor.stop(grace);
                break;
            }
            if dir.join("stop").exists() || !dir.is_dir() || lease_lapsed(&dir) {
                supervisor.stop(grace);
                break;
            }
            if last_flush.elapsed() >= Duration::from_millis(100) {
                flushed = flush(&dir, &journal, flushed);
                last_flush = Instant::now();
            }
            thread::sleep(Duration::from_millis(20));
        }
        // Everything that held the pipes is gone; a straggler that escaped
        // the passes doesn't hold the exit back for long.
        drop(done_tx);
        let wait_until = Instant::now() + Duration::from_secs(1);
        for _ in 0..readers {
            if done_rx
                .recv_timeout(wait_until.saturating_duration_since(Instant::now()))
                .is_err()
            {
                break;
            }
        }
        flush(&dir, &journal, u64::MAX);
        let record = ExitRecord {
            exit: supervisor.root_status.unwrap_or(-1),
            timed_out,
        };
        let _ = write_atomic(
            &dir.join("exit.json"),
            &serde_json::to_vec(&record).expect("exit serializes"),
        );
        // Kept for a replay until released, or until nobody renews it for a
        // lease's time after the exit, so a stopped run can still report.
        let _ = write_lease(&dir, None);
        while supervisor.dir.is_dir() {
            if lease_lapsed(&supervisor.dir) {
                let _ = std::fs::remove_dir_all(&supervisor.dir);
                break;
            }
            thread::sleep(Duration::from_millis(250));
        }
    }

    /// Writes the journal when it changed since version `written`, and
    /// returns the version written.
    fn flush(dir: &Path, journal: &Mutex<Journal>, written: u64) -> u64 {
        let (bytes, version) = {
            let journal = journal.lock().expect("journal lock");
            if journal.version == written {
                return written;
            }
            (journal.encode(), journal.version)
        };
        if dir.is_dir() {
            let _ = write_atomic(&dir.join("journal"), &bytes);
        }
        version
    }

    fn spawn_anchor() -> Result<(i32, OwnedFd), String> {
        use std::os::unix::process::CommandExt;
        let exe =
            std::env::current_exe().map_err(|error| format!("helper path failed: {error}"))?;
        let parent = std::process::id() as i32;
        let mut command = Command::new(exe);
        // SAFETY: `guard_anchor` is async-signal-safe.
        unsafe { command.pre_exec(move || guard_anchor(parent)) };
        let child = command
            .arg("plugin-proc-anchor")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .map_err(|error| format!("anchor spawn failed: {error}"))?;
        let pid = child.id() as i32;
        let fd = pidfd_open(pid).ok_or("anchor pidfd failed")?;
        Ok((pid, fd))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn journal_with(keep_tail: bool, limit: usize, writes: &[(u8, &str)]) -> Journal {
        let mut journal = Journal::new(keep_tail, limit);
        for (stream, data) in writes {
            journal.append(*stream, data.as_bytes());
        }
        journal
    }

    fn text(chunks: &[Chunk]) -> Vec<(u8, String)> {
        chunks
            .iter()
            .map(|chunk| {
                (
                    chunk.stream,
                    String::from_utf8_lossy(&chunk.data).into_owned(),
                )
            })
            .collect()
    }

    #[test]
    fn a_run_keeps_the_head_and_marks_the_rest_dropped() {
        let journal = journal_with(false, 6, &[(0, "abcd"), (1, "efgh"), (0, "ij")]);
        assert_eq!(
            text(&journal.replay(0)),
            [(0, "abcd".into()), (1, "ef".into())]
        );
        assert!(journal.truncated);
        assert_eq!((journal.base(), journal.end), (0, 6));
    }

    #[test]
    fn replay_after_truncation_resumes_at_the_base_in_the_original_order() {
        let journal = journal_with(true, 6, &[(0, "aaaa"), (1, "bb"), (0, "cc"), (1, "dd")]);
        // 10 bytes written, the latest 6 kept: "bb" "cc" "dd" with "aaaa" gone.
        assert_eq!(journal.base(), 4);
        assert_eq!(journal.end, 10);
        let replay = journal.replay(1);
        assert_eq!(
            text(&replay),
            [(1, "bb".into()), (0, "cc".into()), (1, "dd".into())]
        );
        assert_eq!(
            replay.iter().map(|chunk| chunk.seq).collect::<Vec<_>>(),
            [1, 2, 3]
        );
        // A reader in the middle of a chunk resumes inside it.
        assert_eq!(
            text(&journal.replay(7)),
            [(0, "c".into()), (1, "dd".into())]
        );
        assert!(journal.replay(10).is_empty());
        // Cut mid-chunk, the base moves inside it.
        let cut = journal_with(true, 3, &[(0, "aaaa"), (1, "bb")]);
        assert_eq!(
            (cut.base(), text(&cut.replay(0))),
            (3, vec![(0, "a".into()), (1, "bb".into())])
        );
    }

    #[test]
    fn the_journal_reads_back_what_was_written() {
        let journal = journal_with(true, 5, &[(0, "hello"), (1, "\0\n"), (0, "x")]);
        let decoded = Journal::decode(&journal.encode()).expect("decodes");
        assert_eq!(decoded.replay(0), journal.replay(0));
        assert_eq!((decoded.end, decoded.truncated), (journal.end, true));
        assert!(Journal::decode(&journal.encode()[..20]).is_none());
    }

    #[test]
    fn the_environment_block_survives_banners_and_newlines() {
        let mut block = b"Welcome!\nlast login: today\n".to_vec();
        block.extend_from_slice(b"__ALAS_ENV_BEGIN__PATH=/a:/b\0MULTI=one\ntwo\0EMPTY=\0");
        block.extend_from_slice(b"__ALAS_ENV_END__goodbye");
        let env = parse_env_block(&block).expect("parses");
        assert!(env.contains(&("PATH".into(), "/a:/b".into())));
        assert!(env.contains(&("MULTI".into(), "one\ntwo".into())));
        assert!(env.contains(&("EMPTY".into(), String::new())));
        assert!(parse_env_block(b"no sentinels").is_none());
    }

    #[cfg(unix)]
    #[test]
    fn the_login_environment_survives_a_noisy_profile() {
        let home = std::env::temp_dir().join(format!("alas-pproc-home-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join(".profile"),
            "echo 'Welcome to the devbox'\nprintf 'no newline at the end'\nexport ALAS_TEST_MULTI='one\ntwo'\nexport PATH=\"/opt/alas-test/bin:$PATH\"\n",
        )
        .unwrap();
        let env = capture_login_env(Path::new("/bin/sh"), &home).expect("captures");
        let _ = std::fs::remove_dir_all(&home);
        let get = |key: &str| env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
        assert_eq!(get("ALAS_TEST_MULTI").as_deref(), Some("one\ntwo"));
        assert!(get("PATH").is_some_and(|path| path.starts_with("/opt/alas-test/bin:")));
        // Alas's own variables are not the user's.
        assert!(
            scrub_env(env)
                .iter()
                .all(|(key, _)| !key.starts_with("ALAS_"))
        );
    }

    #[cfg(unix)]
    #[test]
    fn executables_resolve_like_the_local_launcher() {
        let root = std::env::temp_dir().join(format!("alas-pproc-resolve-{}", std::process::id()));
        let bin = root.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        for name in ["tool", "local"] {
            std::fs::write(bin.join(name), "#!/bin/sh\n").unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(bin.join(name), std::fs::Permissions::from_mode(0o755))
                .unwrap();
        }
        std::fs::write(bin.join("plain"), "").unwrap();
        let path = format!("/nonexistent:{}", bin.display());
        assert_eq!(
            resolve_executable("tool", Path::new("/"), &path),
            Some(bin.join("tool"))
        );
        assert_eq!(
            resolve_executable("./bin/local", &root, ""),
            Some(root.join("./bin/local"))
        );
        let absolute = bin.join("tool").display().to_string();
        assert_eq!(
            resolve_executable(&absolute, Path::new("/"), ""),
            Some(bin.join("tool"))
        );
        assert_eq!(resolve_executable("plain", Path::new("/"), &path), None);
        assert_eq!(resolve_executable("missing", Path::new("/"), &path), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_hosts_refuse_plugin_processes_with_the_reason() {
        let error = spawn(Some(json!({
            "procId": "p1", "lease": "l", "argv": ["true"], "cwd": "/", "outputLimit": 10
        })))
        .expect_err("refused");
        assert_eq!(error.code, -32003);
        assert!(error.message.contains("macOS"), "{}", error.message);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn stat_parses_names_with_spaces_and_parentheses() {
        let line = "42 (a b) c)) S 7 42 42 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 98765 0 0";
        assert_eq!(
            linux::parse_stat(line),
            Some(linux::Stat {
                ppid: 7,
                pgrp: 42,
                start: 98765,
                dead: false
            })
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_pid_whose_identity_changed_is_never_signalled() {
        let mut child = Command::new("sleep").arg("30").spawn().unwrap();
        let pid = child.id() as i32;
        let start = linux::stat(pid).unwrap().start;
        // The sample saw another process under this pid: it is closed, not
        // signalled, and the process lives on.
        assert!(linux::open_validated(pid, start + 1).is_none());
        assert!(child.try_wait().unwrap().is_none());
        let fd = linux::open_validated(pid, start).expect("same process");
        assert!(linux::pidfd_signal(&fd, libc::SIGKILL));
        let status = child.wait().unwrap();
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(status.signal(), Some(libc::SIGKILL));
    }
}
