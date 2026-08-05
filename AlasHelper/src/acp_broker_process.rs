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
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
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
/// legitimately say nothing at all while it encodes. A total budget would drop
/// that request, breaking the very callers the legacy path exists to serve.
///
/// This is the one bound that has to be a fixed duration rather than a rate,
/// because before a single byte arrives there is nothing to measure a rate
/// against: a peer part-way through encoding two gigabytes and a peer that
/// connected and died look identical. Since it cannot be derived, it is sized
/// against what a sender can physically produce. Serialization measures
/// ~36 MB/s, so this covers something over ten gigabytes of encoding — and the
/// largest legacy request is an `acp/respond` carrying a whole file, which
/// `ACPSessionRunner.serveRead` builds by holding the file, a `String` copy
/// and the encoded JSON in memory at once. A sender that needs longer than
/// this has already failed on its own side.
///
/// The cost of being generous is bounded too: a silent connection holds one
/// worker, there are `MAX_BROKER_CONNECTION_WORKERS` of them, and the listen
/// backlog caps how many a peer can hold at once regardless.
const IPC_REQUEST_IDLE_TIMEOUT: Duration = Duration::from_secs(300);

/// Rate a peer must sustain while reading a response.
///
/// `SO_SNDTIMEO` bounds each write, not the whole reply, so a peer that reads
/// a little every nineteen seconds renews it forever and keeps its handler
/// alive. Enough such peers hold every connection worker, and unlike a flood
/// of idle connections this one never lapses, so the broker does not recover
/// on its own. Requiring a rate ends it. Lenient by design: the only real
/// reader is a helper already blocked on the reply.
const MIN_IPC_RESPONSE_RATE: u64 = 16 * 1024;

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
const IPC_REQUEST_HEAD_BUDGET: IoBudget =
    IoBudget::at_least(IPC_REQUEST_IDLE_TIMEOUT, MIN_IPC_REQUEST_RATE);

/// Largest framed body accepted.
///
/// A rate bound limits how long a body may take, not how much of it is held:
/// a peer declaring a hundred gigabytes and delivering at the required rate is
/// retained byte for byte until the broker dies. Time was never the dimension
/// that ran out.
///
/// So there is a ceiling again — chosen the way the pre-first-byte bound is,
/// from what a sender can physically produce rather than from what feels
/// large. The biggest legitimate request is an `acp/respond` carrying a whole
/// file, which `ACPSessionRunner.serveRead` builds holding the file, a
/// `String` copy and the encoded JSON at once; a maximal image prompt is
/// ~267 MiB by comparison.
const MAX_IPC_FRAME_BYTES: usize = 8 * 1024 * 1024 * 1024;

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
fn trusted_body_budget(_len: usize) -> IoBudget {
    IoBudget::idle(BROKER_IPC_IDLE_TIMEOUT)
}

/// Budget for a framed body of `len` bytes arriving from an arbitrary peer.
///
/// The total scales with the length the caller declared — never below the
/// ordinary idle budget, so a small body is not held to a stricter rule than a
/// large one. The idle bound is kept alongside it and does not scale: a caller
/// that declares 1 TiB and then says nothing would otherwise have bought
/// itself about 29 hours of silence, and a thread to spend it in.
#[cfg(unix)]
fn framed_body_budget(len: usize) -> IoBudget {
    let by_rate = Duration::from_secs_f64(len as f64 / MIN_IPC_BODY_THROUGHPUT as f64);
    IoBudget::within(
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

/// How long a transfer may stall with the peer reading nothing at all.
/// Paired with `MIN_IPC_RESPONSE_RATE`, which is what stops a peer reading
/// just enough to look alive. Writing even a maximal request measures ~0.2s,
/// so neither bound is near what real traffic needs.
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
/// These run on worker threads rather than the helper's serve loop, which is
/// the point — one slow broker must not hold up the others. Within a single
/// broker, though, concurrency is not safe: two `acp/open` calls racing would
/// both find no live supervisor and both spawn one, and the rest mutate broker
/// state written assuming one caller at a time.
///
/// Mutual exclusion only. This does **not** order anything: a mutex is not
/// FIFO, so it says nothing about which of two waiting callers goes first.
/// Ordering comes from the per-broker queue in `dispatch_acp_job`, which is
/// what keeps a `session/cancel` from overtaking the `session/prompt` it was
/// sent to stop. This lock is the backstop for any path that reaches here
/// without going through that queue.
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

fn with_broker_lock<T>(broker_id: Option<&str>, body: impl FnOnce() -> T) -> T {
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
    // The id is copied out before locking so `params` can be *moved* into the
    // dispatch below. Borrowing it across the lock instead would force a clone,
    // and these payloads are the large ones — a maximal image prompt is ~267
    // MiB, and an `acp/respond` carrying a file read is unbounded.
    let broker_id = params
        .as_ref()
        .and_then(|params| params.get("brokerId"))
        .and_then(Value::as_str)
        .map(str::to_string);
    with_broker_lock(broker_id.as_deref(), || {
        dispatch_control_request(method, params)
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
    // Advertise framing here, before anything can connect, and stamp it with
    // this generation so it cannot be mistaken for a later broker's — see
    // `broker_supports_framing`.
    write_restrictive_bytes(
        &dir.join(IPC_FRAMING_MARKER),
        format!("{}\n", metadata.generation.value()).as_bytes(),
    )?;
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

/// How a transfer is bounded in time, in either direction.
///
/// An idle bound alone has a hole — a trickle satisfies it forever — so every
/// transfer with an arbitrary peer pairs one with a `Pace`. Which pace depends
/// on whether the amount is known in advance.
#[derive(Clone, Copy)]
struct IoBudget {
    /// Longest run with no bytes arriving.
    idle: Duration,
    pace: Pace,
}

impl IoBudget {
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
    fn new(budget: IoBudget) -> Self {
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

/// Largest amount handed to a single write. See `BudgetedWriter::write`.
#[cfg(unix)]
const IPC_WRITE_CHUNK_BYTES: usize = 64 * 1024;

/// How long a blocked read or write waits before its budget is re-checked.
/// Also the amount by which a transfer may overshoot.
#[cfg(unix)]
const IPC_IO_POLL_SLICE: Duration = Duration::from_millis(500);

/// Prepares a stream for the budgeted readers below.
///
/// The socket timeout is set once, to a short slice that just wakes a blocked
/// read periodically; the budget checked on each pass is what actually bounds
/// the read. Darwin returns `EINVAL` if the peer already closed, but that state
/// cannot block and may still have a complete response buffered, so it is safe
/// to continue without the timeout. (Re-arming the socket per read would hit
/// the same race mid-stream and turn an otherwise complete read into an error.)
///
/// One reader must be shared across a whole message: `BufReader` reads ahead,
/// so building a second one to read a frame body would discard bytes the first
/// had already pulled off the socket.
#[cfg(unix)]
fn ipc_reader(stream: &UnixStream) -> io::Result<BufReader<&UnixStream>> {
    match stream.set_read_timeout(Some(IPC_IO_POLL_SLICE)) {
        Ok(()) => {}
        #[cfg(target_os = "macos")]
        Err(error) if error.kind() == io::ErrorKind::InvalidInput => {}
        Err(error) => return Err(error),
    }
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
fn read_line_within(reader: &mut BufReader<&UnixStream>, budget: IoBudget) -> io::Result<String> {
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
    budget: IoBudget,
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
#[derive(Clone, Copy, Debug, PartialEq)]
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
/// because its pid is live: the session cannot be reopened at all.
///
/// Matched against the generation rather than the pid. A pid is recycled, so a
/// replacement can be handed the very number a stale marker names — unlikely,
/// but the failure it produces is an unreopenable session, and the generation
/// is a nanosecond stamp written by every build into `metadata.json`, so there
/// is nothing to trade for using it.
#[cfg(unix)]
fn broker_supports_framing(dir: &Path) -> bool {
    let Ok(marker) = std::fs::read_to_string(dir.join(IPC_FRAMING_MARKER)) else {
        return false;
    };
    let Ok(marked_generation) = marker.trim().parse::<u64>() else {
        return false;
    };
    read_broker_metadata(dir)
        .is_some_and(|metadata| metadata.generation.value() == marked_generation)
}

#[cfg(unix)]
fn read_broker_metadata(dir: &Path) -> Option<ACPBrokerMetadata> {
    serde_json::from_slice(&std::fs::read(dir.join("metadata.json")).ok()?).ok()
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
    head: IoBudget,
    body_for_len: fn(usize) -> IoBudget,
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
    // Refused before a byte of the body is read, so an outsized claim costs
    // nothing to turn away.
    if len > MAX_IPC_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("IPC frame length {len} exceeds {MAX_IPC_FRAME_BYTES}"),
        ));
    }
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
        /// Most connections served at once. See the accept loop below.
        ///
        /// Set for headroom rather than thrift: a helper serializes its calls
        /// per broker, so real use is a handful, while thread exhaustion needs
        /// thousands. Sitting between the two means a flood has to be
        /// deliberate to be felt, and even then it costs availability rather
        /// than the process.
        const MAX_BROKER_CONNECTION_WORKERS: usize = 256;

        let socket_path = dir.join("broker.sock");
        let _ = std::fs::remove_file(&socket_path);
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

        let inflight = Arc::new(AtomicUsize::new(0));
        let order = Arc::new(RequestOrder::default());
        while !runtime_is_closing(&runtime) {
            // Stop accepting rather than spawning without limit. Every
            // connection owns a thread that can sit for the whole head
            // timeout, so a peer opening sockets faster than they retire would
            // otherwise exhaust threads until `spawn` panics and takes the
            // supervisor with it. Leaving them in the kernel's backlog is
            // better than a bespoke rejection: a caller that cannot connect
            // sees the same refusal it already handles, and one that is merely
            // queued is served as soon as a worker frees up.
            //
            // Worth being clear about what this does and does not buy. A local
            // peer holding sockets open can still starve this broker for as
            // long as it keeps them, because a connection that has sent
            // nothing yet is indistinguishable from an older helper still
            // encoding its request — that is what the head's idle bound is
            // for. What the ceiling changes is the consequence: a bounded,
            // self-healing stall instead of a dead supervisor and every
            // session on it lost. Fixing the rest means not dedicating a
            // thread to a connection before it has said anything, which is a
            // different I/O model than this file uses.
            if inflight.load(Ordering::Acquire) >= MAX_BROKER_CONNECTION_WORKERS {
                std::thread::sleep(ACCEPT_POLL);
                continue;
            }
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
            let request_reservation = order.reserve();
            let request_inflight = Arc::clone(&inflight);
            request_inflight.fetch_add(1, Ordering::AcqRel);
            if std::thread::Builder::new()
                .spawn(move || {
                    let _ = handle_connection(request_runtime, stream, request_reservation);
                    request_inflight.fetch_sub(1, Ordering::AcqRel);
                })
                .is_err()
            {
                // Out of threads despite the ceiling. Drop the connection
                // rather than propagating: the caller retries, and the
                // supervisor stays up for the sessions it already has.
                inflight.fetch_sub(1, Ordering::AcqRel);
            }
        }

        // A `close` handler sets the closing flag before it replies, so the
        // loop can exit while that reply is still being written. Wait for it.
        let deadline = std::time::Instant::now() + DRAIN_TIMEOUT;
        while std::time::Instant::now() < deadline {
            if inflight.load(Ordering::Acquire) == 0 {
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

/// Hands out turns so requests reach the broker in the order they were
/// accepted, rather than in whatever order their threads happen to finish
/// reading or the scheduler happens to wake them.
///
/// One helper already orders its own calls per broker, but a broker outlives
/// the app that started it and more than one helper can adopt the same one —
/// two Alas builds side by side is ordinary here. Their requests arrive on
/// separate connections, and without this a later `session/cancel` can be
/// applied before the `session/prompt` it was sent to stop, the same silent
/// failure the helper's queue prevents within one process.
///
/// A place is reserved at accept and held only for `RESERVATION_GRACE`. That
/// split is the whole design. Ordering purely by acceptance would mean holding
/// a place across a read allowed to take minutes for a legacy sender still
/// encoding, letting one slow caller stall every other client of the broker —
/// reintroducing at the supervisor exactly what moving dispatch off the serve
/// loop removed at the helper. Ordering purely by arrival lets a small
/// `session/cancel` overtake the large `session/prompt` that was sent first,
/// which is the bug. A request that arrives promptly — a maximal prompt
/// crosses this socket in ~0.2s — keeps the place it was accepted in; one that
/// dawdles forfeits it and is ordered by arrival instead.
#[cfg(unix)]
#[derive(Default)]
struct RequestOrder {
    state: Mutex<OrderState>,
    turn: Condvar,
}

/// How long a reserved place is held for a request that has not arrived yet.
/// Far above what any request needs to cross the socket, far below the minutes
/// a legacy sender may spend encoding before it writes anything.
#[cfg(unix)]
const RESERVATION_GRACE: Duration = Duration::from_secs(5);

#[cfg(unix)]
#[derive(Default)]
struct OrderState {
    next: u64,
    serving: u64,
    /// Accepted but not yet arrived, with the instant each stops holding its
    /// place.
    pending: std::collections::BTreeMap<u64, std::time::Instant>,
    /// Arrived and waiting to run.
    ready: std::collections::BTreeSet<u64>,
    /// How many times a waiter has gone back round the loop. Only read by
    /// tests, where it is the difference between waiting and spinning.
    wakeups: u64,
}

#[cfg(unix)]
impl OrderState {
    /// When the queue could next move on its own, if it can.
    ///
    /// Only the reservation at the head has a deadline worth waking for:
    /// nothing behind it can advance anything, and a head that has already
    /// arrived is released by its turn dropping, which notifies. Taking the
    /// earliest deadline anywhere instead meant one expired reservation
    /// sitting behind a running request handed every waiter a deadline
    /// already in the past — so they woke, took the mutex, found `serving`
    /// unchanged, and did it again a millisecond later, for as long as the
    /// request took.
    fn head_deadline(&self) -> Option<std::time::Instant> {
        self.pending.get(&self.serving).copied()
    }

    /// Steps `serving` past every place that no longer has a claim on it:
    /// abandoned connections, and reservations whose grace has run out.
    fn advance(&mut self) {
        while self.serving < self.next {
            if self.ready.contains(&self.serving) {
                // Arrived and waiting — it runs next, so the queue stops here.
                break;
            }
            match self.pending.get(&self.serving) {
                Some(deadline) if std::time::Instant::now() < *deadline => break,
                Some(_) => {
                    self.pending.remove(&self.serving);
                    self.serving += 1;
                }
                // Neither pending nor ready: the connection went away.
                None => self.serving += 1,
            }
        }
    }
}

#[cfg(unix)]
impl RequestOrder {
    /// Takes a place in line for a connection that has just been accepted.
    fn reserve(self: &Arc<Self>) -> Reservation {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let ticket = state.next;
        state.next += 1;
        state
            .pending
            .insert(ticket, std::time::Instant::now() + RESERVATION_GRACE);
        Reservation {
            order: Arc::clone(self),
            ticket,
            claimed: false,
        }
    }
}

/// A place held for a request that has not arrived yet.
#[cfg(unix)]
struct Reservation {
    order: Arc<RequestOrder>,
    ticket: u64,
    claimed: bool,
}

#[cfg(unix)]
impl Reservation {
    /// The request has arrived. Waits for this place to come up and returns a
    /// guard that advances the queue when the request is done — on drop, so a
    /// panicking handler cannot stall every later request for this broker.
    fn claim(mut self) -> RequestTurn {
        self.claimed = true;
        let order = Arc::clone(&self.order);
        let mut state = order
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        // Forfeiture is decided by the deadline, not by whether another
        // thread has got round to advancing `serving` yet. Reading it off
        // `serving` made the answer depend on scheduling: a request claiming
        // just after its grace expired kept its place if nobody had woken to
        // notice, and lost it if someone had.
        let expired = state
            .pending
            .get(&self.ticket)
            .is_none_or(|deadline| std::time::Instant::now() >= *deadline);
        state.pending.remove(&self.ticket);
        // A place that has been given up cannot be waited for — it will not
        // come round again, so waiting on it is a deadlock rather than a
        // delay. Rejoin at the back instead.
        let ticket = if expired || state.serving > self.ticket {
            let ticket = state.next;
            state.next += 1;
            ticket
        } else {
            self.ticket
        };
        state.ready.insert(ticket);
        loop {
            state.advance();
            if state.serving == ticket {
                drop(state);
                return RequestTurn { order, ticket };
            }
            // Timed, because the head may be a reservation that has to be
            // waited out rather than woken: nothing signals a grace expiring.
            // Wait only as long as the soonest one actually has left, or a
            // waiter arriving late in a grace period sleeps a whole fresh one
            // past it — turning a 5s bound into nearly 10s.
            // A head that has arrived is woken by its turn dropping, so the
            // timeout is only a backstop against a missed notification.
            let wait = state.head_deadline().map_or(RESERVATION_GRACE, |deadline| {
                deadline
                    .saturating_duration_since(std::time::Instant::now())
                    .max(Duration::from_millis(1))
            });
            state.wakeups += 1;
            let (guard, _) = order
                .turn
                .wait_timeout(state, wait)
                .unwrap_or_else(|error| error.into_inner());
            state = guard;
        }
    }
}

#[cfg(unix)]
impl Drop for Reservation {
    fn drop(&mut self) {
        if self.claimed {
            return;
        }
        // The request never arrived — a failed read, or a peer that hung up.
        // Give the place back now rather than making everyone behind it wait
        // out a grace period for a connection that is already gone.
        let mut state = self
            .order
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        state.pending.remove(&self.ticket);
        state.ready.remove(&self.ticket);
        state.advance();
        self.order.turn.notify_all();
    }
}

#[cfg(unix)]
struct RequestTurn {
    order: Arc<RequestOrder>,
    ticket: u64,
}

#[cfg(unix)]
impl Drop for RequestTurn {
    fn drop(&mut self) {
        let mut state = self
            .order
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        state.ready.remove(&self.ticket);
        if state.serving == self.ticket {
            state.serving += 1;
        }
        state.advance();
        self.order.turn.notify_all();
    }
}

/// Reads one request off an accepted connection and answers it, in whichever
/// framing the caller used. Runs on its own thread, so a caller that is slow
/// to deliver its request costs only that thread.
#[cfg(unix)]
fn handle_connection(
    runtime: Runtime,
    stream: UnixStream,
    reservation: Reservation,
) -> io::Result<()> {
    // The reservation was taken in the accept loop, so the place reflects
    // when this connection was accepted rather than when its thread happened
    // to start — see `RequestOrder`.
    let (line, _framing) = {
        let mut reader = ipc_reader(&stream)?;
        read_ipc_message(&mut reader, IPC_REQUEST_HEAD_BUDGET, framed_body_budget)?
    };
    let _turn = reservation.claim();
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
    let mut writer = BufWriter::new(BudgetedWriter::new(
        &stream,
        IoBudget::at_least(BROKER_IPC_WRITE_TIMEOUT, MIN_IPC_RESPONSE_RATE),
    )?);
    serde_json::to_writer(&mut writer, &response).map_err(io::Error::other)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

/// Applies an `IoBudget` to a stream of writes.
///
/// Writes stay **blocking**, and the budget is enforced from outside by a
/// watchdog. That indirection is not for elegance — the two obvious
/// alternatives were both measured and both fail:
///
/// - A write timeout does nothing. `SO_SNDTIMEO` is not honoured for AF_UNIX
///   on Darwin: `set_write_timeout(300ms)` returns `Ok`, reads back as
///   `Some(300ms)`, and a write to a peer draining slowly has still not
///   returned twelve seconds later.
/// - Polling a non-blocking socket is correct but slow in a way that depends
///   on the machine. A 267 MiB reply fills the socket buffer ~34,000 times
///   even when the reader keeps up, and every fill has to be noticed:
///   sleeping on them measured 5.5s against 0.2s blocking, and yielding —
///   fast when the machine is quiet — degraded to tens of seconds under CPU
///   load, which is exactly when a broker can least afford it.
///
/// So the write blocks, the kernel does the waiting, and a watchdog closes the
/// socket under a write that has outstayed its budget.
#[cfg(unix)]
struct BudgetedWriter<'a> {
    stream: &'a UnixStream,
    clock: Arc<Mutex<BudgetClock>>,
    _watch: WriteWatch,
}

#[cfg(unix)]
impl<'a> BudgetedWriter<'a> {
    fn new(stream: &'a UnixStream, budget: IoBudget) -> io::Result<Self> {
        let clock = Arc::new(Mutex::new(BudgetClock::new(budget)));
        let watch = WriteWatch::arm(stream, Arc::clone(&clock))?;
        Ok(Self {
            stream,
            clock,
            _watch: watch,
        })
    }
}

#[cfg(unix)]
impl Write for BudgetedWriter<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        // Chunked, because a blocking AF_UNIX write on Darwin does not return
        // a partial count — it waits until the whole buffer is accepted.
        // Handing it a large reply in one call means no progress is reported
        // until the entire thing is through, so the budget sees `bytes = 0`
        // for as long as the peer cares to take, and only the idle bound ever
        // fires. Capping each call keeps progress observable without costing
        // anything measurable: a 267 MiB reply becomes ~4,200 writes.
        let buf = &buf[..buf.len().min(IPC_WRITE_CHUNK_BYTES)];
        match (&mut &*self.stream).write(buf) {
            Ok(written) => {
                self.clock
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .progressed(written);
                Ok(written)
            }
            // The watchdog unblocks a stalled write by closing the socket, so
            // the failure surfaces as a broken pipe. Reporting that verbatim
            // would send whoever reads the log looking for a peer that
            // disconnected, when what happened is that this peer stopped
            // reading. Say which it was.
            Err(error) => {
                if self
                    .clock
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .expired()
                {
                    return Err(BudgetClock::timed_out());
                }
                Err(error)
            }
        }
    }

    /// Flushing is the last thing either caller does, so a successful one
    /// means the reply is out and the watchdog must stop considering this
    /// socket — see the `done` check there.
    fn flush(&mut self) -> io::Result<()> {
        let flushed = (&mut &*self.stream).flush();
        if flushed.is_ok() {
            self._watch.done.store(true, Ordering::Release);
        }
        flushed
    }
}

/// A write currently being watched. Dropping it stops the watching.
#[cfg(unix)]
struct WriteWatch {
    id: u64,
    done: Arc<AtomicBool>,
}

#[cfg(unix)]
struct WatchedWrite {
    id: u64,
    stream: UnixStream,
    clock: Arc<Mutex<BudgetClock>>,
    done: Arc<AtomicBool>,
}

/// The watched set, and the single thread that polices it.
#[cfg(unix)]
fn watched_writes() -> &'static Mutex<Vec<WatchedWrite>> {
    static WATCHED: OnceLock<Mutex<Vec<WatchedWrite>>> = OnceLock::new();
    WATCHED.get_or_init(|| {
        let spawned = std::thread::Builder::new().spawn(|| {
            loop {
                std::thread::sleep(IPC_IO_POLL_SLICE);
                let watched = watched_writes()
                    .lock()
                    .unwrap_or_else(|error| error.into_inner());
                for write in watched.iter() {
                    // Finished writes are still registered for the moment it
                    // takes their guard to drop. Cutting one then would
                    // discard a reply that was already delivered in full,
                    // which is the opposite of the point.
                    if write.done.load(Ordering::Acquire) {
                        continue;
                    }
                    let expired = write
                        .clock
                        .lock()
                        .unwrap_or_else(|error| error.into_inner())
                        .expired();
                    if expired {
                        // Closing the socket is what unblocks the write: it
                        // returns an error and the handler unwinds. The peer
                        // sees the connection drop, which is the truthful
                        // thing to tell it.
                        let _ = write.stream.shutdown(std::net::Shutdown::Both);
                    }
                }
            }
        });
        // Without the thread nothing enforces the budget, but refusing to
        // write at all would be a worse answer than writing unpoliced.
        let _ = spawned;
        Mutex::new(Vec::new())
    })
}

#[cfg(unix)]
impl WriteWatch {
    fn arm(stream: &UnixStream, clock: Arc<Mutex<BudgetClock>>) -> io::Result<Self> {
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let stream = stream.try_clone()?;
        let done = Arc::new(AtomicBool::new(false));
        watched_writes()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(WatchedWrite {
                id,
                stream,
                clock,
                done: Arc::clone(&done),
            });
        Ok(Self { id, done })
    }
}

#[cfg(unix)]
impl Drop for WriteWatch {
    fn drop(&mut self) {
        watched_writes()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .retain(|write| write.id != self.id);
    }
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
        let stream = UnixStream::connect(dir.join("broker.sock"))
            .map_err(|error| broker_error(-32072, format!("broker connect failed: {error}")))?;
        // Without a bound, a broker that accepted the connection but never
        // answered would block this call forever.

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
        // Budgeted rather than relying on a socket write timeout, which Darwin
        // ignores for AF_UNIX (see `BudgetedWriter`). A broker that stopped
        // reading would otherwise hold this queue's thread forever, and with
        // it every later request for that broker.
        {
            let mut writer = BudgetedWriter::new(
                &stream,
                IoBudget::at_least(BROKER_IPC_WRITE_TIMEOUT, MIN_IPC_RESPONSE_RATE),
            )
            .map_err(|error| broker_error(-32072, format!("broker write setup: {error}")))?;
            write_ipc_message(&mut writer, &body, framing)
                .map_err(|error| broker_error(-32072, format!("broker write failed: {error}")))?;
        }
        // Bounded by inactivity, not total time: a reply's size — and so how
        // long it legitimately takes — is not something we can predict. What
        // can be asked of a broker is that it keep making progress.
        let (line, _) = {
            let mut reader = ipc_reader(&stream)
                .map_err(|error| broker_error(-32072, format!("broker read setup: {error}")))?;
            read_ipc_message(
                &mut reader,
                IoBudget::idle(idle_timeout),
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

    /// A fast broker can write its complete response and close before the
    /// caller installs its read timeout. Darwin reports `EINVAL` for that
    /// timeout setup, but the buffered response is still valid and readable.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_buffered_response_remains_readable_after_the_broker_closes() {
        let (mut broker, caller) = UnixStream::pair().expect("socket pair");
        broker.write_all(b"ready\n").expect("response");
        broker
            .shutdown(std::net::Shutdown::Both)
            .expect("broker closes");
        drop(broker);

        let mut reader = ipc_reader(&caller).expect("reader setup after broker close");
        let response = read_line_within(
            &mut reader,
            IoBudget::idle(Duration::from_secs(1)),
        )
        .expect("buffered response");

        assert_eq!(response, "ready\n");
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
        let line = read_line_within(&mut reader, IoBudget::idle(Duration::from_secs(1)))
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
            IoBudget::within(Duration::from_secs(2), Duration::from_secs(2)),
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
        fn write_metadata(dir: &Path, generation: u64) {
            let metadata = ACPBrokerMetadata {
                broker_id: BrokerId::new("marker-broker"),
                generation: BrokerGeneration::new(generation),
                alas_session_id: "marker-session".to_string(),
                adapter_program: "adapter".to_string(),
                adapter_args: vec![],
                cwd: "/tmp".to_string(),
                env_keys: vec![],
                created_at_millis: 0,
            };
            write_restrictive_json(&dir.join("metadata.json"), &metadata).expect("metadata");
        }

        let dir = PathBuf::from(format!("/tmp/alas-marker-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("marker dir");
        write_metadata(&dir, 1_000);

        assert!(
            !broker_supports_framing(&dir),
            "no marker should mean no framing"
        );

        std::fs::write(dir.join(IPC_FRAMING_MARKER), "1000\n").expect("marker");
        assert!(
            broker_supports_framing(&dir),
            "a marker written by the live broker should be trusted"
        );

        // Stands in for a broker replaced by one from an earlier build: the
        // marker survives its cleanup, but the generation moved on. Matching
        // on the pid instead would let this through whenever the replacement
        // happened to be handed the same pid.
        write_metadata(&dir, 2_000);
        assert!(
            !broker_supports_framing(&dir),
            "a marker from a replaced broker must not be trusted"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Bounding writes must not cost throughput on the writes that matter.
    ///
    /// Polling a non-blocking socket means noticing every time the buffer
    /// fills, which for a large reply to a reader that is keeping up happens
    /// tens of thousands of times. Sleeping on each is ruinous — measured at
    /// 5.5s for 267 MiB against 0.2s blocking, and hours at a full poll slice
    /// — so the loop yields before it sleeps. The bound here is loose on
    /// purpose: it is meant to catch that class of regression, not to police
    /// timing on a shared machine.
    #[cfg(unix)]
    #[test]
    fn a_large_reply_to_a_keeping_up_reader_is_not_slowed_by_the_budget() {
        let (writer, mut reader) = UnixStream::pair().expect("socket pair");
        let payload = vec![b'w'; 64 * 1024 * 1024];
        let expected = payload.len();
        let drain = std::thread::spawn(move || {
            let mut buf = vec![0u8; 256 * 1024];
            let mut total = 0usize;
            while total < expected {
                match std::io::Read::read(&mut reader, &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => total += read,
                }
            }
            total
        });

        let mut budgeted = BudgetedWriter::new(
            &writer,
            IoBudget::at_least(BROKER_IPC_WRITE_TIMEOUT, MIN_IPC_RESPONSE_RATE),
        )
        .expect("budgeted writer");
        let started = std::time::Instant::now();
        budgeted.write_all(&payload).expect("large reply");
        budgeted.flush().expect("flush");
        let elapsed = started.elapsed();
        drop(budgeted);
        drop(writer);
        assert_eq!(drain.join().expect("drain"), expected);

        assert!(
            elapsed < Duration::from_secs(10),
            "budgeted writes collapsed throughput: 64 MiB took {elapsed:?}"
        );
    }

    /// An advertised length is refused before any of the body is read, so a
    /// peer cannot make the broker hold gigabytes simply by claiming them.
    /// The rate bound does not cover this: a peer delivering at the required
    /// rate is retained byte for byte, and time was never what ran out.
    #[cfg(unix)]
    #[test]
    fn an_oversized_declared_frame_is_refused_before_its_body_is_read() {
        let (mut writer, reader) = UnixStream::pair().expect("socket pair");
        let oversized = MAX_IPC_FRAME_BYTES + 1;
        std::thread::spawn(move || {
            // Header only. If the length were accepted this would block
            // forever waiting for a body that never comes.
            let _ = writeln!(writer, "{IPC_FRAME_HEADER}{oversized}");
            let _ = writer.flush();
            std::thread::sleep(Duration::from_secs(30));
        });

        let mut reader = ipc_reader(&reader).expect("reader");
        let started = std::time::Instant::now();
        let error = read_ipc_message(&mut reader, IPC_REQUEST_HEAD_BUDGET, framed_body_budget)
            .expect_err("an outsized declared length must be refused");
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "refusal should not wait on the body: {:?}",
            started.elapsed()
        );
    }

    /// A request keeps the place it was accepted in, even when a later one
    /// finishes arriving first.
    ///
    /// This is the `session/cancel` overtaking `session/prompt` case: the
    /// prompt is large and slower to cross the socket, the cancel is tiny.
    /// Ordering by arrival applies the cancel to a turn that has not started,
    /// after which the prompt runs uncancelled and the user believes they
    /// stopped it.
    #[cfg(unix)]
    #[test]
    fn an_earlier_accepted_request_runs_first_even_if_it_arrives_second() {
        let order = Arc::new(RequestOrder::default());
        let observed = Arc::new(Mutex::new(Vec::new()));

        // Accepted first: the slow, large one.
        let first = order.reserve();
        // Accepted second: the small one that will arrive well before it.
        let second = order.reserve();

        let quick = {
            let observed = Arc::clone(&observed);
            std::thread::spawn(move || {
                let _turn = second.claim();
                observed
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .push("second");
            })
        };

        // Long enough that the second request is unambiguously waiting, and
        // well inside the grace the first one is holding.
        std::thread::sleep(Duration::from_millis(300));
        {
            let _turn = first.claim();
            observed
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .push("first");
        }
        quick.join().expect("second worker");

        let observed = observed.lock().unwrap_or_else(|error| error.into_inner());
        assert_eq!(*observed, vec!["first", "second"]);
    }

    /// Forfeiture must follow the deadline, not whichever thread happened to
    /// run first. Deciding it from `serving` meant a request claiming just
    /// after its grace expired kept its place when nobody had yet woken to
    /// notice, and lost it when someone had — the same request, two answers,
    /// depending on the scheduler.
    #[cfg(unix)]
    #[test]
    fn forfeiture_follows_the_deadline_not_the_scheduler() {
        let order = Arc::new(RequestOrder::default());
        let stale = order.reserve();

        // Let its grace lapse with nobody waiting, so nothing has advanced
        // `serving` past it.
        std::thread::sleep(RESERVATION_GRACE + Duration::from_millis(200));

        // Reserved after the lapse, so this one still holds a live place.
        let fresh = order.reserve();
        {
            let state = order.state.lock().expect("state");
            assert_eq!(
                state.serving, 0,
                "nothing should have advanced the queue while no one was waiting"
            );
        }

        // The stale one now arrives. Its place is gone by the clock, so it
        // must go behind the request that was still holding a live place.
        let observed = Arc::new(Mutex::new(Vec::new()));
        let watcher = {
            let observed = Arc::clone(&observed);
            std::thread::spawn(move || {
                let _turn = stale.claim();
                observed
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .push("stale");
            })
        };
        std::thread::sleep(Duration::from_millis(200));
        {
            let _turn = fresh.claim();
            observed
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .push("fresh");
        }
        watcher.join().expect("stale worker");

        let observed = observed.lock().unwrap_or_else(|error| error.into_inner());
        assert_eq!(*observed, vec!["fresh", "stale"]);
    }

    /// A waiter behind a running request must sleep, not spin.
    ///
    /// Waking for the earliest deadline anywhere meant an expired reservation
    /// sitting behind a running request handed every waiter a deadline already
    /// in the past. They woke on the one-millisecond floor, took the mutex,
    /// found `serving` unchanged and went round again — for as long as the
    /// request ran, across as many threads as were waiting.
    #[cfg(unix)]
    #[test]
    fn a_waiter_behind_a_running_request_does_not_spin() {
        let order = Arc::new(RequestOrder::default());
        let running = order.reserve().claim();
        // Sits behind the running request and lapses while it works.
        let _stalled = order.reserve();
        let queued = order.reserve();

        let waiter = std::thread::spawn(move || {
            let _turn = queued.claim();
        });

        // Let the reservation behind the head expire.
        std::thread::sleep(RESERVATION_GRACE + Duration::from_millis(200));
        let before = {
            let state = order.state.lock().expect("state");
            state.wakeups
        };
        // A window in which nothing can legitimately move: the head is still
        // running, so any wakeup here is wasted work.
        std::thread::sleep(Duration::from_millis(600));
        let after = {
            let state = order.state.lock().expect("state");
            state.wakeups
        };

        drop(running);
        waiter.join().expect("waiter");

        assert!(
            after - before <= 2,
            "waiter spun {} times while the head was running",
            after - before
        );
    }

    /// A waiter must wake when the place ahead of it actually expires, not a
    /// full grace later. Waiting a fresh interval each time turns a five
    /// second bound into nearly ten for anything that arrives late in one.
    #[cfg(unix)]
    #[test]
    fn a_waiter_wakes_when_the_place_ahead_expires_not_a_grace_later() {
        let order = Arc::new(RequestOrder::default());
        let abandoned = order.reserve();
        let waiting = order.reserve();

        // Arrive most of the way through the grace ahead of us.
        std::thread::sleep(RESERVATION_GRACE.mul_f64(0.8));
        let started = std::time::Instant::now();
        {
            let _turn = waiting.claim();
        }
        let waited = started.elapsed();
        drop(abandoned);

        assert!(
            waited < RESERVATION_GRACE.mul_f64(0.6),
            "waited past the deadline ahead of it: {waited:?}"
        );
    }

    /// A request that arrives after its grace has run out must still be
    /// served. Its place is gone by then, so it rejoins at the back — waiting
    /// for a turn that has already passed is a deadlock, and a legacy sender
    /// allowed minutes to encode reaches exactly this path.
    #[cfg(unix)]
    #[test]
    fn a_request_arriving_after_its_grace_still_gets_a_turn() {
        let order = Arc::new(RequestOrder::default());
        let slow = order.reserve();

        // Someone accepted later goes ahead once the grace lapses.
        let next = order.reserve();
        {
            let _turn = next.claim();
        }

        // The slow one now arrives, long past its place. It must run, not hang.
        let started = std::time::Instant::now();
        let ran = std::thread::spawn(move || {
            let _turn = slow.claim();
        });
        // Generous: the point is that it finishes at all.
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        while !ran.is_finished() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            ran.is_finished(),
            "a request that outlived its reservation never got a turn after {:?}",
            started.elapsed()
        );
        ran.join().expect("slow worker");
    }

    /// A reserved place is held only for a grace period, so a caller that
    /// never delivers cannot stall everyone accepted after it. That bound is
    /// what makes reserving at accept affordable at all: a legacy sender is
    /// allowed minutes to encode before it writes, and nobody can be made to
    /// wait that out.
    #[cfg(unix)]
    #[test]
    fn a_reservation_that_never_arrives_stops_holding_its_place() {
        let order = Arc::new(RequestOrder::default());
        let abandoned = order.reserve();
        let next = order.reserve();

        // Never claimed, and deliberately not dropped either — this stands in
        // for a connection still being read from, not one that went away.
        let started = std::time::Instant::now();
        {
            let _turn = next.claim();
        }
        let waited = started.elapsed();
        drop(abandoned);

        assert!(
            waited >= RESERVATION_GRACE,
            "the place should be held for its grace: {waited:?}"
        );
        assert!(
            waited < RESERVATION_GRACE * 3,
            "the place should be forfeited once grace passes, not held on: {waited:?}"
        );
    }

    /// A peer that drains a reply slowly must not be able to hold its handler
    /// open indefinitely. Enough such peers hold every connection worker, and
    /// unlike a flood of idle connections — which lapses on its own — these
    /// never do, so the broker would not recover.
    ///
    /// The peer here keeps reading, just far below the rate asked of it, which
    /// is the case neither an idle bound nor a socket write timeout can catch:
    /// it is always making progress, and every partial write looks healthy.
    #[cfg(unix)]
    #[test]
    fn a_peer_that_drains_a_reply_slowly_does_not_hold_its_handler_open() {
        let (writer, mut reader) = UnixStream::pair().expect("socket pair");
        let done = Arc::new(Mutex::new(false));
        let reader_done = done.clone();
        std::thread::spawn(move || {
            // ~320 KiB/s: fast enough that writes keep completing, far short
            // of the megabytes per second demanded below.
            let mut chunk = vec![0u8; 32 * 1024];
            while !*reader_done.lock().expect("drain flag") {
                if std::io::Read::read(&mut reader, &mut chunk).is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        });

        let mut budgeted = BudgetedWriter::new(
            &writer,
            IoBudget::at_least(Duration::from_secs(120), 4 * 1024 * 1024),
        )
        .expect("budgeted writer");
        let payload = vec![b'r'; 64 * 1024 * 1024];
        let started = std::time::Instant::now();
        let outcome = budgeted.write_all(&payload);
        *done.lock().expect("drain flag") = true;

        let error = outcome.expect_err("a reply drained below the required rate must be cut");
        assert_eq!(
            error.kind(),
            io::ErrorKind::TimedOut,
            "the cause should say the peer was too slow, not that the pipe broke"
        );
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "the rate bound took too long to notice: {:?}",
            started.elapsed()
        );
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
                IoBudget::at_least(Duration::from_secs(30), 64 * 1024),
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
            IoBudget::within(Duration::from_secs(2), Duration::from_secs(2)),
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
        let line = read_line_within(&mut reader, IoBudget::idle(Duration::from_secs(30)))
            .expect("large line");
        assert_eq!(line.len(), expected + 1);
    }
}
