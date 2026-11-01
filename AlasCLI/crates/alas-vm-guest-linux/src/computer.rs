//! Answers `computer_*` requests in a Linux VM by translating them into Cua Driver tool calls.
//! Payloads and error texts mirror `ComputerUseCoordinator` on macOS, so the host and agents see
//! one shape whichever guest answers.

use crate::cua::{CuaDriver, CuaError, CuaResult};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// The Cua Driver calls `Computer` makes; a scripted fake stands in for it in tests.
pub trait Driver {
    fn call(&mut self, tool: &str, args: Value, timeout: Duration) -> Result<CuaResult, CuaError>;
    /// Whether the driver runs and answered the MCP handshake, for the hello's capabilities.
    fn available(&mut self) -> bool;
}

impl Driver for CuaDriver {
    fn call(&mut self, tool: &str, args: Value, timeout: Duration) -> Result<CuaResult, CuaError> {
        CuaDriver::call(self, tool, args, timeout)
    }

    fn available(&mut self) -> bool {
        CuaDriver::available(self)
    }
}

/// Elapsed time and sleeping, so polling loops can run on a virtual clock in tests.
pub trait Clock: Send + Sync {
    fn now(&self) -> Duration;
    fn sleep(&self, duration: Duration);
}

struct SystemClock(Instant);

impl Clock for SystemClock {
    fn now(&self) -> Duration {
        self.0.elapsed()
    }

    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// Cancel flags of the calls in flight, by session and `call_id`.
type CallFlags = HashMap<(String, String), Arc<AtomicBool>>;

/// Stops in-flight calls by their `call_id` from any thread, without the `Computer`.
#[derive(Clone, Default)]
pub struct Canceller {
    calls: Arc<Mutex<CallFlags>>,
}

impl Canceller {
    /// Stops the session's call with `call_id`; another session's call with that id is left alone.
    pub fn cancel(&self, session: &str, call_id: &str) {
        let calls = self.calls.lock().unwrap();
        if let Some(flag) = calls.get(&(session.to_string(), call_id.to_string())) {
            flag.store(true, Ordering::SeqCst);
        }
    }

    /// Stops every call of the session in flight.
    pub fn cancel_session(&self, session: &str) {
        for ((owner, _), flag) in self.calls.lock().unwrap().iter() {
            if owner == session {
                flag.store(true, Ordering::SeqCst);
            }
        }
    }

    fn register(&self, session: &str, call_id: &str, flag: &Arc<AtomicBool>) {
        self.calls
            .lock()
            .unwrap()
            .insert((session.to_string(), call_id.to_string()), Arc::clone(flag));
    }

    /// Forgets the call, unless a later call with the same id took its place.
    fn unregister(&self, session: &str, call_id: &str, flag: &Arc<AtomicBool>) {
        let mut calls = self.calls.lock().unwrap();
        let key = (session.to_string(), call_id.to_string());
        if calls
            .get(&key)
            .is_some_and(|current| Arc::ptr_eq(current, flag))
        {
            calls.remove(&key);
        }
    }
}

// MARK: - Messages, copied from `ComputerUseCoordinator.Message`.

mod message {
    pub const CANCELLED: &str = "computer_cancelled: The call was cancelled.";
    pub const LIMIT: &str = "computer_limit: The result exceeds the response limit. Inspect with a query or a smaller limit.";
    pub const NO_QUITTING: &str = "Agents can't quit apps.";
    pub const NO_CROSS_APP_DRAG: &str = "Dragging between different apps isn't supported yet.";
    /// Linux only: Cua Driver couldn't be started.
    pub const UNAVAILABLE: &str = "computer_unavailable: Cua Driver isn't running in this VM.";
    /// Linux only: appended to a foreground failure while the screen locker shows.
    pub const SCREEN_LOCKED: &str = "The Linux VM's screen is locked.";
    pub const FOREGROUND_UNAVAILABLE: &str =
        "The window couldn't be brought to the front, so no input was sent.";

    pub fn window_not_found(id: u32) -> String {
        format!("computer_window_not_found: No on-screen window {id}. Call computer_apps again.")
    }
    pub fn capture_failed(reason: &str) -> String {
        format!("computer_capture_failed: {reason}")
    }
    pub fn stale(reference: &str, window_id: u32) -> String {
        format!(
            "computer_stale: The element ref {reference} is no longer valid. Call computer_inspect on window {window_id} again."
        )
    }
    pub fn needs_screenshot(window_id: u32) -> String {
        format!(
            "computer_needs_screenshot: x/y are pixels in a screenshot of window {window_id}. Call computer_screenshot first."
        )
    }
    pub fn out_of_bounds(window_id: u32) -> String {
        format!("computer_out_of_bounds: The point is outside window {window_id}.")
    }
    pub fn screenshot_moved(window_id: u32) -> String {
        format!(
            "computer_out_of_bounds: Window {window_id} moved or resized since its screenshot. Call computer_screenshot again."
        )
    }
    pub fn action_failed(reason: &str) -> String {
        format!("computer_action_failed: {reason}")
    }
    pub fn open_failed(reason: &str) -> String {
        format!("computer_open_failed: {reason}")
    }
    pub fn wait_timeout(query: &str, appear: bool, window_id: u32, ms: u64) -> String {
        let verb = if appear { "appeared" } else { "disappeared" };
        format!(
            "computer_wait_timeout: Nothing matching \"{query}\" {verb} in window {window_id} within {ms} ms."
        )
    }
    pub fn wait_inconclusive(query: &str, window_id: u32, ms: u64) -> String {
        format!(
            "computer_wait_timeout: Couldn't confirm that \"{query}\" disappeared from window {window_id} within {ms} ms: the window's accessibility tree couldn't be read completely, so it may still be there."
        )
    }
}

/// `ComputerUseCoordinator.resultLimit`.
const RESULT_LIMIT: usize = 12 * 1024 * 1024;
/// The long edge of every screenshot, as on macOS; Cua scales x/y by the same capture.
const MAX_IMAGE_DIMENSION: u32 = 1280;
const SETTLE_DELAY: Duration = Duration::from_millis(300);
const POLL_INTERVAL: Duration = Duration::from_millis(250);
const OPEN_APP_WAIT: Duration = Duration::from_secs(10);
const READ_TIMEOUT: Duration = Duration::from_secs(15);
const INPUT_TIMEOUT: Duration = Duration::from_secs(30);
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_DEPTH_LIMIT: u32 = 32;

#[derive(Debug, Clone, Copy, PartialEq)]
struct Rect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

impl Rect {
    /// Cua's `{x, y, width, height}` window bounds.
    fn bounds(value: &Value) -> Option<Self> {
        Some(Self {
            x: value.get("x")?.as_f64()?,
            y: value.get("y")?.as_f64()?,
            width: value.get("width")?.as_f64()?,
            height: value.get("height")?.as_f64()?,
        })
    }

    /// Cua's `{x, y, w, h}` element frame.
    fn element_frame(value: &Value) -> Option<Self> {
        Some(Self {
            x: value.get("x")?.as_f64()?,
            y: value.get("y")?.as_f64()?,
            width: value.get("w")?.as_f64()?,
            height: value.get("h")?.as_f64()?,
        })
    }

    const ZERO: Self = Self {
        x: 0.0,
        y: 0.0,
        width: 0.0,
        height: 0.0,
    };

    fn json(self) -> Value {
        json!({"x": self.x, "y": self.y, "width": self.width, "height": self.height})
    }
}

/// The latest screenshot of a window: what its x/y pixels mean.
#[derive(Debug, Clone)]
struct Shot {
    capture_id: String,
    width: f64,
    height: f64,
    window_bounds: Rect,
}

impl Shot {
    fn scale(&self) -> f64 {
        if self.window_bounds.width > 0.0 {
            self.width / self.window_bounds.width
        } else {
            1.0
        }
    }
}

/// What a ref names: the token Cua acts on, and its frame in screen points.
#[derive(Debug, Clone)]
struct ElementRef {
    token: String,
    frame: Option<Rect>,
}

#[derive(Default)]
struct Session {
    /// Per window, the refs its latest read named.
    refs: HashMap<u32, HashMap<String, ElementRef>>,
    shots: HashMap<u32, Shot>,
}

/// A window as `list_windows` reports it.
#[derive(Debug, Clone)]
struct Window {
    id: u32,
    pid: u64,
    app_name: String,
    title: String,
    bounds: Rect,
    on_screen: bool,
}

impl Window {
    fn parse(value: &Value) -> Option<Self> {
        Some(Self {
            id: u32::try_from(value.get("window_id")?.as_u64()?).ok()?,
            pid: value.get("pid")?.as_u64()?,
            app_name: str_field(value, "app_name").unwrap_or_default(),
            title: str_field(value, "title").unwrap_or_default(),
            bounds: value.get("bounds").and_then(Rect::bounds)?,
            on_screen: value.get("is_on_screen").and_then(Value::as_bool) != Some(false),
        })
    }

    /// `ComputerUseCoordinator.windowEntry`.
    fn entry(&self) -> Value {
        let mut entry = json!({"window_id": self.id, "frame": self.bounds.json()});
        if !self.on_screen {
            entry["off_screen"] = json!(true);
        }
        if !self.title.is_empty() {
            entry["title"] = json!(self.title);
        }
        entry
    }
}

/// An app as payloads name it: `bundle_id` is its `.desktop` id.
#[derive(Debug, Clone)]
struct App {
    name: String,
    pid: u64,
    bundle_id: Option<String>,
}

impl App {
    /// `ComputerUseCoordinator.app`.
    fn json(&self) -> Value {
        let mut object = json!({"name": self.name, "pid": self.pid});
        if let Some(bundle_id) = &self.bundle_id {
            object["bundle_id"] = json!(bundle_id);
        }
        object
    }
}

/// `list_apps`, indexed: running apps by pid, and installed `.desktop` entries.
#[derive(Default)]
struct AppIndex {
    running: HashMap<u64, (String, Option<String>)>,
    /// `(desktop id, name)`.
    desktop: Vec<(String, String)>,
}

impl AppIndex {
    fn parse(structured: &Value) -> Self {
        let mut index = Self::default();
        for app in structured
            .get("apps")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let name = str_field(app, "name").unwrap_or_default();
            let bundle_id = str_field(app, "bundle_id");
            let pid = app.get("pid").and_then(Value::as_u64).unwrap_or(0);
            if pid > 0 && app.get("running").and_then(Value::as_bool) != Some(false) {
                index.running.insert(pid, (name.clone(), bundle_id.clone()));
            }
            if let Some(bundle_id) = bundle_id {
                index.desktop.push((bundle_id, name));
            }
        }
        index
    }

    /// The app of `pid`: its `list_apps` entry, else the `.desktop` entry whose id is its window
    /// class (`Org.xfce.mousepad` for `org.xfce.mousepad`), else the window class alone.
    fn app(&self, pid: u64, window_class: &str) -> App {
        if let Some((name, bundle_id)) = self.running.get(&pid)
            && (bundle_id.is_some() || window_class.is_empty())
        {
            return App {
                name: name.clone(),
                pid,
                bundle_id: bundle_id.clone(),
            };
        }
        if let Some((bundle_id, name)) = self
            .desktop
            .iter()
            .find(|(id, _)| !window_class.is_empty() && id.eq_ignore_ascii_case(window_class))
        {
            return App {
                name: name.clone(),
                pid,
                bundle_id: Some(bundle_id.clone()),
            };
        }
        let name = self
            .running
            .get(&pid)
            .map(|(name, _)| name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| window_class.to_string());
        App {
            name,
            pid,
            bundle_id: None,
        }
    }
}

/// Which kind of Cua call failed, for the error it maps to.
#[derive(Clone, Copy)]
enum Kind<'a> {
    Read,
    /// An input; `reference` is the ref it targets, if any.
    Input {
        reference: Option<&'a str>,
    },
    /// `launch_app`; any failure is `computer_open_failed` with this reason.
    Launch(&'a str),
}

/// One call in flight.
struct Call {
    session: String,
    window_id: Option<u32>,
    cancelled: Arc<AtomicBool>,
}

impl Call {
    fn check(&self) -> Result<(), String> {
        if self.cancelled.load(Ordering::SeqCst) {
            Err(message::CANCELLED.to_string())
        } else {
            Ok(())
        }
    }
}

#[derive(Debug, Default, Deserialize)]
struct Params {
    window_id: Option<u32>,
    query: Option<String>,
    limit: Option<u32>,
    max_depth: Option<u32>,
    call_id: Option<String>,
    #[serde(rename = "ref")]
    reference: Option<String>,
    x: Option<f64>,
    y: Option<f64>,
    to_window_id: Option<u32>,
    to_ref: Option<String>,
    to_x: Option<f64>,
    to_y: Option<f64>,
    #[serde(default)]
    modifiers: Vec<String>,
    button: Option<String>,
    count: Option<u32>,
    text: Option<String>,
    mode: Option<String>,
    keys: Option<String>,
    #[serde(default)]
    dx: i32,
    #[serde(default)]
    dy: i32,
    name: Option<String>,
    bundle_id: Option<String>,
    condition: Option<String>,
    timeout_ms: Option<u64>,
    #[serde(default)]
    include_screenshot: bool,
}

const INPUT_ACTIONS: [&str; 5] = ["click", "type", "key", "scroll", "drag"];

impl Params {
    /// `ComputerUseCommand.Action.defaultLimit`.
    fn limit(&self, action: &str) -> u32 {
        self.limit.unwrap_or(match action {
            "apps" | "screenshot" | "inspect" | "cancel" => 300,
            _ => 100,
        })
    }

    /// `ComputerUseCommand.defaultMaxDepth(for:query:)`.
    fn max_depth(&self, action: &str) -> u32 {
        self.max_depth.unwrap_or(
            if (INPUT_ACTIONS.contains(&action) || action == "inspect" || action == "wait")
                && self.query.is_some()
            {
                MAX_DEPTH_LIMIT
            } else {
                12
            },
        )
    }
}

/// An element read of a window.
struct Read {
    elements: Vec<Value>,
    refs: HashMap<String, ElementRef>,
    truncated: bool,
}

/// A point in a window's screenshot pixels, and the capture it belongs to.
struct Point {
    x: f64,
    y: f64,
    capture_id: String,
}

pub struct Computer<D: Driver> {
    driver: D,
    clock: Arc<dyn Clock>,
    sessions: HashMap<String, Session>,
    /// `list_apps`, read on first need and again for a pid it doesn't know.
    apps: Option<AppIndex>,
    /// The app of each pid named so far.
    identities: HashMap<u64, App>,
    canceller: Canceller,
}

impl<D: Driver> Computer<D> {
    pub fn new(driver: D) -> Self {
        Self::with_clock(driver, Arc::new(SystemClock(Instant::now())))
    }

    pub(crate) fn with_clock(driver: D, clock: Arc<dyn Clock>) -> Self {
        Self {
            driver,
            clock,
            sessions: HashMap::new(),
            apps: None,
            identities: HashMap::new(),
            canceller: Canceller::default(),
        }
    }

    /// A handle that cancels this computer's calls from another thread.
    pub fn canceller(&self) -> Canceller {
        self.canceller.clone()
    }

    /// The driver, for its `available` probe.
    pub fn driver_mut(&mut self) -> &mut D {
        &mut self.driver
    }

    /// Answers a `{"command":"computer_<action>","params":{…}}` request with an
    /// `AlasCLIResponse` encoding. The helper uses `perform_with_cancel`.
    #[cfg(test)]
    pub fn perform(&mut self, session: &str, request: &Value) -> Value {
        self.perform_with_cancel(session, request, Arc::new(AtomicBool::new(false)))
    }

    /// `perform`, stopped once `cancelled` is set, whether by its `call_id` or by the caller.
    /// A call cancelled before it starts never reaches the driver.
    pub fn perform_with_cancel(
        &mut self,
        session: &str,
        request: &Value,
        cancelled: Arc<AtomicBool>,
    ) -> Value {
        let action = request
            .get("command")
            .and_then(Value::as_str)
            .and_then(|command| command.strip_prefix("computer_"))
            .unwrap_or_default()
            .to_string();
        let params = match request.get("params") {
            None | Some(Value::Null) => Ok(Params::default()),
            Some(params) => Params::deserialize(params),
        };
        let Ok(params) = params else {
            return error_response(&message::action_failed("The request is malformed."));
        };
        if action == "cancel" {
            if let Some(call_id) = &params.call_id {
                self.canceller.cancel(session, call_id);
            }
            return json!({"ok": true});
        }
        let call = Call {
            session: session.to_string(),
            window_id: params.window_id,
            cancelled,
        };
        if let Err(error) = call.check() {
            return error_response(&error);
        }
        if let Some(call_id) = &params.call_id {
            self.canceller.register(session, call_id, &call.cancelled);
        }
        let result = self.execute(&action, &params, &call);
        if let Some(call_id) = &params.call_id {
            self.canceller.unregister(session, call_id, &call.cancelled);
        }
        match result {
            Ok(payload) => {
                let line = payload.to_string();
                if line.len() > RESULT_LIMIT {
                    error_response(message::LIMIT)
                } else {
                    json!({"ok": true, "lines": [line]})
                }
            }
            Err(error) => error_response(&error),
        }
    }

    /// Refs and screenshots from the ended turn are no longer valid.
    pub fn turn_ended(&mut self, session: &str) {
        self.sessions.remove(session);
    }

    pub fn session_ended(&mut self, session: &str) {
        self.sessions.remove(session);
        self.canceller.cancel_session(session);
    }

    fn execute(&mut self, action: &str, params: &Params, call: &Call) -> Result<Value, String> {
        match action {
            "apps" => return self.list_apps(call),
            "open_app" => return self.open_app(params, call),
            "screenshot" | "inspect" | "wait" => {}
            _ if INPUT_ACTIONS.contains(&action) => {}
            _ => return Err(message::action_failed("The request is malformed.")),
        }
        let window_id = params
            .window_id
            .ok_or_else(|| message::window_not_found(0))?;
        let window = self.window(call, window_id)?;
        let app = self.app(call, &window);
        let mut payload = json!({"version": 1, "window_id": window.id, "app": app.json()});
        match action {
            "screenshot" => {
                let (shot, png, title) = self.capture(call, &window, true)?;
                let title = if title.is_empty() {
                    window.title.clone()
                } else {
                    title
                };
                payload["window"] = json!({"frame": shot.window_bounds.json()});
                // macOS leaves out a window's missing title.
                if !title.is_empty() {
                    payload["window"]["title"] = json!(title);
                }
                payload["image_size"] =
                    json!({"width": shot.width as u64, "height": shot.height as u64});
                payload["scale"] = json!(shot.scale());
                payload["captured_at"] = json!(iso8601_now());
                payload["image"] = image(&png);
            }
            "inspect" => {
                let read = self.read(call, &window, params, action, true)?;
                payload["truncated"] = json!(read.truncated);
                payload["elements"] = Value::Array(read.elements);
            }
            "wait" => {
                let read = self.wait(call, &window, params)?;
                payload["truncated"] = json!(read.truncated);
                payload["elements"] = Value::Array(read.elements);
            }
            _ => {
                let delivery = self.input(action, params, call, &window)?;
                self.clock.sleep(SETTLE_DELAY);
                call.check()?;
                payload["action"] = json!(action);
                payload["delivery"] = json!(delivery);
                let read = self.read(call, &window, params, action, true)?;
                payload["truncated"] = json!(read.truncated);
                payload["elements"] = Value::Array(read.elements);
                if params.include_screenshot {
                    match self.capture(call, &window, true) {
                        Ok((shot, png, _)) => {
                            payload["scale"] = json!(shot.scale());
                            payload["image"] = image(&png);
                        }
                        Err(error) if error == message::CANCELLED => return Err(error),
                        Err(error) => payload["screenshot_error"] = json!(error),
                    }
                }
            }
        }
        Ok(payload)
    }

    // MARK: - Reads

    fn list_apps(&mut self, call: &Call) -> Result<Value, String> {
        let listed = self.cua(
            call,
            "list_windows",
            json!({"on_screen_only": false}),
            READ_TIMEOUT,
            Kind::Read,
        )?;
        let windows = parse_windows(&listed.structured);
        self.refresh_apps(call)?;
        let mut by_pid: BTreeMap<u64, Vec<Window>> = BTreeMap::new();
        for window in windows {
            by_pid.entry(window.pid).or_default().push(window);
        }
        let index = self.apps.as_ref().expect("just read");
        let identities = &mut self.identities;
        let mut entries: Vec<(String, u64, Value)> = by_pid
            .into_iter()
            .map(|(pid, windows)| {
                let app = index.app(pid, &windows[0].app_name);
                identities.insert(pid, app.clone());
                let mut object = app.json();
                // The VM is the permission: every app in it is allowed.
                object["approval"] = json!("allowed");
                object["windows"] = windows.iter().map(Window::entry).collect();
                (app.name.to_lowercase(), pid, object)
            })
            .collect();
        entries.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        Ok(json!({
            "version": 1,
            "apps": entries.into_iter().map(|(_, _, object)| object).collect::<Vec<_>>(),
        }))
    }

    fn open_app(&mut self, params: &Params, call: &Call) -> Result<Value, String> {
        let reason = match (&params.name, &params.bundle_id) {
            (Some(name), _) => format!("No app named \"{name}\"."),
            (None, bundle_id) => format!(
                "No app with bundle id \"{}\".",
                bundle_id.as_deref().unwrap_or_default()
            ),
        };
        let target = params
            .bundle_id
            .as_ref()
            .or(params.name.as_ref())
            .cloned()
            .unwrap_or_default();
        let launched = self.cua(
            call,
            "launch_app",
            json!({"name": target}),
            LAUNCH_TIMEOUT,
            Kind::Launch(&reason),
        )?;
        let pid = ["pid", "launcher_pid"]
            .iter()
            .find_map(|key| launched.structured.get(key).and_then(Value::as_u64))
            .filter(|pid| *pid > 0)
            .ok_or_else(|| message::open_failed(&reason))?;
        let launched_name = str_field(&launched.structured, "name").unwrap_or(target);
        // The app shows its window a moment after it starts.
        let deadline = self.clock.now() + OPEN_APP_WAIT;
        let windows = loop {
            let listed = self.cua(
                call,
                "list_windows",
                json!({"pid": pid}),
                READ_TIMEOUT,
                Kind::Read,
            )?;
            let windows: Vec<Window> = parse_windows(&listed.structured)
                .into_iter()
                .filter(|window| window.pid == pid)
                .collect();
            if !windows.is_empty() || self.clock.now() >= deadline {
                break windows;
            }
            self.clock.sleep(POLL_INTERVAL);
            call.check()?;
        };
        let class = windows
            .first()
            .map_or(launched_name, |window| window.app_name.clone());
        let app = self.app(
            call,
            &Window {
                id: 0,
                pid,
                app_name: class,
                title: String::new(),
                bounds: Rect::ZERO,
                on_screen: true,
            },
        );
        Ok(json!({
            "version": 1,
            "app": app.json(),
            "windows": windows.iter().map(Window::entry).collect::<Vec<_>>(),
        }))
    }

    /// The window as `list_windows` reports it now.
    fn window(&mut self, call: &Call, id: u32) -> Result<Window, String> {
        let listed = self.cua(
            call,
            "list_windows",
            json!({"on_screen_only": false}),
            READ_TIMEOUT,
            Kind::Read,
        )?;
        parse_windows(&listed.structured)
            .into_iter()
            .find(|window| window.id == id)
            .ok_or_else(|| message::window_not_found(id))
    }

    /// The app that owns `window`. `list_apps` is read again only for a pid not named before.
    fn app(&mut self, call: &Call, window: &Window) -> App {
        if let Some(app) = self.identities.get(&window.pid) {
            return app.clone();
        }
        if self.refresh_apps(call).is_err() {
            // Without a listing the window's own class names it.
            return AppIndex::default().app(window.pid, &window.app_name);
        }
        let app = self
            .apps
            .as_ref()
            .expect("just read")
            .app(window.pid, &window.app_name);
        self.identities.insert(window.pid, app.clone());
        app
    }

    fn refresh_apps(&mut self, call: &Call) -> Result<(), String> {
        let listed = self.cua(call, "list_apps", json!({}), READ_TIMEOUT, Kind::Read)?;
        self.apps = Some(AppIndex::parse(&listed.structured));
        // A pid may belong to another app by now.
        self.identities.clear();
        Ok(())
    }

    /// Takes a screenshot of the window. `record` makes it what the agent's x/y pixels mean; a
    /// capture the agent never saw must not be.
    fn capture(
        &mut self,
        call: &Call,
        window: &Window,
        record: bool,
    ) -> Result<(Shot, String, String), String> {
        let state = self.cua(
            call,
            "get_window_state",
            json!({
                "pid": window.pid,
                "window_id": window.id,
                "include_accessibility_tree": false,
                "max_image_dimension": MAX_IMAGE_DIMENSION,
            }),
            READ_TIMEOUT,
            Kind::Read,
        )?;
        let structured = &state.structured;
        let png = state
            .image_png_base64
            .clone()
            .ok_or_else(|| message::capture_failed("Cua Driver returned no screenshot."))?;
        let shot = (|| {
            Some(Shot {
                capture_id: str_field(structured, "capture_id")?,
                width: structured.get("screenshot_width")?.as_f64()?,
                height: structured.get("screenshot_height")?.as_f64()?,
                window_bounds: structured.get("window_bounds").and_then(Rect::bounds)?,
            })
        })()
        .ok_or_else(|| message::capture_failed("Cua Driver returned an incomplete screenshot."))?;
        let title = str_field(structured, "window_title").unwrap_or_default();
        if record {
            self.session(&call.session)
                .shots
                .insert(window.id, shot.clone());
        }
        Ok((shot, png, title))
    }

    /// Reads the window's elements; `record` replaces its refs with the ones this read names.
    fn read(
        &mut self,
        call: &Call,
        window: &Window,
        params: &Params,
        action: &str,
        record: bool,
    ) -> Result<Read, String> {
        let mut args = json!({
            "pid": window.pid,
            "window_id": window.id,
            "include_screenshot": false,
            "tree_format": "elements",
            "max_elements": params.limit(action),
            "max_depth": params.max_depth(action),
        });
        if let Some(query) = &params.query {
            args["query"] = json!(query);
        }
        let state = self.cua(call, "get_window_state", args, READ_TIMEOUT, Kind::Read)?;
        let read = map_elements(&state.structured);
        if record {
            self.record(call, window.id, read.refs.clone());
        }
        Ok(read)
    }

    fn record(&mut self, call: &Call, window_id: u32, refs: HashMap<String, ElementRef>) {
        self.session(&call.session).refs.insert(window_id, refs);
    }

    /// `ComputerUseCoordinator.waitFor`: reads until the query appears or disappears.
    fn wait(&mut self, call: &Call, window: &Window, params: &Params) -> Result<Read, String> {
        let query = params.query.clone().unwrap_or_default();
        let appear = params.condition.as_deref() != Some("disappear");
        let timeout_ms = params.timeout_ms.unwrap_or(5000);
        let deadline = self.clock.now() + Duration::from_millis(timeout_ms);
        loop {
            // Only the read returned to the agent replaces its refs.
            let read = self.read(call, window, params, "wait", false)?;
            // A partial read can miss the element, so only a complete one confirms it is gone.
            let met = if appear {
                !read.elements.is_empty()
            } else {
                read.elements.is_empty() && !read.truncated
            };
            if met {
                self.record(call, window.id, read.refs.clone());
                return Ok(read);
            }
            if self.clock.now() >= deadline {
                // The window changed while the agent waited; the refs it holds may point elsewhere.
                self.record(call, window.id, HashMap::new());
                return Err(if !appear && read.elements.is_empty() {
                    message::wait_inconclusive(&query, window.id, timeout_ms)
                } else {
                    message::wait_timeout(&query, appear, window.id, timeout_ms)
                });
            }
            self.clock.sleep(POLL_INTERVAL);
            call.check()?;
        }
    }

    // MARK: - Input

    /// Delivers the input and names how: `ax` for an element action, `activation` for one sent
    /// as real input events to the raised window.
    fn input(
        &mut self,
        action: &str,
        params: &Params,
        call: &Call,
        window: &Window,
    ) -> Result<&'static str, String> {
        let target = json!({"pid": window.pid, "window_id": window.id});
        let foreground = |mut args: Value| {
            args["delivery_mode"] = json!("foreground");
            args
        };
        match action {
            "click" => {
                let button = params.button.as_deref().unwrap_or("left");
                let count = params.count.unwrap_or(1);
                if let Some(reference) = &params.reference {
                    let element = self.element(call, window.id, reference)?;
                    let mut args = json!({"element_token": element.token});
                    if button != "left" {
                        args["button"] = json!(button);
                    }
                    if count != 1 {
                        args["count"] = json!(count);
                    }
                    self.input_call(call, "click", args, Some(reference))?;
                    return Ok("ax");
                }
                let point = self.point(call, window, params.x, params.y)?;
                let mut args = merge(&target, json!({"x": point.x, "y": point.y}));
                args["capture_id"] = json!(point.capture_id);
                args["button"] = json!(button);
                args["count"] = json!(count);
                self.input_call(call, "click", foreground(args), None)?;
                Ok("activation")
            }
            "type" => {
                let text = params.text.clone().unwrap_or_default();
                // Typing goes key by key: about 40 characters a second.
                let timeout =
                    INPUT_TIMEOUT + Duration::from_millis(text.chars().count() as u64 * 25);
                let Some(reference) = &params.reference else {
                    let args = merge(&target, json!({"text": text}));
                    self.cua(
                        call,
                        "type_text",
                        foreground(args),
                        timeout,
                        Kind::Input { reference: None },
                    )?;
                    return Ok("activation");
                };
                let element = self.element(call, window.id, reference)?;
                let at = merge(&target, json!({"element_token": element.token}));
                if params.mode.as_deref() == Some("replace") {
                    let select_all = merge(&at, json!({"keys": ["ctrl", "a"]}));
                    self.input_call(call, "hotkey", select_all, Some(reference))?;
                    call.check()?;
                }
                self.cua(
                    call,
                    "type_text",
                    merge(&at, json!({"text": text})),
                    timeout,
                    Kind::Input {
                        reference: Some(reference),
                    },
                )?;
                Ok("ax")
            }
            "key" => {
                let chord = params.keys.clone().unwrap_or_default();
                let keys = xkb_keys(&chord)?;
                let args = merge(&target, json!({"keys": keys}));
                self.input_call(call, "hotkey", foreground(args), None)?;
                Ok("activation")
            }
            "scroll" => {
                // A ref scrolls its element with Cua's default delivery; x/y are foreground input.
                let at = match &params.reference {
                    Some(reference) => {
                        let element = self.element(call, window.id, reference)?;
                        merge(&target, json!({"element_token": element.token}))
                    }
                    None => {
                        let point = self.point(call, window, params.x, params.y)?;
                        foreground(merge(&target, json!({"x": point.x, "y": point.y})))
                    }
                };
                let mut scrolls = Vec::new();
                for (delta, positive, negative) in
                    [(params.dy, "down", "up"), (params.dx, "right", "left")]
                {
                    let direction = if delta > 0 { positive } else { negative };
                    scrolls.extend(
                        scroll_steps(delta.unsigned_abs()).map(|amount| (direction, amount)),
                    );
                }
                for (index, (direction, amount)) in scrolls.into_iter().enumerate() {
                    if index > 0 {
                        call.check()?;
                    }
                    let args = merge(&at, json!({"direction": direction, "amount": amount}));
                    self.input_call(call, "scroll", args, params.reference.as_deref())?;
                }
                Ok(if params.reference.is_some() {
                    "ax"
                } else {
                    "activation"
                })
            }
            "drag" => {
                if params.to_window_id.is_some_and(|id| id != window.id) {
                    return Err(message::action_failed(message::NO_CROSS_APP_DRAG));
                }
                let mut modifiers: Vec<&'static str> = Vec::new();
                for modifier in &params.modifiers {
                    let key = drag_modifier(modifier)?;
                    if !modifiers.contains(&key) {
                        modifiers.push(key);
                    }
                }
                // x/y ends first: they must match the agent's own screenshot, which a ref end's
                // capture would replace.
                let from_point = match params.reference {
                    None => Some(self.point(call, window, params.x, params.y)?),
                    Some(_) => None,
                };
                let to_point = match params.to_ref {
                    None => Some(self.point(call, window, params.to_x, params.to_y)?),
                    Some(_) => None,
                };
                // Taken for the ref ends when the agent's screenshot doesn't fit; never recorded.
                let mut own_shot = None;
                let from = match (from_point, &params.reference) {
                    (Some(point), _) => point,
                    (None, reference) => self.ref_point(
                        call,
                        window,
                        reference.as_deref().unwrap_or_default(),
                        &mut own_shot,
                    )?,
                };
                let to = match (to_point, &params.to_ref) {
                    (Some(point), _) => point,
                    (None, reference) => self.ref_point(
                        call,
                        window,
                        reference.as_deref().unwrap_or_default(),
                        &mut own_shot,
                    )?,
                };
                let mut args = merge(
                    &target,
                    json!({"from_x": from.x, "from_y": from.y, "to_x": to.x, "to_y": to.y}),
                );
                if !modifiers.is_empty() {
                    args["modifier"] = json!(modifiers);
                }
                self.input_call(call, "drag", foreground(args), None)?;
                Ok("activation")
            }
            _ => Err(message::action_failed("The request is malformed.")),
        }
    }

    fn input_call(
        &mut self,
        call: &Call,
        tool: &str,
        args: Value,
        reference: Option<&str>,
    ) -> Result<CuaResult, String> {
        self.cua(call, tool, args, INPUT_TIMEOUT, Kind::Input { reference })
    }

    /// The element `reference` names in the window's latest read this turn.
    fn element(
        &mut self,
        call: &Call,
        window_id: u32,
        reference: &str,
    ) -> Result<ElementRef, String> {
        self.session(&call.session)
            .refs
            .get(&window_id)
            .and_then(|refs| refs.get(reference))
            .cloned()
            .ok_or_else(|| message::stale(reference, window_id))
    }

    /// The window's latest screenshot, if the window hasn't moved or resized since.
    fn shot(&mut self, call: &Call, window: &Window) -> Result<Shot, String> {
        let shot = self
            .session(&call.session)
            .shots
            .get(&window.id)
            .cloned()
            .ok_or_else(|| message::needs_screenshot(window.id))?;
        if shot.window_bounds != window.bounds {
            return Err(message::screenshot_moved(window.id));
        }
        Ok(shot)
    }

    /// x/y in pixels of the window's latest screenshot, passed on unchanged.
    fn point(
        &mut self,
        call: &Call,
        window: &Window,
        x: Option<f64>,
        y: Option<f64>,
    ) -> Result<Point, String> {
        let (Some(x), Some(y)) = (x, y) else {
            return Err(message::action_failed("The action needs a ref or x and y."));
        };
        let shot = self.shot(call, window)?;
        if !(0.0..=shot.width).contains(&x) || !(0.0..=shot.height).contains(&y) {
            return Err(message::out_of_bounds(window.id));
        }
        Ok(Point {
            x,
            y,
            capture_id: shot.capture_id,
        })
    }

    /// A ref's centre in pixels of the window's latest screenshot. Without one that still fits
    /// the window, `own` is used, taken first if it's empty: Cua's `drag` needs a screenshot as
    /// its frame too. `own` isn't recorded, so the agent's x/y still need its own screenshot.
    fn ref_point(
        &mut self,
        call: &Call,
        window: &Window,
        reference: &str,
        own: &mut Option<Shot>,
    ) -> Result<Point, String> {
        let element = self.element(call, window.id, reference)?;
        let shot = match self.shot(call, window) {
            Ok(shot) => shot,
            Err(_) => match own {
                Some(shot) => shot.clone(),
                None => own.insert(self.capture(call, window, false)?.0).clone(),
            },
        };
        let frame = element
            .frame
            .ok_or_else(|| message::out_of_bounds(window.id))?;
        let scale = shot.scale();
        let x = (frame.x + frame.width / 2.0 - shot.window_bounds.x) * scale;
        let y = (frame.y + frame.height / 2.0 - shot.window_bounds.y) * scale;
        if !(0.0..=shot.width).contains(&x) || !(0.0..=shot.height).contains(&y) {
            return Err(message::out_of_bounds(window.id));
        }
        Ok(Point {
            x,
            y,
            capture_id: shot.capture_id,
        })
    }

    // MARK: - Cua calls

    fn session(&mut self, session: &str) -> &mut Session {
        self.sessions.entry(session.to_string()).or_default()
    }

    /// Calls a Cua tool and maps a failure to the macOS error it stands for.
    fn cua(
        &mut self,
        call: &Call,
        tool: &str,
        args: Value,
        timeout: Duration,
        kind: Kind,
    ) -> Result<CuaResult, String> {
        call.check()?;
        let failed = |reason: &str| match kind {
            Kind::Read => message::capture_failed(reason),
            Kind::Input { .. } => message::action_failed(reason),
            Kind::Launch(open) => message::open_failed(open),
        };
        let result = match self.driver.call(tool, args, timeout) {
            Ok(result) => result,
            Err(CuaError::Unavailable(_)) => return Err(message::UNAVAILABLE.to_string()),
            Err(CuaError::Timeout) => return Err(failed("Cua Driver didn't answer in time.")),
            Err(CuaError::Exited) => return Err(failed("Cua Driver stopped before answering.")),
        };
        if !result.is_error {
            return Ok(result);
        }
        let window_id = call.window_id.unwrap_or(0);
        let code = result.structured.get("code").and_then(Value::as_str);
        match code {
            Some("foreground_unavailable") => {
                let mut reason = message::FOREGROUND_UNAVAILABLE.to_string();
                if self.screen_locked() {
                    reason.push(' ');
                    reason.push_str(message::SCREEN_LOCKED);
                }
                Err(message::action_failed(&reason))
            }
            Some("screenshot_context_missing") => {
                if let Some(id) = call.window_id {
                    self.session(&call.session).shots.remove(&id);
                }
                Err(message::screenshot_moved(window_id))
            }
            _ if matches!(kind, Kind::Launch(_)) => Err(failed("")),
            _ if result.text.contains("stale or no longer running") => {
                Err(message::window_not_found(window_id))
            }
            _ => match kind {
                Kind::Input {
                    reference: Some(reference),
                } if result.text.contains("stale") => Err(message::stale(reference, window_id)),
                _ => Err(failed(if result.text.is_empty() {
                    "Cua Driver reported an error."
                } else {
                    &result.text
                })),
            },
        }
    }

    /// Whether xfce4-screensaver shows its lock window: foreground input then goes to it.
    fn screen_locked(&mut self) -> bool {
        let Ok(listed) = self.driver.call(
            "list_windows",
            json!({"on_screen_only": true}),
            READ_TIMEOUT,
        ) else {
            return false;
        };
        parse_windows(&listed.structured).iter().any(|window| {
            window.app_name.to_lowercase().contains("xfce4-screensaver")
                || window.title.to_lowercase().contains("xfce4-screensaver")
        })
    }
}

pub(crate) fn error_response(message: &str) -> Value {
    json!({"ok": false, "error": message})
}

fn str_field(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

/// `base` with `extra`'s keys added.
fn merge(base: &Value, extra: Value) -> Value {
    let mut object: Map<String, Value> = base.as_object().cloned().unwrap_or_default();
    if let Value::Object(extra) = extra {
        object.extend(extra);
    }
    Value::Object(object)
}

fn parse_windows(structured: &Value) -> Vec<Window> {
    structured
        .get("windows")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Window::parse)
        .collect()
}

/// `ComputerUseCoordinator.image`.
fn image(png_base64: &str) -> Value {
    json!({"mime_type": "image/png", "data": png_base64})
}

/// Cua's `elements` tree as `ComputerUseCoordinator.element` writes elements, numbered `e1`… in
/// the order Cua lists them. An element Cua gives no frame is off screen.
fn map_elements(structured: &Value) -> Read {
    let mut elements = Vec::new();
    let mut refs = HashMap::new();
    for (index, element) in structured
        .get("elements")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let reference = format!("e{}", index + 1);
        let frame = element.get("frame").and_then(Rect::element_frame);
        let focused = element
            .get("states")
            .and_then(Value::as_array)
            .is_some_and(|states| states.iter().any(|state| state == "focused"));
        let mut object = json!({
            "ref": reference,
            "depth": element.get("depth").and_then(Value::as_u64).unwrap_or(0),
            "role": str_field(element, "role").unwrap_or_default(),
            "frame": frame.unwrap_or(Rect::ZERO).json(),
            "enabled": element.get("enabled").and_then(Value::as_bool).unwrap_or(true),
            "focused": focused,
        });
        if let Some(label) = str_field(element, "label") {
            object["title"] = json!(label);
        }
        match element.get("value") {
            Some(Value::String(value)) => object["value"] = json!(value),
            Some(value @ (Value::Number(_) | Value::Bool(_))) => {
                object["value"] = json!(value.to_string())
            }
            _ => {}
        }
        if let Some(description) = str_field(element, "description") {
            object["description"] = json!(description);
        }
        if frame.is_none() {
            object["visible"] = json!(false);
        }
        if let Some(token) = str_field(element, "element_token") {
            refs.insert(reference, ElementRef { token, frame });
        }
        elements.push(object);
    }
    Read {
        elements,
        refs,
        truncated: structured.get("truncated").and_then(Value::as_bool) == Some(true),
    }
}

/// A chord in `ComputerUseKeyChord` syntax as X keysym names for Cua's `hotkey`: command and
/// control are Ctrl, option is Alt.
fn xkb_keys(chord: &str) -> Result<Vec<String>, String> {
    let not_a_chord = || message::action_failed(&format!("\"{chord}\" is not a key chord."));
    let mut modifiers: Vec<&'static str> = Vec::new();
    let mut key: Option<String> = None;
    for component in chord.split('+') {
        let lower = component.to_lowercase();
        if component.is_empty() {
            return Err(not_a_chord());
        }
        let modifier = match lower.as_str() {
            "cmd" | "command" | "⌘" | "ctrl" | "control" | "⌃" => Some("ctrl"),
            "shift" | "⇧" => Some("shift"),
            "opt" | "option" | "alt" | "⌥" => Some("alt"),
            // There's no Fn key to press in a Linux VM.
            "fn" => return Err(not_a_chord()),
            _ => None,
        };
        if let Some(modifier) = modifier {
            if !modifiers.contains(&modifier) {
                modifiers.push(modifier);
            }
            continue;
        }
        if key.is_some() {
            return Err(not_a_chord());
        }
        key = Some(
            named_key(&lower)
                .map(str::to_string)
                .or_else(|| {
                    let mut characters = lower.chars();
                    match (characters.next(), characters.next()) {
                        (Some(character), None)
                            if !character.is_whitespace() && !character.is_control() =>
                        {
                            Some(character.to_string())
                        }
                        _ => None,
                    }
                })
                .ok_or_else(not_a_chord)?,
        );
    }
    let key = key.ok_or_else(not_a_chord)?;
    if modifiers.contains(&"ctrl") && key == "q" {
        return Err(message::action_failed(message::NO_QUITTING));
    }
    Ok(modifiers
        .into_iter()
        .map(str::to_string)
        .chain(std::iter::once(key))
        .collect())
}

/// `ComputerUseKeyChord.NamedKey` and its aliases, lowercased, as X keysym names.
fn named_key(name: &str) -> Option<&'static str> {
    Some(match name {
        "return" | "enter" => "Return",
        "tab" => "Tab",
        "space" => "space",
        "delete" | "backspace" => "BackSpace",
        "forwarddelete" | "del" => "Delete",
        "escape" | "esc" => "Escape",
        "up" => "Up",
        "down" => "Down",
        "left" => "Left",
        "right" => "Right",
        "home" => "Home",
        "end" => "End",
        "pageup" | "pgup" => "Prior",
        "pagedown" | "pgdn" => "Next",
        "f1" => "F1",
        "f2" => "F2",
        "f3" => "F3",
        "f4" => "F4",
        "f5" => "F5",
        "f6" => "F6",
        "f7" => "F7",
        "f8" => "F8",
        "f9" => "F9",
        "f10" => "F10",
        "f11" => "F11",
        "f12" => "F12",
        _ => return None,
    })
}

/// Cua's `scroll.amount` is 1…50 steps: a larger delta goes as several scrolls.
fn scroll_steps(delta: u32) -> impl Iterator<Item = u32> {
    (0..delta.div_ceil(50)).map(move |index| (delta - index * 50).min(50))
}

/// A drag's `ComputerUseKeyChord.Modifier` as the key Cua holds.
fn drag_modifier(modifier: &str) -> Result<&'static str, String> {
    match modifier {
        "command" | "control" => Ok("ctrl"),
        "shift" => Ok("shift"),
        "option" => Ok("alt"),
        _ => Err(message::action_failed(&format!(
            "\"{modifier}\" can't be held during a drag."
        ))),
    }
}

/// Now as `ISO8601DateFormatter` writes it: `2026-11-01T12:34:56Z`.
fn iso8601_now() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs());
    let (days, time) = (seconds / 86_400, seconds % 86_400);
    // Howard Hinnant's civil_from_days.
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time / 3600,
        time % 3600 / 60,
        time % 60
    )
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::collections::{BTreeSet, VecDeque};
    use std::sync::atomic::AtomicU64;
    use std::sync::mpsc;
    use std::thread;

    pub(crate) const WINDOW: u64 = 39845891;
    const PID: u64 = 64288;
    pub(crate) const SESSION: &str = "s1";
    const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

    /// A recorded Cua answer from `tests/fixtures/cua`, edited by `edit` first.
    pub(crate) fn fixture_with(name: &str, edit: impl FnOnce(&mut Value)) -> CuaResult {
        let path = format!(
            "{}/tests/fixtures/cua/{name}.json",
            env!("CARGO_MANIFEST_DIR")
        );
        let text = std::fs::read_to_string(&path).unwrap_or_else(|_| panic!("{path}"));
        let mut result = serde_json::from_str::<Value>(&text).unwrap()["result"].take();
        edit(&mut result);
        CuaResult::from_response(&json!({"result": result}))
    }

    pub(crate) fn fixture(name: &str) -> CuaResult {
        fixture_with(name, |_| {})
    }

    /// Pauses the first call of `tool` until the test lets it go.
    pub(crate) struct Gate {
        pub(crate) tool: String,
        pub(crate) reached: mpsc::Sender<()>,
        pub(crate) release: mpsc::Receiver<()>,
    }

    #[derive(Default)]
    pub(crate) struct FakeState {
        /// Answers per tool, in order; the last one repeats.
        scripts: HashMap<String, VecDeque<CuaResult>>,
        calls: Vec<(String, Value)>,
        pub(crate) gate: Option<Gate>,
        pub(crate) available: bool,
    }

    #[derive(Clone, Default)]
    pub(crate) struct Fake(pub(crate) Arc<Mutex<FakeState>>);

    impl Fake {
        /// Mousepad's one window, and the guest's apps.
        pub(crate) fn mousepad() -> Self {
            let fake = Self::default();
            fake.script("list_windows", vec![fixture("list_windows_mousepad")]);
            fake.script("list_apps", vec![fixture("list_apps")]);
            fake
        }

        pub(crate) fn script(&self, tool: &str, answers: Vec<CuaResult>) {
            self.0
                .lock()
                .unwrap()
                .scripts
                .insert(tool.to_string(), answers.into());
        }

        pub(crate) fn calls(&self, tool: &str) -> Vec<Value> {
            let state = self.0.lock().unwrap();
            state
                .calls
                .iter()
                .filter(|(name, _)| name == tool)
                .map(|(_, args)| args.clone())
                .collect()
        }

        pub(crate) fn tools(&self) -> Vec<String> {
            let state = self.0.lock().unwrap();
            state.calls.iter().map(|(name, _)| name.clone()).collect()
        }
    }

    impl Driver for Fake {
        fn call(
            &mut self,
            tool: &str,
            args: Value,
            _timeout: Duration,
        ) -> Result<CuaResult, CuaError> {
            let (answer, gate) = {
                let mut state = self.0.lock().unwrap();
                state.calls.push((tool.to_string(), args));
                let gate = match &state.gate {
                    Some(gate) if gate.tool == tool => state.gate.take(),
                    _ => None,
                };
                let answer = state.scripts.get_mut(tool).and_then(|queue| {
                    if queue.len() > 1 {
                        queue.pop_front()
                    } else {
                        queue.front().cloned()
                    }
                });
                (answer, gate)
            };
            if let Some(gate) = gate {
                gate.reached.send(()).unwrap();
                gate.release.recv().unwrap();
            }
            answer.ok_or_else(|| CuaError::Unavailable(format!("{tool} isn't scripted")))
        }

        fn available(&mut self) -> bool {
            self.0.lock().unwrap().available
        }
    }

    /// Advances only when slept on.
    #[derive(Default)]
    pub(crate) struct FakeClock(AtomicU64);

    impl Clock for FakeClock {
        fn now(&self) -> Duration {
            Duration::from_millis(self.0.load(Ordering::SeqCst))
        }

        fn sleep(&self, duration: Duration) {
            self.0
                .fetch_add(duration.as_millis() as u64, Ordering::SeqCst);
        }
    }

    pub(crate) fn new_computer(fake: &Fake) -> Computer<Fake> {
        Computer::with_clock(fake.clone(), Arc::new(FakeClock::default()))
    }

    pub(crate) fn request(action: &str, params: Value) -> Value {
        json!({"command": format!("computer_{action}"), "params": params})
    }

    /// The payload of a successful response.
    fn payload(response: &Value) -> Value {
        assert_eq!(response["ok"], true, "{response}");
        let lines = response["lines"].as_array().unwrap();
        assert_eq!(lines.len(), 1);
        serde_json::from_str(lines[0].as_str().unwrap()).unwrap()
    }

    pub(crate) fn error(response: &Value) -> String {
        assert_eq!(response["ok"], false, "{response}");
        response["error"].as_str().unwrap().to_string()
    }

    fn keys(object: &Value) -> BTreeSet<String> {
        object.as_object().unwrap().keys().cloned().collect()
    }

    fn mousepad_app() -> Value {
        json!({"name": "Mousepad", "pid": PID, "bundle_id": "org.xfce.mousepad"})
    }

    fn screenshot(computer: &mut Computer<Fake>) {
        payload(&computer.perform(
            SESSION,
            &request("screenshot", json!({"window_id": WINDOW})),
        ));
    }

    fn inspect(computer: &mut Computer<Fake>, query: Option<&str>) -> Value {
        let mut params = json!({"window_id": WINDOW});
        if let Some(query) = query {
            params["query"] = json!(query);
        }
        payload(&computer.perform(SESSION, &request("inspect", params)))
    }

    /// The Edit menu as the query read maps it.
    fn edit_menu() -> Value {
        json!({
            "ref": "e1", "depth": 4, "role": "menu",
            "frame": {"x": 775.0, "y": 780.0, "width": 41.0, "height": 27.0},
            "enabled": true, "focused": false, "title": "Edit",
            "description": "Edit menu; closed menu with 19 items; not expanded: click it to open",
        })
    }

    #[test]
    fn screenshot_reports_scale_frame_and_image_like_macos() {
        let fake = Fake::mousepad();
        // A window drawn at twice its size.
        fake.script(
            "get_window_state",
            vec![fixture_with("gws_screenshot", |result| {
                result["structuredContent"]["screenshot_width"] = json!(1280);
                result["structuredContent"]["screenshot_height"] = json!(960);
            })],
        );
        let mut computer = new_computer(&fake);

        let shot = payload(&computer.perform(
            SESSION,
            &request("screenshot", json!({"window_id": WINDOW})),
        ));

        assert_eq!(
            fake.calls("get_window_state"),
            vec![json!({
                "pid": PID, "window_id": WINDOW,
                "include_accessibility_tree": false, "max_image_dimension": 1280,
            })]
        );
        assert_eq!(
            keys(&shot),
            [
                "app",
                "captured_at",
                "image",
                "image_size",
                "scale",
                "version",
                "window",
                "window_id"
            ]
            .map(String::from)
            .into()
        );
        assert_eq!(shot["version"], 1);
        assert_eq!(shot["window_id"], WINDOW);
        assert_eq!(shot["app"], mousepad_app());
        assert_eq!(
            shot["window"],
            json!({
                "frame": {"x": 736.0, "y": 780.0, "width": 640.0, "height": 480.0},
                "title": "Untitled 1 - Mousepad",
            })
        );
        assert_eq!(shot["image_size"], json!({"width": 1280, "height": 960}));
        assert_eq!(shot["scale"], json!(2.0));
        assert_eq!(
            shot["image"],
            json!({"mime_type": "image/png", "data": ONE_PIXEL_PNG})
        );
        let captured_at = shot["captured_at"].as_str().unwrap();
        assert_eq!(captured_at.len(), "2026-11-01T12:00:00Z".len());
        assert!(captured_at.starts_with("20") && captured_at.ends_with('Z'));
    }

    #[test]
    fn inspect_numbers_refs_and_maps_frames() {
        let fake = Fake::mousepad();
        fake.script(
            "get_window_state",
            vec![fixture_with("gws_elements", |result| {
                result["structuredContent"]["elements"][6]["states"] = json!(["focused"]);
            })],
        );
        let mut computer = new_computer(&fake);

        let read = inspect(&mut computer, None);

        assert_eq!(
            fake.calls("get_window_state"),
            vec![json!({
                "pid": PID, "window_id": WINDOW, "include_screenshot": false,
                "tree_format": "elements", "max_elements": 300, "max_depth": 12,
            })]
        );
        assert_eq!(
            keys(&read),
            ["app", "elements", "truncated", "version", "window_id"]
                .map(String::from)
                .into()
        );
        assert_eq!(read["truncated"], false);
        let elements = read["elements"].as_array().unwrap();
        assert_eq!(elements.len(), 20);
        let refs: Vec<&str> = elements
            .iter()
            .map(|e| e["ref"].as_str().unwrap())
            .collect();
        assert_eq!(refs[..3], ["e1", "e2", "e3"]);
        assert_eq!(refs[19], "e20");
        assert_eq!(
            elements[0],
            json!({
                "ref": "e1", "depth": 4, "role": "menu",
                "frame": {"x": 736.0, "y": 780.0, "width": 39.0, "height": 27.0},
                "enabled": true, "focused": false, "title": "File",
                "description": "File menu; closed menu with 19 items; not expanded: click it to open",
            })
        );
        // The text area Cua reports focused.
        assert_eq!(elements[6]["role"], "text");
        assert_eq!(elements[6]["focused"], true);
        // An element Cua gives no frame: off screen.
        assert_eq!(elements[7]["title"], "New");
        assert_eq!(
            elements[7]["frame"],
            json!({"x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0})
        );
        assert_eq!(elements[7]["visible"], false);
        assert_eq!(elements[18]["value"], "0.0");
    }

    #[test]
    fn ref_click_uses_the_element_token_of_the_latest_read() {
        let fake = Fake::mousepad();
        fake.script(
            "get_window_state",
            vec![fixture("gws_elements"), fixture("gws_elements_query")],
        );
        fake.script("click", vec![fixture("click_element")]);
        let mut computer = new_computer(&fake);
        inspect(&mut computer, None);
        inspect(&mut computer, Some("Edit"));

        payload(&computer.perform(
            SESSION,
            &request("click", json!({"window_id": WINDOW, "ref": "e1"})),
        ));

        assert_eq!(
            fake.calls("click"),
            vec![json!({"element_token": "s00000003:1"})]
        );
    }

    #[test]
    fn stale_and_previous_turn_refs_are_refused() {
        let fake = Fake::mousepad();
        fake.script(
            "get_window_state",
            vec![fixture("gws_elements"), fixture("gws_elements_query")],
        );
        fake.script("click", vec![fixture("click_element")]);
        let mut computer = new_computer(&fake);
        inspect(&mut computer, None);
        inspect(&mut computer, Some("Edit"));

        let click = |computer: &mut Computer<Fake>, reference: &str| {
            error(&computer.perform(
                SESSION,
                &request("click", json!({"window_id": WINDOW, "ref": reference})),
            ))
        };
        // e5 was in the first read, not in the latest.
        assert_eq!(
            click(&mut computer, "e5"),
            "computer_stale: The element ref e5 is no longer valid. Call computer_inspect on window 39845891 again."
        );
        computer.turn_ended(SESSION);
        assert_eq!(
            click(&mut computer, "e1"),
            "computer_stale: The element ref e1 is no longer valid. Call computer_inspect on window 39845891 again."
        );
        assert!(fake.calls("click").is_empty());
        // Cua reports the window itself gone.
        fake.script("get_window_state", vec![fixture("gws_bad_window")]);
        assert_eq!(
            error(&computer.perform(SESSION, &request("inspect", json!({"window_id": WINDOW})))),
            "computer_window_not_found: No on-screen window 39845891. Call computer_apps again."
        );
    }

    #[test]
    fn xy_click_passes_pixels_and_capture_id_in_foreground() {
        let fake = Fake::mousepad();
        fake.script(
            "get_window_state",
            vec![fixture("gws_screenshot"), fixture("gws_elements_query")],
        );
        fake.script("click", vec![fixture("click_xy_fg")]);
        let mut computer = new_computer(&fake);
        screenshot(&mut computer);

        payload(&computer.perform(
            SESSION,
            &request(
                "click",
                json!({"window_id": WINDOW, "x": 200, "y": 150, "button": "right", "count": 2}),
            ),
        ));

        assert_eq!(
            fake.calls("click"),
            vec![json!({
                "pid": PID, "window_id": WINDOW, "x": 200.0, "y": 150.0,
                "capture_id": "capture_313c65c3bd684ff3a36a01314d81d37b_0000000000000000",
                "button": "right", "count": 2, "delivery_mode": "foreground",
            })]
        );
    }

    #[test]
    fn xy_after_resize_asks_for_a_new_screenshot() {
        let moved = "computer_out_of_bounds: Window 39845891 moved or resized since its screenshot. Call computer_screenshot again.";
        let click = request("click", json!({"window_id": WINDOW, "x": 200, "y": 150}));

        // The helper sees the new bounds itself.
        let fake = Fake::mousepad();
        fake.script("get_window_state", vec![fixture("gws_screenshot")]);
        let mut computer = new_computer(&fake);
        screenshot(&mut computer);
        fake.script(
            "list_windows",
            vec![fixture_with("list_windows_mousepad", |result| {
                result["structuredContent"]["windows"][0]["bounds"]["width"] = json!(800);
            })],
        );
        assert_eq!(error(&computer.perform(SESSION, &click)), moved);
        assert!(fake.calls("click").is_empty());

        // Cua noticed first.
        let fake = Fake::mousepad();
        fake.script("get_window_state", vec![fixture("gws_screenshot")]);
        fake.script("click", vec![fixture("click_screenshot_context_missing")]);
        let mut computer = new_computer(&fake);
        screenshot(&mut computer);
        assert_eq!(error(&computer.perform(SESSION, &click)), moved);
    }

    #[test]
    fn xy_without_screenshot_is_refused() {
        let fake = Fake::mousepad();
        let mut computer = new_computer(&fake);

        let response = computer.perform(
            SESSION,
            &request("click", json!({"window_id": WINDOW, "x": 200, "y": 150})),
        );

        assert_eq!(
            error(&response),
            "computer_needs_screenshot: x/y are pixels in a screenshot of window 39845891. Call computer_screenshot first."
        );
        assert!(fake.calls("click").is_empty());
    }

    #[test]
    fn key_chords_map_to_xkb_names() {
        for (chord, expected) in [
            ("cmd+s", json!(["ctrl", "s"])),
            ("shift+tab", json!(["shift", "Tab"])),
            ("return", json!(["Return"])),
            ("forwardDelete", json!(["Delete"])),
            ("ctrl+alt+f1", json!(["ctrl", "alt", "F1"])),
            ("pageUp", json!(["Prior"])),
        ] {
            let fake = Fake::mousepad();
            fake.script("get_window_state", vec![fixture("gws_elements_query")]);
            fake.script("hotkey", vec![fixture("hotkey_escape")]);
            let mut computer = new_computer(&fake);

            payload(&computer.perform(
                SESSION,
                &request("key", json!({"window_id": WINDOW, "keys": chord})),
            ));

            assert_eq!(
                fake.calls("hotkey"),
                vec![json!({
                    "pid": PID, "window_id": WINDOW, "keys": expected,
                    "delivery_mode": "foreground",
                })],
                "{chord}"
            );
        }
    }

    #[test]
    fn scroll_splits_dx_and_dy() {
        let fake = Fake::mousepad();
        fake.script(
            "get_window_state",
            vec![fixture("gws_screenshot"), fixture("gws_elements_query")],
        );
        fake.script("scroll", vec![fixture("scroll_fg")]);
        let mut computer = new_computer(&fake);
        screenshot(&mut computer);

        payload(&computer.perform(
            SESSION,
            &request(
                "scroll",
                json!({"window_id": WINDOW, "x": 200, "y": 150, "dx": -2, "dy": 120}),
            ),
        ));

        let at = |direction: &str, amount: u64| {
            json!({
                "pid": PID, "window_id": WINDOW, "x": 200.0, "y": 150.0,
                "direction": direction, "amount": amount, "delivery_mode": "foreground",
            })
        };
        // Cua scrolls at most 50 steps a call.
        assert_eq!(
            fake.calls("scroll"),
            vec![
                at("down", 50),
                at("down", 50),
                at("down", 20),
                at("left", 2)
            ]
        );
    }

    #[test]
    fn type_replace_selects_all_first() {
        let fake = Fake::mousepad();
        fake.script("get_window_state", vec![fixture("gws_elements")]);
        fake.script("hotkey", vec![fixture("hotkey_escape")]);
        fake.script("type_text", vec![fixture("type_fg")]);
        let mut computer = new_computer(&fake);
        inspect(&mut computer, None);

        payload(&computer.perform(
            SESSION,
            &request(
                "type",
                json!({"window_id": WINDOW, "ref": "e7", "text": "hello", "mode": "replace"}),
            ),
        ));

        let target = json!({"pid": PID, "window_id": WINDOW, "element_token": "s00000002:17"});
        let mut select_all = target.clone();
        select_all["keys"] = json!(["ctrl", "a"]);
        let mut typed = target;
        typed["text"] = json!("hello");
        let inputs: Vec<String> = fake
            .tools()
            .into_iter()
            .filter(|tool| tool == "hotkey" || tool == "type_text")
            .collect();
        assert_eq!(inputs, ["hotkey", "type_text"]);
        assert_eq!(fake.calls("hotkey"), vec![select_all]);
        assert_eq!(fake.calls("type_text"), vec![typed]);
    }

    #[test]
    fn foreground_unavailable_with_lock_reports_the_lock() {
        let fake = Fake::mousepad();
        let locked = fixture_with("list_windows_mousepad", |result| {
            let windows = result["structuredContent"]["windows"]
                .as_array_mut()
                .unwrap();
            let mut locker = windows[0].clone();
            locker["app_name"] = json!("Xfce4-screensaver-dialog");
            locker["title"] = json!("xfce4-screensaver");
            locker["window_id"] = json!(1234);
            windows.push(locker);
        });
        fake.script(
            "list_windows",
            vec![fixture("list_windows_mousepad"), locked],
        );
        fake.script("type_text", vec![fixture("type_foreground_unavailable")]);
        let mut computer = new_computer(&fake);

        let response = computer.perform(
            SESSION,
            &request("type", json!({"window_id": WINDOW, "text": "hi"})),
        );

        assert_eq!(
            error(&response),
            "computer_action_failed: The window couldn't be brought to the front, so no input was sent. The Linux VM's screen is locked."
        );
    }

    #[test]
    fn open_app_waits_for_a_window() {
        let fake = Fake::mousepad();
        fake.script("launch_app", vec![fixture("launch_app_mousepad")]);
        fake.script(
            "list_windows",
            vec![
                fixture_with("list_windows_mousepad", |result| {
                    result["structuredContent"]["windows"] = json!([]);
                }),
                fixture("list_windows_mousepad"),
            ],
        );
        let mut computer = new_computer(&fake);

        let opened = payload(&computer.perform(
            SESSION,
            &request("open_app", json!({"bundle_id": "org.xfce.mousepad"})),
        ));

        assert_eq!(
            fake.calls("launch_app"),
            vec![json!({"name": "org.xfce.mousepad"})]
        );
        assert_eq!(
            fake.calls("list_windows"),
            vec![json!({"pid": PID}), json!({"pid": PID})]
        );
        assert_eq!(
            opened,
            json!({
                "version": 1,
                "app": mousepad_app(),
                "windows": [{
                    "window_id": WINDOW,
                    "frame": {"x": 736.0, "y": 780.0, "width": 640.0, "height": 480.0},
                    "title": "Untitled 1 - Mousepad",
                }],
            })
        );
    }

    #[test]
    fn wait_disappear_times_out_with_the_last_read() {
        let gone_but_cut = fixture_with("gws_elements_query", |result| {
            result["structuredContent"]["elements"] = json!([]);
            result["structuredContent"]["truncated"] = json!(true);
        });
        for (last_read, expected) in [
            (
                fixture("gws_elements_query"),
                "computer_wait_timeout: Nothing matching \"Edit\" disappeared in window 39845891 within 1000 ms.",
            ),
            (
                gone_but_cut,
                "computer_wait_timeout: Couldn't confirm that \"Edit\" disappeared from window 39845891 within 1000 ms: the window's accessibility tree couldn't be read completely, so it may still be there.",
            ),
        ] {
            let fake = Fake::mousepad();
            fake.script(
                "get_window_state",
                vec![fixture("gws_elements_query"), last_read],
            );
            let mut computer = new_computer(&fake);

            let response = computer.perform(
                SESSION,
                &request(
                    "wait",
                    json!({"window_id": WINDOW, "query": "Edit", "condition": "disappear", "timeout_ms": 1000}),
                ),
            );

            assert_eq!(error(&response), expected);
            assert_eq!(fake.calls("get_window_state")[0]["query"], "Edit");
        }
    }

    #[test]
    fn cancel_stops_a_wait() {
        let fake = Fake::mousepad();
        fake.script("get_window_state", vec![fixture("gws_elements_query")]);
        let (reached_sender, reached) = mpsc::channel();
        let (release, release_receiver) = mpsc::channel();
        fake.0.lock().unwrap().gate = Some(Gate {
            tool: "get_window_state".to_string(),
            reached: reached_sender,
            release: release_receiver,
        });
        let mut computer = new_computer(&fake);
        let canceller = computer.canceller();

        let waiting = thread::spawn(move || {
            computer.perform(
                SESSION,
                &request(
                    "wait",
                    json!({"window_id": WINDOW, "query": "Edit", "condition": "disappear",
                           "timeout_ms": 20000, "call_id": "c1"}),
                ),
            )
        });
        reached.recv().unwrap();
        canceller.cancel("other-session", "c1");
        canceller.cancel(SESSION, "c1");
        release.send(()).unwrap();

        assert_eq!(
            error(&waiting.join().unwrap()),
            "computer_cancelled: The call was cancelled."
        );
        assert_eq!(fake.calls("get_window_state").len(), 1);
    }

    #[test]
    fn every_action_returns_the_new_elements() {
        for (action, params) in [
            ("click", json!({"ref": "e1"})),
            ("click", json!({"x": 10, "y": 10})),
            ("type", json!({"text": "x"})),
            ("key", json!({"keys": "escape"})),
            ("scroll", json!({"ref": "e1", "dy": 1})),
            ("drag", json!({"ref": "e1", "to_x": 300, "to_y": 20})),
        ] {
            let fake = Fake::mousepad();
            fake.script(
                "get_window_state",
                vec![
                    fixture("gws_screenshot"),
                    fixture("gws_elements"),
                    fixture("gws_elements_query"),
                ],
            );
            for (tool, answer) in [
                ("click", "click_element"),
                ("type_text", "type_fg"),
                ("hotkey", "hotkey_escape"),
                ("scroll", "scroll_fg"),
                ("drag", "drag_fg"),
            ] {
                fake.script(tool, vec![fixture(answer)]);
            }
            let mut computer = new_computer(&fake);
            screenshot(&mut computer);
            inspect(&mut computer, None);
            let mut params = params;
            params["window_id"] = json!(WINDOW);
            params["query"] = json!("Edit");

            let result = payload(&computer.perform(SESSION, &request(action, params)));

            assert_eq!(result["action"], action);
            assert_eq!(result["app"], mousepad_app());
            assert_eq!(result["elements"], json!([edit_menu()]), "{action}");
            assert_eq!(result["truncated"], false);
            if action == "scroll" {
                // A ref scroll goes by element, with Cua's default delivery.
                assert_eq!(
                    fake.calls("scroll"),
                    vec![json!({
                        "pid": PID, "window_id": WINDOW, "element_token": "s00000002:0",
                        "direction": "down", "amount": 1,
                    })]
                );
            }
            let reads = fake.calls("get_window_state");
            assert_eq!(
                reads.last().unwrap(),
                &json!({
                    "pid": PID, "window_id": WINDOW, "include_screenshot": false,
                    "tree_format": "elements", "max_elements": 100, "max_depth": 32,
                    "query": "Edit",
                }),
                "{action}"
            );
        }
    }

    #[test]
    fn drag_from_refs_converts_centres_and_holds_modifiers() {
        let fake = Fake::mousepad();
        // No screenshot of the agent's: the drag takes one, drawn at twice the window's size.
        fake.script(
            "get_window_state",
            vec![
                fixture("gws_elements"),
                fixture_with("gws_screenshot", |result| {
                    result["structuredContent"]["screenshot_width"] = json!(1280);
                    result["structuredContent"]["screenshot_height"] = json!(960);
                }),
                fixture("gws_elements_query"),
            ],
        );
        fake.script("drag", vec![fixture("drag_fg")]);
        let mut computer = new_computer(&fake);
        inspect(&mut computer, None);

        payload(&computer.perform(
            SESSION,
            &request(
                "drag",
                json!({"window_id": WINDOW, "ref": "e1", "to_ref": "e2",
                       "modifiers": ["command", "control", "shift"]}),
            ),
        ));

        assert_eq!(
            fake.calls("get_window_state")[1]["max_image_dimension"],
            1280
        );
        // File's centre (755.5, 793.5) and Edit's (795.5, 793.5), less the window's origin
        // (736, 780), times 2.
        assert_eq!(
            fake.calls("drag"),
            vec![json!({
                "pid": PID, "window_id": WINDOW,
                "from_x": 39.0, "from_y": 27.0, "to_x": 119.0, "to_y": 27.0,
                "modifier": ["ctrl", "shift"], "delivery_mode": "foreground",
            })]
        );
        // The drag's own capture isn't the agent's: its x/y still need a screenshot.
        assert_eq!(
            error(&computer.perform(
                SESSION,
                &request("click", json!({"window_id": WINDOW, "x": 10, "y": 10})),
            )),
            "computer_needs_screenshot: x/y are pixels in a screenshot of window 39845891. Call computer_screenshot first."
        );
        assert!(fake.calls("click").is_empty());
    }

    #[test]
    fn apps_lists_apps_with_windows_by_name() {
        let fake = Fake::mousepad();
        fake.script(
            "list_windows",
            vec![fixture_with("list_windows", |result| {
                let mousepad = fixture("list_windows_mousepad").structured["windows"][0].clone();
                result["structuredContent"]["windows"]
                    .as_array_mut()
                    .unwrap()
                    .push(mousepad);
            })],
        );
        let mut computer = new_computer(&fake);

        let apps = payload(&computer.perform(SESSION, &request("apps", json!({}))));

        let panel = |id: u64, frame: Value| json!({"window_id": id, "frame": frame, "title": "xfce4-panel"});
        assert_eq!(
            apps,
            json!({
                "version": 1,
                "apps": [
                    {
                        "name": "Mousepad", "pid": PID, "bundle_id": "org.xfce.mousepad",
                        "approval": "allowed",
                        "windows": [{
                            "window_id": WINDOW,
                            "frame": {"x": 736.0, "y": 780.0, "width": 640.0, "height": 480.0},
                            "title": "Untitled 1 - Mousepad",
                        }],
                    },
                    {
                        "name": "Panel", "pid": 1430, "bundle_id": "panel-preferences",
                        "approval": "allowed",
                        "windows": [
                            panel(14680067, json!({"x": 0.0, "y": 0.0, "width": 2112.0, "height": 27.0})),
                            panel(14680078, json!({"x": 903.0, "y": 1941.0, "width": 306.0, "height": 49.0})),
                        ],
                    },
                    {
                        "name": "xfdesktop", "pid": 1449, "approval": "allowed",
                        "windows": [{
                            "window_id": 18874391,
                            "frame": {"x": 0.0, "y": 0.0, "width": 2112.0, "height": 1990.0},
                            "title": "Desktop",
                        }],
                    },
                ],
            })
        );
    }
}
