//! The Alas helper inside a Linux worktree VM. It listens on vsock for the host, answers `hello`,
//! runs `vm_run` commands, and answers computer use through Cua Driver. It runs as a systemd user
//! service that may start before the desktop, so it never needs a display until a computer-use
//! call starts the driver.

// Off Linux only the code under test is built; the vsock listener that uses it is Linux only.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod computer;
mod cua;
mod protocol;
mod runner;
mod service;

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
    use crate::computer::Computer;
    use crate::cua::{CuaConfig, CuaDriver};
    use crate::protocol::{self, Framer};
    use crate::service::{Connection, Desktop};
    use std::fs::File;
    use std::io::{self, Read};
    use std::os::fd::FromRawFd;
    use std::sync::Arc;
    use std::thread;

    /// Binds the vsock port and serves each host connection on a thread of its own. Every
    /// connection shares the one desktop; Cua Driver starts on the first hello or call, and each
    /// start reads the desktop session's environment afresh.
    pub fn serve() -> io::Result<()> {
        let desktop = Desktop::new(Computer::new(CuaDriver::new(CuaConfig::for_session)));
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
            let desktop = Arc::clone(&desktop);
            thread::spawn(move || serve_connection(stream, desktop));
        }
    }

    /// Reads one host connection's messages until it closes.
    fn serve_connection(mut reader: File, desktop: Arc<Desktop<CuaDriver>>) {
        let writer = match reader.try_clone() {
            Ok(writer) => writer,
            Err(error) => {
                eprintln!("alas-vm-guest-linux: couldn't set up a connection: {error}");
                return;
            }
        };
        eprintln!("alas-vm-guest-linux: host connected");
        let connection = Connection::new(desktop, Box::new(writer));
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
        connection.close();
    }
}
