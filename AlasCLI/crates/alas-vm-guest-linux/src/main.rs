//! The Alas helper inside a Linux worktree VM. It listens on vsock for the host, answers `hello`,
//! and runs `vm_run` commands; computer use is not available yet. It runs as a systemd user
//! service that may start before the desktop, so it never needs a display.

// Off Linux only the pure protocol and runner code is built, for its tests.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

// Not used on Linux until the computer-use commands are wired to it.
#[cfg_attr(target_os = "linux", allow(dead_code))]
mod cua;
mod protocol;
mod runner;

#[cfg(target_os = "linux")]
fn main() -> std::process::ExitCode {
    match guest::serve() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("alas-vm-guest-linux: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() -> std::process::ExitCode {
    eprintln!("alas-vm-guest-linux: linux only");
    std::process::ExitCode::FAILURE
}

#[cfg(target_os = "linux")]
mod guest {
    use crate::protocol::{self, Framer, Message};
    use crate::runner::{self, Canceller, Run};
    use std::collections::HashMap;
    use std::fs::File;
    use std::io::{self, Read, Write};
    use std::os::fd::FromRawFd;
    use std::sync::{Arc, Mutex};
    use std::thread;

    /// Binds the vsock port and serves each host connection on a thread of its own.
    pub fn serve() -> io::Result<()> {
        let fd = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // Owns the descriptor from here on, so an early return closes it.
        let _listener = unsafe { File::from_raw_fd(fd) };
        let mut address: libc::sockaddr_vm = unsafe { std::mem::zeroed() };
        address.svm_family = libc::AF_VSOCK as libc::sa_family_t;
        address.svm_cid = libc::VMADDR_CID_ANY;
        address.svm_port = protocol::PORT;
        let bound = unsafe {
            libc::bind(
                fd,
                (&raw const address).cast::<libc::sockaddr>(),
                std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t,
            )
        };
        if bound != 0 || unsafe { libc::listen(fd, 8) } != 0 {
            return Err(io::Error::last_os_error());
        }
        eprintln!(
            "alas-vm-guest-linux: listening on vsock port {}",
            protocol::PORT
        );
        loop {
            let connection = unsafe {
                libc::accept4(
                    fd,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    libc::SOCK_CLOEXEC,
                )
            };
            if connection < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    eprintln!("alas-vm-guest-linux: accept failed: {error}");
                    // Back off so a persistent error (EMFILE, say) doesn't spin a core.
                    thread::sleep(std::time::Duration::from_millis(100));
                }
                continue;
            }
            let stream = unsafe { File::from_raw_fd(connection) };
            thread::spawn(move || Connection::serve(stream));
        }
    }

    /// One host connection. Request ids are the host's, so they are scoped to it.
    struct Connection {
        /// None once the host went away, so no reply reaches a closed connection. The lock keeps
        /// frames whole when replies finish together.
        writer: Mutex<Option<File>>,
        runs: Mutex<HashMap<u64, Canceller>>,
    }

    impl Connection {
        fn serve(mut reader: File) {
            let writer = match reader.try_clone() {
                Ok(writer) => writer,
                Err(error) => {
                    eprintln!("alas-vm-guest-linux: couldn't set up a connection: {error}");
                    return;
                }
            };
            eprintln!("alas-vm-guest-linux: host connected");
            let connection = Arc::new(Connection {
                writer: Mutex::new(Some(writer)),
                runs: Mutex::default(),
            });
            let mut framer = Framer::default();
            let mut buffer = vec![0; 64 * 1024];
            loop {
                let count = match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => count,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                let output = framer.append(&buffer[..count]);
                if output.malformed_frames > 0 {
                    eprintln!(
                        "alas-vm-guest-linux: skipped {} malformed frame(s)",
                        output.malformed_frames
                    );
                }
                for message in output.messages {
                    Arc::clone(&connection).handle(message);
                }
            }
            eprintln!("alas-vm-guest-linux: host disconnected");
            // Nobody waits for this connection's answers: end its runs and drop its replies.
            connection.writer.lock().unwrap().take();
            for canceller in connection
                .runs
                .lock()
                .unwrap()
                .drain()
                .map(|(_, canceller)| canceller)
            {
                canceller.cancel();
            }
        }

        /// Handles one message without blocking the read loop, so a `cancel` is read while its
        /// run is still going.
        fn handle(self: Arc<Self>, message: Message) {
            match message {
                Message::Hello { .. } => self.send(&protocol::hello_reply()),
                Message::Command { id, .. } => {
                    self.send(&protocol::unsupported_command_response(id))
                }
                Message::Cancel { id } => {
                    if let Some(canceller) = self.runs.lock().unwrap().get(&id) {
                        canceller.cancel();
                    }
                }
                Message::Lifecycle { .. } => {}
                Message::Run {
                    id,
                    command,
                    timeout_seconds,
                } => {
                    let run = Run::default();
                    self.runs.lock().unwrap().insert(id, run.canceller());
                    thread::spawn(move || {
                        let result = run.execute(
                            &runner::SHELL,
                            &command,
                            runner::clamp_timeout(timeout_seconds),
                        );
                        self.runs.lock().unwrap().remove(&id);
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
                Message::HelloReply { .. }
                | Message::Response { .. }
                | Message::RunResult { .. } => {
                    eprintln!(
                        "alas-vm-guest-linux: ignoring a guest-to-host message sent to the guest"
                    );
                }
            }
        }

        fn send(&self, message: &Message) {
            let frame = protocol::frame(message);
            if let Some(writer) = self.writer.lock().unwrap().as_mut()
                && let Err(error) = writer.write_all(&frame)
            {
                eprintln!("alas-vm-guest-linux: write failed: {error}");
            }
        }
    }
}
