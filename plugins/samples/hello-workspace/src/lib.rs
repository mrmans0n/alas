//! Minimal Alas plugin (API v1). Logs a summary of the project's worktrees and
//! agent sessions, and deliberately calls `worktree/switch` without the
//! capability to show the denial path.

use serde_json::{json, Value};

#[link(wasm_import_module = "alas")]
extern "C" {
    #[link_name = "send"]
    fn alas_send(ptr: *const u8, len: usize);
}

fn send(message: Value) {
    let text = message.to_string();
    unsafe { alas_send(text.as_ptr(), text.len()) }
}

fn log(level: &str, message: String) {
    send(json!({"jsonrpc": "2.0", "method": "log", "params": {"level": level, "message": message}}));
}

fn request(id: i64, method: &str, params: Value) {
    send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
}

fn summary(snapshot: &Value) -> String {
    let empty = Vec::new();
    let worktrees = snapshot["worktrees"].as_array().unwrap_or(&empty);
    let sessions: Vec<&Value> = worktrees
        .iter()
        .flat_map(|worktree| worktree["sessions"].as_array().unwrap_or(&empty).iter())
        .collect();
    let running = sessions.iter().filter(|session| session["state"] == "running").count();
    format!("{} worktrees, {} sessions ({} running)", worktrees.len(), sessions.len(), running)
}

/// Alas writes each incoming message into a buffer allocated here.
/// `alas_handle` takes ownership and frees it.
#[no_mangle]
pub extern "C" fn alas_alloc(len: usize) -> *mut u8 {
    Box::into_raw(vec![0u8; len].into_boxed_slice()) as *mut u8
}

/// # Safety
/// `ptr`/`len` must come from `alas_alloc`; Alas guarantees this.
#[no_mangle]
pub unsafe extern "C" fn alas_handle(ptr: *mut u8, len: usize) {
    let bytes = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len));
    let Ok(message) = serde_json::from_slice::<Value>(&bytes) else { return };
    match message["method"].as_str() {
        Some("alas/activate") => {
            send(json!({"jsonrpc": "2.0", "id": message["id"], "result": {}}));
            log("info", format!("activated for {}", message["params"]["project"]["name"]));
            request(1, "workspace/snapshot", json!({}));
            request(2, "worktree/switch", json!({"id": "any"}));
        }
        Some("workspace/changed") => {
            log("info", format!("changed: {}", summary(&message["params"]["snapshot"])));
        }
        Some(_) => {}
        None => match message["id"].as_i64() {
            Some(1) => log("info", format!("snapshot: {}", summary(&message["result"]["snapshot"]))),
            Some(2) => log("warn", format!("worktree/switch replied {}", message["error"])),
            _ => {}
        },
    }
}
