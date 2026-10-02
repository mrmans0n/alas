use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Barrier};

struct Helper {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next_id: u64,
}
impl Helper {
    fn start(root: &Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_alas-helper"))
            .arg("serve")
            .env("ALAS_HELPER_STATE_DIR", root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        Self {
            input: child.stdin.take().unwrap(),
            output: BufReader::new(child.stdout.take().unwrap()),
            child,
            next_id: 0,
        }
    }
    fn raw(&mut self, method: &str, params: Value) -> Value {
        self.next_id += 1;
        writeln!(
            self.input,
            "{}",
            json!({"jsonrpc":"2.0", "id":self.next_id,"method":method,"params":params})
        )
        .unwrap();
        self.input.flush().unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(
                self.output.read_line(&mut line).unwrap(),
                0,
                "helper exited"
            );
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["id"] == self.next_id {
                return value;
            }
        }
    }
    fn request(&mut self, method: &str, params: Value) -> Value {
        let response = self.raw(method, params);
        assert!(response.get("error").is_none(), "{method}: {response}");
        response["result"].clone()
    }
}
impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
struct Fixture(std::path::PathBuf);
impl Fixture {
    fn new() -> Self {
        static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
        loop {
            let path = std::env::temp_dir().join(format!(
                "alas-remote-{}-{}",
                std::process::id(),
                NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => return Self(path),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create isolated fixture directory: {error}"),
            }
        }
    }
    fn claim(&self, owner: &str) -> Value {
        json!({"key":{"worktreePath":self.0,"agentId":"test","remoteSessionId":"conversation"},"owner":{"serverId":owner,"instanceId":owner},"proposedProcId":format!("acp-{owner}"),"requestedToken":format!("token-{owner}")})
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn concurrent_claims_choose_one_owner_across_helper_processes() {
    let fixture = Fixture::new();
    let mut a = Helper::start(&fixture.0);
    let mut b = Helper::start(&fixture.0);
    let claim_a = fixture.claim("a");
    let claim_b = fixture.claim("b");
    let barrier = Arc::new(Barrier::new(2));
    let results = std::thread::scope(|scope| {
        let first = barrier.clone();
        let left = scope.spawn(move || {
            first.wait();
            a.request("lease/claim", claim_a)
        });
        let right = scope.spawn(move || {
            barrier.wait();
            b.request("lease/claim", claim_b)
        });
        [left.join().unwrap(), right.join().unwrap()]
    });
    assert_eq!(results.iter().filter(|r| !r["fence"].is_null()).count(), 1);
    assert_eq!(results[0]["lease"]["owner"], results[1]["lease"]["owner"]);
    assert_eq!(results[0]["lease"]["procId"], results[1]["lease"]["procId"]);
}

#[test]
fn replica_retry_is_idempotent_and_takeover_fences_old_publications() {
    let fixture = Fixture::new();
    let mut a = Helper::start(&fixture.0);
    let mut b = Helper::start(&fixture.0);
    let first = a.request("lease/claim", fixture.claim("a"));
    let publish = json!({"fence":first["fence"],"batchId":"first","status":"busy","entries":[
        {"kind":"message","key":"0","payload":"aGVsbG8=","revision":0}
    ]});
    let receipt = a.request("replica/publish", publish.clone());
    assert_eq!(a.request("replica/publish", publish.clone()), receipt);
    assert_eq!(
        a.request("lease/claim", fixture.claim("a"))["lease"]["status"],
        "busy"
    );
    let seized = b.request("lease/seize", fixture.claim("b"));
    assert_eq!(a.raw("replica/publish", publish)["error"]["code"], -32081);
    assert_eq!(
        a.raw("lease/release", json!({"fence":first["fence"]}))["error"]["code"],
        -32081
    );
    let read = b.request(
        "replica/read",
        json!({"recordId":seized["lease"]["recordId"],"afterRevision":0}),
    );
    assert_eq!(read["entries"][0]["payload"], "aGVsbG8=");
    assert_eq!(read["cutoffRevision"], receipt["revision"]);
}

#[test]
fn paginated_reads_pin_the_cutoff_while_another_helper_updates_rows() {
    let fixture = Fixture::new();
    let mut writer = Helper::start(&fixture.0);
    let mut reader = Helper::start(&fixture.0);
    let claim = writer.request("lease/claim", fixture.claim("a"));
    let entries: Vec<_> = (0..300)
        .map(|i| json!({"kind":"message","key":format!("{i:03}"),"payload":"b2xk","revision":0}))
        .collect();
    writer.request(
        "replica/publish",
        json!({"fence":claim["fence"],"batchId":"seed","status":"idle","entries":entries}),
    );
    let first = reader.request(
        "replica/read",
        json!({"recordId":claim["lease"]["recordId"],"afterRevision":0}),
    );
    assert!(!first["nextPageToken"].is_null());
    writer.request(
        "replica/publish",
        json!({"fence":claim["fence"],"batchId":"edit","status":"idle","entries":[
            {"kind":"message","key":"299","payload":"bmV3","revision":0}
        ]}),
    );
    let last=reader.request("replica/read",json!({"recordId":claim["lease"]["recordId"],"afterRevision":0,"pageToken":first["nextPageToken"]}));
    assert_eq!(last["cutoffRevision"], first["cutoffRevision"]);
    assert_eq!(
        last["entries"].as_array().unwrap().last().unwrap()["payload"],
        "b2xk"
    );
    let delta = reader.request(
        "replica/read",
        json!({"recordId":claim["lease"]["recordId"],"afterRevision":last["cutoffRevision"]}),
    );
    assert_eq!(delta["entries"][0]["key"], "299");
    assert_eq!(delta["entries"][0]["payload"], "bmV3");
}

#[test]
fn takeover_fences_old_stdin_retries_spawn_and_kill_without_disturbing_the_new_writer() {
    use base64::Engine;
    let fixture = Fixture::new();
    let mut old = Helper::start(&fixture.0);
    let mut new = Helper::start(&fixture.0);
    let first = old.request("lease/claim", fixture.claim("a"));
    let proc_id = first["lease"]["procId"].clone();
    let spawn = json!({"procId":proc_id,"command":"/bin/cat","args":[],"cwd":fixture.0,"env":{},"leaseFence":first["fence"]});
    old.request("proc/spawn", spawn.clone());
    let bytes = b"{\"jsonrpc\":\"2.0\",\"method\":\"owned\"}\n";
    let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
    let write = json!({"procId":proc_id,"dataBase64":encoded,"expectedStdinOffset":0,"leaseFence":first["fence"]});
    old.request("proc/write", write.clone());
    let successor = new.request("lease/seize", fixture.claim("b"));
    assert_eq!(successor["lease"]["procId"], proc_id);
    for (method, params) in [
        ("proc/write", write),
        ("proc/spawn", spawn.clone()),
        (
            "proc/kill",
            json!({"procId":proc_id,"leaseFence":first["fence"]}),
        ),
        (
            "proc/write",
            json!({"procId":proc_id,"dataBase64":encoded,"expectedStdinOffset":bytes.len()}),
        ),
    ] {
        assert_eq!(old.raw(method, params)["error"]["code"], -32081, "{method}");
    }
    let still_running = new.request("proc/attach", json!({"procId":proc_id}));
    assert_eq!(still_running["running"], true);
    assert_eq!(still_running["stdinOffset"], bytes.len());
    new.request(
        "proc/kill",
        json!({"procId":proc_id,"leaseFence":successor["fence"]}),
    );
    let mut successor_spawn = spawn;
    successor_spawn["leaseFence"] = successor["fence"].clone();
    new.request("proc/spawn", successor_spawn);
    new.request("proc/write", json!({"procId":proc_id,"dataBase64":encoded,"expectedStdinOffset":0,"leaseFence":successor["fence"]}));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let output = new.request("proc/attach", json!({"procId":proc_id}));
        if let Some(frame) = output["stdoutFrames"].as_array().unwrap().first() {
            let echoed = base64::engine::general_purpose::STANDARD
                .decode(frame["dataBase64"].as_str().unwrap())
                .unwrap();
            assert_eq!(
                serde_json::from_slice::<Value>(&echoed).unwrap(),
                json!({"jsonrpc":"2.0","method":"owned"})
            );
            assert_eq!(output["stdinOffset"], bytes.len());
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "successor process never echoed its input"
        );
    }
    new.request(
        "proc/kill",
        json!({"procId":proc_id,"leaseFence":successor["fence"]}),
    );
}

#[test]
fn replacement_attachment_requires_the_current_token_and_fences_the_previous_attachment() {
    let fixture = Fixture::new();
    let mut helper = Helper::start(&fixture.0);
    let first = helper.request("lease/claim", fixture.claim("a"));
    let mut replacement = fixture.claim("a");
    replacement["requestedToken"] = json!("replacement");
    assert!(helper.request("lease/claim", replacement.clone())["fence"].is_null());
    replacement["previousFence"] = first["fence"].clone();
    let replaced = helper.request("lease/claim", replacement);
    assert_eq!(replaced["fence"]["token"], "replacement");
    assert_eq!(
        helper.raw(
            "lease/heartbeat",
            json!({"fence":first["fence"],"status":"busy"})
        )["error"]["code"],
        -32081
    );
    helper.request(
        "lease/heartbeat",
        json!({"fence":replaced["fence"],"status":"busy"}),
    );
}

#[test]
fn taking_over_a_parent_does_not_take_over_its_child_or_another_agent() {
    let fixture = Fixture::new();
    let mut helper = Helper::start(&fixture.0);
    let parent = helper.request("lease/claim", fixture.claim("a"));
    let mut child_params = fixture.claim("a");
    child_params["key"]["remoteSessionId"] = Value::Null;
    child_params["proposedProcId"] = json!("child-proc");
    child_params["requestedToken"] = json!("child-token");
    let child = helper.request("lease/claim", child_params);
    helper.request(
        "lease/bind",
        json!({"fence":child["fence"],"remoteSessionId":"child-conversation"}),
    );
    let mut agent_params = fixture.claim("a");
    agent_params["key"]["agentId"] = json!("another-agent");
    agent_params["proposedProcId"] = json!("other-agent-proc");
    agent_params["requestedToken"] = json!("other-agent-token");
    let other_agent = helper.request("lease/claim", agent_params);
    helper.request("lease/seize", fixture.claim("b"));
    assert_eq!(
        helper.raw(
            "lease/heartbeat",
            json!({"fence":parent["fence"],"status":"busy"})
        )["error"]["code"],
        -32081
    );
    helper.request(
        "lease/heartbeat",
        json!({"fence":child["fence"],"status":"busy"}),
    );
    helper.request(
        "lease/heartbeat",
        json!({"fence":other_agent["fence"],"status":"busy"}),
    );
    let child_key =
        json!({"worktreePath":fixture.0,"agentId":"test","remoteSessionId":"child-conversation"});
    let observed = helper.request("lease/observe", json!({"key":child_key}));
    assert_eq!(observed["lease"]["owner"]["serverId"], "a");
    assert_eq!(observed["lease"]["procId"], "child-proc");
}
