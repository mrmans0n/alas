//! SDK for Alas plugins (API 1 and 2). Handles the ABI, JSON-RPC framing, the
//! activation handshake and request ids. On non-wasm targets the host imports are
//! replaced by an in-memory recorder (`test_host`) so plugins can be unit tested.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::cell::Cell;

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Snapshot {
    pub worktrees: Vec<Worktree>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Worktree {
    pub id: String,
    pub branch: String,
    pub current: bool,
    #[serde(default)]
    pub dirty: Option<Dirty>,
    pub sessions: Vec<Session>,
}

#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
pub struct Dirty {
    pub files: u32,
    pub conflicts: u32,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Session {
    pub id: String,
    pub agent: String,
    pub title: String,
    pub state: String,
    #[serde(default)]
    pub plan: Option<Plan>,
}

#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
pub struct Plan {
    pub completed: u32,
    pub total: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Region {
    pub id: String,
    pub label: String,
    pub rect: [i32; 4],
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Activate { project_id: String, project_name: String, grants: Vec<String> },
    Deactivate,
    WorkspaceChanged(Snapshot),
    Tick { dt: u32 },
    Click { tab: u32, region: String },
    Reply { id: i64, result: Result<Value, RpcError> },
}

pub trait Plugin: Default {
    fn handle(&mut self, event: Event);
}

#[cfg(target_arch = "wasm32")]
mod sys {
    #[link(wasm_import_module = "alas")]
    extern "C" {
        pub fn send(ptr: *const u8, len: usize);
        pub fn present(tab: u32, ptr: *const u8, len: usize, width: u32);
    }
}

/// Records what a plugin sends when it is compiled for the host, for tests.
#[cfg(not(target_arch = "wasm32"))]
pub mod test_host {
    use serde_json::Value;
    use std::cell::RefCell;

    thread_local! {
        pub(crate) static SENT: RefCell<Vec<Value>> = RefCell::new(Vec::new());
        pub(crate) static FRAMES: RefCell<Vec<(u32, u32, Vec<u8>)>> = RefCell::new(Vec::new());
    }

    pub fn take_sent() -> Vec<Value> {
        SENT.with(|sent| std::mem::take(&mut *sent.borrow_mut()))
    }

    /// `(tab, width, pixels)` for each `present` call.
    pub fn take_frames() -> Vec<(u32, u32, Vec<u8>)> {
        FRAMES.with(|frames| std::mem::take(&mut *frames.borrow_mut()))
    }
}

fn send(message: &Value) {
    #[cfg(target_arch = "wasm32")]
    {
        let text = message.to_string();
        unsafe { sys::send(text.as_ptr(), text.len()) }
    }
    #[cfg(not(target_arch = "wasm32"))]
    test_host::SENT.with(|sent| sent.borrow_mut().push(message.clone()));
}

pub fn log(level: &str, message: &str) {
    send(&json!({"jsonrpc": "2.0", "method": "log", "params": {"level": level, "message": message}}));
}

thread_local! {
    static NEXT_ID: Cell<i64> = const { Cell::new(1) };
}

/// Sends a request and returns its id. The reply arrives in a later call as `Event::Reply`.
pub fn request(method: &str, params: Value) -> i64 {
    let id = NEXT_ID.with(|next| {
        let id = next.get();
        next.set(id + 1);
        id
    });
    send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
    id
}

/// Hands Alas one RGBA8 frame for tab `tab`. Alas copies it during this call.
pub fn present(tab: u32, pixels: &[u8], width: u32) {
    #[cfg(target_arch = "wasm32")]
    unsafe {
        sys::present(tab, pixels.as_ptr(), pixels.len(), width)
    }
    #[cfg(not(target_arch = "wasm32"))]
    test_host::FRAMES.with(|frames| frames.borrow_mut().push((tab, width, pixels.to_vec())));
}

pub fn set_regions(tab: u32, regions: &[Region]) {
    send(&json!({"jsonrpc": "2.0", "method": "canvas/regions", "params": {"tab": tab, "regions": regions}}));
}

/// Parses one incoming message and hands it to `plugin`. Activation is answered
/// before the plugin sees it, so a plugin cannot forget the handshake.
pub fn dispatch<P: Plugin>(plugin: &mut P, bytes: &[u8]) {
    let Ok(message) = serde_json::from_slice::<Value>(bytes) else { return };
    let params = &message["params"];
    let event = match message["method"].as_str() {
        Some("alas/activate") => {
            send(&json!({"jsonrpc": "2.0", "id": message["id"], "result": {}}));
            Event::Activate {
                project_id: params["project"]["id"].as_str().unwrap_or_default().to_string(),
                project_name: params["project"]["name"].as_str().unwrap_or_default().to_string(),
                grants: serde_json::from_value(params["grants"].clone()).unwrap_or_default(),
            }
        }
        Some("alas/deactivate") => Event::Deactivate,
        Some("workspace/changed") => match serde_json::from_value(params["snapshot"].clone()) {
            Ok(snapshot) => Event::WorkspaceChanged(snapshot),
            Err(_) => return,
        },
        Some("tick") => Event::Tick { dt: params["dt"].as_u64().unwrap_or(0) as u32 },
        Some("canvas/click") => Event::Click {
            tab: params["tab"].as_u64().unwrap_or(0) as u32,
            region: params["region"].as_str().unwrap_or_default().to_string(),
        },
        Some(_) => return,
        None => {
            let Some(id) = message["id"].as_i64() else { return };
            let result = match serde_json::from_value::<RpcError>(message["error"].clone()) {
                Ok(error) => Err(error),
                Err(_) => Ok(message["result"].clone()),
            };
            Event::Reply { id, result }
        }
    };
    plugin.handle(event);
}

#[doc(hidden)]
pub fn alloc(len: usize) -> *mut u8 {
    Box::into_raw(vec![0u8; len].into_boxed_slice()) as *mut u8
}

/// # Safety
/// `ptr`/`len` must come from `alloc`; Alas guarantees this.
#[doc(hidden)]
pub unsafe fn take(ptr: *mut u8, len: usize) -> Box<[u8]> {
    Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))
}

/// Exports `alas_alloc` and `alas_handle` for a `Plugin` type.
#[macro_export]
macro_rules! export_plugin {
    ($plugin:ty) => {
        thread_local! {
            static ALAS_PLUGIN: ::std::cell::RefCell<$plugin> = ::std::cell::RefCell::new(<$plugin>::default());
        }

        #[no_mangle]
        pub extern "C" fn alas_alloc(len: usize) -> *mut u8 {
            $crate::alloc(len)
        }

        /// # Safety
        /// Called by Alas with a buffer from `alas_alloc`.
        #[no_mangle]
        pub unsafe extern "C" fn alas_handle(ptr: *mut u8, len: usize) {
            let bytes = $crate::take(ptr, len);
            ALAS_PLUGIN.with(|plugin| $crate::dispatch(&mut *plugin.borrow_mut(), &bytes));
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Recorder(Vec<Event>);

    impl Plugin for Recorder {
        fn handle(&mut self, event: Event) {
            self.0.push(event);
        }
    }

    fn feed(plugin: &mut Recorder, message: Value) {
        dispatch(plugin, message.to_string().as_bytes());
    }

    #[test]
    fn activation_is_answered_before_the_plugin_sees_it() {
        test_host::take_sent();
        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":0,"method":"alas/activate",
            "params":{"api":2,"project":{"id":"p","name":"Proj"},"grants":["workspace.read"]}}));
        assert_eq!(test_host::take_sent(), vec![json!({"jsonrpc":"2.0","id":0,"result":{}})]);
        assert_eq!(plugin.0, vec![Event::Activate {
            project_id: "p".into(), project_name: "Proj".into(), grants: vec!["workspace.read".into()],
        }]);
    }

    #[test]
    fn requests_get_increasing_ids_and_replies_carry_them_back() {
        test_host::take_sent();
        let first = request("workspace/snapshot", json!({}));
        let second = request("session/focus", json!({"id": "s"}));
        assert!(second > first);
        assert_eq!(test_host::take_sent()[1]["id"], json!(second));

        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":second,"error":{"code":-32003,"message":"unknown session s"}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":first,"result":{"ok":true}}));
        assert_eq!(plugin.0, vec![
            Event::Reply { id: second, result: Err(RpcError { code: -32003, message: "unknown session s".into() }) },
            Event::Reply { id: first, result: Ok(json!({"ok": true})) },
        ]);
    }

    #[test]
    fn canvas_events_and_snapshots_decode() {
        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"tick","params":{"dt":66}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"canvas/click","params":{"tab":0,"region":"r3"}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"workspace/changed","params":{"snapshot":{"worktrees":[
            {"id":"w","branch":"main","current":true,"sessions":[{"id":"s","agent":"claude","title":"T","state":"running","plan":{"completed":1,"total":3}}]}
        ]}}}));
        assert_eq!(plugin.0[0], Event::Tick { dt: 66 });
        assert_eq!(plugin.0[1], Event::Click { tab: 0, region: "r3".into() });
        let Event::WorkspaceChanged(snapshot) = &plugin.0[2] else { panic!("expected a snapshot") };
        assert_eq!(snapshot.worktrees[0].dirty, None);
        assert_eq!(snapshot.worktrees[0].sessions[0].plan, Some(Plan { completed: 1, total: 3 }));
    }

    #[test]
    fn regions_encode_as_the_wire_shape() {
        test_host::take_sent();
        set_regions(0, &[Region { id: "r0".into(), label: "L".into(), rect: [1, 2, 3, 4] }]);
        assert_eq!(test_host::take_sent()[0]["params"],
            json!({"tab": 0, "regions": [{"id": "r0", "label": "L", "rect": [1, 2, 3, 4]}]}));
    }
}
