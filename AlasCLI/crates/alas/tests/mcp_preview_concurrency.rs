use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

enum ServerEvent {
    Wait { release: mpsc::Sender<()> },
    Cancel,
}

struct FakeAlas {
    socket: PathBuf,
    events: mpsc::Receiver<ServerEvent>,
    stop: mpsc::Sender<()>,
    handle: Option<thread::JoinHandle<()>>,
}

impl Drop for FakeAlas {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        let _ = std::fs::remove_file(&self.socket);
    }
}

fn start_fake_alas(test_name: &str) -> FakeAlas {
    let socket = PathBuf::from(format!(
        "/tmp/alas-mcp-{test_name}-{}-{}.sock",
        std::process::id(),
        line!()
    ));
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let (events_tx, events_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    let handle = thread::spawn(move || {
        loop {
            if stop_rx.try_recv().is_ok() {
                return;
            }
            match listener.accept() {
                Ok((stream, _)) => {
                    let events_tx = events_tx.clone();
                    thread::spawn(move || handle_fake_connection(stream, events_tx));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5));
                }
                Err(_) => return,
            }
        }
    });
    FakeAlas {
        socket,
        events: events_rx,
        stop: stop_tx,
        handle: Some(handle),
    }
}

fn handle_fake_connection(mut stream: UnixStream, events_tx: mpsc::Sender<ServerEvent>) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let read = stream.read(&mut chunk).unwrap();
        if read == 0 {
            return;
        }
        buf.extend_from_slice(&chunk[..read]);
        if serde_json::from_slice::<Value>(&buf).is_ok() {
            break;
        }
    }
    let request: Value = serde_json::from_slice(&buf).unwrap();
    match request.get("command").and_then(Value::as_str) {
        Some("preview_wait") => {
            let (release_tx, release_rx) = mpsc::channel();
            events_tx
                .send(ServerEvent::Wait {
                    release: release_tx,
                })
                .unwrap();
            release_rx.recv().unwrap();
            stream
                .write_all(
                    br#"{"ok":true,"lines":["{\"version\":1,\"event\":\"wait-complete\"}"]}"#,
                )
                .unwrap();
        }
        Some("preview_cancel") => {
            events_tx.send(ServerEvent::Cancel).unwrap();
            stream
                .write_all(br#"{"ok":true,"lines":["{\"version\":1,\"event\":\"cancelled\"}"]}"#)
                .unwrap();
        }
        Some("preview_capture") => {
            let data = "a".repeat(8 * 1024 * 1024);
            let payload = json!({
                "version": 1,
                "url": "http://127.0.0.1:5173/",
                "image": { "mime_type": "image/png", "data": data }
            })
            .to_string();
            let response = json!({ "ok": true, "lines": [payload] }).to_string();
            stream.write_all(response.as_bytes()).unwrap();
        }
        _ => {
            stream.write_all(br#"{"ok":true}"#).unwrap();
        }
    }
}

struct McpProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

struct HttpMcpProcess {
    child: Child,
    port: u16,
}

impl Drop for HttpMcpProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for McpProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_mcp(socket: &PathBuf) -> McpProcess {
    let mut child = Command::new(env!("CARGO_BIN_EXE_alas"))
        .arg("mcp")
        .env("ALAS_SOCKET_PATH", socket)
        .env("ALAS_WORKTREE_DIR", "/tmp")
        .env("ALAS_SESSION_ID", "session-1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdin = child.stdin.take().unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    McpProcess {
        child,
        stdin,
        stdout,
    }
}

fn start_mcp_http(socket: &PathBuf, token: &str) -> HttpMcpProcess {
    let mut child = Command::new(env!("CARGO_BIN_EXE_alas"))
        .arg("mcp")
        .arg("--http")
        .env("ALAS_SOCKET_PATH", socket)
        .env("ALAS_WORKTREE_DIR", "/tmp")
        .env("ALAS_SESSION_ID", "session-1")
        .env("ALAS_MCP_HTTP_TOKEN", token)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut stdout = BufReader::new(stdout);
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    let port = line
        .trim()
        .strip_prefix("PORT ")
        .unwrap()
        .parse::<u16>()
        .unwrap();
    HttpMcpProcess { child, port }
}

fn send_line(stdin: &mut ChildStdin, value: Value) {
    writeln!(stdin, "{value}").unwrap();
    stdin.flush().unwrap();
}

fn http_post(port: u16, token: &str, body: Value) -> String {
    let body = body.to_string();
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    write!(
        stream,
        "POST /mcp HTTP/1.1\r\nHost: localhost:{port}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
    .unwrap();
    stream.flush().unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    response
}

fn poll_http_until_result(
    port: u16,
    token: &str,
    body: Value,
    expected_id: &str,
    timeout: Duration,
) -> String {
    let deadline = std::time::Instant::now() + timeout;
    let mut last_response = String::new();
    while std::time::Instant::now() < deadline {
        last_response = http_post(port, token, body.clone());
        if last_response.starts_with("HTTP/1.1 200 OK")
            && last_response.contains(&format!(r#""id":"{expected_id}""#))
            && last_response.contains(r#""result""#)
        {
            return last_response;
        }
        thread::sleep(Duration::from_millis(100));
    }
    panic!("timed out waiting for HTTP result; last response: {last_response}");
}

fn http_post_without_reading(port: u16, token: &str, body: Value) -> thread::JoinHandle<()> {
    let token = token.to_string();
    thread::spawn(move || {
        let body = body.to_string();
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(
            stream,
            "POST /mcp HTTP/1.1\r\nHost: localhost:{port}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
        stream.flush().unwrap();
        thread::sleep(Duration::from_secs(5));
    })
}

fn read_reply(stdout: &mut BufReader<ChildStdout>) -> Value {
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

#[test]
fn stdio_preview_cancel_tool_runs_while_preview_wait_socket_response_is_pending() {
    let fake = start_fake_alas("cancel-tool");
    let mut mcp = start_mcp(&fake.socket);

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "preview_wait",
                "arguments": {
                    "preview_id": "preview-runtime-id",
                    "condition": "loaded",
                    "timeout_ms": 20000
                }
            }
        }),
    );
    let wait_release = match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Wait { release } => release,
        ServerEvent::Cancel => panic!("cancel arrived before wait started"),
    };

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "preview_cancel",
                "arguments": { "preview_id": "preview-runtime-id" }
            }
        }),
    );

    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Cancel => {}
        ServerEvent::Wait { .. } => panic!("unexpected second wait"),
    }
    wait_release.send(()).unwrap();

    let first = read_reply(&mut mcp.stdout);
    let second = read_reply(&mut mcp.stdout);
    let mut ids = vec![first["id"].clone(), second["id"].clone()];
    ids.sort_by_key(|value| value.to_string());
    assert_eq!(ids, vec![json!(1), json!(2)]);
    assert!(first.get("result").is_some());
    assert!(second.get("result").is_some());
}

#[test]
fn stdio_cancelled_notification_sends_preview_cancel_before_wait_completes() {
    let fake = start_fake_alas("cancel-notification");
    let mut mcp = start_mcp(&fake.socket);

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "id": "wait-1",
            "method": "tools/call",
            "params": {
                "name": "preview_wait",
                "arguments": {
                    "preview_id": "preview-runtime-id",
                    "condition": "loaded",
                    "timeout_ms": 20000
                }
            }
        }),
    );
    let wait_release = match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Wait { release } => release,
        ServerEvent::Cancel => panic!("cancel arrived before wait started"),
    };

    send_line(
        &mut mcp.stdin,
        json!({
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": { "requestId": "wait-1", "reason": "test cancellation" }
        }),
    );

    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Cancel => {}
        ServerEvent::Wait { .. } => panic!("unexpected second wait"),
    }
    wait_release.send(()).unwrap();

    let reply = read_reply(&mut mcp.stdout);
    assert_eq!(reply["id"], json!("wait-1"));
    assert!(reply.get("result").is_some());
}

#[test]
fn http_cancelled_notification_sends_preview_cancel_before_wait_completes() {
    let fake = start_fake_alas("http-cancel-notification");
    let mcp = start_mcp_http(&fake.socket, "test-token");

    let port = mcp.port;
    let wait = thread::spawn(move || {
        http_post(
            port,
            "test-token",
            json!({
                "jsonrpc": "2.0",
                "id": "wait-1",
                "method": "tools/call",
                "params": {
                    "name": "preview_wait",
                    "arguments": {
                        "preview_id": "preview-runtime-id",
                        "condition": "loaded",
                        "timeout_ms": 20000
                    }
                }
            }),
        )
    });

    let wait_release = match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Wait { release } => release,
        ServerEvent::Cancel => panic!("cancel arrived before wait started"),
    };

    let cancel_response = http_post(
        mcp.port,
        "test-token",
        json!({
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": { "requestId": "wait-1", "reason": "test cancellation" }
        }),
    );
    assert!(cancel_response.starts_with("HTTP/1.1 202 Accepted"));

    match fake.events.recv_timeout(Duration::from_secs(5)).unwrap() {
        ServerEvent::Cancel => {}
        ServerEvent::Wait { .. } => panic!("unexpected second wait"),
    }
    wait_release.send(()).unwrap();

    let wait_response = wait.join().unwrap();
    assert!(wait_response.starts_with("HTTP/1.1 200 OK"));
    assert!(wait_response.contains(r#""id":"wait-1""#));
    assert!(wait_response.contains(r#""result""#));
}

#[test]
fn http_stalled_response_reader_does_not_pin_connection_worker_forever() {
    let fake = start_fake_alas("http-stalled-reader");
    let mcp = start_mcp_http(&fake.socket, "test-token");

    let mut stalled = Vec::new();
    for id in 0..8 {
        stalled.push(http_post_without_reading(
            mcp.port,
            "test-token",
            json!({
                "jsonrpc": "2.0",
                "id": format!("capture-{id}"),
                "method": "tools/call",
                "params": {
                    "name": "preview_capture",
                    "arguments": { "preview_id": format!("preview-{id}") }
                }
            }),
        ));
    }

    let response = poll_http_until_result(
        mcp.port,
        "test-token",
        json!({
            "jsonrpc": "2.0",
            "id": "list-after-stalled-readers",
            "method": "tools/call",
            "params": {
                "name": "preview_list",
                "arguments": {}
            }
        }),
        "list-after-stalled-readers",
        Duration::from_secs(10),
    );

    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    assert!(response.contains(r#""id":"list-after-stalled-readers""#));
    assert!(response.contains(r#""result""#));

    for handle in stalled {
        let _ = handle.join();
    }
}
