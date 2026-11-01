//! Answers the host's messages, mirroring `VMGuestService` on macOS: computer-use calls through
//! the VM's one `Computer`, lifecycle events, and `vm_run` commands. Request ids are the host's, so
//! they are scoped to the connection they arrived on.

use crate::computer::{self, Canceller, Computer, Driver};
use crate::protocol::{self, LifecycleEvent, Message};
use crate::runner::{self, Run};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, mpsc};
use std::thread;
use std::time::Duration;

/// How long `hello` waits for Cua Driver to answer. A first start may take longer; the driver
/// finishes starting anyway, and the next hello sees it.
const PROBE_CEILING: Duration = Duration::from_secs(5);
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
}

impl<D: Driver + Send + 'static> Desktop<D> {
    pub fn new(computer: Computer<D>) -> Arc<Self> {
        Arc::new(Self {
            canceller: computer.canceller(),
            computer: Mutex::new(computer),
            ended: Mutex::default(),
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

    /// Whether Cua Driver answers, within `PROBE_CEILING`.
    fn computer_use_available(self: &Arc<Self>) -> bool {
        let (sender, answer) = mpsc::channel();
        let desktop = Arc::clone(self);
        thread::spawn(move || {
            let available = desktop.computer().driver_mut().available();
            let _ = sender.send(available);
        });
        answer.recv_timeout(PROBE_CEILING).unwrap_or(false)
    }
}

/// A computer-use command in flight, for `cancel{id}`.
struct Pending {
    session: String,
    call_id: Option<String>,
    /// Cancelled before it reached the computer.
    cancelled: bool,
}

/// One host connection.
pub struct Connection<D: Driver> {
    desktop: Arc<Desktop<D>>,
    /// None once the host went away, so no reply reaches a closed connection. The lock keeps
    /// frames whole when replies finish together.
    writer: Mutex<Option<Box<dyn Write + Send>>>,
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
                if let Some(command) = lock(&self.commands).get_mut(&id) {
                    command.cancelled = true;
                    if let Some(call_id) = &command.call_id {
                        self.desktop.canceller.cancel(&command.session, call_id);
                    }
                }
            }
            Message::Lifecycle { session_id, event } => match event {
                LifecycleEvent::Stop => self.desktop.canceller.cancel_session(&session_id),
                // The host refuses a stopped session's calls itself, until it resumes.
                LifecycleEvent::Resume => {}
                LifecycleEvent::TurnEnded => self.desktop.end(session_id, event),
                LifecycleEvent::SessionEnded => {
                    lock(&self.sessions).remove(&session_id);
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
                // A call still waiting for the computer has no flag to set yet.
                for command in lock(&self.commands).values_mut() {
                    if command.session == session && command.call_id.as_ref() == Some(call_id) {
                        command.cancelled = true;
                    }
                }
            }
            self.respond(id, &json!({"ok": true}));
            return;
        }
        lock(&self.commands).insert(
            id,
            Pending {
                session: session.clone(),
                call_id,
                cancelled: false,
            },
        );
        thread::spawn(move || {
            let response = {
                let mut computer = self.desktop.computer();
                if lock(&self.writer).is_none() {
                    // Work queued from a connection that closed is dropped, not started.
                    None
                } else if lock(&self.commands)
                    .get(&id)
                    .is_some_and(|command| command.cancelled)
                {
                    Some(computer::error_response(computer::message::CANCELLED))
                } else {
                    Some(computer.perform(&session, &request))
                }
            };
            lock(&self.commands).remove(&id);
            if let Some(response) = response {
                self.respond(id, &response);
            }
        });
    }

    /// The host went away: nobody waits for this connection's answers, and its sessions end.
    pub fn close(&self) {
        lock(&self.writer).take();
        for (_, canceller) in lock(&self.runs).drain() {
            canceller.cancel();
        }
        for session in std::mem::take(&mut *lock(&self.sessions)) {
            self.desktop.end(session.clone(), LifecycleEvent::TurnEnded);
            self.desktop.end(session, LifecycleEvent::SessionEnded);
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

    /// A stop, a `cancel` of the request, and an agent's `computer_cancel` all end the wait in
    /// flight. The `computer_cancel` is answered while the wait still holds the computer.
    #[test]
    fn stop_cancels_the_sessions_wait() {
        for stop in ["lifecycle", "cancel", "computer_cancel"] {
            let fake = Fake::mousepad();
            fake.script("get_window_state", vec![fixture("gws_elements_query")]);
            let (reached_sender, reached) = mpsc::channel();
            let (release, release_receiver) = mpsc::channel();
            fake.0.lock().unwrap().gate = Some(Gate {
                tool: "get_window_state".to_string(),
                reached: reached_sender,
                release: release_receiver,
            });
            let mut host = Host::connect(&fake);
            host.command(
                1,
                &request(
                    "wait",
                    json!({"window_id": WINDOW, "query": "Edit", "condition": "disappear",
                           "timeout_ms": 20000, "call_id": "c1"}),
                ),
            );
            reached.recv().unwrap();

            match stop {
                "lifecycle" => host.send(Message::Lifecycle {
                    session_id: SESSION.to_string(),
                    event: LifecycleEvent::Stop,
                }),
                "cancel" => host.send(Message::Cancel { id: 1 }),
                _ => {
                    host.command(2, &request("cancel", json!({"call_id": "c1"})));
                    assert_eq!(host.response(2), json!({"ok": true}));
                }
            }
            release.send(()).unwrap();

            assert_eq!(
                error(&host.response(1)),
                "computer_cancelled: The call was cancelled.",
                "{stop}"
            );
        }
    }
}
