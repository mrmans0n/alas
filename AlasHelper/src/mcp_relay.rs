//! Built-in Alas MCP relay for SSH sessions (`visual_show`, `pr_create`,
//! `pr_status`).
//!
//! A remote agent runs `alas-helper mcp-proxy` as a stdio MCP server. For
//! every frame the proxy resolves the record's current route from the remote
//! session registry, then does one framed exchange over that route's private
//! Unix socket. The `serve` helper that owns the route forwards the opaque
//! frame to the app as an `mcp/request` notification and replies with whatever
//! the app completes it with. Neither side interprets MCP payloads beyond the
//! JSON-RPC envelope identity needed to answer a failed request.

use crate::remote_sessions::{
    McpRouteReader, RemoteSessionError, RemoteSessionFence, RemoteSessionStore, now,
};
use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, Read, Write};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::{Duration, Instant};

pub const RELAY_PROTOCOL_VERSION: u32 = 1;
/// Largest raw MCP frame in either direction, excluding a line terminator.
pub const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;
const MAGIC: &[u8] = b"ALASMCP1 ";
/// `MAX_FRAME_BYTES` has seven digits; one spare still rejects by value.
const MAX_HEADER_BYTES: usize = MAGIC.len() + 8;
const HEADER_TIMEOUT: Duration = Duration::from_secs(5);
const BODY_TIMEOUT: Duration = Duration::from_secs(10);
/// Slightly longer than the app's slowest local transport deadline, the
/// 120 seconds `alas mcp` gives `pr_create`.
const COMPLETION_TIMEOUT: Duration = Duration::from_secs(130);
const PROXY_REPLY_TIMEOUT: Duration = Duration::from_secs(135);
const MAX_IN_FLIGHT_PER_RECORD: usize = 2;
const MAX_IN_FLIGHT: usize = 8;
const MAX_PROXY_IN_FLIGHT: usize = 4;
const UNAVAILABLE: &str = "Alas relay unavailable; the call's outcome is unknown";
/// Darwin's `sun_path` holds 104 bytes including the terminating NUL.
const MAX_SOCKET_PATH_BYTES: usize = 103;

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

fn error(code: i64, message: &str) -> RemoteSessionError {
    RemoteSessionError {
        code,
        message: message.into(),
    }
}

// MARK: Framing

/// Writes `ALASMCP1 <length>\n<bytes>` in one call.
pub fn write_frame(writer: &mut impl Write, body: &[u8]) -> io::Result<()> {
    if body.len() > MAX_FRAME_BYTES {
        return Err(invalid("visual relay frame exceeds the size limit"));
    }
    let mut frame = Vec::with_capacity(MAX_HEADER_BYTES + 1 + body.len());
    frame.extend_from_slice(MAGIC);
    frame.extend_from_slice(body.len().to_string().as_bytes());
    frame.push(b'\n');
    frame.extend_from_slice(body);
    writer.write_all(&frame)?;
    writer.flush()
}

/// Reads and validates a frame header, rejecting an over-limit length before
/// anything is allocated for its body.
pub fn read_frame_len(reader: &mut impl Read) -> io::Result<usize> {
    let mut header = Vec::with_capacity(MAX_HEADER_BYTES);
    let mut byte = [0u8; 1];
    loop {
        match reader.read(&mut byte) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
        if byte[0] == b'\n' {
            break;
        }
        if header.len() == MAX_HEADER_BYTES {
            return Err(invalid("visual relay frame header is too long"));
        }
        header.push(byte[0]);
    }
    let digits = header
        .strip_prefix(MAGIC)
        .ok_or_else(|| invalid("not a visual relay frame"))?;
    if digits.is_empty()
        || !digits.iter().all(u8::is_ascii_digit)
        || (digits.len() > 1 && digits[0] == b'0')
    {
        return Err(invalid("invalid visual relay frame length"));
    }
    let length: usize = std::str::from_utf8(digits)
        .ok()
        .and_then(|digits| digits.parse().ok())
        .ok_or_else(|| invalid("invalid visual relay frame length"))?;
    if length > MAX_FRAME_BYTES {
        return Err(invalid("visual relay frame exceeds the size limit"));
    }
    Ok(length)
}

pub fn read_frame(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let length = read_frame_len(reader)?;
    read_frame_body(reader, length)
}

fn read_frame_body(reader: &mut impl Read, length: usize) -> io::Result<Vec<u8>> {
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    Ok(body)
}

/// Reads from a socket until an absolute deadline, so a peer trickling bytes
/// cannot stretch a read past its budget.
struct DeadlineReader<'a> {
    stream: &'a UnixStream,
    until: Instant,
}
impl Read for DeadlineReader<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let remaining = self.until.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::ErrorKind::TimedOut.into());
        }
        // macOS rejects socket options once the peer has closed; the read
        // then returns immediately anyway, so a failure here is harmless.
        let _ = self.stream.set_read_timeout(Some(remaining));
        (&mut &*self.stream).read(buf)
    }
}

fn read_socket_frame(stream: &UnixStream, header_timeout: Duration) -> io::Result<Vec<u8>> {
    let mut reader = DeadlineReader {
        stream,
        until: Instant::now() + header_timeout,
    };
    let length = read_frame_len(&mut reader)?;
    reader.until = Instant::now() + BODY_TIMEOUT;
    read_frame_body(&mut reader, length)
}

// MARK: Envelope identity

/// The id a reply must carry, or `None` when the frame expects no reply (a
/// notification, or a response to a server request). Unparseable frames are
/// answered like JSON-RPC parse errors, with a null id.
pub fn reply_id(frame: &[u8]) -> Option<Value> {
    match serde_json::from_slice::<Value>(frame) {
        Ok(Value::Object(envelope)) if envelope.contains_key("method") => {
            envelope.get("id").cloned()
        }
        Ok(Value::Object(envelope)) if envelope.contains_key("id") => None,
        _ => Some(Value::Null),
    }
}

fn error_reply(id: Value, code: i64, message: &str) -> Vec<u8> {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
        .to_string()
        .into_bytes()
}

pub fn unavailable_reply(id: Value) -> Vec<u8> {
    error_reply(id, -32000, UNAVAILABLE)
}

// MARK: Private sockets

fn random_hex(bytes: usize) -> io::Result<String> {
    let mut buffer = vec![0u8; bytes];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut buffer)?;
    Ok(buffer.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn verify_private_dir(dir: &Path) -> io::Result<()> {
    let metadata = std::fs::symlink_metadata(dir)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "visual relay socket directory is not private",
        ));
    }
    Ok(())
}

/// Checks a route's socket before connecting: an absolute socket, owned by
/// this user, directly inside a private directory owned by this user.
pub fn check_private_socket(path: &Path) -> io::Result<()> {
    let parent = path
        .parent()
        .filter(|_| path.is_absolute())
        .ok_or_else(|| invalid("visual relay socket path is not absolute"))?;
    verify_private_dir(parent)?;
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.file_type().is_socket() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "visual relay socket is not private",
        ));
    }
    Ok(())
}

struct PrivateSocket {
    dir: PathBuf,
    path: PathBuf,
}
impl PrivateSocket {
    /// Binds a fresh listener under a newly created 0700 directory with a
    /// random name. Paths are never derived from records or state roots, so
    /// they stay short and are never reused by a later registration.
    fn bind() -> io::Result<(UnixListener, Self)> {
        let base = [std::env::temp_dir(), PathBuf::from("/tmp")]
            .into_iter()
            .find(|base| {
                base.is_absolute()
                    && base.as_os_str().len() + "/alas-mcp-0123456789abcdef/s".len()
                        <= MAX_SOCKET_PATH_BYTES
            })
            .ok_or_else(|| invalid("no temporary directory fits a Unix socket path"))?;
        for _ in 0..8 {
            let dir = base.join(format!("alas-mcp-{}", random_hex(8)?));
            match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
            let socket = Self {
                path: dir.join("s"),
                dir,
            };
            verify_private_dir(&socket.dir)?;
            let listener = UnixListener::bind(&socket.path)?;
            std::fs::set_permissions(&socket.path, std::fs::Permissions::from_mode(0o600))?;
            return Ok((listener, socket));
        }
        Err(io::ErrorKind::AlreadyExists.into())
    }
}
impl Drop for PrivateSocket {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_dir(&self.dir);
    }
}

// MARK: Serve-side relay

/// One registration's identity, shared by its accept loop and workers.
struct Route {
    record_id: String,
    relay_id: String,
    fence_token: String,
    closed: AtomicBool,
}

struct Registration {
    route: Arc<Route>,
    socket: PrivateSocket,
}

enum Completion {
    Response(Vec<u8>),
    Ack,
    Error { code: i64, message: String },
}

struct Pending {
    route: Arc<Route>,
    sender: mpsc::SyncSender<Completion>,
}

#[derive(Default)]
struct InFlight {
    total: usize,
    per_record: HashMap<String, usize>,
}

/// Releases an in-flight slot when its exchange ends, however it ends.
struct Permit {
    inner: Arc<Inner>,
    record_id: String,
}
impl Drop for Permit {
    fn drop(&mut self) {
        let mut in_flight = self.inner.in_flight.lock().unwrap();
        in_flight.total -= 1;
        if let Some(count) = in_flight.per_record.get_mut(&self.record_id) {
            *count -= 1;
            if *count == 0 {
                in_flight.per_record.remove(&self.record_id);
            }
        }
    }
}

struct Inner {
    state_root: PathBuf,
    emit: Box<dyn Fn(String) + Send + Sync>,
    reader: Mutex<Option<McpRouteReader>>,
    registrations: Mutex<HashMap<String, Registration>>,
    pending: Mutex<HashMap<String, Pending>>,
    in_flight: Mutex<InFlight>,
    request_prefix: String,
    next_request: AtomicU64,
}

/// The `serve` side of the relay: registrations, their listeners, and the
/// exchanges waiting on the app. Waits run on worker threads, never on the
/// serve loop; `emit` hands a notification line to the serialized writer.
pub struct McpRelay {
    inner: Arc<Inner>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RouteParams {
    fence: RemoteSessionFence,
    relay_id: String,
}

impl McpRelay {
    pub fn new(state_root: PathBuf, emit: impl Fn(String) + Send + Sync + 'static) -> Self {
        Self {
            inner: Arc::new(Inner {
                state_root,
                emit: Box::new(emit),
                reader: Mutex::new(None),
                registrations: Mutex::new(HashMap::new()),
                pending: Mutex::new(HashMap::new()),
                in_flight: Mutex::new(InFlight::default()),
                request_prefix: random_hex(8)
                    .unwrap_or_else(|_| format!("{:x}", std::process::id())),
                next_request: AtomicU64::new(0),
            }),
        }
    }

    pub fn handle(
        &self,
        store: &mut RemoteSessionStore,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, RemoteSessionError> {
        match method {
            "mcp/register" => self.register(store, decode(params)?),
            "mcp/complete" => self.complete(store, params),
            "mcp/unregister" => self.unregister(store, decode(params)?),
            _ => Err(error(-32601, "Unknown visual relay method")),
        }
    }

    fn register(
        &self,
        store: &mut RemoteSessionStore,
        p: RouteParams,
    ) -> Result<Value, RemoteSessionError> {
        if p.relay_id.is_empty()
            || p.relay_id.len() > 128
            || !p
                .relay_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
        {
            return Err(error(-32602, "Invalid visual relay ID"));
        }
        let state_dir = self
            .inner
            .state_root
            .to_str()
            .filter(|_| self.inner.state_root.is_absolute())
            .ok_or_else(|| error(-32080, "Remote state directory is not absolute"))?
            .to_string();
        let proxy_command = proxy_command()
            .ok_or_else(|| error(-32080, "Cannot locate the helper executable"))?;
        let unavailable = |_| error(-32000, "Cannot create the visual relay socket");
        let (listener, socket) = PrivateSocket::bind().map_err(unavailable)?;
        let socket_path = socket
            .path
            .to_str()
            .ok_or_else(|| error(-32000, "Cannot create the visual relay socket"))?
            .to_string();
        let route = Arc::new(Route {
            record_id: p.fence.record_id.clone(),
            relay_id: p.relay_id.clone(),
            fence_token: p.fence.token.clone(),
            closed: AtomicBool::new(false),
        });
        let registration = Registration {
            route: route.clone(),
            socket,
        };
        let inner = self.inner.clone();
        std::thread::Builder::new()
            .spawn(move || accept_loop(inner, listener, route))
            .map_err(|_| error(-32000, "Cannot start the visual relay listener"))?;
        // The listener is live before its path is published; a failed
        // publication closes it again without ever exposing it.
        if let Err(failure) = store.register_mcp_route(&p.fence, &p.relay_id, &socket_path, now())
        {
            self.inner.close(registration);
            return Err(failure);
        }
        let previous = self
            .inner
            .registrations
            .lock()
            .unwrap()
            .insert(p.fence.record_id.clone(), registration);
        if let Some(previous) = previous {
            self.inner.close(previous);
        }
        Ok(json!({
            "recordId": p.fence.record_id,
            "relayId": p.relay_id,
            "proxyCommand": proxy_command,
            "proxyArgs": ["mcp-proxy", "--state-dir", state_dir, "--record-id", p.fence.record_id],
            "relayProtocolVersion": RELAY_PROTOCOL_VERSION,
        }))
    }

    fn complete(
        &self,
        store: &mut RemoteSessionStore,
        params: Option<Value>,
    ) -> Result<Value, RemoteSessionError> {
        let malformed = || error(-32602, "Invalid visual relay completion");
        let params = params.ok_or_else(malformed)?;
        let object = params.as_object().ok_or_else(malformed)?;
        let fence: RemoteSessionFence = object
            .get("fence")
            .and_then(|fence| serde_json::from_value(fence.clone()).ok())
            .ok_or_else(malformed)?;
        let relay_id = object
            .get("relayId")
            .and_then(Value::as_str)
            .ok_or_else(malformed)?;
        let request_id = object
            .get("requestId")
            .and_then(Value::as_str)
            .ok_or_else(malformed)?;
        let completion = match (object.get("responseBase64"), object.get("error")) {
            (Some(Value::Null), None) => Completion::Ack,
            (Some(Value::String(encoded)), None) => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(encoded)
                    .map_err(|_| malformed())?;
                if bytes.is_empty() || bytes.len() > MAX_FRAME_BYTES {
                    return Err(malformed());
                }
                Completion::Response(bytes)
            }
            (None, Some(Value::Object(failure))) => Completion::Error {
                code: failure
                    .get("code")
                    .and_then(Value::as_i64)
                    .ok_or_else(malformed)?,
                message: failure
                    .get("message")
                    .and_then(Value::as_str)
                    .ok_or_else(malformed)?
                    .to_string(),
            },
            _ => return Err(malformed()),
        };
        let matches = |pending: &Pending| {
            pending.route.record_id == fence.record_id
                && pending.route.relay_id == relay_id
                && pending.route.fence_token == fence.token
        };
        if let Err(failure) = store.validate_mcp_route(&fence, relay_id, now()) {
            // Its authority is gone for good, so the exchange can never be
            // completed legitimately: fail it now instead of at its deadline.
            let mut pending = self.inner.pending.lock().unwrap();
            if pending.get(request_id).is_some_and(matches) {
                pending.remove(request_id);
            }
            return Err(failure);
        }
        let pending = {
            let mut pending = self.inner.pending.lock().unwrap();
            if !pending.get(request_id).is_some_and(matches) {
                return Err(error(-32000, "Unknown or expired visual relay request"));
            }
            pending.remove(request_id).expect("matched pending request")
        };
        pending
            .sender
            .try_send(completion)
            .map_err(|_| error(-32000, "Unknown or expired visual relay request"))?;
        Ok(json!({"ok": true}))
    }

    fn unregister(
        &self,
        store: &mut RemoteSessionStore,
        p: RouteParams,
    ) -> Result<Value, RemoteSessionError> {
        // Local resources go regardless of remote authority, but only this
        // exact registration's: a stale unregister cannot close a newer one.
        let mine = {
            let mut registrations = self.inner.registrations.lock().unwrap();
            let owned = registrations.get(&p.fence.record_id).is_some_and(|r| {
                r.route.relay_id == p.relay_id && r.route.fence_token == p.fence.token
            });
            owned
                .then(|| registrations.remove(&p.fence.record_id))
                .flatten()
        };
        if let Some(registration) = mine {
            self.inner.close(registration);
        }
        store.unregister_mcp_route(&p.fence, &p.relay_id, now())?;
        Ok(json!({"ok": true}))
    }

    /// Closes every listener this relay owns and fails every waiting exchange.
    pub fn shutdown(&self) {
        let registrations: Vec<_> = self
            .inner
            .registrations
            .lock()
            .unwrap()
            .drain()
            .map(|(_, registration)| registration)
            .collect();
        for registration in registrations {
            self.inner.close(registration);
        }
        self.inner.pending.lock().unwrap().clear();
    }
}

impl Drop for McpRelay {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn decode<T: serde::de::DeserializeOwned>(params: Option<Value>) -> Result<T, RemoteSessionError> {
    serde_json::from_value(params.unwrap_or(json!({})))
        .map_err(|_| error(-32602, "Invalid visual relay parameters"))
}

/// The absolute path a retained proxy descriptor should run.
fn proxy_command() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    // Linux reports a replaced executable as "<path> (deleted)"; the path
    // itself is what an upgraded installation still provides.
    let exe = exe
        .to_str()
        .and_then(|path| path.strip_suffix(" (deleted)"))
        .map(PathBuf::from)
        .unwrap_or(exe);
    let exe = std::fs::canonicalize(&exe).unwrap_or(exe);
    exe.is_absolute().then(|| exe.to_str().map(str::to_string))?
}

impl Inner {
    fn close(&self, registration: Registration) {
        registration.route.closed.store(true, Ordering::SeqCst);
        // Wake the accept loop so it notices and drops the listener.
        let _ = UnixStream::connect(&registration.socket.path);
        self.pending
            .lock()
            .unwrap()
            .retain(|_, pending| !Arc::ptr_eq(&pending.route, &registration.route));
        // Dropping the socket unlinks only this registration's own path.
        drop(registration);
    }

    fn acquire(self: &Arc<Self>, record_id: &str) -> Option<Permit> {
        let mut in_flight = self.in_flight.lock().unwrap();
        let record = in_flight.per_record.get(record_id).copied().unwrap_or(0);
        if in_flight.total >= MAX_IN_FLIGHT || record >= MAX_IN_FLIGHT_PER_RECORD {
            return None;
        }
        in_flight.total += 1;
        in_flight.per_record.insert(record_id.to_string(), record + 1);
        Some(Permit {
            inner: self.clone(),
            record_id: record_id.to_string(),
        })
    }

    fn route_is_current(&self, route: &Route) -> bool {
        let mut reader = self.reader.lock().unwrap();
        if reader.is_none() {
            *reader = McpRouteReader::open(&self.state_root).ok();
        }
        let current = reader.as_ref().map(|reader| {
            reader.validate_mcp_route(&route.record_id, &route.relay_id, &route.fence_token, now())
        });
        match current {
            Some(Ok(current)) => current,
            _ => {
                *reader = None;
                false
            }
        }
    }

    fn exchange(&self, stream: UnixStream, route: &Arc<Route>) {
        let Ok(frame) = read_socket_frame(&stream, HEADER_TIMEOUT) else {
            return;
        };
        let reply_to = reply_id(&frame);
        let completion = self.forward(route, &frame);
        let reply = match (reply_to, completion) {
            (None, _) => Vec::new(),
            (Some(_), Some(Completion::Response(bytes))) => bytes,
            (Some(id), Some(Completion::Error { code, message })) => {
                error_reply(id, code, &message)
            }
            (Some(id), Some(Completion::Ack) | None) => unavailable_reply(id),
        };
        let _ = stream.set_write_timeout(Some(BODY_TIMEOUT));
        let _ = write_frame(&mut &stream, &reply);
    }

    fn forward(&self, route: &Arc<Route>, frame: &[u8]) -> Option<Completion> {
        if route.closed.load(Ordering::SeqCst) || !self.route_is_current(route) {
            return None;
        }
        let request_id = format!(
            "{}-{}",
            self.request_prefix,
            self.next_request.fetch_add(1, Ordering::Relaxed)
        );
        let (sender, receiver) = mpsc::sync_channel(1);
        self.pending.lock().unwrap().insert(
            request_id.clone(),
            Pending {
                route: route.clone(),
                sender,
            },
        );
        // `close` marks the route before clearing its waiters, so either it
        // removed this entry or the mark is already visible here.
        if route.closed.load(Ordering::SeqCst) {
            self.pending.lock().unwrap().remove(&request_id);
            return None;
        }
        (self.emit)(
            json!({
                "jsonrpc": "2.0",
                "method": "mcp/request",
                "params": {
                    "requestId": request_id,
                    "recordId": route.record_id,
                    "relayId": route.relay_id,
                    "frameBase64": base64::engine::general_purpose::STANDARD.encode(frame),
                }
            })
            .to_string(),
        );
        // A dropped sender (unregister, replacement, shutdown) ends the wait.
        let completion = receiver.recv_timeout(COMPLETION_TIMEOUT).ok();
        self.pending.lock().unwrap().remove(&request_id);
        completion
    }
}

fn accept_loop(inner: Arc<Inner>, listener: UnixListener, route: Arc<Route>) {
    for stream in listener.incoming() {
        if route.closed.load(Ordering::SeqCst) {
            return;
        }
        let Ok(stream) = stream else {
            // Typically descriptor exhaustion; back off instead of spinning.
            std::thread::sleep(Duration::from_millis(50));
            continue;
        };
        // Over capacity, the connection closes unanswered and the proxy
        // reports the relay unavailable: no queue, no unbounded threads.
        let Some(permit) = inner.acquire(&route.record_id) else {
            continue;
        };
        let worker_inner = inner.clone();
        let worker_route = route.clone();
        let _ = std::thread::Builder::new().spawn(move || {
            let _permit = permit;
            worker_inner.exchange(stream, &worker_route);
        });
    }
}

// MARK: Proxy

/// One stdin line: a frame, an over-limit line already discarded, or EOF.
#[derive(Debug, PartialEq)]
pub enum Line {
    Frame(Vec<u8>),
    Oversized,
    Eof,
}

/// Reads a newline-terminated line holding at most `max` bytes besides its
/// terminator. Longer lines are consumed and dropped while buffering at most
/// one sentinel byte past the limit (which also leaves room for a CR).
pub fn read_bounded_line(reader: &mut impl BufRead, max: usize) -> io::Result<Line> {
    let mut line = Vec::new();
    let mut oversized = false;
    let mut started = false;
    loop {
        let buffer = match reader.fill_buf() {
            Ok(buffer) => buffer,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if buffer.is_empty() {
            return Ok(match (started, oversized) {
                (false, _) => Line::Eof,
                (true, true) => Line::Oversized,
                (true, false) if line.len() > max => Line::Oversized,
                (true, false) => Line::Frame(line),
            });
        }
        started = true;
        let newline = buffer.iter().position(|&b| b == b'\n');
        let chunk = &buffer[..newline.unwrap_or(buffer.len())];
        if !oversized {
            if line.len() + chunk.len() > max + 1 {
                oversized = true;
                line = Vec::new();
            } else {
                line.extend_from_slice(chunk);
            }
        }
        let consumed = newline.map_or(buffer.len(), |index| index + 1);
        reader.consume(consumed);
        if newline.is_some() {
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            return Ok(if oversized || line.len() > max {
                Line::Oversized
            } else {
                Line::Frame(line)
            });
        }
    }
}

struct Proxy {
    state_root: PathBuf,
    record_id: String,
    reader: Mutex<Option<McpRouteReader>>,
    stdout: Mutex<io::Stdout>,
    in_flight: (Mutex<usize>, Condvar),
}

impl Proxy {
    /// Resolves the record's route anew for every frame: a replacement owner
    /// may publish a new route while this process stays alive.
    fn resolve(&self) -> Option<PathBuf> {
        let mut reader = self.reader.lock().unwrap();
        if reader.is_none() {
            *reader = McpRouteReader::open(&self.state_root).ok();
        }
        match reader.as_ref()?.resolve_mcp_route(&self.record_id, now()) {
            Ok(route) => route.map(|route| PathBuf::from(route.socket_path)),
            Err(_) => {
                *reader = None;
                None
            }
        }
    }

    /// One exchange, sent at most once. `Ok` holds the raw reply bytes.
    fn exchange(&self, frame: &[u8]) -> io::Result<Vec<u8>> {
        let path = self
            .resolve()
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
        check_private_socket(&path)?;
        let stream = UnixStream::connect(&path)?;
        stream.set_write_timeout(Some(BODY_TIMEOUT))?;
        write_frame(&mut &stream, frame)?;
        read_socket_frame(&stream, PROXY_REPLY_TIMEOUT)
    }

    fn forward(&self, frame: Vec<u8>) {
        let Some(id) = reply_id(&frame) else {
            let _ = self.exchange(&frame);
            return;
        };
        let reply = match self.exchange(&frame) {
            Ok(mut reply) => {
                while matches!(reply.last(), Some(b'\n' | b'\r')) {
                    reply.pop();
                }
                // An empty or multi-line reply cannot stand in for this
                // request's one-line response.
                if reply.is_empty() || reply.contains(&b'\n') {
                    unavailable_reply(id)
                } else {
                    reply
                }
            }
            Err(_) => {
                eprintln!("alas-helper mcp-proxy: {UNAVAILABLE}");
                unavailable_reply(id)
            }
        };
        self.write_line(&reply);
    }

    fn write_line(&self, line: &[u8]) {
        let mut stdout = self.stdout.lock().unwrap();
        let _ = stdout
            .write_all(line)
            .and_then(|()| stdout.write_all(b"\n"))
            .and_then(|()| stdout.flush());
    }

    fn acquire(&self) {
        let (count, ready) = &self.in_flight;
        let mut count = count.lock().unwrap();
        while *count >= MAX_PROXY_IN_FLIGHT {
            count = ready.wait(count).unwrap();
        }
        *count += 1;
    }

    fn release(&self) {
        let (count, ready) = &self.in_flight;
        *count.lock().unwrap() -= 1;
        ready.notify_all();
    }

    fn drain(&self) {
        let (count, ready) = &self.in_flight;
        let mut count = count.lock().unwrap();
        while *count > 0 {
            count = ready.wait(count).unwrap();
        }
    }
}

fn parse_proxy_args(args: impl Iterator<Item = String>) -> Option<(PathBuf, String)> {
    let mut state_dir = None;
    let mut record_id = None;
    let mut args = args;
    while let Some(flag) = args.next() {
        let slot = match flag.as_str() {
            "--state-dir" => &mut state_dir,
            "--record-id" => &mut record_id,
            _ => return None,
        };
        if slot.replace(args.next()?).is_some() {
            return None;
        }
    }
    let state_dir = PathBuf::from(state_dir?);
    let record_id = record_id?;
    let valid_record = !record_id.is_empty()
        && record_id.len() <= 128
        && record_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    (state_dir.is_absolute() && valid_record).then_some((state_dir, record_id))
}

/// `alas-helper mcp-proxy --state-dir <absolute> --record-id <id>`: a stdio
/// MCP server that forwards each frame to the record's current relay route.
/// Returns the process exit code.
pub fn proxy_main(args: impl Iterator<Item = String>) -> i32 {
    let Some((state_root, record_id)) = parse_proxy_args(args) else {
        eprintln!("usage: alas-helper mcp-proxy --state-dir <absolute-path> --record-id <id>");
        return 2;
    };
    let proxy = Arc::new(Proxy {
        state_root,
        record_id,
        reader: Mutex::new(None),
        stdout: Mutex::new(io::stdout()),
        in_flight: (Mutex::new(0), Condvar::new()),
    });
    let mut stdin = io::stdin().lock();
    loop {
        match read_bounded_line(&mut stdin, MAX_FRAME_BYTES) {
            Ok(Line::Eof) | Err(_) => break,
            Ok(Line::Oversized) => {
                eprintln!("alas-helper mcp-proxy: discarded a frame over the 4 MiB limit");
            }
            Ok(Line::Frame(frame)) => {
                if frame.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                proxy.acquire();
                let worker = proxy.clone();
                let spawned = std::thread::Builder::new().spawn(move || {
                    worker.forward(frame);
                    worker.release();
                });
                if spawned.is_err() {
                    // The closure, and the frame with it, is gone; it was
                    // never sent, so nothing was delivered twice.
                    proxy.release();
                    eprintln!("alas-helper mcp-proxy: could not start a relay worker");
                }
            }
        }
    }
    proxy.drain();
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Hands out at most `step` bytes per read, like a fragmented socket.
    struct Trickle<'a> {
        data: &'a [u8],
        step: usize,
    }
    impl Read for Trickle<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let n = self.step.min(buf.len()).min(self.data.len());
            buf[..n].copy_from_slice(&self.data[..n]);
            self.data = &self.data[n..];
            Ok(n)
        }
    }

    fn framed(body: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        write_frame(&mut out, body).unwrap();
        out
    }

    #[test]
    fn frames_round_trip_opaque_bytes_through_fragmented_reads() {
        let html = "<p title='\"quoted\"'>caf\u{e9} \u{1F600}\u{0}\u{7}\t\r\n</p> /.alas-remote/example/srv/repo";
        let body = json!({"jsonrpc":"2.0","id":"x","method":"tools/call","params":{"html":html}})
            .to_string()
            .into_bytes();
        for step in [1, 3, 4096] {
            let wire = framed(&body);
            let decoded = read_frame(&mut Trickle { data: &wire, step }).unwrap();
            assert_eq!(decoded, body);
            let value: Value = serde_json::from_slice(&decoded).unwrap();
            assert_eq!(value["params"]["html"], html);
        }
    }

    #[test]
    fn frame_limit_is_exact_and_checked_before_allocation() {
        let max = vec![b'a'; MAX_FRAME_BYTES];
        assert_eq!(read_frame(&mut framed(&max).as_slice()).unwrap().len(), MAX_FRAME_BYTES);
        assert!(write_frame(&mut Vec::new(), &[b'a'; MAX_FRAME_BYTES + 1]).is_err());
        let over = format!("ALASMCP1 {}\n", MAX_FRAME_BYTES + 1);
        // No body follows: a reader that allocated first would hit EOF, not
        // InvalidData.
        for header in [over.as_str(), "ALASMCP1 99999999999999999999\n", "ALASMCP1 -1\n", "ALASMCP2 1\n", "ALASMCP1 01\n"] {
            let failure = read_frame(&mut header.as_bytes()).unwrap_err();
            assert_eq!(failure.kind(), io::ErrorKind::InvalidData, "{header:?}");
        }
        assert_eq!(read_frame(&mut "ALASMCP1 0\n".as_bytes()).unwrap(), b"");
    }

    #[test]
    fn bounded_lines_accept_the_limit_and_discard_longer_lines() {
        let input = [
            vec![b'a'; 8],
            b"\r\n".to_vec(),
            vec![b'b'; 9],
            b"\n{}".to_vec(),
        ]
        .concat();
        let mut reader = io::BufReader::with_capacity(3, input.as_slice());
        assert_eq!(read_bounded_line(&mut reader, 8).unwrap(), Line::Frame(vec![b'a'; 8]));
        assert_eq!(read_bounded_line(&mut reader, 8).unwrap(), Line::Oversized);
        assert_eq!(read_bounded_line(&mut reader, 8).unwrap(), Line::Frame(b"{}".to_vec()));
        assert_eq!(read_bounded_line(&mut reader, 8).unwrap(), Line::Eof);
    }

    #[test]
    fn reply_id_preserves_the_original_id_type() {
        for (frame, expected) in [
            (r#"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#, Some(json!(7))),
            (r#"{"jsonrpc":"2.0","id":"7","method":"tools/call"}"#, Some(json!("7"))),
            (r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, None),
            (r#"{"jsonrpc":"2.0","id":3,"result":{}}"#, None),
            ("not json", Some(Value::Null)),
        ] {
            assert_eq!(reply_id(frame.as_bytes()), expected, "{frame}");
        }
    }
}
