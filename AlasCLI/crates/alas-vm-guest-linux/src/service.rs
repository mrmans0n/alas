//! Answers the host's messages, mirroring `VMGuestService` on macOS: computer-use calls through
//! the VM's one `Computer`, lifecycle events, and `vm_run` commands. Request ids are the host's, so
//! they are scoped to the connection they arrived on.

use crate::computer::{self, Canceller, Computer, Driver};
use crate::protocol::{self, LifecycleEvent, Message};
use crate::runner::{self, Run};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, TryLockError, mpsc};
use std::thread;
use std::time::Duration;

/// How long `hello` waits for Cua Driver to answer, well inside the host's 5 s hello timeout
/// (`VMGuestClient.helloTimeout`). A first start may take longer; the driver finishes starting
/// anyway, and the next hello sees it.
const PROBE_CEILING: Duration = Duration::from_secs(2);
/// `VMGuestService`'s answer to a request it can't decode.
const MALFORMED: &str = "computer_malformed: The VM guest helper couldn't read the request.";

/// Locks `mutex`, carrying on past a panic of an earlier holder.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The VM's one desktop, shared by every connection. Calls take turns on it, whichever session
/// or connection they come from.
pub struct Desktop<D: Driver> {
    computer: Mutex<Computer<D>>,
    /// Reaches calls in flight without waiting for the computer.
    canceller: Canceller,
    /// Turn and session ends not applied yet, in arrival order. Whoever takes the computer applies
    /// them first, so a command read after one never runs before it.
    ended: Mutex<Vec<(String, LifecycleEvent)>>,
    /// The last probe's answer, or yes after a call that succeeded, for a hello that can't wait
    /// for the driver.
    last_available: AtomicBool,
}

impl<D: Driver + Send + 'static> Desktop<D> {
    pub fn new(computer: Computer<D>) -> Arc<Self> {
        Arc::new(Self {
            canceller: computer.canceller(),
            computer: Mutex::new(computer),
            ended: Mutex::default(),
            last_available: AtomicBool::new(false),
        })
    }

    fn computer(&self) -> MutexGuard<'_, Computer<D>> {
        let mut computer = lock(&self.computer);
        for (session, event) in std::mem::take(&mut *lock(&self.ended)) {
            match event {
                LifecycleEvent::TurnEnded => computer.turn_ended(&session),
                LifecycleEvent::SessionEnded => computer.session_ended(&session),
                LifecycleEvent::Stop | LifecycleEvent::Resume => {}
            }
        }
        computer
    }

    /// Ends the session's turn, or the session. A session end stops its calls at once; the
    /// computer forgets the rest once the call in flight lets it go.
    fn end(self: &Arc<Self>, session: String, event: LifecycleEvent) {
        if event == LifecycleEvent::SessionEnded {
            self.canceller.cancel_session(&session);
        }
        lock(&self.ended).push((session, event));
        let desktop = Arc::clone(self);
        thread::spawn(move || drop(desktop.computer()));
    }

    /// Whether Cua Driver answers, within `PROBE_CEILING`. While a call holds the computer, and
    /// with it the driver, or when the probe runs out of time, the last answer stands; a slow
    /// probe carries on and updates it for the next hello.
    fn computer_use_available(self: &Arc<Self>) -> bool {
        let cached = self.last_available.load(Ordering::SeqCst);
        if let Err(TryLockError::WouldBlock) = self.computer.try_lock() {
            return cached;
        }
        let (sender, answer) = mpsc::channel();
        let desktop = Arc::clone(self);
        thread::spawn(move || {
            let available = desktop.computer().driver_mut().available();
            desktop.last_available.store(available, Ordering::SeqCst);
            let _ = sender.send(available);
        });
        answer.recv_timeout(PROBE_CEILING).unwrap_or(cached)
    }
}

/// A computer-use command queued or in flight, for `cancel{id}`, `stop` and `computer_cancel`.
struct Pending {
    session: String,
    call_id: Option<String>,
    /// The call's cancel flag, set before or while it runs.
    cancelled: Arc<AtomicBool>,
}

/// One host connection.
pub struct Connection<D: Driver> {
    desktop: Arc<Desktop<D>>,
    /// None once the host went away, so no reply reaches a closed connection. The lock keeps
    /// frames whole when replies finish together.
    writer: Mutex<Option<Box<dyn Write + Send>>>,
    /// Set once the host went away, so work still queued from it is dropped, not started.
    closed: AtomicBool,
    runs: Mutex<HashMap<u64, runner::Canceller>>,
    commands: Mutex<HashMap<u64, Pending>>,
    /// The sessions this connection used and hasn't ended, so a disconnect can end them.
    sessions: Mutex<HashSet<String>>,
}

impl<D: Driver + Send + 'static> Connection<D> {
    pub fn new(desktop: Arc<Desktop<D>>, writer: Box<dyn Write + Send>) -> Arc<Self> {
        Arc::new(Self {
            desktop,
            writer: Mutex::new(Some(writer)),
            closed: AtomicBool::new(false),
            runs: Mutex::default(),
            commands: Mutex::default(),
            sessions: Mutex::default(),
        })
    }

    /// Handles one message without blocking the read loop, so a `cancel` is read while its
    /// command or run is still going. Nothing here waits for the computer.
    pub fn handle(self: Arc<Self>, message: Message) {
        match message {
            Message::Hello { .. } => {
                thread::spawn(move || {
                    let available = self.desktop.computer_use_available();
                    self.send(&protocol::hello_reply(available));
                });
            }
            Message::Command {
                id,
                session_id,
                request,
            } => self.command(id, session_id, &request),
            Message::Cancel { id } => {
                if let Some(canceller) = lock(&self.runs).get(&id) {
                    canceller.cancel();
                }
                if let Some(command) = lock(&self.commands).get(&id) {
                    command.cancelled.store(true, Ordering::SeqCst);
                }
            }
            Message::Lifecycle { session_id, event } => match event {
                LifecycleEvent::Stop => {
                    self.desktop.canceller.cancel_session(&session_id);
                    self.cancel_pending(&session_id, None);
                }
                // The host refuses a stopped session's calls itself, until it resumes.
                LifecycleEvent::Resume => {}
                LifecycleEvent::TurnEnded => self.desktop.end(session_id, event),
                LifecycleEvent::SessionEnded => {
                    lock(&self.sessions).remove(&session_id);
                    self.cancel_pending(&session_id, None);
                    self.desktop.end(session_id, event);
                }
            },
            Message::Run {
                id,
                command,
                timeout_seconds,
            } => {
                let run = Run::default();
                lock(&self.runs).insert(id, run.canceller());
                thread::spawn(move || {
                    let result = run.execute(
                        &runner::SHELL,
                        &command,
                        runner::clamp_timeout(timeout_seconds),
                    );
                    lock(&self.runs).remove(&id);
                    self.send(&Message::RunResult {
                        id,
                        exit_code: result.exit_code,
                        stdout: result.stdout,
                        stderr: result.stderr,
                        truncated: result.truncated,
                        timed_out: result.timed_out,
                    });
                });
            }
            Message::HelloReply { .. } | Message::Response { .. } | Message::RunResult { .. } => {
                eprintln!(
                    "alas-vm-guest-linux: ignoring a guest-to-host message sent to the guest"
                );
            }
        }
    }

    /// Runs a computer-use request on a thread of its own. A `computer_cancel` is answered at
    /// once instead, since the call it cancels holds the computer.
    fn command(self: Arc<Self>, id: u64, session: String, request: &str) {
        lock(&self.sessions).insert(session.clone());
        let request = protocol::unbase64(request)
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .filter(Value::is_object);
        let Some(request) = request else {
            self.respond(id, &computer::error_response(MALFORMED));
            return;
        };
        let call_id = request
            .pointer("/params/call_id")
            .and_then(Value::as_str)
            .map(str::to_string);
        if request.get("command").and_then(Value::as_str) == Some("computer_cancel") {
            if let Some(call_id) = &call_id {
                self.desktop.canceller.cancel(&session, call_id);
                self.cancel_pending(&session, Some(call_id));
            }
            self.respond(id, &json!({"ok": true}));
            return;
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        lock(&self.commands).insert(
            id,
            Pending {
                session: session.clone(),
                call_id,
                cancelled: Arc::clone(&cancelled),
            },
        );
        thread::spawn(move || {
            let response = {
                let mut computer = self.desktop.computer();
                if self.closed.load(Ordering::SeqCst) {
                    None
                } else {
                    Some(computer.perform_with_cancel(&session, &request, cancelled))
                }
            };
            // The driver just answered, so a hello while the next call holds the computer says so.
            if response
                .as_ref()
                .is_some_and(|response| response["ok"] == true)
            {
                self.desktop.last_available.store(true, Ordering::SeqCst);
            }
            lock(&self.commands).remove(&id);
            if let Some(response) = response {
                self.respond(id, &response);
            }
        });
    }

    /// The host went away: nobody waits for this connection's answers, and its sessions end.
    pub fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        lock(&self.writer).take();
        for (_, canceller) in lock(&self.runs).drain() {
            canceller.cancel();
        }
        // Calls without a `call_id` are reachable only through their own flag.
        for command in lock(&self.commands).values() {
            command.cancelled.store(true, Ordering::SeqCst);
        }
        for session in std::mem::take(&mut *lock(&self.sessions)) {
            self.desktop.end(session.clone(), LifecycleEvent::TurnEnded);
            self.desktop.end(session, LifecycleEvent::SessionEnded);
        }
    }

    /// Cancels this connection's commands of `session`, queued or running: all of them, or the
    /// one with `call_id`.
    fn cancel_pending(&self, session: &str, call_id: Option<&String>) {
        for command in lock(&self.commands).values() {
            if command.session == session
                && (call_id.is_none() || command.call_id.as_ref() == call_id)
            {
                command.cancelled.store(true, Ordering::SeqCst);
            }
        }
    }

    fn respond(&self, id: u64, response: &Value) {
        self.send(&Message::Response {
            id,
            body: protocol::base64(response.to_string().as_bytes()),
        });
    }

    fn send(&self, message: &Message) {
        let frame = protocol::frame(message);
        if let Some(writer) = lock(&self.writer).as_mut()
            && let Err(error) = writer.write_all(&frame)
        {
            eprintln!("alas-vm-guest-linux: write failed: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::computer::tests::{
        Fake, Gate, SESSION, WINDOW, error, fixture, new_computer, request,
    };
    use crate::protocol::Framer;
    use std::collections::VecDeque;
    use std::io;

    /// Hands each write to the test.
    struct Sink(mpsc::Sender<Vec<u8>>);

    impl Write for Sink {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            let _ = self.0.send(bytes.to_vec());
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct Host {
        connection: Arc<Connection<Fake>>,
        writes: mpsc::Receiver<Vec<u8>>,
        framer: Framer,
        replies: VecDeque<Message>,
    }

    impl Host {
        fn connect(fake: &Fake) -> Self {
            let (sender, writes) = mpsc::channel();
            Self {
                connection: Connection::new(
                    Desktop::new(new_computer(fake)),
                    Box::new(Sink(sender)),
                ),
                writes,
                framer: Framer::default(),
                replies: VecDeque::new(),
            }
        }

        fn send(&self, message: Message) {
            Arc::clone(&self.connection).handle(message);
        }

        fn command(&self, id: u64, request: &Value) {
            self.send(Message::Command {
                id,
                session_id: SESSION.to_string(),
                request: protocol::base64(request.to_string().as_bytes()),
            });
        }

        fn reply(&mut self) -> Message {
            loop {
                if let Some(reply) = self.replies.pop_front() {
                    return reply;
                }
                let bytes = self
                    .writes
                    .recv_timeout(Duration::from_secs(10))
                    .expect("a reply");
                self.replies.extend(self.framer.append(&bytes).messages);
            }
        }

        /// The next reply, which must be the response to `id`, decoded.
        fn response(&mut self, id: u64) -> Value {
            match self.reply() {
                Message::Response { id: got, body } => {
                    assert_eq!(got, id);
                    serde_json::from_slice(&protocol::unbase64(&body).unwrap()).unwrap()
                }
                other => panic!("expected a response, got {other:?}"),
            }
        }
    }

    #[test]
    fn hello_advertises_computer_use_only_when_cua_answers() {
        for (available, capabilities) in [(true, vec!["run", "computer_use"]), (false, vec!["run"])]
        {
            let fake = Fake::default();
            fake.0.lock().unwrap().available = available;
            let mut host = Host::connect(&fake);

            host.send(Message::Hello {
                host_version: "1".to_string(),
            });

            match host.reply() {
                Message::HelloReply {
                    capabilities: got, ..
                } => assert_eq!(
                    got,
                    Some(capabilities.iter().map(|c| c.to_string()).collect())
                ),
                other => panic!("expected a hello reply, got {other:?}"),
            }
        }
    }

    #[test]
    fn command_reply_is_the_computer_response() {
        let apps = request("apps", json!({}));
        let expected = new_computer(&Fake::mousepad()).perform(SESSION, &apps);
        assert_eq!(expected["ok"], true, "{expected}");
        let mut host = Host::connect(&Fake::mousepad());

        host.command(4, &apps);

        assert_eq!(host.response(4), expected);
    }

    #[test]
    fn a_successful_call_counts_as_the_driver_answering() {
        let fake = Fake::mousepad();
        let mut host = Host::connect(&fake);

        host.command(4, &request("apps", json!({})));
        assert_eq!(host.response(4)["ok"], true);

        assert!(
            host.connection
                .desktop
                .last_available
                .load(Ordering::SeqCst)
        );
    }

    /// A host whose `wait` (request 1, `call_id` "c1") holds the computer until `release`.
    fn holding_the_computer(fake: &Fake) -> (Host, mpsc::Sender<()>) {
        holding_the_computer_with(fake, Some("c1"))
    }

    /// A `wait` holds the computer until `release`, with `call_id` if given.
    fn holding_the_computer_with(fake: &Fake, call_id: Option<&str>) -> (Host, mpsc::Sender<()>) {
        fake.script("get_window_state", vec![fixture("gws_elements_query")]);
        let (reached_sender, reached) = mpsc::channel();
        let (release, release_receiver) = mpsc::channel();
        fake.0.lock().unwrap().gate = Some(Gate {
            tool: "get_window_state".to_string(),
            reached: reached_sender,
            release: release_receiver,
        });
        let host = Host::connect(fake);
        let mut params = json!({"window_id": WINDOW, "query": "Edit", "condition": "disappear",
                                "timeout_ms": 20000});
        if let Some(call_id) = call_id {
            params["call_id"] = json!(call_id);
        }
        host.command(1, &request("wait", params));
        reached
            .recv_timeout(Duration::from_secs(10))
            .expect("the wait reads the window");
        (host, release)
    }

    #[test]
    fn hello_answers_from_the_last_probe_while_a_call_holds_the_computer() {
        let fake = Fake::mousepad();
        fake.0.lock().unwrap().available = true;
        let (mut host, release) = holding_the_computer(&fake);
        // A probe before the call took the computer saw the driver.
        host.connection
            .desktop
            .last_available
            .store(true, Ordering::SeqCst);
        fake.0.lock().unwrap().available = false;

        let started = std::time::Instant::now();
        host.send(Message::Hello {
            host_version: "1".to_string(),
        });
        let reply = host.reply();

        assert!(started.elapsed() < PROBE_CEILING);
        match reply {
            Message::HelloReply { capabilities, .. } => assert_eq!(
                capabilities,
                Some(vec!["run".to_string(), "computer_use".to_string()])
            ),
            other => panic!("expected a hello reply, got {other:?}"),
        }
        release.send(()).unwrap();
    }

    /// A stop, a `cancel` of the request, and an agent's `computer_cancel` all end the wait in
    /// flight and the call queued behind it, which never reaches the driver. The
    /// `computer_cancel` is answered while the wait still holds the computer.
    #[test]
    fn stop_cancels_the_sessions_wait() {
        for stop in ["lifecycle", "cancel", "computer_cancel"] {
            let fake = Fake::mousepad();
            let (mut host, release) = holding_the_computer(&fake);
            // Without a `call_id`, only the request id or a stop reaches it.
            let queued = if stop == "computer_cancel" {
                json!({"call_id": "c2"})
            } else {
                json!({})
            };
            host.command(3, &request("apps", queued));

            match stop {
                "lifecycle" => host.send(Message::Lifecycle {
                    session_id: SESSION.to_string(),
                    event: LifecycleEvent::Stop,
                }),
                "cancel" => {
                    host.send(Message::Cancel { id: 1 });
                    host.send(Message::Cancel { id: 3 });
                }
                _ => {
                    for (id, call_id) in [(2, "c1"), (4, "c2")] {
                        host.command(id, &request("cancel", json!({"call_id": call_id})));
                        assert_eq!(host.response(id), json!({"ok": true}));
                    }
                }
            }
            let tools = fake.tools();
            release.send(()).unwrap();

            let mut errors = HashMap::new();
            for _ in 0..2 {
                match host.reply() {
                    Message::Response { id, body } => {
                        let body = serde_json::from_slice(&protocol::unbase64(&body).unwrap());
                        errors.insert(id, error(&body.unwrap()));
                    }
                    other => panic!("expected a response, got {other:?}"),
                }
            }
            let cancelled = "computer_cancelled: The call was cancelled.".to_string();
            assert_eq!(
                errors,
                HashMap::from([(1, cancelled.clone()), (3, cancelled)]),
                "{stop}"
            );
            assert_eq!(fake.tools(), tools, "{stop}");
        }
    }

    #[test]
    fn a_disconnect_cancels_a_running_call_without_a_call_id() {
        let fake = Fake::mousepad();
        // Only its own flag reaches a call without a `call_id`; the wait would poll for 20 s.
        let (host, release) = holding_the_computer_with(&fake, None);

        host.connection.close();
        let tools = fake.tools();
        release.send(()).unwrap();

        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !lock(&host.connection.commands).is_empty() {
            assert!(std::time::Instant::now() < deadline, "the calls end");
            std::thread::yield_now();
        }
        assert_eq!(fake.tools(), tools);
    }
}
