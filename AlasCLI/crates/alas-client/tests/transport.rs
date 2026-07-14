use alas_client::{send, Request};
use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;

static STUB_COUNTER: AtomicU32 = AtomicU32::new(0);

fn stub_server(reply: &'static str) -> (PathBuf, thread::JoinHandle<Vec<u8>>) {
    // Tests in this file run concurrently (default cargo test behavior) and
    // share a process id, so mix in a counter to keep each stub's socket path
    // unique and avoid racing on the same file.
    let unique = STUB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!(
        "alas-cli-stub-{}-{}.sock",
        std::process::id(),
        unique
    ));
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).unwrap();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buf = Vec::new();
        // Read one JSON object: read until we can parse (mirrors the app).
        let mut chunk = [0u8; 1024];
        loop {
            let n = stream.read(&mut chunk).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
            if serde_json::from_slice::<serde_json::Value>(&buf).is_ok() {
                break;
            }
        }
        stream.write_all(reply.as_bytes()).unwrap();
        buf
    });
    (path, handle)
}

#[test]
fn send_writes_request_and_parses_reply() {
    let (path, handle) = stub_server(r#"{"ok":true,"lines":["a","b"]}"#);
    let mut req = Request::new("wt");
    req.session_id = Some("s1".into());
    req.subcommand = Some("list".into());

    let resp = send(&path, &req).unwrap();
    assert!(resp.ok);
    assert_eq!(resp.lines.unwrap(), vec!["a", "b"]);

    let received = handle.join().unwrap();
    let parsed: serde_json::Value = serde_json::from_slice(&received).unwrap();
    assert_eq!(parsed["command"], "wt");
    assert_eq!(parsed["subcommand"], "list");
    let _ = std::fs::remove_file(&path);
}

use alas_client::{Command, DispatchError, Target};

#[test]
fn dispatch_directory_single_owner_sends_command() {
    let (path, handle) = stub_server(r#"{"ok":true}"#);
    let target = Target::Directory { cwd: "/repo".into() };
    // One explicit socket via the test-only entry point.
    let resp = alas_client::dispatch_to_sockets(
        &Command::WtList,
        &target,
        std::slice::from_ref(&path),
    );
    assert!(matches!(resp, Ok(r) if r.ok));
    let _ = handle.join();
    let _ = std::fs::remove_file(&path);
}

#[test]
fn dispatch_directory_no_sockets_is_no_alas() {
    let target = Target::Directory { cwd: "/repo".into() };
    let resp = alas_client::dispatch_to_sockets(&Command::WtList, &target, &[]);
    assert!(matches!(resp, Err(DispatchError::NoAlas)));
}
