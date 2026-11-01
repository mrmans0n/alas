//! Drives Cua Driver (`cua-driver mcp --direct`), the computer-use backend inside a Linux VM, over
//! MCP: newline-delimited JSON-RPC on the child's stdin and stdout. The child is spawned on first
//! use, kept for later calls, and replaced on the next call after it exits or a call times out.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

/// Where guest setup installs the driver; `LinuxGuestSetup.cuaDriverPath` in AlasCore.
pub const PROGRAM: &str = "/usr/local/bin/cua-driver";
const PROTOCOL_VERSION: &str = "2025-06-18";
/// For the `initialize` handshake, separate from any call's own timeout.
const INIT_TIMEOUT: Duration = Duration::from_secs(10);
/// How long `available` trusts its last answer: a working driver for a while, a missing one only
/// briefly, since a first start or a desktop session that isn't up yet fails only for now.
const PROBE_TTL: Duration = Duration::from_secs(30);
const UNAVAILABLE_PROBE_TTL: Duration = Duration::from_secs(2);
/// The driver's stderr kept in `$CUA_HOME/driver.log` per spawn.
const LOG_LIMIT: u64 = 1024 * 1024;

#[derive(Clone)]
pub struct CuaConfig {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

impl CuaConfig {
    /// The installed driver in MCP mode, pointed at the user's Xfce session.
    pub fn for_session() -> Self {
        let uid = unsafe { libc::getuid() };
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
        Self {
            program: PathBuf::from(PROGRAM),
            args: vec!["mcp".to_string(), "--direct".to_string()],
            env: session_env(Path::new("/proc"), uid, &home),
        }
    }
}

/// The driver's environment for `uid`'s desktop: `DISPLAY` and `XAUTHORITY` from the environment
/// of that user's `xfce4-session` under `proc_root`, each falling back on its own to `:0` and
/// `~/.Xauthority`.
pub fn session_env(proc_root: &Path, uid: u32, home: &Path) -> Vec<(String, String)> {
    let session = xfce_session_environ(proc_root, uid).unwrap_or_default();
    let display = session
        .get("DISPLAY")
        .cloned()
        .unwrap_or_else(|| ":0".to_string());
    let xauthority = session
        .get("XAUTHORITY")
        .cloned()
        .unwrap_or_else(|| home.join(".Xauthority").to_string_lossy().into_owned());
    let cua_home = home.join(".local/state/alas-cua");
    [
        ("DISPLAY", display),
        ("XAUTHORITY", xauthority),
        (
            "DBUS_SESSION_BUS_ADDRESS",
            format!("unix:path=/run/user/{uid}/bus"),
        ),
        ("CUA_DRIVER_RS_UPDATE_CHECK", "false".to_string()),
        ("DO_NOT_TRACK", "1".to_string()),
        ("CUA_TELEMETRY", "0".to_string()),
        ("CUA_HOME", cua_home.to_string_lossy().into_owned()),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_string(), value))
    .collect()
}

/// The environment of the first `xfce4-session` whose real uid is `uid`.
fn xfce_session_environ(proc_root: &Path, uid: u32) -> Option<HashMap<String, String>> {
    fs::read_dir(proc_root)
        .ok()?
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().parse::<u32>().is_ok())
        .map(|entry| entry.path())
        .filter(|dir| {
            fs::read_to_string(dir.join("comm"))
                .is_ok_and(|comm| comm.trim_end() == "xfce4-session")
        })
        .filter(|dir| real_uid(&dir.join("status")) == Some(uid))
        .find_map(|dir| fs::read(dir.join("environ")).ok())
        .map(|environ| {
            environ
                .split(|byte| *byte == 0)
                .filter_map(|entry| {
                    let entry = String::from_utf8_lossy(entry);
                    let (key, value) = entry.split_once('=')?;
                    Some((key.to_string(), value.to_string()))
                })
                .collect()
        })
}

/// The real uid on the `Uid:` line of a `/proc/<pid>/status`.
fn real_uid(status: &Path) -> Option<u32> {
    fs::read_to_string(status)
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
}

/// A `tools/call` result. A JSON-RPC error answer is a result too, with `is_error` set, the
/// error's message as `text` and its `{code, message}` as `structured`.
#[derive(Debug, Clone, PartialEq)]
pub struct CuaResult {
    pub is_error: bool,
    /// `structuredContent`, or null.
    pub structured: Value,
    /// The text content items, one per line.
    pub text: String,
    /// The first PNG image content item.
    pub image_png_base64: Option<String>,
}

impl CuaResult {
    pub(crate) fn from_response(response: &Value) -> Self {
        let Some(result) = response.get("result") else {
            let message = response
                .pointer("/error/message")
                .and_then(Value::as_str)
                .unwrap_or("the driver answered without a result");
            let code = response
                .pointer("/error/code")
                .cloned()
                .unwrap_or(Value::Null);
            return Self {
                is_error: true,
                structured: json!({"code": code, "message": message}),
                text: message.to_string(),
                image_png_base64: None,
            };
        };
        let content = result
            .get("content")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        let of_type = |kind: &'static str| {
            content
                .iter()
                .filter(move |item| item.get("type").and_then(Value::as_str) == Some(kind))
        };
        Self {
            is_error: result.get("isError").and_then(Value::as_bool) == Some(true),
            structured: result
                .get("structuredContent")
                .cloned()
                .unwrap_or(Value::Null),
            text: of_type("text")
                .filter_map(|item| item.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n"),
            image_png_base64: of_type("image")
                .find(|item| item.get("mimeType").and_then(Value::as_str) == Some("image/png"))
                .and_then(|item| item.get("data").and_then(Value::as_str))
                .map(str::to_string),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CuaError {
    /// The driver couldn't be started or didn't finish the MCP handshake.
    Unavailable(String),
    /// The call had no answer in time. The driver was killed; the next call starts another.
    Timeout,
    /// The driver exited before answering. The next call starts another.
    Exited,
}

/// What the stdout reader thread passes on.
enum Incoming {
    Message(Value),
    Closed,
}

/// A running, initialized driver.
struct Process {
    child: Child,
    stdin: ChildStdin,
    incoming: Receiver<Incoming>,
    next_id: u64,
}

impl Process {
    fn spawn(config: &CuaConfig) -> Result<Self, CuaError> {
        let mut command = Command::new(&config.program);
        command
            .args(&config.args)
            .envs(config.env.iter().map(|(key, value)| (key, value)))
            .env_remove("CUA_DRIVER_EMBEDDED")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Its own process group, so a kill also ends anything it started.
            .process_group(0);
        let mut child = command.spawn().map_err(|error| {
            CuaError::Unavailable(format!(
                "couldn't start {}: {error}",
                config.program.display()
            ))
        })?;
        let (sender, incoming) = mpsc::channel();
        read_messages(child.stdout.take(), sender);
        log_stderr(child.stderr.take(), driver_log(config));
        let stdin = child.stdin.take().expect("stdin is piped");
        let mut process = Self {
            child,
            stdin,
            incoming,
            next_id: 0,
        };
        let initialized = process
            .request(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "alas-vm-guest-linux", "version": env!("CARGO_PKG_VERSION")},
                }),
                INIT_TIMEOUT,
            )
            .and_then(|response| match response.get("error") {
                Some(error) => Err(CuaError::Unavailable(format!(
                    "initialize failed: {error}"
                ))),
                None => process.send(&json!({
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                })),
            });
        match initialized {
            Ok(()) => Ok(process),
            // Dropping the process kills it.
            Err(error) => Err(match error {
                CuaError::Unavailable(reason) => CuaError::Unavailable(reason),
                CuaError::Timeout => {
                    CuaError::Unavailable("the driver didn't answer initialize".to_string())
                }
                CuaError::Exited => {
                    CuaError::Unavailable("the driver exited during initialize".to_string())
                }
            }),
        }
    }

    /// Sends a request and waits for the answer with its id. A request from the driver gets a
    /// method-not-found error; other lines that aren't the answer, such as notifications, are
    /// skipped.
    fn request(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, CuaError> {
        self.next_id += 1;
        let id = self.next_id;
        self.send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))?;
        let deadline = Instant::now() + timeout;
        loop {
            match self
                .incoming
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            {
                // A server-to-client request has a method and may reuse the id. This client
                // offers no capabilities, so it answers none of them.
                Ok(Incoming::Message(message))
                    if message.get("method").is_some() && message.get("id").is_some() =>
                {
                    self.send(&json!({
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "error": {"code": -32601, "message": "Method not found"},
                    }))?;
                }
                Ok(Incoming::Message(message)) if message.get("id") == Some(&json!(id)) => {
                    return Ok(message);
                }
                Ok(Incoming::Message(_)) => {}
                Ok(Incoming::Closed) | Err(RecvTimeoutError::Disconnected) => {
                    return Err(CuaError::Exited);
                }
                Err(RecvTimeoutError::Timeout) => return Err(CuaError::Timeout),
            }
        }
    }

    fn send(&mut self, message: &Value) -> Result<(), CuaError> {
        let mut line = message.to_string();
        line.push('\n');
        self.stdin
            .write_all(line.as_bytes())
            .and_then(|()| self.stdin.flush())
            .map_err(|_| CuaError::Exited)
    }

    fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    /// Kills the driver's process group and reaps it. A leader that was already reaped is left
    /// alone, since its pid may belong to someone else by now.
    fn kill(&mut self) {
        if !matches!(self.child.try_wait(), Ok(None)) {
            return;
        }
        // The unreaped leader keeps its pid, the group id, from being reused until the wait.
        unsafe { libc::killpg(self.child.id() as libc::pid_t, libc::SIGKILL) };
        let _ = self.child.wait();
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        self.kill();
    }
}

/// Parses each stdout line that is JSON and passes it on; the driver logs other lines there too.
fn read_messages(stdout: Option<impl Read + Send + 'static>, sender: Sender<Incoming>) {
    thread::spawn(move || {
        if let Some(stdout) = stdout {
            let mut reader = BufReader::new(stdout);
            let mut line = Vec::new();
            loop {
                line.clear();
                match reader.read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if let Ok(message) = serde_json::from_slice::<Value>(&line)
                            && sender.send(Incoming::Message(message)).is_err()
                        {
                            return;
                        }
                    }
                }
            }
        }
        let _ = sender.send(Incoming::Closed);
    });
}

/// `$CUA_HOME/driver.log`, when the driver's environment names a `CUA_HOME`.
fn driver_log(config: &CuaConfig) -> Option<PathBuf> {
    let (_, home) = config.env.iter().find(|(key, _)| key == "CUA_HOME")?;
    Some(Path::new(home).join("driver.log"))
}

/// Writes the first `LOG_LIMIT` bytes of the driver's stderr to `path`, and drains the rest so the
/// driver never blocks on a full pipe. The previous driver's log moves to `driver.log.1`, so a
/// crash's stderr outlives the respawn.
fn log_stderr(stderr: Option<impl Read + Send + 'static>, path: Option<PathBuf>) {
    let Some(mut stderr) = stderr else { return };
    thread::spawn(move || {
        let log = path.and_then(|path| {
            fs::create_dir_all(path.parent()?).ok()?;
            let _ = fs::rename(&path, path.with_extension("log.1"));
            File::create(path).ok()
        });
        if let Some(log) = log {
            let _ = std::io::copy(&mut (&mut stderr).take(LOG_LIMIT), &mut { log });
        }
        let _ = std::io::copy(&mut stderr, &mut std::io::sink());
    });
}

/// The helper's handle on Cua Driver. Nothing starts until the first `call` or `available`.
pub struct CuaDriver {
    /// Builds each spawn's config, so a respawn sees the desktop session as it is then.
    config: Box<dyn FnMut() -> CuaConfig + Send>,
    process: Option<Process>,
    /// When `available` last answered, and its answer.
    probe: Option<(Instant, bool)>,
}

impl CuaDriver {
    pub fn new(config: impl FnMut() -> CuaConfig + Send + 'static) -> Self {
        Self {
            config: Box::new(config),
            process: None,
            probe: None,
        }
    }

    /// Calls an MCP tool, starting the driver first if none is running. `timeout` covers the call
    /// alone: starting the driver and its `initialize` handshake are bounded by their own timeout
    /// first.
    pub fn call(
        &mut self,
        tool: &str,
        args: Value,
        timeout: Duration,
    ) -> Result<CuaResult, CuaError> {
        let process = self.process()?;
        match process.request(
            "tools/call",
            json!({"name": tool, "arguments": args}),
            timeout,
        ) {
            Ok(response) => Ok(CuaResult::from_response(&response)),
            Err(error) => {
                // Dropping it kills it: a timed-out driver may answer late, so it's never reused.
                self.process = None;
                Err(error)
            }
        }
    }

    /// Whether the driver starts and completes the MCP handshake. A yes is kept for `PROBE_TTL`,
    /// a no for `UNAVAILABLE_PROBE_TTL`.
    pub fn available(&mut self) -> bool {
        if let Some((at, available)) = self.probe
            && at.elapsed()
                < if available {
                    PROBE_TTL
                } else {
                    UNAVAILABLE_PROBE_TTL
                }
        {
            return available;
        }
        let available = self.process().is_ok();
        self.probe = Some((Instant::now(), available));
        available
    }

    /// The running driver, started if there is none or the last one exited.
    fn process(&mut self) -> Result<&mut Process, CuaError> {
        if let Some(process) = &mut self.process
            && !process.is_running()
        {
            self.process = None;
        }
        if self.process.is_none() {
            self.process = Some(Process::spawn(&(self.config)())?);
        }
        Ok(self.process.as_mut().expect("just started"))
    }

    #[cfg(test)]
    fn pid(&self) -> Option<u32> {
        self.process.as_ref().map(|process| process.child.id())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    /// A fresh directory under the system temp dir, removed when dropped.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "alas-cua-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// A driver backed by `tests/fake_cua.py` running `script`.
    fn fake_driver(dir: &TempDir, script: Value) -> CuaDriver {
        let script_path = dir.0.join("script.json");
        fs::write(&script_path, script.to_string()).unwrap();
        let config = CuaConfig {
            program: PathBuf::from("python3"),
            args: vec![
                concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_cua.py").to_string(),
                script_path.to_string_lossy().into_owned(),
            ],
            env: vec![(
                "CUA_HOME".to_string(),
                dir.0.join("cua").to_string_lossy().into_owned(),
            )],
        };
        CuaDriver::new(move || config.clone())
    }

    fn text_result(text: &str) -> Value {
        json!({"content": [{"type": "text", "text": text}], "structuredContent": {}})
    }

    const TIMEOUT: Duration = Duration::from_secs(10);

    #[test]
    fn call_round_trips_structured_content_text_and_image() {
        let dir = TempDir::new();
        let mut driver = fake_driver(
            &dir,
            json!({"tools": {
                "get_window_state": [{
                    "content": [
                        {"type": "text", "text": "Mousepad"},
                        {"type": "image", "data": "iVBORw0K", "mimeType": "image/png"},
                        {"type": "text", "text": "640x480"}
                    ],
                    "structuredContent": {"window_id": 39845891, "screenshot_width": 640}
                }],
                "click": [{
                    "content": [{"type": "text", "text": "stale window"}],
                    "isError": true,
                    "structuredContent": "$arguments"
                }]
            }}),
        );

        let state = driver
            .call("get_window_state", json!({"pid": 1}), TIMEOUT)
            .unwrap();
        assert_eq!(
            state,
            CuaResult {
                is_error: false,
                structured: json!({"window_id": 39845891, "screenshot_width": 640}),
                text: "Mousepad\n640x480".to_string(),
                image_png_base64: Some("iVBORw0K".to_string()),
            }
        );

        let click = driver
            .call("click", json!({"x": 1, "y": 2}), TIMEOUT)
            .unwrap();
        assert!(click.is_error);
        assert_eq!(click.structured, json!({"x": 1, "y": 2}));
        assert_eq!(click.text, "stale window");
        assert_eq!(click.image_png_base64, None);
    }

    #[test]
    fn json_rpc_error_answer_carries_its_code_and_message() {
        let result = CuaResult::from_response(&json!({
            "jsonrpc": "2.0", "id": 3,
            "error": {"code": -32602, "message": "unknown tool: nope"}
        }));
        assert_eq!(
            result,
            CuaResult {
                is_error: true,
                structured: json!({"code": -32602, "message": "unknown tool: nope"}),
                text: "unknown tool: nope".to_string(),
                image_png_base64: None,
            }
        );
    }

    #[test]
    fn driver_crash_respawns_on_next_call() {
        let dir = TempDir::new();
        let mut driver = fake_driver(
            &dir,
            json!({"tools": {"list_apps": [text_result("apps")]}, "crash_on_call": 1}),
        );

        assert_eq!(
            driver.call("list_apps", json!({}), TIMEOUT),
            Err(CuaError::Exited)
        );
        assert_eq!(
            driver.call("list_apps", json!({}), TIMEOUT).unwrap().text,
            "apps"
        );
    }

    #[test]
    fn driver_requests_get_method_not_found() {
        let dir = TempDir::new();
        let mut driver = fake_driver(
            &dir,
            json!({"tools": {"list_apps": [text_result("apps")]}, "server_request_on": "list_apps"}),
        );

        let answer = driver.call("list_apps", json!({}), TIMEOUT).unwrap();

        // The id the driver used, which is the call's, the one after `initialize`.
        assert_eq!(answer.structured["id"], 2);
        assert_eq!(answer.structured["error"]["code"], -32601);
    }

    #[test]
    fn hung_call_times_out() {
        let dir = TempDir::new();
        let mut driver = fake_driver(
            &dir,
            json!({"tools": {"list_apps": [text_result("apps")]}, "hang_on": "wait"}),
        );
        assert!(driver.available());
        let hung = driver.pid().unwrap();

        let started = Instant::now();
        assert_eq!(
            driver.call("wait", json!({}), Duration::from_millis(300)),
            Err(CuaError::Timeout)
        );
        assert!(started.elapsed() < Duration::from_secs(1));
        // The hung process is gone, not left running beside its replacement.
        assert_ne!(unsafe { libc::kill(hung as libc::pid_t, 0) }, 0);

        assert_eq!(
            driver.call("list_apps", json!({}), TIMEOUT).unwrap().text,
            "apps"
        );
        assert_ne!(driver.pid(), Some(hung));
    }

    #[test]
    fn missing_program_is_unavailable() {
        let mut driver = CuaDriver::new(|| CuaConfig {
            program: PathBuf::from("/nonexistent/cua-driver"),
            args: vec![],
            env: vec![],
        });
        assert!(!driver.available());
        assert!(matches!(
            driver.call("list_apps", json!({}), TIMEOUT),
            Err(CuaError::Unavailable(_))
        ));
    }

    /// A driver that failed to start, say before the desktop session was up, is tried again
    /// soon after, not only once a working answer would expire.
    #[test]
    fn unavailable_answer_is_kept_only_briefly() {
        let dir = TempDir::new();
        let working = fake_driver(&dir, json!({"tools": {}}));
        let installed = Arc::new(AtomicBool::new(false));
        let mut working_config = working.config;
        let config = {
            let installed = Arc::clone(&installed);
            move || {
                if installed.load(Ordering::SeqCst) {
                    working_config()
                } else {
                    CuaConfig {
                        program: PathBuf::from("/nonexistent/cua-driver"),
                        args: vec![],
                        env: vec![],
                    }
                }
            }
        };
        let mut driver = CuaDriver::new(config);
        assert!(!driver.available());
        installed.store(true, Ordering::SeqCst);
        let aged = |age: u64| {
            Some((
                Instant::now()
                    .checked_sub(Duration::from_secs(age))
                    .unwrap(),
                false,
            ))
        };

        driver.probe = aged(1);
        assert!(!driver.available());

        driver.probe = aged(3);
        assert!(driver.available());
    }

    #[test]
    fn session_env_prefers_xfce_session_environ() {
        let proc_root = TempDir::new();
        let add = |pid: u32, comm: &str, uid: u32, environ: &[&str]| {
            let dir = proc_root.0.join(pid.to_string());
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("comm"), format!("{comm}\n")).unwrap();
            fs::write(
                dir.join("status"),
                format!("Name:\t{comm}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"),
            )
            .unwrap();
            fs::write(dir.join("environ"), environ.join("\0") + "\0").unwrap();
        };
        add(
            100,
            "xfce4-session",
            1001,
            &["DISPLAY=:9", "XAUTHORITY=/other"],
        );
        add(200, "bash", 1000, &["DISPLAY=:5"]);
        add(
            300,
            "xfce4-session",
            1000,
            &["HOME=/home/u", "DISPLAY=:1", "XAUTHORITY=/run/x"],
        );
        fs::create_dir_all(proc_root.0.join("self")).unwrap();
        let home = Path::new("/home/u");

        let env = session_env(&proc_root.0, 1000, home);
        let get = |env: &[(String, String)], key: &str| {
            env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
        };
        assert_eq!(get(&env, "DISPLAY").as_deref(), Some(":1"));
        assert_eq!(get(&env, "XAUTHORITY").as_deref(), Some("/run/x"));
        assert_eq!(
            get(&env, "DBUS_SESSION_BUS_ADDRESS").as_deref(),
            Some("unix:path=/run/user/1000/bus")
        );
        assert_eq!(
            get(&env, "CUA_HOME").as_deref(),
            Some("/home/u/.local/state/alas-cua")
        );

        // No session of this user: the fallbacks.
        let env = session_env(&proc_root.0, 1002, home);
        assert_eq!(get(&env, "DISPLAY").as_deref(), Some(":0"));
        assert_eq!(
            get(&env, "XAUTHORITY").as_deref(),
            Some("/home/u/.Xauthority")
        );
    }
}
