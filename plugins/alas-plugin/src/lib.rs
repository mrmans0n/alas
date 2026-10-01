//! SDK for Alas plugins (API 1 to 3). Handles the ABI, JSON-RPC framing, the
//! activation handshake and request ids. On non-wasm targets the host imports are
//! replaced by an in-memory recorder (`test_host`) so plugins can be unit tested.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use serde_json::value::RawValue;
use std::cell::{Cell, RefCell};

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
    /// The reply to `request_snapshot`.
    Snapshot(Snapshot),
    Tick { dt: u32 },
    Click { tab: u32, region: String },
    /// A control in a view tab was used: `kind` is `click` (button, card), `submit` (text field) or `select` (menu).
    ViewEvent { tab: u32, id: String, kind: String, value: Option<String> },
    /// A task started with `task_start` failed to launch in the background.
    TaskFailed { session_id: String, reason: String },
    /// The reply to `storage_get`: the stored JSON as raw text, `None` when unset.
    /// Raw, so a large value is parsed once, straight into the plugin's own types.
    Stored { id: i64, value: Result<Option<String>, RpcError> },
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

/// Alas meters plugins by fuel, and charges a function or loop body in full each time it
/// is entered. The default allocator's `malloc`/`free` are large bodies, so every
/// allocation cost thousands of fuel. This one is a handful of instructions: power-of-two
/// size classes with a free list each, carved from a bump region grown with `memory.grow`.
// ponytail: freed blocks are never coalesced, split or returned, so memory use is the sum of
// each size class's peak, not what is live now (plus up to 2x rounding per block). Fine for
// the 64 MiB cap and JSON-sized payloads; switch back to dlmalloc for plugins whose large
// buffers keep changing size class.
#[cfg(target_arch = "wasm32")]
mod allocator {
    use std::alloc::{GlobalAlloc, Layout};
    use std::cell::UnsafeCell;

    /// Blocks are aligned to their size, capped at this.
    const MAX_ALIGN: usize = 4096;
    const PAGE: usize = 65536;

    struct Heap {
        /// Head of each size class's free list; a free block stores the next head.
        free: [usize; usize::BITS as usize],
        next: usize,
        end: usize,
    }

    struct SizeClasses(UnsafeCell<Heap>);

    // Plugins are single-threaded wasm modules.
    unsafe impl Sync for SizeClasses {}

    #[global_allocator]
    static HEAP: SizeClasses = SizeClasses(UnsafeCell::new(Heap { free: [0; usize::BITS as usize], next: 0, end: 0 }));

    /// log2 of the block size that holds `layout`, at least one pointer.
    fn class(layout: Layout) -> usize {
        let size = layout.size().max(layout.align()).max(size_of::<usize>());
        (usize::BITS - (size - 1).leading_zeros()) as usize
    }

    unsafe impl GlobalAlloc for SizeClasses {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            if layout.align() > MAX_ALIGN {
                return std::ptr::null_mut();
            }
            let heap = &mut *self.0.get();
            let class = class(layout);
            let head = heap.free[class];
            if head != 0 {
                heap.free[class] = *(head as *const usize);
                return head as *mut u8;
            }
            let size = 1usize << class;
            let align = size.min(MAX_ALIGN);
            let mut start = (heap.next + align - 1) & !(align - 1);
            if start + size > heap.end {
                let pages = size.div_ceil(PAGE) + 1;
                let old = core::arch::wasm32::memory_grow(0, pages);
                if old == usize::MAX {
                    return std::ptr::null_mut();
                }
                // The first region starts at the grown memory; later ones extend the last.
                if old * PAGE != heap.end {
                    heap.next = old * PAGE;
                }
                heap.end = (old + pages) * PAGE;
                start = (heap.next + align - 1) & !(align - 1);
            }
            heap.next = start + size;
            start as *mut u8
        }

        unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
            let heap = &mut *self.0.get();
            let class = class(layout);
            *(ptr as *mut usize) = heap.free[class];
            heap.free[class] = ptr as usize;
        }

        unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
            let new = Layout::from_size_align_unchecked(new_size, layout.align());
            if class(new) == class(layout) {
                return ptr;
            }
            let grown = self.alloc(new);
            if !grown.is_null() {
                std::ptr::copy_nonoverlapping(ptr, grown, layout.size().min(new_size));
                self.dealloc(ptr, layout);
            }
            grown
        }
    }
}

/// Records what a plugin sends when it is compiled for the host, for tests.
#[cfg(not(target_arch = "wasm32"))]
pub mod test_host {
    use serde_json::Value;
    use std::cell::RefCell;

    thread_local! {
        pub(crate) static SENT: RefCell<Vec<Value>> = const { RefCell::new(Vec::new()) };
        pub(crate) static FRAMES: RefCell<Vec<(u32, u32, Vec<u8>)>> = const { RefCell::new(Vec::new()) };
    }

    pub fn take_sent() -> Vec<Value> {
        SENT.with(|sent| std::mem::take(&mut *sent.borrow_mut()))
    }

    /// `(tab, width, pixels)` for each `present` call.
    pub fn take_frames() -> Vec<(u32, u32, Vec<u8>)> {
        FRAMES.with(|frames| std::mem::take(&mut *frames.borrow_mut()))
    }
}

/// Serialises straight to text: going through `json!` would copy large payloads
/// (a view tree, a stored board) into a `Value` tree first, which costs fuel.
fn send<T: Serialize + ?Sized>(message: &T) {
    let text = match serde_json::to_string(message) {
        Ok(text) => text,
        Err(error) => {
            debug_assert!(false, "could not serialise a message: {error}");
            // `log` sends a plain `Value`, which always serialises.
            log("error", &format!("could not serialise a message: {error}"));
            return;
        }
    };
    #[cfg(target_arch = "wasm32")]
    unsafe {
        sys::send(text.as_ptr(), text.len())
    }
    #[cfg(not(target_arch = "wasm32"))]
    test_host::SENT.with(|sent| sent.borrow_mut().push(serde_json::from_str(&text).expect("sent JSON")));
}

#[derive(Serialize)]
struct Outgoing<'a, P> {
    jsonrpc: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<i64>,
    method: &'a str,
    params: P,
}

fn notify<P: Serialize>(method: &str, params: P) {
    send(&Outgoing { jsonrpc: "2.0", id: None, method, params });
}

pub fn log(level: &str, message: &str) {
    notify("log", json!({"level": level, "message": message}));
}

thread_local! {
    static NEXT_ID: Cell<i64> = const { Cell::new(1) };
}

/// Sends a request and returns its id. The reply arrives in a later call as `Event::Reply`.
pub fn request<P: Serialize>(method: &str, params: P) -> i64 {
    let id = NEXT_ID.with(|next| {
        let id = next.get();
        next.set(id + 1);
        id
    });
    send(&Outgoing { jsonrpc: "2.0", id: Some(id), method, params });
    id
}

/// Requests whose replies are decoded into their own event instead of `Event::Reply`.
#[derive(Clone, Copy, PartialEq)]
enum Typed {
    Snapshot,
    Storage,
}

thread_local! {
    static TYPED_REQUESTS: RefCell<Vec<(i64, Typed)>> = const { RefCell::new(Vec::new()) };
}

fn typed_request<P: Serialize>(method: &str, params: P, kind: Typed) -> i64 {
    let id = request(method, params);
    TYPED_REQUESTS.with(|ids| ids.borrow_mut().push((id, kind)));
    id
}

fn take_typed(id: i64) -> Option<Typed> {
    TYPED_REQUESTS.with(|ids| {
        let mut ids = ids.borrow_mut();
        let index = ids.iter().position(|&(pending, _)| pending == id)?;
        Some(ids.remove(index).1)
    })
}

/// Requests the whole workspace snapshot. The reply arrives as `Event::Snapshot`,
/// decoded straight into typed structs (it is the one large payload).
pub fn request_snapshot() -> i64 {
    typed_request("workspace/snapshot", json!({}), Typed::Snapshot)
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
    #[derive(Serialize)]
    struct Params<'a> {
        tab: u32,
        regions: &'a [Region],
    }
    notify("canvas/regions", Params { tab, regions });
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Axis { Vertical, Horizontal }

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TextStyle { Body, Caption, Title, Monospaced }

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Tone { Normal, Dim, Accent, Warn, Danger }

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ButtonStyle { Normal, Primary, Plain }

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MenuItem {
    pub id: String,
    pub label: String,
}

/// A node of a view tab's tree. Ids must be unique within the tree.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Node {
    Vstack {
        id: String,
        children: Vec<Node>,
        /// Points between children. The host rejects a tree with spacing above 32.
        #[serde(skip_serializing_if = "Option::is_none")]
        spacing: Option<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        width: Option<u16>,
    },
    Hstack {
        id: String,
        children: Vec<Node>,
        /// Points between children. The host rejects a tree with spacing above 32.
        #[serde(skip_serializing_if = "Option::is_none")]
        spacing: Option<u8>,
    },
    Scroll { id: String, axis: Axis, child: Box<Node> },
    Text {
        id: String,
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        style: Option<TextStyle>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tone: Option<Tone>,
    },
    Badge {
        id: String,
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        tone: Option<Tone>,
    },
    Button {
        id: String,
        label: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        style: Option<ButtonStyle>,
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        disabled: bool,
    },
    TextField {
        id: String,
        value: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        placeholder: Option<String>,
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        multiline: bool,
    },
    Menu { id: String, label: String, items: Vec<MenuItem> },
    Card {
        id: String,
        children: Vec<Node>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tone: Option<Tone>,
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        clickable: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        width: Option<u16>,
    },
    Divider { id: String },
    Spacer { id: String },
}

/// Replaces the tree shown in view tab `tab`.
pub fn render(tab: u32, root: &Node) {
    #[derive(Serialize)]
    struct Params<'a> {
        tab: u32,
        root: &'a Node,
    }
    notify("view/render", Params { tab, root });
}

/// Starts a task in a new worktree. The reply (`Event::Reply`) holds `{sessionId, branch}`.
pub fn task_start(title: &str, prompt: &str) -> i64 {
    task_start_with(title, prompt, None, None)
}

/// Like `task_start`, optionally naming the branch and the agent to run it.
pub fn task_start_with(title: &str, prompt: &str, branch: Option<&str>, agent: Option<&str>) -> i64 {
    #[derive(Serialize)]
    struct Params<'a> {
        title: &'a str,
        prompt: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        branch: Option<&'a str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        agent: Option<&'a str>,
    }
    request("task/start", Params { title, prompt, branch, agent })
}

/// The reply (`Event::Reply`) decodes with `parse_last_message`.
pub fn last_message(session_id: &str) -> i64 {
    #[derive(Serialize)]
    struct Params<'a> {
        id: &'a str,
    }
    request("session/last_message", Params { id: session_id })
}

/// The reply (`Event::Reply`) decodes with `parse_agents`.
pub fn agent_list() -> i64 {
    #[derive(Serialize)]
    struct Params {}
    request("agent/list", Params {})
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Agent {
    pub id: String,
    pub name: String,
}

/// `{"message": "..."}` gives `Some`; `null` or a missing key gives `None`.
pub fn parse_last_message(result: &Value) -> Option<String> {
    result.get("message")?.as_str().map(str::to_owned)
}

/// Malformed results give an empty list.
pub fn parse_agents(result: &Value) -> Vec<Agent> {
    result.get("agents").and_then(|a| Vec::<Agent>::deserialize(a).ok()).unwrap_or_default()
}

/// The reply arrives as `Event::Stored`.
pub fn storage_get(key: &str) -> i64 {
    typed_request("storage/get", json!({"key": key}), Typed::Storage)
}

/// A `null` value deletes the key.
pub fn storage_set<T: Serialize + ?Sized>(key: &str, value: &T) -> i64 {
    #[derive(Serialize)]
    struct Params<'a, T: ?Sized> {
        key: &'a str,
        value: &'a T,
    }
    request("storage/set", Params { key, value })
}

/// Payloads stay raw until their method is known, so the snapshot is parsed once,
/// straight into typed structs, never through a generic `Value` tree.
#[derive(Deserialize)]
struct Incoming<'a> {
    #[serde(default)]
    id: Option<Value>,
    #[serde(default)]
    method: Option<String>,
    #[serde(borrow, default)]
    params: Option<&'a RawValue>,
    #[serde(borrow, default)]
    result: Option<&'a RawValue>,
    #[serde(borrow, default)]
    error: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct StoragePayload<'a> {
    #[serde(borrow, default)]
    value: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct SnapshotPayload {
    snapshot: Snapshot,
}

#[derive(Deserialize)]
struct ActivateParams {
    project: ProjectRef,
    #[serde(default)]
    grants: Vec<String>,
}

#[derive(Deserialize)]
struct ProjectRef {
    id: String,
    name: String,
}

#[derive(Deserialize)]
struct TickParams {
    dt: u32,
}

#[derive(Deserialize)]
struct ClickParams {
    tab: u32,
    region: String,
}

#[derive(Deserialize)]
struct ViewEventParams {
    tab: u32,
    id: String,
    kind: String,
    #[serde(default)]
    value: Option<String>,
}

#[derive(Deserialize)]
struct TaskFailedParams {
    #[serde(rename = "sessionId")]
    session_id: String,
    reason: String,
}

fn parse<'a, T: Deserialize<'a>>(raw: Option<&'a RawValue>) -> Option<T> {
    serde_json::from_str(raw?.get()).ok()
}

/// Parses one incoming message and hands it to `plugin`. Activation is answered
/// before the plugin sees it, so a plugin cannot forget the handshake.
pub fn dispatch<P: Plugin>(plugin: &mut P, bytes: &[u8]) {
    let Ok(message) = serde_json::from_slice::<Incoming>(bytes) else { return };
    let event = match message.method.as_deref() {
        Some("alas/activate") => {
            send(&json!({"jsonrpc": "2.0", "id": message.id, "result": {}}));
            let Some(params) = parse::<ActivateParams>(message.params) else { return };
            Event::Activate { project_id: params.project.id, project_name: params.project.name, grants: params.grants }
        }
        Some("alas/deactivate") => Event::Deactivate,
        Some("workspace/changed") => match parse::<SnapshotPayload>(message.params) {
            Some(payload) => Event::WorkspaceChanged(payload.snapshot),
            None => return,
        },
        Some("tick") => match parse::<TickParams>(message.params) {
            Some(params) => Event::Tick { dt: params.dt },
            None => return,
        },
        Some("canvas/click") => match parse::<ClickParams>(message.params) {
            Some(params) => Event::Click { tab: params.tab, region: params.region },
            None => return,
        },
        Some("view/event") => match parse::<ViewEventParams>(message.params) {
            Some(p) => Event::ViewEvent { tab: p.tab, id: p.id, kind: p.kind, value: p.value },
            None => return,
        },
        Some("task/failed") => match parse::<TaskFailedParams>(message.params) {
            Some(p) => Event::TaskFailed { session_id: p.session_id, reason: p.reason },
            None => return,
        },
        Some(_) => return,
        None => {
            let Some(id) = message.id.as_ref().and_then(Value::as_i64) else { return };
            let typed = take_typed(id);
            match (parse::<RpcError>(message.error), typed) {
                (Some(error), Some(Typed::Storage)) => Event::Stored { id, value: Err(error) },
                (Some(error), _) => Event::Reply { id, result: Err(error) },
                (None, Some(Typed::Snapshot)) => match parse::<SnapshotPayload>(message.result) {
                    Some(payload) => Event::Snapshot(payload.snapshot),
                    None => return,
                },
                (None, Some(Typed::Storage)) => match parse::<StoragePayload>(message.result) {
                    Some(payload) => Event::Stored { id, value: Ok(payload.value.map(|raw| raw.get().to_string())) },
                    None => return,
                },
                (None, None) => {
                    let result = message.result.and_then(|raw| serde_json::from_str(raw.get()).ok()).unwrap_or(Value::Null);
                    Event::Reply { id, result: Ok(result) }
                }
            }
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

    /// The snapshot is the one large payload; it must decode straight into typed structs.
    #[test]
    fn a_snapshot_reply_arrives_as_a_typed_snapshot_and_other_replies_stay_values() {
        test_host::take_sent();
        let snapshot_id = request_snapshot();
        assert_eq!(test_host::take_sent()[0]["method"], "workspace/snapshot");
        let other_id = request("worktree/switch", json!({"id": "w"}));
        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":snapshot_id,"result":{"snapshot":{"worktrees":[
            {"id":"w","branch":"main","current":false,"dirty":{"files":2,"conflicts":0},"sessions":[]}]}}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":other_id,"result":{}}));
        let Event::Snapshot(snapshot) = &plugin.0[0] else { panic!("expected a snapshot, got {:?}", plugin.0[0]) };
        assert_eq!(snapshot.worktrees[0].dirty, Some(Dirty { files: 2, conflicts: 0 }));
        assert_eq!(plugin.0[1], Event::Reply { id: other_id, result: Ok(json!({})) });
    }

    #[test]
    fn storage_replies_arrive_as_raw_text() {
        let (set, unset, failed) = (storage_get("a"), storage_get("b"), storage_get("c"));
        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":set,"result":{"value":{"n":1.0}}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":unset,"result":{"value":null}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":failed,"error":{"code":-32003,"message":"no"}}));
        assert_eq!(plugin.0, vec![
            Event::Stored { id: set, value: Ok(Some(r#"{"n":1.0}"#.into())) },
            Event::Stored { id: unset, value: Ok(None) },
            Event::Stored { id: failed, value: Err(RpcError { code: -32003, message: "no".into() }) },
        ]);
    }

    #[test]
    fn malformed_messages_are_ignored() {
        let mut plugin = Recorder::default();
        dispatch(&mut plugin, b"{not json");
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"workspace/changed","params":{"snapshot":5}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"tick","params":"x"}));
        assert!(plugin.0.is_empty());
    }

    #[test]
    fn regions_encode_as_the_wire_shape() {
        test_host::take_sent();
        set_regions(0, &[Region { id: "r0".into(), label: "L".into(), rect: [1, 2, 3, 4] }]);
        assert_eq!(test_host::take_sent()[0]["params"],
            json!({"tab": 0, "regions": [{"id": "r0", "label": "L", "rect": [1, 2, 3, 4]}]}));
    }

    #[test]
    fn view_nodes_encode_to_the_wire_shape() {
        test_host::take_sent();
        let s = |v: &str| v.to_string();
        let tree = Node::Vstack { id: s("root"), spacing: None, width: Some(300), children: vec![
            Node::TextField { id: s("t"), value: s("v"), placeholder: Some(s("p")), multiline: false },
            Node::Menu { id: s("m"), label: s("M"), items: vec![MenuItem { id: s("a"), label: s("A") }] },
            Node::Card { id: s("c"), tone: Some(Tone::Warn), clickable: true, width: None, children: vec![
                Node::Button { id: s("b"), label: s("B"), icon: None, style: Some(ButtonStyle::Primary), disabled: false },
            ] },
        ] };
        render(2, &tree);
        assert_eq!(test_host::take_sent()[0], json!({"jsonrpc":"2.0","method":"view/render","params":{"tab":2,"root":{
            "kind":"vstack","id":"root","width":300,"children":[
                {"kind":"textField","id":"t","value":"v","placeholder":"p"},
                {"kind":"menu","id":"m","label":"M","items":[{"id":"a","label":"A"}]},
                {"kind":"card","id":"c","tone":"warn","clickable":true,"children":[
                    {"kind":"button","id":"b","label":"B","style":"primary"}]}]}}}));
    }

    #[test]
    fn view_events_and_task_failures_decode() {
        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"view/event","params":{"tab":1,"id":"f","kind":"select","value":"x"}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"view/event","params":{"tab":1,"id":"b","kind":"click"}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"task/failed","params":{"sessionId":"s","reason":"boom"}}));
        assert_eq!(plugin.0, vec![
            Event::ViewEvent { tab: 1, id: "f".into(), kind: "select".into(), value: Some("x".into()) },
            Event::ViewEvent { tab: 1, id: "b".into(), kind: "click".into(), value: None },
            Event::TaskFailed { session_id: "s".into(), reason: "boom".into() },
        ]);
    }

    #[test]
    fn task_and_storage_helpers_send_the_documented_requests() {
        test_host::take_sent();
        task_start("T", "do it");
        storage_get("k");
        storage_set("k", &json!([1]));
        last_message("s1");
        agent_list();
        task_start_with("t", "p", Some("task/kan-3"), Some("claude"));
        let sent = test_host::take_sent();
        assert_eq!((sent[0]["method"].clone(), sent[0]["params"].clone()), (json!("task/start"), json!({"title":"T","prompt":"do it"})));
        assert_eq!((sent[1]["method"].clone(), sent[1]["params"].clone()), (json!("storage/get"), json!({"key":"k"})));
        assert_eq!((sent[2]["method"].clone(), sent[2]["params"].clone()), (json!("storage/set"), json!({"key":"k","value":[1]})));
        assert_eq!((sent[3]["method"].clone(), sent[3]["params"].clone()), (json!("session/last_message"), json!({"id":"s1"})));
        assert_eq!((sent[4]["method"].clone(), sent[4]["params"].clone()), (json!("agent/list"), json!({})));
        assert_eq!(sent[5]["params"], json!({"title":"t","prompt":"p","branch":"task/kan-3","agent":"claude"}));

        assert_eq!(parse_last_message(&json!({"message":"hi"})), Some("hi".into()));
        assert_eq!(parse_last_message(&json!({"message":null})), None);
        assert_eq!(parse_agents(&json!({"agents":[{"id":"a","name":"A"}]})), vec![Agent { id: "a".into(), name: "A".into() }]);
        assert!(parse_agents(&json!({"agents":"x"})).is_empty() && parse_agents(&json!(null)).is_empty());
    }
}
