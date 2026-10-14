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

/// A manifest command (at most 32 entries) plus the 32 arguments a plugin may append.
/// Far beyond any declared command, and below what Linux takes for an
/// argv. Alas checks the same bounds before it asks.
const MAX_ARGS: usize = 4096;
const MAX_ARGV_BYTES: usize = 1024 * 1024;
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
/// A login environment past this is not one: the capture fails and the
/// helper's own is used.
const MAX_LOGIN_ENV_BYTES: usize = 1024 * 1024;
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
        platform::supported().err()
    }
    #[cfg(not(target_os = "linux"))]
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
    if !argv_valid(&params.argv) {
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
    // A retry joins its claim before the launch is checked again: the run it
    // started may since have moved its worktree or its executable.
    if let Some(existing) = owned_dir(&params.proc_id, &params.lease)? {
        if let Some(joined) = join_claim(&existing, &params.proc_id)? {
            return Ok(joined);
        }
    }
    let cwd = std::fs::canonicalize(&params.cwd)
        .ok()
        .filter(|path| path.is_dir())
        .ok_or_else(|| jsonrpc_error(-32003, format!("worktree {} does not exist", params.cwd)))?;

    let env = login_env();
    let path = env
        .iter()
        .find(|(key, _)| key == "PATH")
        .map(|(_, value)| value.as_str());
    let executable = resolve_executable(&params.argv[0], &cwd, path.unwrap_or(""))
        .ok_or_else(|| jsonrpc_error(-32003, format!("command not found: {}", params.argv[0])))?;

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
    let root = root_dir()?;
    create_private_dir_all(&root)?;
    let dir = root.join(&params.proc_id);
    // The claim is built aside and published with one rename, so it is never
    // seen without its owner or its launcher's identity. A dot keeps the
    // temporary name out of the process id space.
    // ponytail: a helper that dies while building leaves a `.claim-*`
    // behind; sweep old ones if they ever pile up.
    let launcher = process_identity(std::process::id() as i32)
        .ok_or_else(|| jsonrpc_error(-32050, "helper identity unavailable"))?;
    let temp = root.join(format!(".claim-{}-{}", params.proc_id, now_ms()));
    let built = (|| {
        create_private_dir_all(&temp)?;
        write_atomic(&temp.join("owner"), params.lease.as_bytes())?;
        write_atomic(&temp.join("launching"), launcher.as_bytes())?;
        write_lease(&temp, params.lease_ms)?;
        write_atomic(
            &temp.join("launch.json"),
            &serde_json::to_vec(&launch).expect("launch serializes"),
        )
    })();
    if let Err(error) = built {
        let _ = std::fs::remove_dir_all(&temp);
        return Err(error);
    }
    let published = publish_claim(&temp, &dir, &params.proc_id, &params.lease);
    if !matches!(published, Ok(None)) {
        let _ = std::fs::remove_dir_all(&temp);
        return published.map(|joined| joined.expect("an earlier claim's answer"));
    }
    // A retry never removes a claim whose launcher lives, so this one is ours
    // until the supervisor starts; checked all the same before launching.
    let ours =
        std::fs::read_to_string(dir.join("launching")).is_ok_and(|record| record == launcher);
    let result = if ours {
        start_supervisor(&dir)
    } else {
        Err(jsonrpc_error(-32050, "the process claim was taken over"))
    };
    if let Err(error) = result {
        if ours {
            let _ = std::fs::remove_dir_all(&dir);
        }
        return Err(error);
    }
    Ok(json!({ "procId": params.proc_id, "spawned": true }))
}

/// Publishes the claim built in `temp` as `dir`. `Ok(None)` once it is
/// published; the answer to give instead when an earlier claim of this lease
/// started, or still may start, the process. A claim nothing will start is
/// removed and replaced.
fn publish_claim(
    temp: &Path,
    dir: &Path,
    proc_id: &str,
    lease: &str,
) -> Result<Option<Value>, HelperError> {
    for _ in 0..3 {
        match owned_dir(proc_id, lease)? {
            Some(existing) => {
                if let Some(joined) = join_claim(&existing, proc_id)? {
                    return Ok(Some(joined));
                }
                remove_claim(&existing)?;
            }
            // Ownerless: left by a helper from before claims were published
            // whole.
            None if dir.exists() => remove_claim(dir)?,
            None => {}
        }
        match std::fs::rename(temp, dir) {
            Ok(()) => return Ok(None),
            // Another spawn published first; look at its claim again.
            Err(_) if dir.exists() => {}
            Err(error) => {
                return Err(jsonrpc_error(
                    -32050,
                    format!("process claim failed: {error}"),
                ));
            }
        }
    }
    Err(jsonrpc_error(
        -32050,
        "another spawn of this process is still starting",
    ))
}

fn remove_claim(dir: &Path) -> Result<(), HelperError> {
    match std::fs::remove_dir_all(dir) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(jsonrpc_error(
            -32050,
            format!("stale process cleanup failed: {error}"),
        )),
        _ => Ok(()),
    }
}

/// `pid` with its start time, so a reused pid never matches it.
fn process_identity(pid: i32) -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        platform::stat(pid).map(|stat| format!("{pid} {}", stat.start))
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = pid;
        None
    }
}

/// Whether the process a `pid start` record names still runs; a bare `pid`
/// only says that some process has it.
fn identity_alive(record: &str) -> bool {
    let mut fields = record.split_whitespace().map(str::parse::<u64>);
    let Some(Ok(pid)) = fields.next() else {
        return false;
    };
    match fields.next() {
        #[cfg(target_os = "linux")]
        Some(Ok(start)) => {
            platform::stat(pid as i32).is_some_and(|stat| stat.start == start && !stat.dead)
        }
        #[cfg(not(target_os = "linux"))]
        Some(Ok(_)) => false,
        Some(Err(_)) => false,
        // SAFETY: signal 0 only checks that the pid exists.
        None => (unsafe { libc::kill(pid as i32, 0) }) == 0,
    }
}

/// A program name, at most `MAX_ARGS` entries of at most `MAX_ARGV_BYTES`
/// together, each counted with its terminating NUL, and none holding one.
fn argv_valid(argv: &[String]) -> bool {
    argv.first().is_some_and(|name| !name.is_empty())
        && argv.len() <= MAX_ARGS
        && argv.iter().map(|arg| arg.len() + 1).sum::<usize>() <= MAX_ARGV_BYTES
        && !argv.iter().any(|arg| arg.contains('\0'))
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
    // Provisional and pid-only, in a file of its own: the supervisor writes its full identity to `supervisor`, and
    // a late write here must never replace it.
    let _ = write_atomic(
        &dir.join("supervisor.launch"),
        supervisor.id().to_string().as_bytes(),
    );
    thread::spawn(move || {
        let _ = supervisor.wait();
    });
    if await_start(dir)? {
        return Ok(());
    }
    let _ = std::fs::write(dir.join("stop"), b"");
    Err(jsonrpc_error(
        -32050,
        "supervisor did not start the process",
    ))
}

/// A retried spawn's answer when an earlier one owns the claim: it went
/// through if it started the process, whose end `settled_exit` records if its
/// supervisor is gone, or still may if its supervisor lives. Not run twice.
/// None when nothing started it and nothing will.
fn join_claim(dir: &Path, proc_id: &str) -> Result<Option<Value>, HelperError> {
    if dir.join("started").is_file() || read_exit(dir).is_some() {
        settled_exit(dir);
        return Ok(Some(json!({ "procId": proc_id, "spawned": false })));
    }
    let launching =
        std::fs::read_to_string(dir.join("launching")).is_ok_and(|record| identity_alive(&record));
    if supervisor_alive(dir) || launching {
        if await_start(dir)? {
            return Ok(Some(json!({ "procId": proc_id, "spawned": false })));
        }
        // ponytail: a launcher alive but stalled past the start deadline is
        // refused rather than raced; the retry can come again.
        if launching {
            return Err(jsonrpc_error(
                -32050,
                "another spawn of this process is still starting",
            ));
        }
    }
    Ok(None)
}

/// True once the supervisor started the process, false when it hasn't in
/// time; its refusal when it couldn't.
fn await_start(dir: &Path) -> Result<bool, HelperError> {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if dir.join("started").is_file() {
            return Ok(true);
        }
        if let Ok(message) = std::fs::read_to_string(dir.join("error")) {
            return Err(jsonrpc_error(-32003, message));
        }
        thread::sleep(Duration::from_millis(10));
    }
    Ok(false)
}

/// Whether the supervisor recorded for `dir` still runs. It records its pid
/// with its start time, so a reused pid doesn't pass; until it does, and only
/// before the run started, the helper's provisional pid-only record covers
/// its first moments.
fn supervisor_alive(dir: &Path) -> bool {
    let record = match std::fs::read_to_string(dir.join("supervisor")) {
        Ok(record) => record,
        Err(_) if !dir.join("started").exists() => {
            match std::fs::read_to_string(dir.join("supervisor.launch")) {
                Ok(record) => record,
                Err(_) => return false,
            }
        }
        Err(_) => return false,
    };
    identity_alive(&record)
}

/// The run's exit; for a started run whose supervisor is gone, which nothing
/// will ever end, a recorded -1, so no caller waits for it forever.
fn settled_exit(dir: &Path) -> Option<ExitRecord> {
    if let Some(exit) = read_exit(dir) {
        return Some(exit);
    }
    if !dir.join("started").is_file() || supervisor_alive(dir) {
        return None;
    }
    // The supervisor may have written its exit just before it left.
    if let Some(exit) = read_exit(dir) {
        return Some(exit);
    }
    let record = ExitRecord {
        exit: -1,
        timed_out: false,
    };
    let _ = write_atomic(
        &dir.join("exit.json"),
        &serde_json::to_vec(&record).expect("exit serializes"),
    );
    Some(record)
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
    let exit = settled_exit(&dir);
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
        let path = dir.join("journal");
        let mut journal = Journal::default();
        let mut seen = None;
        loop {
            // Read the exit first: a journal read after it holds everything.
            let exit = settled_exit(&dir);
            // The supervisor replaces the file on every change, so an
            // unchanged one is not decoded again.
            let stamp = journal_stamp(&path);
            if stamp != seen {
                seen = stamp;
                journal = Journal::read(&path);
            }
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

/// Identifies one version of the journal file: the supervisor writes a new
/// file and renames it over the old one.
fn journal_stamp(path: &Path) -> Option<(u64, u64, SystemTime)> {
    use std::os::unix::fs::MetadataExt;
    let meta = std::fs::metadata(path).ok()?;
    Some((meta.ino(), meta.len(), meta.modified().ok()?))
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
        // Moved aside first, in one step: the supervisor may still be writing
        // into it, and a removal racing its writes would fail half done.
        let trash = dir.with_file_name(format!(".released-{}-{}", params.proc_id, now_ms()));
        std::fs::rename(&dir, &trash)
            .map_err(|error| jsonrpc_error(-32050, format!("release failed: {error}")))?;
        for _ in 0..3 {
            if remove_claim(&trash).is_ok() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
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

/// Milliseconds on a clock wall-clock changes don't move, shared by every
/// process on the host: the helper writes a lease and the supervisor checks it.
/// `CLOCK_BOOTTIME` on Linux also counts suspended time, so a lease still lapses
/// across a suspend.
fn lease_clock_ms() -> u64 {
    #[cfg(target_os = "linux")]
    let clock = libc::CLOCK_BOOTTIME;
    #[cfg(not(target_os = "linux"))]
    let clock = libc::CLOCK_MONOTONIC;
    let mut now: libc::timespec = unsafe { std::mem::zeroed() };
    // SAFETY: plain clock read into a local.
    if unsafe { libc::clock_gettime(clock, &mut now) } != 0 {
        return 0;
    }
    now.tv_sec as u64 * 1000 + now.tv_nsec as u64 / 1_000_000
}

fn write_lease(dir: &Path, lease_ms: Option<u64>) -> Result<(), HelperError> {
    let until = lease_clock_ms() + lease_ms.unwrap_or(DEFAULT_LEASE_MS).clamp(1, MAX_LEASE_MS);
    write_atomic(&dir.join("lease-until"), until.to_string().as_bytes())
}

/// A lease file that can't be read counts as lapsed: nobody can renew it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn lease_lapsed(dir: &Path) -> bool {
    std::fs::read_to_string(dir.join("lease-until"))
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .is_none_or(|until| lease_clock_ms() > until)
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
    // A temporary name of its own per writer: `supervisor` and
    // `supervisor.launch` once shared `supervisor.tmp`, and the helper and the
    // supervisor write files in one directory at the same time.
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("file");
    let temp = path.with_file_name(format!(
        ".{name}.{}.{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let fail = |error: std::io::Error| jsonrpc_error(-32050, format!("write failed: {error}"));
    let written = options
        .open(&temp)
        .and_then(|mut file| file.write_all(bytes))
        .and_then(|()| std::fs::rename(&temp, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written.map_err(fail)
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
        use std::os::unix::ffi::OsStrExt;
        // Executable by this user, not merely by someone: a root-only 0700 file earlier on PATH is skipped.
        std::fs::metadata(path).is_ok_and(|meta| meta.is_file())
            && std::ffi::CString::new(path.as_os_str().as_bytes())
                .is_ok_and(|c| unsafe { libc::access(c.as_ptr(), libc::X_OK) } == 0)
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
    use std::os::fd::AsRawFd;
    use std::os::unix::process::CommandExt;
    let script = format!("printf '%s' '{ENV_BEGIN}'; env -0; printf '%s' '{ENV_END}'");
    // Its own group, so whatever a startup file leaves running, holding the
    // pipe open, goes with it.
    let mut child = Command::new(shell)
        .args(["-l", "-c", &script])
        .current_dir(home)
        .env("HOME", home)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let fd = stdout.as_raw_fd();
    // SAFETY: fcntl on a pipe we own; reads below then never block.
    unsafe {
        libc::fcntl(
            fd,
            libc::F_SETFL,
            libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK,
        )
    };
    let pid = child.id() as i32;
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 64 * 1024];
    let mut deadline = Instant::now() + Duration::from_secs(10);
    let mut exited = false;
    let mut eof = false;
    let captured = loop {
        if Instant::now() >= deadline {
            break false;
        }
        if !exited && shell_exited(pid) {
            exited = true;
            // What it left holding the pipe goes; what's written is read for
            // at most another second.
            // SAFETY: plain kill of the group the unreaped shell still leads.
            unsafe { libc::kill(-pid, libc::SIGKILL) };
            deadline = deadline.min(Instant::now() + Duration::from_secs(1));
        }
        if exited && eof {
            break true;
        }
        if eof {
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        let mut poll = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: poll on one valid pollfd.
        if unsafe { libc::poll(&mut poll, 1, 10) } <= 0 {
            continue;
        }
        match stdout.read(&mut buffer) {
            Ok(0) => eof = true,
            Ok(read) => {
                bytes.extend_from_slice(&buffer[..read]);
                if bytes.len() > MAX_LOGIN_ENV_BYTES {
                    break false;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) => {}
            Err(_) => break false,
        }
    };
    // Closing the read end stops any writer that is left.
    drop(stdout);
    // SAFETY: plain kill of the group the unreaped shell still leads.
    unsafe { libc::kill(-pid, libc::SIGKILL) };
    let _ = child.wait();
    if captured {
        parse_env_block(&bytes)
    } else {
        None
    }
}

/// Whether the shell exited, without reaping it: until it is reaped, its pid,
/// and so its group id, stays ours.
fn shell_exited(pid: i32) -> bool {
    // SAFETY: zeroed siginfo is a valid out value.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    // SAFETY: waitid with a valid out pointer, on our own child.
    let waited = unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            &mut info,
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };
    // SAFETY: reading the pid field waitid filled in, zero when nothing exited.
    waited != 0 || unsafe { info.si_pid() } == pid
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
        supervisor::supervise(PathBuf::from(dir));
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
pub(crate) fn anchor_main(parent: Option<String>) -> ! {
    #[cfg(target_os = "linux")]
    if let Some(parent) = parent.and_then(|parent| parent.parse().ok()) {
        platform::anchor(parent);
    }
    #[cfg(not(target_os = "linux"))]
    let _ = parent;
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
#[path = "plugin_proc/linux.rs"]
mod platform;
#[cfg(target_os = "linux")]
mod supervisor;

/// A process as the supervisor sees it: enough to walk the tree, tell a
/// reused pid from the process it was, and skip one that already ended.
#[cfg(target_os = "linux")]
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Stat {
    pub ppid: i32,
    pub pgrp: i32,
    pub start: u64,
    pub dead: bool,
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

    #[test]
    fn argv_bounds_leave_room_for_any_declared_command() {
        let args = |count: usize, size: usize| vec!["x".repeat(size); count];
        assert!(argv_valid(&args(MAX_ARGS, 1)));
        assert!(!argv_valid(&args(MAX_ARGS + 1, 1)));
        // Each entry counts with its NUL: 1024 entries of 1023 bytes fill it.
        assert!(argv_valid(&args(1024, 1023)));
        assert!(!argv_valid(&args(1024, 1024)));
        assert!(!argv_valid(&["".into()]));
        assert!(!argv_valid(&["ls".into(), "a\0b".into()]));
    }

    #[test]
    fn a_profile_that_floods_stdout_falls_back_promptly() {
        let home = std::env::temp_dir().join(format!("alas-pproc-yes-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join(".profile"), "yes\n").unwrap();
        let started = Instant::now();
        let env = capture_login_env(Path::new("/bin/sh"), &home);
        let _ = std::fs::remove_dir_all(&home);
        assert!(env.is_none());
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "{:?}",
            started.elapsed()
        );
    }

    #[test]
    fn a_profile_that_leaves_a_process_holding_stdout_does_not_hold_the_capture() {
        let home = std::env::temp_dir().join(format!("alas-pproc-bg-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join(".profile"),
            "sleep 300 &\nexport ALAS_TEST_BG=yes\n",
        )
        .unwrap();
        let started = Instant::now();
        let env = capture_login_env(Path::new("/bin/sh"), &home).expect("captures");
        let _ = std::fs::remove_dir_all(&home);
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "{:?}",
            started.elapsed()
        );
        assert!(env.contains(&("ALAS_TEST_BG".into(), "yes".into())));
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
        // An execute bit for someone else (group only) doesn't make it ours: the later candidate wins. Root may
        // execute anything with an execute bit, so this only holds for an ordinary user.
        if unsafe { libc::geteuid() } != 0 {
            let other = root.join("other");
            std::fs::create_dir_all(&other).unwrap();
            std::fs::write(other.join("tool"), "#!/bin/sh\n").unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(other.join("tool"), std::fs::Permissions::from_mode(0o010))
                .unwrap();
            let path = format!("{}:{}", other.display(), bin.display());
            assert_eq!(
                resolve_executable("tool", Path::new("/"), &path),
                Some(bin.join("tool"))
            );
        }
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
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn stat_parses_names_with_spaces_and_parentheses() {
        let line = "42 (a b) c)) S 7 42 42 0 -1 4194560 1 0 0 0 0 0 0 0 20 0 1 0 98765 0 0";
        assert_eq!(
            platform::parse_stat(line),
            Some(Stat {
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
        let start = platform::stat(pid).unwrap().start;
        // The sample saw another process under this pid: it is closed, not
        // signalled, and the process lives on.
        assert!(platform::open_validated(pid, start + 1).is_none());
        assert!(child.try_wait().unwrap().is_none());
        let fd = platform::open_validated(pid, start).expect("same process");
        assert!(platform::signal(&fd, libc::SIGKILL));
        let status = child.wait().unwrap();
        use std::os::unix::process::ExitStatusExt;
        assert_eq!(status.signal(), Some(libc::SIGKILL));
    }
}
