use crate::acp_broker::{
    ACPBrokerMetadata, ACPBrokerSnapshot, ACPBrokerState, AdapterRPCOutcome, BrokerGeneration,
    BrokerId, BrokerTurnState, JSONRPCErrorObject, OperationKey, PendingClientRequestKind,
};
use crate::acp_broker_protocol::{
    AcpAckParams, AcpAttachParams, AcpCloseParams, AcpDetachParams, AcpNotifyParams, AcpOpenParams,
    AcpOpenResult, AcpRespondParams, AcpSendParams,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};

/// How long the supervisor waits on a silent caller before giving up on the
/// first line of a request.
///
/// Idle, not total, and that is forced by the legacy encoding: under framing
/// this line is a short header, but a legacy caller sends the whole message
/// here — and an older helper serializes *after* connecting, so it can
/// legitimately say nothing at all for the ~7.4s a maximal image prompt takes
/// to encode. A total budget would drop that request, breaking the very
/// callers the legacy path exists to keep working.
///
/// Shorter than `BROKER_IPC_IDLE_TIMEOUT` because it is the one bound a caller
/// can hold without having promised anything yet; past this line a framed
/// caller has declared a length and is held to it instead.
const IPC_REQUEST_IDLE_TIMEOUT: Duration = Duration::from_secs(60);

/// Rate a caller must sustain on the first line once it starts sending.
///
/// A fixed duration cannot work here. Under the legacy encoding this line is
/// the whole message, and a legacy request is not bounded in size — an
/// `acp/respond` carries whatever `fs/read_text_file` was asked for, and
/// `ACPSessionRunner.serveRead` returns a whole file when the adapter sends no
/// line/limit. Any ceiling on elapsed time is therefore a ceiling on size.
/// Requiring a rate instead tells a large transfer apart from a trickle
/// without needing to know how large: this is ~1% of what the socket
/// measures, so a genuine sender clears it easily, while one byte every 59s
/// does not — and since every connection owns a thread, that pattern would
/// otherwise accumulate threads until the broker cannot spawn any more.
const MIN_IPC_REQUEST_RATE: u64 = 16 * 1024;

/// Bounds on the first line of a request: silence, and sustained rate.
#[cfg(unix)]
const IPC_REQUEST_HEAD_BUDGET: ReadBudget =
    ReadBudget::at_least(IPC_REQUEST_IDLE_TIMEOUT, MIN_IPC_REQUEST_RATE);

/// Slowest a caller may deliver a framed body before we stop waiting.
///
/// An idle budget alone is not enough once a length is known: a caller can
/// advertise an enormous frame and dribble it, renewing the budget forever
/// while the buffer grows. Holding it to a rate turns the promise into a
/// deadline — and the floor is generous, since this socket measures ~1.3 GB/s,
/// so a legitimate transfer clears it by two orders of magnitude.
const MIN_IPC_BODY_THROUGHPUT: u64 = 10 * 1024 * 1024;

/// Budget for a framed body from a broker this helper spawned.
///
/// Progress only. A reply's size is not something we can turn into a deadline,
/// and the exposure differs in kind from an inbound request: one thread per
/// outstanding request, bounded by how many sessions exist rather than by
/// anything the peer chooses.
#[cfg(unix)]
fn trusted_body_budget(_len: usize) -> ReadBudget {
    ReadBudget::idle(BROKER_IPC_IDLE_TIMEOUT)
}

/// Budget for a framed body of `len` bytes arriving from an arbitrary peer.
///
/// The total scales with the length the caller declared — never below the
/// ordinary idle budget, so a small body is not held to a stricter rule than a
/// large one. The idle bound is kept alongside it and does not scale: a caller
/// that declares 1 TiB and then says nothing would otherwise have bought
/// itself about 29 hours of silence, and a thread to spend it in.
#[cfg(unix)]
fn framed_body_budget(len: usize) -> ReadBudget {
    let by_rate = Duration::from_secs_f64(len as f64 / MIN_IPC_BODY_THROUGHPUT as f64);
    ReadBudget::within(
        BROKER_IPC_IDLE_TIMEOUT,
        by_rate.max(BROKER_IPC_IDLE_TIMEOUT),
    )
}

/// How long a caller gives a broker to send *something* before treating it as
/// wedged. Idle rather than total, because a legitimate reply has no size we
/// can predict and therefore no duration we can predict either; a total budget
/// would have to out-guess that, while an idle one only has to notice a broker
/// that has stopped.
///
/// Generous, because nothing waits behind it any more. `acp/*` runs on its own
/// thread (see `AcpJob`) and same-broker calls serialize on `broker_lock`, so
/// this bounds one session's call rather than the whole helper. Erring long is
/// the right way round: too short fails a healthy broker and, because
/// `ACPBrokerClient` drops the error, can leave an adapter waiting forever —
/// too long merely delays reporting a broker that is genuinely stuck.
const BROKER_IPC_IDLE_TIMEOUT: Duration = Duration::from_secs(120);

/// How long a single write to a broker may block. Writing even a maximal
/// request measures ~0.2s, so this only ever fires on a broker that has
/// stopped reading.
const BROKER_IPC_WRITE_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug)]
pub struct AcpBrokerProcessError {
    pub code: i64,
    pub message: String,
}

impl AcpBrokerProcessError {
    fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrokerLaunch {
    broker_id: BrokerId,
    session_id: String,
    command: String,
    args: Vec<String>,
    cwd: String,
    env: HashMap<String, String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrokerPidMetadata {
    pid: u32,
    process_group_id: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct BrokerIpcRequest {
    method: String,
    params: Option<Value>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct BrokerIpcResponse {
    ok: bool,
    result: Option<Value>,
    error: Option<String>,
}

#[derive(Clone)]
struct Runtime {
    state: Arc<(Mutex<RuntimeState>, Condvar)>,
    adapter_stdin: Arc<Mutex<std::process::ChildStdin>>,
}

struct RuntimeState {
    broker: ACPBrokerState,
    pending_methods: HashMap<u64, PendingOperation>,
    adapter_process_group_id: Option<u32>,
    adapter_exited: bool,
    closing: bool,
}

#[derive(Clone, Debug)]
struct PendingOperation {
    operation_key: OperationKey,
    method: String,
}

/// Serializes requests per broker.
///
/// These now run on worker threads rather than the helper's serve loop, which
/// is the point — one slow broker must not hold up the others. Within a single
/// broker, though, concurrency is not safe: two `acp/open` calls racing would
/// both find no live supervisor and both spawn one, and the rest mutate broker
/// state that was written assuming one caller at a time. Holding a per-broker
/// lock keeps exactly the ordering the single-threaded loop used to provide,
/// while letting different brokers proceed at once.
fn broker_lock(broker_id: &str) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();
    let locks = LOCKS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut locks = locks.lock().unwrap_or_else(|error| error.into_inner());
    Arc::clone(
        locks
            .entry(broker_id.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(()))),
    )
}

fn with_broker_lock<T>(params: Option<&Value>, body: impl FnOnce() -> T) -> T {
    let broker_id = params
        .and_then(|params| params.get("brokerId"))
        .and_then(Value::as_str);
    match broker_id {
        Some(broker_id) => {
            let lock = broker_lock(broker_id);
            let _guard = lock.lock().unwrap_or_else(|error| error.into_inner());
            body()
        }
        // `acp/list` names no broker: it sweeps every one of them, so there is
        // no single lock to take, and it only reads.
        None => body(),
    }
}

pub fn handle_control_request(
    method: &str,
    params: Option<Value>,
) -> Result<Value, AcpBrokerProcessError> {
    with_broker_lock(params.as_ref(), || {
        dispatch_control_request(method, params.clone())
    })
}

fn dispatch_control_request(
    method: &str,
    params: Option<Value>,
) -> Result<Value, AcpBrokerProcessError> {
    match method {
        "acp/open" => acp_open(params),
        "acp/attach" => acp_attach(params),
        "acp/send" => acp_send(params),
        "acp/notify" => acp_notify(params),
        "acp/respond" => acp_respond(params),
        "acp/ack" => acp_ack(params),
        "acp/detach" => acp_detach(params),
        "acp/close" => acp_close(params),
        "acp/list" => acp_list(),
        _ => Err(AcpBrokerProcessError::new(
            -32601,
            format!("method not found: {method}"),
        )),
    }
}

pub fn run_broker_supervisor(dir: PathBuf) -> Result<(), AcpBrokerProcessError> {
    let result = run_broker_supervisor_inner(dir.clone());
    if let Err(error) = &result {
        let _ = write_restrictive_bytes(&dir.join("startup-error"), error.message.as_bytes());
    }
    result
}

fn run_broker_supervisor_inner(dir: PathBuf) -> Result<(), AcpBrokerProcessError> {
    let launch_path = dir.join("launch.json");
    let launch: BrokerLaunch = serde_json::from_slice(
        &std::fs::read(&launch_path)
            .map_err(|error| broker_error(-32070, format!("launch read failed: {error}")))?,
    )
    .map_err(|error| broker_error(-32070, format!("launch decode failed: {error}")))?;
    let _ = std::fs::remove_file(&launch_path);

    let metadata = ACPBrokerMetadata {
        broker_id: launch.broker_id.clone(),
        generation: BrokerGeneration::new(current_nanos()),
        alas_session_id: launch.session_id.clone(),
        adapter_program: launch.command.clone(),
        adapter_args: launch.args.clone(),
        cwd: launch.cwd.clone(),
        env_keys: sorted_env_keys(&launch.env),
        created_at_millis: current_millis(),
    };
    write_restrictive_json(&dir.join("metadata.json"), &metadata)?;
    write_broker_pid(&dir)?;

    let mut command = Command::new(&launch.command);
    command
        .args(&launch.args)
        .current_dir(&launch.cwd)
        .env_clear()
        .envs(&launch.env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .spawn()
        .map_err(|error| broker_error(-32071, format!("adapter spawn failed: {error}")))?;
    let adapter_stdin = child
        .stdin
        .take()
        .ok_or_else(|| broker_error(-32071, "adapter stdin unavailable"))?;
    let adapter_stdout = child
        .stdout
        .take()
        .ok_or_else(|| broker_error(-32071, "adapter stdout unavailable"))?;
    let adapter_stderr = child
        .stderr
        .take()
        .ok_or_else(|| broker_error(-32071, "adapter stderr unavailable"))?;
    let adapter_process_group_id = adapter_process_group_id(&child);

    let runtime = Runtime {
        state: Arc::new((
            Mutex::new(RuntimeState {
                broker: ACPBrokerState::new(metadata),
                pending_methods: HashMap::new(),
                adapter_process_group_id,
                adapter_exited: false,
                closing: false,
            }),
            Condvar::new(),
        )),
        adapter_stdin: Arc::new(Mutex::new(adapter_stdin)),
    };

    spawn_stdout_reader(runtime.clone(), adapter_stdout);
    spawn_stderr_reader(runtime.clone(), adapter_stderr);
    spawn_waiter(runtime.clone(), child);
    serve_broker_ipc(runtime, dir)
}

fn acp_open(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpOpenParams = decode(params)?;
    validate_broker_id(params.broker_id.as_str())?;
    let dir = broker_dir(params.broker_id.as_str())?;
    std::fs::create_dir_all(&dir)
        .map_err(|error| broker_error(-32070, format!("broker dir failed: {error}")))?;
    set_restrictive_dir_permissions(&dir)?;

    if broker_is_running(&dir) {
        match send_ipc_with_retry(&dir, "snapshot", json!({}), Duration::from_secs(2)) {
            Ok(result) => {
                let snapshot: ACPBrokerSnapshot =
                    serde_json::from_value(result.clone()).map_err(|error| {
                        broker_error(-32072, format!("snapshot decode failed: {error}"))
                    })?;
                if result
                    .get("adapterExited")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                {
                    let _ = send_ipc(
                        &dir,
                        "close",
                        json!({
                            "brokerId": params.broker_id.clone(),
                            "generation": snapshot.metadata.generation
                        }),
                    );
                    // The supervisor is alive but its adapter is gone. Close
                    // that generation and fall through to spawn a replacement.
                } else {
                    return Ok(json!(AcpOpenResult {
                        snapshot,
                        adopted: true,
                    }));
                }
            }
            Err(error) if broker_is_running(&dir) => {
                return Err(error);
            }
            Err(_) => {
                // The pid disappeared while we were waiting for its socket.
                // It is now safe to remove stale startup files and spawn a replacement.
            }
        }
    }

    let env = decode_env(params.env)?;
    let launch = BrokerLaunch {
        broker_id: params.broker_id,
        session_id: params.session_id,
        command: params.command,
        args: params.args,
        cwd: params.cwd,
        env,
    };
    remove_transient_startup_files(&dir);
    write_restrictive_json(&dir.join("launch.json"), &launch)?;
    spawn_broker_supervisor(&dir)?;
    let snapshot = send_ipc_with_retry(&dir, "snapshot", json!({}), Duration::from_secs(2))?;
    Ok(json!(AcpOpenResult {
        snapshot: serde_json::from_value(snapshot)
            .map_err(|error| broker_error(-32072, format!("snapshot decode failed: {error}")))?,
        adopted: false,
    }))
}

fn acp_attach(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpAttachParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "attach",
        serde_json::to_value(params).expect("attach params serialize"),
    )?;
    Ok(result)
}

fn acp_send(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpSendParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "send",
        serde_json::to_value(params).expect("send params serialize"),
    )?;
    Ok(result)
}

fn acp_notify(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpNotifyParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "notify",
        serde_json::to_value(params).expect("notify params serialize"),
    )?;
    Ok(result)
}

fn acp_respond(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpRespondParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "respond",
        serde_json::to_value(params).expect("respond params serialize"),
    )?;
    Ok(result)
}

fn acp_ack(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpAckParams = decode(params)?;
    let result = send_ipc(
        &broker_dir(params.broker_id.as_str())?,
        "ack",
        serde_json::to_value(params).expect("ack params serialize"),
    )?;
    Ok(result)
}

fn acp_detach(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpDetachParams = decode(params)?;
    let _ = broker_dir(params.broker_id.as_str())?;
    Ok(json!({ "ok": true }))
}

fn acp_close(params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpCloseParams = decode(params)?;
    let dir = broker_dir(params.broker_id.as_str())?;
    if broker_is_running(&dir) {
        send_ipc(
            &dir,
            "close",
            serde_json::to_value(&params).expect("close params serialize"),
        )?;
    }
    remove_broker_dir(&dir)?;
    Ok(json!({ "ok": true }))
}

fn acp_list() -> Result<Value, AcpBrokerProcessError> {
    let root = broker_root()?;
    let mut brokers = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return Ok(json!({ "brokers": brokers }));
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() || !broker_is_running(&dir) {
            continue;
        }
        // The ordinary budget, deliberately. A shorter one was tempting here
        // — this sweeps every broker dir on disk, including leftovers from
        // earlier runs — but it silently drops healthy brokers: a snapshot
        // carrying a retained large-image prompt takes ~7.4s to serialize,
        // all of it silent, so any budget below that omits a live broker from
        // the list rather than reporting it. The cheap exclusions are already
        // handled above by `broker_is_running`, and a dead socket fails the
        // connect immediately; what is left is a broker that is live but
        // wedged, which is exactly what an idle budget is for.
        if let Ok(snapshot) = send_ipc_within(&dir, "snapshot", json!({}), BROKER_IPC_IDLE_TIMEOUT)
        {
            if snapshot
                .get("adapterExited")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                continue;
            }
            brokers.push(snapshot);
        }
    }
    Ok(json!({ "brokers": brokers }))
}

/// What is asked of a peer beyond not going silent.
#[derive(Clone, Copy)]
enum Pace {
    /// Finish within this, however fast you go. Right where the sender
    /// declared a length, since the deadline can then be derived from it.
    Within(Duration),
    /// Once you start sending, keep up at least this many bytes per second.
    /// Right where the length is *not* known — a legacy request is the whole
    /// message on one line, so there is no size to turn into a deadline, and
    /// any fixed duration would be a size ceiling in disguise. A rate tells a
    /// large transfer apart from a trickle without needing to know how large.
    AtLeast(u64),
    /// Nothing beyond the idle bound. For a broker this helper spawned: its
    /// reply has no size we could bound, and one thread per outstanding
    /// request is limited by how many sessions exist, not by the peer.
    Unbounded,
}

/// How a read is bounded in time.
///
/// An idle bound alone has a hole — a trickle satisfies it forever — so every
/// read from an arbitrary peer pairs one with a `Pace`. Which pace depends on
/// whether the sender told us how much to expect.
#[derive(Clone, Copy)]
struct ReadBudget {
    /// Longest run with no bytes arriving.
    idle: Duration,
    pace: Pace,
}

impl ReadBudget {
    /// For a peer we trust to finish what it starts.
    fn idle(idle: Duration) -> Self {
        Self {
            idle,
            pace: Pace::Unbounded,
        }
    }

    /// For a sender that declared how much it is about to send.
    fn within(idle: Duration, total: Duration) -> Self {
        Self {
            idle,
            pace: Pace::Within(total),
        }
    }

    /// For a sender whose length we cannot know.
    const fn at_least(idle: Duration, bytes_per_second: u64) -> Self {
        Self {
            idle,
            pace: Pace::AtLeast(bytes_per_second),
        }
    }
}

/// Grace before a rate is judged, so a sender is not failed on the strength of
/// its first few hundred bytes.
#[cfg(unix)]
const IPC_RATE_GRACE: Duration = Duration::from_secs(10);

/// Tracks whether a read still has time left under its bounds.
#[cfg(unix)]
struct BudgetClock {
    idle: Duration,
    pace: Pace,
    idle_deadline: std::time::Instant,
    total_deadline: Option<std::time::Instant>,
    first_byte_at: Option<std::time::Instant>,
    bytes: u64,
}

#[cfg(unix)]
impl BudgetClock {
    fn new(budget: ReadBudget) -> Self {
        let now = std::time::Instant::now();
        Self {
            idle: budget.idle,
            pace: budget.pace,
            idle_deadline: now + budget.idle,
            total_deadline: match budget.pace {
                Pace::Within(total) => Some(now + total),
                _ => None,
            },
            first_byte_at: None,
            bytes: 0,
        }
    }

    fn expired(&self) -> bool {
        let now = std::time::Instant::now();
        if now >= self.idle_deadline {
            return true;
        }
        if self.total_deadline.is_some_and(|deadline| now >= deadline) {
            return true;
        }
        let Pace::AtLeast(rate) = self.pace else {
            return false;
        };
        let Some(first_byte_at) = self.first_byte_at else {
            // Nothing sent yet, so there is no rate to judge — the idle bound
            // above is what covers a sender still preparing its request.
            return false;
        };
        let elapsed = now.duration_since(first_byte_at);
        let judged = elapsed.saturating_sub(IPC_RATE_GRACE);
        self.bytes < rate.saturating_mul(judged.as_secs())
    }

    /// `count` bytes arrived, so the idle bound starts over. Neither the total
    /// nor the required rate does: those are what a trickle cannot renew.
    fn progressed(&mut self, count: usize) {
        let now = std::time::Instant::now();
        self.idle_deadline = now + self.idle;
        self.first_byte_at.get_or_insert(now);
        self.bytes = self.bytes.saturating_add(count as u64);
    }

    fn timed_out() -> io::Error {
        io::Error::new(io::ErrorKind::TimedOut, "timed out reading IPC message")
    }
}

/// How long a blocked read waits before its budget is re-checked. Also the
/// amount by which a read may overshoot.
#[cfg(unix)]
const IPC_READ_POLL_SLICE: Duration = Duration::from_millis(500);

/// Prepares a stream for the budgeted readers below.
///
/// The socket timeout is set once, to a short slice that just wakes a blocked
/// read periodically; the budget checked on each pass is what actually bounds
/// the read. (Re-arming the socket per read would express a deadline more
/// directly, but `setsockopt` starts failing with `EINVAL` once the peer goes
/// away mid-stream, which would turn an otherwise complete read into an error.)
///
/// One reader must be shared across a whole message: `BufReader` reads ahead,
/// so building a second one to read a frame body would discard bytes the first
/// had already pulled off the socket.
#[cfg(unix)]
fn ipc_reader(stream: &UnixStream) -> io::Result<BufReader<&UnixStream>> {
    stream.set_read_timeout(Some(IPC_READ_POLL_SLICE))?;
    Ok(BufReader::new(stream))
}

/// True when an error means "nothing to read just yet" rather than a failure.
/// The budget decides when quiet has gone on too long.
#[cfg(unix)]
fn is_quiet(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
    )
}

/// Reads one newline-terminated line, bounded in time by `budget`.
///
/// `set_read_timeout` on its own would not bound it: that applies to each
/// underlying read for inactivity, while reading a line keeps issuing fresh
/// reads until it finds a newline, so a peer trickling bytes faster than the
/// timeout renews its budget indefinitely.
#[cfg(unix)]
fn read_line_within(reader: &mut BufReader<&UnixStream>, budget: ReadBudget) -> io::Result<String> {
    let mut clock = BudgetClock::new(budget);
    let mut line: Vec<u8> = Vec::new();
    loop {
        if clock.expired() {
            return Err(BudgetClock::timed_out());
        }
        let (finished, consumed) = match reader.fill_buf() {
            Ok([]) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "peer closed before completing the IPC line",
                ));
            }
            Ok(available) => match available.iter().position(|byte| *byte == b'\n') {
                Some(index) => {
                    line.extend_from_slice(&available[..=index]);
                    (true, index + 1)
                }
                None => {
                    line.extend_from_slice(available);
                    (false, available.len())
                }
            },
            Err(error) if is_quiet(&error) => continue,
            Err(error) => return Err(error),
        };
        reader.consume(consumed);
        clock.progressed(consumed);
        if finished {
            return String::from_utf8(line)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error));
        }
    }
}

/// Reads exactly `len` bytes.
///
/// Knowing the length up front is the point of framing: there is no ceiling to
/// guess and no newline to wait for, so an idle budget is enough — a peer that
/// keeps delivering is making progress no matter how much it has left to send.
#[cfg(unix)]
fn read_exact_within(
    reader: &mut BufReader<&UnixStream>,
    len: usize,
    budget: ReadBudget,
) -> io::Result<String> {
    let mut clock = BudgetClock::new(budget);
    let mut body: Vec<u8> = Vec::with_capacity(len.min(1024 * 1024));
    while body.len() < len {
        if clock.expired() {
            return Err(BudgetClock::timed_out());
        }
        let consumed = match reader.fill_buf() {
            Ok([]) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "peer closed before completing the IPC frame",
                ));
            }
            Ok(available) => {
                let take = available.len().min(len - body.len());
                body.extend_from_slice(&available[..take]);
                take
            }
            Err(error) if is_quiet(&error) => continue,
            Err(error) => return Err(error),
        };
        reader.consume(consumed);
        clock.progressed(consumed);
    }
    String::from_utf8(body).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

/// How a message is delimited on the broker socket.
///
/// `Framed` prefixes a byte count, so the reader knows the length up front and
/// needs no ceiling and no total-time budget standing in for one. `Legacy` is
/// the original newline-delimited JSON, kept because a helper can adopt a
/// broker that a previous build started and which is still speaking it.
#[cfg(unix)]
#[derive(Clone, Copy, PartialEq)]
enum Framing {
    Legacy,
    Framed,
}

/// Header introducing a framed message: this, a byte count, and a newline.
/// Chosen so it cannot be confused with the legacy encoding, which always
/// starts with `{`.
#[cfg(unix)]
const IPC_FRAME_HEADER: &str = "ALASIPC1 ";

/// Marker a supervisor writes to advertise that it understands framing.
/// Callers check for it rather than negotiating, because the answer has to
/// survive the caller restarting while the broker keeps running.
#[cfg(unix)]
const IPC_FRAMING_MARKER: &str = "framing";

/// True when the broker *currently* running in `dir` wrote the marker.
///
/// Presence alone is not enough. A supervisor from an earlier build can
/// replace one from this build in the same directory, and its cleanup does not
/// know to remove a file it has never heard of — so the marker outlives the
/// broker that meant it. Framed requests would then go to a broker that only
/// understands newlines, which rejects them, and `acp/open` will not replace it
/// because its pid is live: the session cannot be reopened at all. Recording
/// the pid the marker was written for makes it expire with its broker, since
/// any replacement writes a new `pid.json`.
#[cfg(unix)]
fn broker_supports_framing(dir: &Path) -> bool {
    let Ok(marker) = std::fs::read_to_string(dir.join(IPC_FRAMING_MARKER)) else {
        return false;
    };
    let Ok(marked_pid) = marker.trim().parse::<u32>() else {
        return false;
    };
    read_broker_pid_metadata(dir).is_some_and(|metadata| metadata.pid == marked_pid)
}

/// Reads one message, in whichever framing the peer used.
///
/// Detection is by prefix rather than by configuration so that both mixed
/// pairings work: a new caller reaching an old broker, and an old caller
/// reaching a new one.
///
/// `head` bounds the first line, which is a short framing header or — under
/// the legacy encoding — the entire message. `body_for_len` then bounds the
/// framed body, and the two callers differ on it: a request comes from an
/// arbitrary peer and is held to the length it declared, while a reply comes
/// from a broker this helper spawned and is only asked to keep making
/// progress.
#[cfg(unix)]
fn read_ipc_message(
    reader: &mut BufReader<&UnixStream>,
    head: ReadBudget,
    body_for_len: fn(usize) -> ReadBudget,
) -> io::Result<(String, Framing)> {
    let head = read_line_within(reader, head)?;
    let Some(len) = head.strip_prefix(IPC_FRAME_HEADER) else {
        return Ok((head, Framing::Legacy));
    };
    let len: usize = len.trim().parse().map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid IPC frame length: {}", len.trim()),
        )
    })?;
    let body = read_exact_within(reader, len, body_for_len(len))?;
    Ok((body, Framing::Framed))
}

#[cfg(unix)]
fn write_ipc_message(writer: &mut impl Write, body: &str, framing: Framing) -> io::Result<()> {
    if framing == Framing::Framed {
        writeln!(writer, "{IPC_FRAME_HEADER}{}", body.len())?;
    }
    writer.write_all(body.as_bytes())?;
    if framing == Framing::Legacy {
        writer.write_all(b"\n")?;
    }
    writer.flush()
}

fn serve_broker_ipc(runtime: Runtime, dir: PathBuf) -> Result<(), AcpBrokerProcessError> {
    #[cfg(unix)]
    {
        /// How long the accept loop sleeps between polls when no client is
        /// waiting. Also the longest a `close` takes to end the loop.
        const ACCEPT_POLL: Duration = Duration::from_millis(50);
        /// How long to let in-flight handlers finish after a `close`, so the
        /// caller that asked for it still receives its answer.
        const DRAIN_TIMEOUT: Duration = Duration::from_secs(5);

        let socket_path = dir.join("broker.sock");
        let _ = std::fs::remove_file(&socket_path);
        // Advertise framing before the socket exists, not after: a caller that
        // connected in between would find no marker and fall back to the
        // legacy encoding for that request. Stamped with this process's pid so
        // it cannot outlive this broker — see `broker_supports_framing`.
        write_restrictive_bytes(
            &dir.join(IPC_FRAMING_MARKER),
            format!("{}\n", std::process::id()).as_bytes(),
        )?;
        let listener = UnixListener::bind(&socket_path)
            .map_err(|error| broker_error(-32072, format!("socket bind failed: {error}")))?;
        // Non-blocking so the loop can notice `close` without waiting for
        // another connection to arrive. Handling used to run inline for
        // exactly that reason, which is what let one slow client hold up
        // everyone else.
        listener
            .set_nonblocking(true)
            .map_err(|error| broker_error(-32072, format!("socket mode failed: {error}")))?;
        write_restrictive_bytes(&dir.join("ready"), b"1\n")?;

        let inflight = Arc::new(Mutex::new(0usize));
        while !runtime_is_closing(&runtime) {
            let stream = match listener.accept() {
                Ok((stream, _)) => stream,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(ACCEPT_POLL);
                    continue;
                }
                Err(_) => continue,
            };
            // Accepted sockets do not reliably inherit the listener's mode,
            // and the readers below want a blocking socket with timeouts.
            if stream.set_nonblocking(false).is_err() {
                continue;
            }
            let request_runtime = runtime.clone();
            let request_inflight = Arc::clone(&inflight);
            *request_inflight.lock().unwrap_or_else(|e| e.into_inner()) += 1;
            std::thread::spawn(move || {
                let _ = handle_connection(request_runtime, stream);
                *request_inflight.lock().unwrap_or_else(|e| e.into_inner()) -= 1;
            });
        }

        // A `close` handler sets the closing flag before it replies, so the
        // loop can exit while that reply is still being written. Wait for it.
        let deadline = std::time::Instant::now() + DRAIN_TIMEOUT;
        while std::time::Instant::now() < deadline {
            if *inflight.lock().unwrap_or_else(|e| e.into_inner()) == 0 {
                break;
            }
            std::thread::sleep(ACCEPT_POLL);
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = runtime;
        let _ = dir;
        Err(broker_error(-32072, "ACP broker IPC requires Unix sockets"))
    }
}

/// Reads one request off an accepted connection and answers it, in whichever
/// framing the caller used. Runs on its own thread, so a caller that is slow
/// to deliver its request costs only that thread.
#[cfg(unix)]
fn handle_connection(runtime: Runtime, stream: UnixStream) -> io::Result<()> {
    // Guards against a caller that stops reading. Generous, because a reply
    // can legitimately be large and cutting one short would corrupt it rather
    // than rescue anything.
    stream.set_write_timeout(Some(BROKER_IPC_WRITE_TIMEOUT))?;
    let (line, _framing) = {
        let mut reader = ipc_reader(&stream)?;
        read_ipc_message(&mut reader, IPC_REQUEST_HEAD_BUDGET, framed_body_budget)?
    };
    handle_ipc_line(runtime, stream, line)
}

#[cfg(unix)]
fn handle_ipc_line(runtime: Runtime, stream: UnixStream, line: String) -> io::Result<()> {
    let response = match serde_json::from_str::<BrokerIpcRequest>(&line) {
        Ok(request) => match handle_ipc_request(&runtime, request) {
            Ok(result) => BrokerIpcResponse {
                ok: true,
                result: Some(result),
                error: None,
            },
            Err(error) => BrokerIpcResponse {
                ok: false,
                result: None,
                error: Some(error.message),
            },
        },
        Err(error) => BrokerIpcResponse {
            ok: false,
            result: None,
            error: Some(format!("invalid IPC request: {error}")),
        },
    };
    // Replies are never framed, whichever encoding the request used.
    //
    // Framing earns its keep on the request path: the peer is arbitrary, so
    // the read needs a total budget, and a total budget without a declared
    // length is a size ceiling in disguise. None of that applies here. The
    // caller is a helper that spawned this process and reads replies against
    // an idle budget with no ceiling, so a newline is all the delimiter it
    // needs — and it lets the reply be *streamed*.
    //
    // That matters because a reply is not small. `pendingRequests` carries the
    // payload of every unanswered client request, which for an
    // `fs/write_text_file` is the file content, and the replayed
    // `PendingRequest` event carries it a second time. Framing would mean
    // serializing all of that into memory before writing a byte: an extra copy
    // of an unbounded payload, and a silent stretch long enough to trip the
    // caller's idle budget before the reply even begins.
    let mut writer = BufWriter::new(stream);
    serde_json::to_writer(&mut writer, &response).map_err(io::Error::other)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

fn handle_ipc_request(
    runtime: &Runtime,
    request: BrokerIpcRequest,
) -> Result<Value, AcpBrokerProcessError> {
    match request.method.as_str() {
        "snapshot" => Ok(broker_snapshot(runtime)),
        "attach" => broker_attach(runtime, request.params),
        "send" => broker_send(runtime, request.params),
        "notify" => broker_notify(runtime, request.params),
        "respond" => broker_respond(runtime, request.params),
        "ack" => broker_ack(runtime, request.params),
        "close" => broker_close(runtime, request.params),
        _ => Err(broker_error(
            -32601,
            format!("broker method not found: {}", request.method),
        )),
    }
}

fn broker_snapshot(runtime: &Runtime) -> Value {
    let state = lock_runtime(runtime);
    let mut snapshot = json!(state.broker.snapshot());
    if let Some(object) = snapshot.as_object_mut() {
        object.insert("adapterExited".to_string(), json!(state.adapter_exited));
    }
    snapshot
}

fn broker_attach(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpAttachParams = decode(params)?;
    let state = lock_runtime(runtime);
    ensure_generation(&state, params.generation)?;
    let events = state
        .broker
        .replay_after(params.acknowledged_cursor)
        .map_err(domain_error)?;
    Ok(json!({
        "snapshot": state.broker.snapshot(),
        "events": events
    }))
}

fn broker_send(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpSendParams = decode(params)?;
    let operation = {
        let mut state = lock_runtime(runtime);
        ensure_generation(&state, params.generation)?;
        let operation = state
            .broker
            .begin_operation(
                params.operation_key.clone(),
                params.method.clone(),
                params.params.clone(),
            )
            .map_err(domain_error)?;
        if operation.replayed {
            if let Some(outcome) = operation.terminal_outcome {
                let mut response = json!({
                    "requestId": operation.adapter_request_id,
                    "replayed": true,
                });
                apply_outcome_fields(&mut response, outcome);
                return Ok(response);
            }
        } else {
            state.pending_methods.insert(
                operation.adapter_request_id.value(),
                PendingOperation {
                    operation_key: params.operation_key.clone(),
                    method: params.method.clone(),
                },
            );
            if params.method == "session/prompt" {
                let _ = state.broker.set_turn_state(BrokerTurnState::Sending);
            }
        }
        operation
    };

    if !operation.replayed {
        write_adapter_request(
            runtime,
            operation.adapter_request_id.value(),
            &params.method,
            params.params,
        )?;
    }
    Ok(json!({
        "requestId": operation.adapter_request_id,
        "replayed": operation.replayed,
        "pending": true
    }))
}

fn broker_notify(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpNotifyParams = decode(params)?;
    {
        let mut state = lock_runtime(runtime);
        ensure_generation(&state, params.generation)?;
        if params.method == "session/cancel" {
            let _ = state.broker.set_turn_state(BrokerTurnState::Cancelling);
        }
    }
    write_adapter_notification(runtime, &params.method, params.params)?;
    Ok(json!({ "ok": true }))
}

fn broker_respond(
    runtime: &Runtime,
    params: Option<Value>,
) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpRespondParams = decode(params)?;
    let request_key = request_id_key(&params.request_id);
    let outcome = params
        .outcome()
        .ok_or_else(|| broker_error(-32602, "respond requires exactly one of result or error"))?;
    {
        let mut state = lock_runtime(runtime);
        ensure_generation(&state, params.generation)?;
        state
            .broker
            .respond_to_pending_request(&request_key, outcome.clone())
            .map_err(domain_error)?;
    }
    write_adapter_response(runtime, params.request_id, outcome)?;
    Ok(json!({ "ok": true }))
}

fn broker_ack(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpAckParams = decode(params)?;
    let mut state = lock_runtime(runtime);
    ensure_generation(&state, params.generation)?;
    state.broker.ack(params.cursor).map_err(domain_error)?;
    Ok(json!({ "ok": true }))
}

fn broker_close(runtime: &Runtime, params: Option<Value>) -> Result<Value, AcpBrokerProcessError> {
    let params: AcpCloseParams = decode(params)?;
    let adapter_process_group_id = {
        let mut state = lock_runtime(runtime);
        ensure_generation(&state, params.generation)?;
        state.closing = true;
        if state.adapter_exited {
            None
        } else {
            state.adapter_process_group_id
        }
    };
    terminate_adapter_process_group(runtime, adapter_process_group_id);
    Ok(json!({ "ok": true }))
}

fn spawn_stdout_reader(runtime: Runtime, stdout: std::process::ChildStdout) {
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            handle_adapter_stdout_line(&runtime, &line);
        }
    });
}

fn spawn_stderr_reader(runtime: Runtime, stderr: std::process::ChildStderr) {
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            let mut state = lock_runtime(&runtime);
            state
                .broker
                .add_adapter_notification("adapter/stderr", json!({ "text": line }));
        }
    });
}

fn spawn_waiter(runtime: Runtime, mut child: std::process::Child) {
    std::thread::spawn(move || {
        let _ = child.wait();
        let (lock, condvar) = &*runtime.state;
        let mut state = lock.lock().expect("broker state poisoned");
        state.adapter_exited = true;
        if !state.closing {
            let _ = state.broker.set_turn_state(BrokerTurnState::Ambiguous);
            complete_pending_operations_after_adapter_exit(&mut state);
            state
                .broker
                .add_adapter_notification("adapter/exit", json!({ "unexpected": true }));
        }
        condvar.notify_all();
    });
}

fn complete_pending_operations_after_adapter_exit(state: &mut RuntimeState) {
    let outcome = AdapterRPCOutcome::error(JSONRPCErrorObject {
        code: -32074,
        message: "adapter exited before completing request".to_string(),
        data: None,
    });
    let pending: Vec<_> = state
        .pending_methods
        .drain()
        .map(|(_, pending)| pending)
        .collect();
    for pending in pending {
        let _ = state
            .broker
            .complete_operation(&pending.operation_key, outcome.clone());
    }
}

fn handle_adapter_stdout_line(runtime: &Runtime, line: &str) {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        let mut state = lock_runtime(runtime);
        state
            .broker
            .add_adapter_notification("adapter/stdout", json!({ "line": line }));
        return;
    };
    if value.get("id").is_some() && (value.get("result").is_some() || value.get("error").is_some())
    {
        handle_adapter_response(runtime, value);
    } else if value.get("id").is_some() && value.get("method").is_some() {
        handle_adapter_client_request(runtime, value);
    } else if let Some(method) = value.get("method").and_then(Value::as_str) {
        let params = value.get("params").cloned().unwrap_or(Value::Null);
        let (lock, condvar) = &*runtime.state;
        let mut state = lock.lock().expect("broker state poisoned");
        if method == "session/update"
            && state
                .pending_methods
                .values()
                .any(|pending| pending.method == "session/prompt")
        {
            let _ = state.broker.set_turn_state(BrokerTurnState::Streaming);
        }
        state.broker.add_adapter_notification(method, params);
        condvar.notify_all();
    }
}

fn handle_adapter_response(runtime: &Runtime, value: Value) {
    let Some(id) = value.get("id").and_then(Value::as_u64) else {
        return;
    };
    let Some(outcome) = adapter_response_outcome(&value) else {
        return;
    };
    let (lock, condvar) = &*runtime.state;
    let mut state = lock.lock().expect("broker state poisoned");
    let Some(pending) = state.pending_methods.remove(&id) else {
        state
            .broker
            .add_adapter_notification("adapter/orphanResponse", value);
        return;
    };
    if let Some(result) = &outcome.result {
        if pending.method == "initialize" {
            let _ = state.broker.record_initialize_result(result.clone());
        } else if matches!(
            pending.method.as_str(),
            "session/new" | "session/load" | "session/resume"
        ) {
            let _ = state.broker.record_remote_session_result(result.clone());
        }
    }
    if pending.method == "session/prompt" {
        let _ = state.broker.set_turn_state(BrokerTurnState::Completed);
    }
    let _ = state
        .broker
        .complete_operation(&pending.operation_key, outcome);
    condvar.notify_all();
}

fn handle_adapter_client_request(runtime: &Runtime, value: Value) {
    let Some(id) = value.get("id").cloned() else {
        return;
    };
    let request_id = id
        .as_u64()
        .map(|number| number.to_string())
        .or_else(|| id.as_str().map(ToString::to_string))
        .unwrap_or_else(|| id.to_string());
    let method = value
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or("adapter/request")
        .to_string();
    let params = value.get("params").cloned().unwrap_or(Value::Null);
    let kind = pending_kind(&method);
    let (lock, condvar) = &*runtime.state;
    let mut state = lock.lock().expect("broker state poisoned");
    let _ = state.broker.add_pending_request(
        request_id,
        id,
        kind,
        json!({ "method": method, "params": params }),
    );
    if pending_kind_awaits_user(kind) {
        let _ = state.broker.set_turn_state(BrokerTurnState::AwaitingInput);
    }
    condvar.notify_all();
}

fn pending_kind_awaits_user(kind: PendingClientRequestKind) -> bool {
    matches!(
        kind,
        PendingClientRequestKind::Permission
            | PendingClientRequestKind::Question
            | PendingClientRequestKind::Elicitation
    )
}

fn pending_kind(method: &str) -> PendingClientRequestKind {
    if method.contains("permission") {
        PendingClientRequestKind::Permission
    } else if method.contains("question") {
        PendingClientRequestKind::Question
    } else if method.contains("elicitation") {
        PendingClientRequestKind::Elicitation
    } else if method.contains("file") {
        PendingClientRequestKind::File
    } else {
        PendingClientRequestKind::Terminal
    }
}

fn adapter_response_outcome(value: &Value) -> Option<AdapterRPCOutcome> {
    if let Some(result) = value.get("result") {
        return Some(AdapterRPCOutcome::result(result.clone()));
    }
    if let Some(error) = value.get("error") {
        return Some(AdapterRPCOutcome::error(jsonrpc_error_object(error)));
    }
    None
}

fn jsonrpc_error_object(value: &Value) -> JSONRPCErrorObject {
    JSONRPCErrorObject {
        code: value.get("code").and_then(Value::as_i64).unwrap_or(-32000),
        message: value
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("adapter JSON-RPC error")
            .to_string(),
        data: value.get("data").cloned(),
    }
}

fn request_id_key(id: &Value) -> String {
    id.as_u64()
        .map(|number| number.to_string())
        .or_else(|| id.as_str().map(ToString::to_string))
        .unwrap_or_else(|| id.to_string())
}

fn apply_outcome_fields(response: &mut Value, outcome: AdapterRPCOutcome) {
    if let Some(object) = response.as_object_mut() {
        match (outcome.result, outcome.error) {
            (Some(result), None) => {
                object.insert("result".to_string(), result);
            }
            (None, Some(error)) => {
                object.insert("error".to_string(), json!(error));
            }
            _ => {
                object.insert(
                    "error".to_string(),
                    json!({ "code": -32603, "message": "invalid broker outcome" }),
                );
            }
        }
    }
}

fn write_adapter_request(
    runtime: &Runtime,
    id: u64,
    method: &str,
    params: Value,
) -> Result<(), AcpBrokerProcessError> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    });
    write_adapter_line(runtime, &request)
}

fn write_adapter_notification(
    runtime: &Runtime,
    method: &str,
    params: Value,
) -> Result<(), AcpBrokerProcessError> {
    let notification = json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params
    });
    write_adapter_line(runtime, &notification)
}

fn write_adapter_response(
    runtime: &Runtime,
    id: Value,
    outcome: AdapterRPCOutcome,
) -> Result<(), AcpBrokerProcessError> {
    let mut response = json!({
        "jsonrpc": "2.0",
        "id": id,
    });
    apply_outcome_fields(&mut response, outcome);
    write_adapter_line(runtime, &response)
}

fn write_adapter_line(runtime: &Runtime, value: &Value) -> Result<(), AcpBrokerProcessError> {
    let mut stdin = runtime
        .adapter_stdin
        .lock()
        .map_err(|_| broker_error(-32074, "adapter stdin lock poisoned"))?;
    writeln!(stdin, "{value}")
        .map_err(|error| broker_error(-32074, format!("adapter write failed: {error}")))?;
    stdin
        .flush()
        .map_err(|error| broker_error(-32074, format!("adapter flush failed: {error}")))
}

fn ensure_generation(
    state: &RuntimeState,
    generation: BrokerGeneration,
) -> Result<(), AcpBrokerProcessError> {
    if state.broker.metadata().generation != generation {
        return Err(broker_error(-32075, "broker generation mismatch"));
    }
    Ok(())
}

fn lock_runtime(runtime: &Runtime) -> std::sync::MutexGuard<'_, RuntimeState> {
    runtime.state.0.lock().expect("broker state poisoned")
}

fn runtime_is_closing(runtime: &Runtime) -> bool {
    lock_runtime(runtime).closing
}

fn decode<T: for<'de> Deserialize<'de>>(params: Option<Value>) -> Result<T, AcpBrokerProcessError> {
    let params = params.ok_or_else(|| broker_error(-32602, "missing params"))?;
    serde_json::from_value(params)
        .map_err(|error| broker_error(-32602, format!("invalid params: {error}")))
}

fn decode_env(value: Value) -> Result<HashMap<String, String>, AcpBrokerProcessError> {
    let object = value
        .as_object()
        .ok_or_else(|| broker_error(-32602, "env must be an object"))?;
    let mut env = HashMap::new();
    for (key, value) in object {
        validate_env_key(key)?;
        let string = value
            .as_str()
            .ok_or_else(|| broker_error(-32602, format!("env value for {key} must be a string")))?;
        env.insert(key.clone(), string.to_string());
    }
    Ok(env)
}

fn validate_env_key(key: &str) -> Result<(), AcpBrokerProcessError> {
    if !key.is_empty() && !key.bytes().any(|byte| byte == b'=' || byte == b'\0') {
        return Ok(());
    }
    Err(broker_error(-32602, format!("invalid env key: {key}")))
}

fn sorted_env_keys(env: &HashMap<String, String>) -> Vec<String> {
    let mut keys: Vec<_> = env.keys().cloned().collect();
    keys.sort();
    keys
}

fn send_ipc(dir: &Path, method: &str, params: Value) -> Result<Value, AcpBrokerProcessError> {
    send_ipc_within(dir, method, params, BROKER_IPC_IDLE_TIMEOUT)
}

fn send_ipc_within(
    dir: &Path,
    method: &str,
    params: Value,
    idle_timeout: Duration,
) -> Result<Value, AcpBrokerProcessError> {
    #[cfg(unix)]
    {
        // Serialize BEFORE connecting. The broker starts its request deadline
        // the moment `accept()` returns, so any work done between connecting
        // and writing is spent out of the broker's budget rather than ours.
        // That is not a small effect at the sizes the UI permits: encoding a
        // maximal image prompt (~267 MiB) measures
        // ~7.4s on an idle machine, against an `IPC_REQUEST_TIMEOUT` of 5s —
        // so connecting first would drop a perfectly valid prompt every time,
        // not merely under load. Writing the bytes, by contrast, takes ~0.2s,
        // which is what the broker's deadline should actually be covering.
        let body = serde_json::to_string(&BrokerIpcRequest {
            method: method.to_string(),
            params: Some(params),
        })
        .expect("IPC request serialization");
        // This connect is blocking and deliberately left that way. On Darwin
        // — the only platform that reaches this code, since the ACP broker is
        // spawned for local sessions only — a full listen backlog fails the
        // connect with ECONNREFUSED immediately rather than waiting for room,
        // so a wedged supervisor cannot stall the caller here; the retry
        // deadline in `send_ipc_with_retry` handles the refusal. Linux instead
        // *blocks* until backlog space frees up, so if brokers ever run on a
        // remote helper — this binary is built for Linux too — this needs a
        // non-blocking, deadline-aware connect before it can be trusted.
        // `connect_does_not_block_on_a_full_backlog` pins the Darwin
        // behaviour this relies on.
        let mut stream = UnixStream::connect(dir.join("broker.sock"))
            .map_err(|error| broker_error(-32072, format!("broker connect failed: {error}")))?;
        // Without a bound, a broker that accepted the connection but never
        // answered would block this call forever.
        stream
            .set_write_timeout(Some(BROKER_IPC_WRITE_TIMEOUT))
            .map_err(|error| {
                broker_error(-32072, format!("broker write timeout failed: {error}"))
            })?;
        // Frame the request when the broker advertises it. Without framing the
        // reader has to hunt for a newline, which needs a total budget, which
        // is a size ceiling wearing a different hat — and this request can be
        // an `acp/respond` carrying a whole file the adapter asked to read.
        // A broker started by an earlier build has no marker and still gets
        // the original encoding.
        let framing = if broker_supports_framing(dir) {
            Framing::Framed
        } else {
            Framing::Legacy
        };
        write_ipc_message(&mut stream, &body, framing)
            .map_err(|error| broker_error(-32072, format!("broker write failed: {error}")))?;
        // Bounded by inactivity, not total time: a reply's size — and so how
        // long it legitimately takes — is not something we can predict. What
        // can be asked of a broker is that it keep making progress.
        let (line, _) = {
            let mut reader = ipc_reader(&stream)
                .map_err(|error| broker_error(-32072, format!("broker read setup: {error}")))?;
            read_ipc_message(
                &mut reader,
                ReadBudget::idle(idle_timeout),
                trusted_body_budget,
            )
            .map_err(|error| broker_error(-32072, format!("broker read failed: {error}")))?
        };
        let response: BrokerIpcResponse = serde_json::from_str(&line)
            .map_err(|error| broker_error(-32072, format!("broker response failed: {error}")))?;
        if response.ok {
            Ok(response.result.unwrap_or(Value::Null))
        } else {
            Err(broker_error(
                -32072,
                response
                    .error
                    .unwrap_or_else(|| "broker request failed".to_string()),
            ))
        }
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        let _ = method;
        let _ = params;
        Err(broker_error(-32072, "ACP broker IPC requires Unix sockets"))
    }
}

fn send_ipc_with_retry(
    dir: &Path,
    method: &str,
    params: Value,
    retry_budget: Duration,
) -> Result<Value, AcpBrokerProcessError> {
    let deadline = std::time::Instant::now() + retry_budget;
    loop {
        if let Some(message) = read_startup_error(dir) {
            return Err(broker_error(-32072, message));
        }
        // Each attempt gets the ordinary response budget, NOT what is left of
        // `retry_budget`. The two measure different things: `retry_budget` is
        // how long to keep re-trying a broker that is not answering *yet* —
        // typically one still starting up, whose socket does not exist — while
        // `BROKER_IPC_IDLE_TIMEOUT` is how long a single legitimate response may
        // take once the broker does answer. Those are far apart: `acp_open`
        // adopts a live broker on a 2s retry budget, and a snapshot carrying a
        // retained large-image prompt takes ~7.4s just to serialize on the
        // broker side. Deriving the response deadline from the retry budget
        // makes adopting such a broker fail permanently, since every retry
        // hits the same wall.
        match send_ipc_within(dir, method, params.clone(), BROKER_IPC_IDLE_TIMEOUT) {
            Ok(value) => return Ok(value),
            Err(error) if std::time::Instant::now() < deadline => {
                let _ = error;
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => return Err(error),
        }
    }
}

fn read_startup_error(dir: &Path) -> Option<String> {
    let message = std::fs::read_to_string(dir.join("startup-error")).ok()?;
    let trimmed = message.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn remove_transient_startup_files(dir: &Path) {
    for name in [
        "broker.sock",
        "ready",
        "startup-error",
        "pid.json",
        IPC_FRAMING_MARKER,
    ] {
        let _ = std::fs::remove_file(dir.join(name));
    }
}

fn spawn_broker_supervisor(dir: &Path) -> Result<(), AcpBrokerProcessError> {
    let exe = std::env::current_exe()
        .map_err(|error| broker_error(-32070, format!("helper path failed: {error}")))?;
    let mut command = Command::new(exe);
    command
        .arg("acp-broker-supervise")
        .arg(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .spawn()
        .map_err(|error| broker_error(-32070, format!("broker spawn failed: {error}")))?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

fn broker_is_running(dir: &Path) -> bool {
    let Some(metadata) = read_broker_pid_metadata(dir) else {
        return false;
    };
    if !pid_is_alive(metadata.pid) {
        mark_stale_broker_pid(dir);
        return false;
    }
    if let Some(expected_pgid) = metadata.process_group_id {
        if current_process_group_id(metadata.pid) != Some(expected_pgid) {
            mark_stale_broker_pid(dir);
            return false;
        }
    }
    true
}

fn read_broker_pid_metadata(dir: &Path) -> Option<BrokerPidMetadata> {
    serde_json::from_slice::<BrokerPidMetadata>(&std::fs::read(dir.join("pid.json")).ok()?).ok()
}

fn mark_stale_broker_pid(dir: &Path) {
    let _ = std::fs::remove_file(dir.join("pid.json"));
}

fn write_broker_pid(dir: &Path) -> Result<(), AcpBrokerProcessError> {
    let metadata = BrokerPidMetadata {
        pid: std::process::id(),
        process_group_id: current_process_group_id(std::process::id()),
    };
    write_restrictive_json(&dir.join("pid.json"), &metadata)
}

#[cfg(unix)]
fn pid_is_alive(pid: u32) -> bool {
    unsafe { libc_kill(pid as i32, 0) == 0 }
}

#[cfg(not(unix))]
fn pid_is_alive(_pid: u32) -> bool {
    false
}

#[cfg(unix)]
fn current_process_group_id(pid: u32) -> Option<u32> {
    let pgid = unsafe { libc_getpgid(pid as i32) };
    if pgid >= 0 { Some(pgid as u32) } else { None }
}

#[cfg(not(unix))]
fn current_process_group_id(_pid: u32) -> Option<u32> {
    None
}

#[cfg(unix)]
fn adapter_process_group_id(child: &std::process::Child) -> Option<u32> {
    Some(child.id())
}

#[cfg(not(unix))]
fn adapter_process_group_id(_child: &std::process::Child) -> Option<u32> {
    None
}

fn terminate_adapter_process_group(runtime: &Runtime, process_group_id: Option<u32>) {
    let Some(process_group_id) = process_group_id else {
        return;
    };
    signal_process_group(process_group_id, 15);
    if wait_for_adapter_exit(runtime, Duration::from_millis(500)) {
        return;
    }
    signal_process_group(process_group_id, 9);
    let _ = wait_for_adapter_exit(runtime, Duration::from_secs(2));
}

fn wait_for_adapter_exit(runtime: &Runtime, timeout: Duration) -> bool {
    let (lock, condvar) = &*runtime.state;
    let mut state = lock.lock().expect("broker state poisoned");
    let deadline = std::time::Instant::now() + timeout;
    while !state.adapter_exited {
        let now = std::time::Instant::now();
        if now >= deadline {
            break;
        }
        let (next_state, _) = condvar
            .wait_timeout(state, deadline.saturating_duration_since(now))
            .expect("broker state poisoned");
        state = next_state;
    }
    state.adapter_exited
}

#[cfg(unix)]
fn signal_process_group(process_group_id: u32, signal: i32) {
    unsafe {
        let _ = libc_kill(-(process_group_id as i32), signal);
        let _ = libc_kill(process_group_id as i32, signal);
    }
}

#[cfg(not(unix))]
fn signal_process_group(_process_group_id: u32, _signal: i32) {}

#[cfg(unix)]
unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
    fn getpgid(pid: i32) -> i32;
}

#[cfg(unix)]
unsafe fn libc_kill(pid: i32, sig: i32) -> i32 {
    unsafe { kill(pid, sig) }
}

#[cfg(unix)]
unsafe fn libc_getpgid(pid: i32) -> i32 {
    unsafe { getpgid(pid) }
}

fn validate_broker_id(broker_id: &str) -> Result<(), AcpBrokerProcessError> {
    if broker_id.is_empty()
        || broker_id.len() > 160
        || !broker_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err(broker_error(-32602, "invalid brokerId"));
    }
    Ok(())
}

fn broker_root() -> Result<PathBuf, AcpBrokerProcessError> {
    let home = std::env::var("HOME").map_err(|_| broker_error(-32070, "HOME is not set"))?;
    Ok(PathBuf::from(home).join(".alas").join("acp-brokers"))
}

fn broker_dir(broker_id: &str) -> Result<PathBuf, AcpBrokerProcessError> {
    validate_broker_id(broker_id)?;
    Ok(broker_root()?.join(broker_id))
}

fn remove_broker_dir(dir: &Path) -> Result<(), AcpBrokerProcessError> {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(broker_error(
            -32070,
            format!("broker cleanup failed: {error}"),
        )),
    }
}

fn write_restrictive_json<T: Serialize>(
    path: &Path,
    value: &T,
) -> Result<(), AcpBrokerProcessError> {
    write_restrictive_bytes(
        path,
        &serde_json::to_vec(value).expect("broker JSON serialization"),
    )
}

fn write_restrictive_bytes(path: &Path, bytes: &[u8]) -> Result<(), AcpBrokerProcessError> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|error| broker_error(-32070, format!("file create failed: {error}")))?;
    file.write_all(bytes)
        .map_err(|error| broker_error(-32070, format!("file write failed: {error}")))?;
    file.flush()
        .map_err(|error| broker_error(-32070, format!("file flush failed: {error}")))?;
    Ok(())
}

#[cfg(unix)]
fn set_restrictive_dir_permissions(dir: &Path) -> Result<(), AcpBrokerProcessError> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|error| broker_error(-32070, format!("broker chmod failed: {error}")))
}

#[cfg(not(unix))]
fn set_restrictive_dir_permissions(_dir: &Path) -> Result<(), AcpBrokerProcessError> {
    Ok(())
}

fn current_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

fn current_nanos() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default()
}

fn domain_error(error: crate::acp_broker::BrokerError) -> AcpBrokerProcessError {
    broker_error(-32076, format!("broker state error: {:?}", error.kind()))
}

fn broker_error(code: i64, message: impl Into<String>) -> AcpBrokerProcessError {
    AcpBrokerProcessError::new(code, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_user_facing_pending_requests_move_turn_to_awaiting_input() {
        assert!(pending_kind_awaits_user(
            PendingClientRequestKind::Permission
        ));
        assert!(pending_kind_awaits_user(PendingClientRequestKind::Question));
        assert!(pending_kind_awaits_user(
            PendingClientRequestKind::Elicitation
        ));
        assert!(!pending_kind_awaits_user(PendingClientRequestKind::File));
        assert!(!pending_kind_awaits_user(
            PendingClientRequestKind::Terminal
        ));
    }

    /// The retry budget governs how long to keep retrying a broker that is not
    /// answering *yet* — its socket may not exist while it starts up. It must
    /// not double as the deadline for a single legitimate response, which can
    /// take far longer: `acp_open` adopts with a 2s retry budget, while a
    /// snapshot carrying a retained large-image prompt takes ~7.4s just to
    /// serialize broker-side. Conflating the two makes adoption of a live
    /// broker fail permanently, every retry hitting the same wall.
    #[cfg(unix)]
    #[test]
    fn a_retry_budget_does_not_cap_how_long_one_response_may_take() {
        let dir = PathBuf::from(format!("/tmp/alas-slow-broker-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("broker dir");
        let listener = UnixListener::bind(dir.join("broker.sock")).expect("listener binds");

        let responder = std::thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            let mut line = String::new();
            BufReader::new(&stream)
                .read_line(&mut line)
                .expect("request");
            // Stands in for a broker serializing a large snapshot: answers
            // correctly, just well past the caller's retry budget.
            std::thread::sleep(Duration::from_secs(4));
            let mut stream = stream;
            writeln!(stream, r#"{{"ok":true,"result":{{"slow":true}}}}"#).expect("response");
            stream.flush().expect("flush");
        });

        let outcome = send_ipc_with_retry(&dir, "snapshot", json!({}), Duration::from_secs(2));
        let _ = responder.join();
        let _ = std::fs::remove_dir_all(&dir);

        let value = outcome.expect("a slow but healthy broker must not be given up on");
        assert_eq!(value["slow"], json!(true));
    }

    /// `send_ipc_within` connects with a blocking socket, which is only safe
    /// because Darwin refuses a connect to a full listen backlog instead of
    /// waiting for room — otherwise a wedged supervisor could stall the
    /// helper's single-threaded loop before any timeout is installed. Pin that
    /// behaviour so a future Darwin that starts blocking is caught here.
    ///
    /// Darwin-only on purpose. This helper is also built for Linux (see
    /// `scripts/build-alas-helper.sh`), where a full backlog *does* block —
    /// but Linux never reaches the code this guards, because brokers are
    /// spawned for local sessions only. Running it there would fail for an
    /// assumption that platform does not need to hold. What Linux would need
    /// if brokers ever ran on a remote helper is documented at the connect
    /// itself, which is the thing that would have to change.
    #[cfg(target_os = "macos")]
    #[test]
    fn connect_does_not_block_on_a_full_backlog() {
        use std::sync::mpsc;

        let path = std::env::temp_dir().join(format!("alas-backlog-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        // Bound to a listener that never accepts, so the backlog fills and
        // stays full.
        let listener = UnixListener::bind(&path).expect("listener binds");

        let (sender, receiver) = mpsc::channel();
        let connect_path = path.clone();
        std::thread::spawn(move || {
            let mut held = Vec::new();
            // Comfortably past the default backlog on any platform we target.
            for _ in 0..1024 {
                match UnixStream::connect(&connect_path) {
                    Ok(stream) => held.push(stream),
                    Err(error) => {
                        let _ = sender.send(Some(error.kind()));
                        return;
                    }
                }
            }
            let _ = sender.send(None);
        });

        let outcome = receiver.recv_timeout(Duration::from_secs(20));
        drop(listener);
        let _ = std::fs::remove_file(&path);

        let kind = outcome
            .expect("connect blocked on a full backlog — send_ipc_within needs a bounded connect")
            .expect("expected the backlog to fill within 1024 connects");
        assert_eq!(kind, io::ErrorKind::ConnectionRefused);
    }

    /// An idle budget must survive a transfer that runs well past it in total,
    /// which is the whole reason responses use one: a maximal attach reply
    /// carries its prompt params twice and takes ~15s to serialize before a
    /// byte is written, and there is no total we could pick that a larger
    /// legitimate reply would not eventually exceed. A total budget of the
    /// same size would fail this.
    #[cfg(unix)]
    #[test]
    fn an_idle_budget_survives_a_transfer_longer_than_the_budget_itself() {
        let (mut writer, reader) = UnixStream::pair().expect("socket pair");
        std::thread::spawn(move || {
            // Six chunks over ~3s, none more than 0.5s apart: never idle for
            // long, but comfortably past a 1s total.
            for _ in 0..6 {
                if writer.write_all(&[b'z'; 512]).is_err() {
                    return;
                }
                let _ = writer.flush();
                std::thread::sleep(Duration::from_millis(500));
            }
            let _ = writer.write_all(b"\n");
            let _ = writer.flush();
        });

        let started = std::time::Instant::now();
        let mut reader = ipc_reader(&reader).expect("reader");
        let line = read_line_within(&mut reader, ReadBudget::idle(Duration::from_secs(1)))
            .expect("a peer that keeps making progress must not be given up on");
        assert_eq!(line.len(), 6 * 512 + 1);
        assert!(
            started.elapsed() > Duration::from_secs(1),
            "transfer finished too fast to prove the budget was exceeded in total"
        );
    }

    /// A framed caller declares a length, and is then held to delivering it.
    /// Without that, an idle budget alone lets a caller advertise an enormous
    /// body and dribble it, renewing its budget forever while the buffer
    /// grows — the trickle path framing was supposed to close, not reopen.
    #[cfg(unix)]
    #[test]
    fn a_framed_body_must_be_delivered_at_a_minimum_rate() {
        let (mut writer, reader) = UnixStream::pair().expect("socket pair");
        let done = Arc::new(Mutex::new(false));
        let writer_done = done.clone();
        std::thread::spawn(move || {
            while !*writer_done.lock().expect("drip flag") {
                if writer.write_all(b"z").is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });

        // Claims 4 MiB, which the floor allows well under the 2s asked for
        // here, then delivers a byte at a time.
        let mut reader = ipc_reader(&reader).expect("reader");
        let started = std::time::Instant::now();
        let outcome = read_exact_within(
            &mut reader,
            4 * 1024 * 1024,
            ReadBudget::within(Duration::from_secs(2), Duration::from_secs(2)),
        );
        *done.lock().expect("drip flag") = true;

        let error = outcome.expect_err("a dribbled body must not be waited on forever");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    /// A framing marker must expire with the broker that wrote it.
    ///
    /// A supervisor from an earlier build can replace this one in the same
    /// directory, and its cleanup does not know to remove a file it has never
    /// heard of — so the marker outlives the broker that meant it. Trusting it
    /// then sends framed requests to a broker that only speaks newlines, which
    /// rejects them, and `acp/open` will not replace it while its pid is live.
    ///
    /// Tested here rather than end-to-end because reproducing it for real
    /// needs a supervisor built before framing existed; what can be pinned is
    /// that presence alone is not taken as consent.
    #[cfg(unix)]
    #[test]
    fn a_framing_marker_is_only_trusted_for_the_live_broker() {
        let dir = PathBuf::from(format!("/tmp/alas-marker-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("marker dir");
        write_broker_pid(&dir).expect("pid metadata");
        let live = std::process::id();

        assert!(
            !broker_supports_framing(&dir),
            "no marker should mean no framing"
        );

        std::fs::write(dir.join(IPC_FRAMING_MARKER), format!("{live}\n")).expect("marker");
        assert!(
            broker_supports_framing(&dir),
            "a marker written by the live broker should be trusted"
        );

        // Stands in for a marker left behind by a broker that has since been
        // replaced: present, but naming a process that is no longer the one
        // serving this directory.
        std::fs::write(dir.join(IPC_FRAMING_MARKER), format!("{}\n", live + 1)).expect("marker");
        assert!(
            !broker_supports_framing(&dir),
            "a marker from a replaced broker must not be trusted"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A rate bound has to separate the two cases a fixed duration cannot: a
    /// legacy request whose sender pauses to encode and then delivers a lot,
    /// and a trickle that never intends to finish. Both look identical to an
    /// idle bound, and any total that admits the first admits the second.
    #[cfg(unix)]
    #[test]
    fn a_rate_bound_admits_a_slow_start_but_not_a_trickle() {
        fn read_with(chunk: usize, gap: Duration, chunks: usize) -> io::Result<String> {
            let (mut writer, reader) = UnixStream::pair().expect("socket pair");
            std::thread::spawn(move || {
                // A long pause first, standing in for an older helper encoding
                // its request before it writes anything at all.
                std::thread::sleep(Duration::from_secs(1));
                for _ in 0..chunks {
                    if writer.write_all(&vec![b'q'; chunk]).is_err() {
                        return;
                    }
                    let _ = writer.flush();
                    std::thread::sleep(gap);
                }
                let _ = writer.write_all(b"\n");
                let _ = writer.flush();
            });
            let mut reader = ipc_reader(&reader).expect("reader");
            // 64 KiB/s required, judged after a 10s grace.
            read_line_within(
                &mut reader,
                ReadBudget::at_least(Duration::from_secs(30), 64 * 1024),
            )
        }

        // Pauses a second, then sends ~2 MiB in bursts: comfortably above the
        // rate, and a fixed total tuned to reject the trickle below would have
        // had to reject this too.
        let delivered = read_with(256 * 1024, Duration::from_millis(50), 8)
            .expect("a sender that pauses and then delivers must be allowed to finish");
        assert_eq!(delivered.len(), 8 * 256 * 1024 + 1);

        // A byte every 100ms never approaches the rate, and never ends.
        let started = std::time::Instant::now();
        let error = read_with(1, Duration::from_millis(100), usize::MAX)
            .expect_err("a trickle must not be allowed to run indefinitely");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(
            started.elapsed() < Duration::from_secs(30),
            "the rate bound took too long to notice: {:?}",
            started.elapsed()
        );
    }

    /// The two body budgets encode different trust, and mixing them up is easy
    /// to do silently: holding a broker's reply to a throughput floor would
    /// fail a legitimately slow one, while letting an inbound request go
    /// unbounded is the trickle path this all exists to close.
    #[test]
    fn only_arbitrary_peers_are_held_to_a_declared_length() {
        let len = 64 * 1024 * 1024;
        assert!(
            matches!(framed_body_budget(len).pace, Pace::Within(_)),
            "a request body must be bounded by the length its sender declared"
        );
        assert!(
            matches!(trusted_body_budget(len).pace, Pace::Unbounded),
            "a reply from our own broker has no size we can turn into a deadline"
        );
        assert_eq!(trusted_body_budget(len).idle, BROKER_IPC_IDLE_TIMEOUT);
    }

    /// A declared length buys time proportional to itself, and nothing else.
    /// Deriving the only deadline from it would let a caller claim 1 TiB and
    /// then say nothing for the ~29 hours that implies, parking a thread per
    /// such connection.
    #[cfg(unix)]
    #[test]
    fn a_huge_declared_length_does_not_buy_silence() {
        let (_writer, reader) = UnixStream::pair().expect("socket pair");
        let mut reader = ipc_reader(&reader).expect("reader");

        let one_tib = 1024usize.pow(4);
        let mut budget = framed_body_budget(one_tib);
        assert!(
            matches!(budget.pace, Pace::Within(total) if total > Duration::from_secs(3600)),
            "a 1 TiB body should be allowed hours in total"
        );
        // Shorten only the silence bound, so this test does not sit for the
        // full idle budget while proving the total is not what stops it.
        budget.idle = Duration::from_millis(300);

        let started = std::time::Instant::now();
        let error = read_exact_within(&mut reader, one_tib, budget)
            .expect_err("a silent caller must be cut by the idle bound, not its own claim");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(30));
    }

    /// The rate floor must not turn into a ceiling on legitimate payloads: a
    /// body large enough to take real time still has to be allowed to arrive.
    #[test]
    fn the_body_deadline_scales_with_the_length_a_caller_declares() {
        // Small bodies are not held to a stricter rule than large ones.
        assert!(matches!(
            framed_body_budget(1024).pace,
            Pace::Within(total) if total == BROKER_IPC_IDLE_TIMEOUT
        ));
        // A maximal image prompt (~267 MiB) gets time proportional to its size.
        let maximal = 267 * 1024 * 1024;
        let budget = framed_body_budget(maximal);
        assert!(
            matches!(budget.pace, Pace::Within(total) if total >= BROKER_IPC_IDLE_TIMEOUT),
            "a large body was given less time than a small one"
        );
        // The silence bound does not scale with the declared length, or a
        // caller could buy quiet by claiming a huge body.
        assert_eq!(budget.idle, BROKER_IPC_IDLE_TIMEOUT);
    }

    /// The whole fix rests on this: a peer that keeps the connection alive and
    /// keeps sending, but never ends the line, must still hit the deadline.
    /// A per-read inactivity timeout never would — and with no length ceiling
    /// left, this total budget is the only thing standing between a trickling
    /// peer and an unbounded read.
    #[cfg(unix)]
    #[test]
    fn read_line_within_stops_a_peer_that_drips_without_ever_ending_the_line() {
        let (mut writer, reader) = UnixStream::pair().expect("socket pair");
        let done = Arc::new(Mutex::new(false));
        let writer_done = done.clone();
        std::thread::spawn(move || {
            while !*writer_done.lock().expect("drip flag") {
                if writer.write_all(b" ").is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });

        let started = std::time::Instant::now();
        let mut reader = ipc_reader(&reader).expect("reader");
        let outcome = read_line_within(
            &mut reader,
            ReadBudget::within(Duration::from_secs(2), Duration::from_secs(2)),
        );
        let elapsed = started.elapsed();
        *done.lock().expect("drip flag") = true;

        let error = outcome.expect_err("a line that never ends must not read forever");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(
            elapsed < Duration::from_secs(10),
            "deadline overshot badly: {elapsed:?}"
        );
    }

    /// A large line must arrive intact rather than being cut short mid-way:
    /// an `acp/respond` can carry a whole file the adapter asked to read.
    #[cfg(unix)]
    #[test]
    fn read_line_within_accepts_a_line_larger_than_a_typical_request() {
        let (mut writer, reader) = UnixStream::pair().expect("socket pair");
        let payload = vec![b'x'; 40 * 1024 * 1024];
        let expected = payload.len();
        std::thread::spawn(move || {
            let _ = writer.write_all(&payload);
            let _ = writer.write_all(b"\n");
            let _ = writer.flush();
        });

        let mut reader = ipc_reader(&reader).expect("reader");
        let line = read_line_within(&mut reader, ReadBudget::idle(Duration::from_secs(30)))
            .expect("large line");
        assert_eq!(line.len(), expected + 1);
    }
}
