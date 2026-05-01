use std::{
    thread,
    time::{Duration, Instant},
};

use alas::agent::{AgentTerminalHandle, AgentTerminalService, AgentTerminalStatus, AgentTrustMode};

#[test]
fn command_runs_captures_output_and_release_removes_handle() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, worktree.clone());

    let handle = service
        .create(&print_command("hello terminal"), &worktree)
        .expect("create terminal command");
    let result = service.wait_for_exit(handle).expect("wait for exit");

    assert_eq!(result.status, AgentTerminalStatus::Exited(Some(0)));
    assert!(
        service
            .output(handle)
            .expect("read output")
            .contains("hello terminal")
    );

    service.release(handle).expect("release handle");
    let error = service
        .output(handle)
        .expect_err("released handle should not have output");
    assert!(
        error.to_string().contains("not found"),
        "unexpected error: {error:#}"
    );
}

#[test]
fn command_captures_stderr_and_tail_output_after_wait() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, worktree.clone());

    let handle = service
        .create(stdout_stderr_tail_command(), &worktree)
        .expect("create terminal command");
    let result = service.wait_for_exit(handle).expect("wait for exit");
    let output = service.output(handle).expect("read output");

    assert_eq!(result.status, AgentTerminalStatus::Exited(Some(0)));
    assert!(output.contains("stdout"), "missing stdout in {output:?}");
    assert!(output.contains("stderr"), "missing stderr in {output:?}");
    assert!(output.contains("tail"), "missing tail output in {output:?}");
}

#[test]
fn non_zero_exit_status_is_reported() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, worktree.clone());

    let handle = service
        .create(&exit_command(7), &worktree)
        .expect("create terminal command");
    let result = service.wait_for_exit(handle).expect("wait for exit");

    assert_eq!(result.status, AgentTerminalStatus::Exited(Some(7)));
}

#[test]
fn invalid_handle_errors_for_terminal_operations() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, worktree);
    let handle = AgentTerminalHandle(999);

    assert_not_found(service.output(handle).expect_err("output should fail"));
    assert_not_found(service.wait_for_exit(handle).expect_err("wait should fail"));
    assert_not_found(service.kill(handle).expect_err("kill should fail"));
    assert_not_found(service.release(handle).expect_err("release should fail"));
}

#[test]
fn release_running_command_removes_handle_and_stops_process() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let marker = worktree.join("marker");
    let marker_arg = marker.to_string_lossy();
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, worktree.clone());

    let handle = service
        .create(&delayed_marker_command(&marker_arg), &worktree)
        .expect("create terminal command");

    service.release(handle).expect("release running handle");
    thread::sleep(Duration::from_millis(700));

    assert!(
        service.output(handle).is_err(),
        "released handle should not allow later output"
    );
    assert!(
        !marker.exists(),
        "released command should have been stopped"
    );
}

#[test]
fn kill_running_command_marks_failed_and_later_wait_returns() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, worktree.clone());

    let handle = service
        .create(long_running_command(), &worktree)
        .expect("create terminal command");

    let result = service.kill(handle).expect("kill running command");
    assert_eq!(result.status, AgentTerminalStatus::Failed);

    let start = Instant::now();
    let later_result = service.wait_for_exit(handle).expect("wait after kill");
    assert_eq!(later_result.status, AgentTerminalStatus::Failed);
    assert!(
        start.elapsed() < Duration::from_secs(1),
        "wait after kill should return immediately"
    );
}

#[cfg(unix)]
#[test]
fn kill_escalates_when_command_ignores_term() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, worktree.clone());

    let handle = service
        .create(term_resistant_command(), &worktree)
        .expect("create terminal command");
    wait_for_output(&service, handle, "ready");

    let start = Instant::now();
    let result = service.kill(handle).expect("kill TERM-resistant command");

    assert_eq!(result.status, AgentTerminalStatus::Failed);
    assert!(
        start.elapsed() < Duration::from_secs(3),
        "kill should escalate to SIGKILL instead of waiting for sleep"
    );
}

#[test]
fn output_is_visible_before_wait() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let mut service = AgentTerminalService::new(AgentTrustMode::AllowEverything, worktree.clone());

    let handle = service
        .create(ready_then_sleep_command(), &worktree)
        .expect("create terminal command");

    wait_for_output(&service, handle, "ready");

    let result = service.wait_for_exit(handle).expect("wait for exit");
    assert_eq!(result.status, AgentTerminalStatus::Exited(Some(0)));
    service.release(handle).expect("release handle");
}

#[test]
fn deny_rejects_command() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().to_path_buf();
    let mut service = AgentTerminalService::new(AgentTrustMode::Deny, worktree.clone());

    let error = service
        .create(&print_command("should not run"), &worktree)
        .expect_err("command should be denied");

    assert!(
        error.to_string().contains("permission denied"),
        "unexpected error: {error:#}"
    );
}

fn wait_for_output(service: &AgentTerminalService, handle: AgentTerminalHandle, expected: &str) {
    let mut output = String::new();
    for _ in 0..20 {
        output = service.output(handle).expect("read output");
        if output.contains(expected) {
            return;
        }
        thread::sleep(Duration::from_millis(50));
    }

    panic!("expected {expected:?} in terminal output, got {output:?}");
}

fn assert_not_found(error: anyhow::Error) {
    assert!(
        error.to_string().contains("not found"),
        "unexpected error: {error:#}"
    );
}

#[cfg(windows)]
fn print_command(message: &str) -> String {
    format!("echo {message}")
}

#[cfg(not(windows))]
fn print_command(message: &str) -> String {
    format!("printf '{message}'")
}

#[cfg(windows)]
fn stdout_stderr_tail_command() -> &'static str {
    "echo stdout && echo stderr 1>&2 && echo tail"
}

#[cfg(not(windows))]
fn stdout_stderr_tail_command() -> &'static str {
    "printf stdout; printf stderr >&2; printf tail"
}

#[cfg(windows)]
fn exit_command(code: i32) -> String {
    format!("exit /B {code}")
}

#[cfg(not(windows))]
fn exit_command(code: i32) -> String {
    format!("exit {code}")
}

#[cfg(windows)]
fn delayed_marker_command(marker: &str) -> String {
    format!("ping -n 3 127.0.0.1 >NUL & type nul > \"{marker}\"")
}

#[cfg(not(windows))]
fn delayed_marker_command(marker: &str) -> String {
    format!("sleep 2; touch '{marker}'")
}

#[cfg(windows)]
fn ready_then_sleep_command() -> &'static str {
    "echo ready && ping -n 2 127.0.0.1 >NUL"
}

#[cfg(not(windows))]
fn ready_then_sleep_command() -> &'static str {
    "printf 'ready'; sleep 1"
}

#[cfg(windows)]
fn long_running_command() -> &'static str {
    "ping -n 6 127.0.0.1 >NUL"
}

#[cfg(not(windows))]
fn long_running_command() -> &'static str {
    "sleep 5"
}

#[cfg(unix)]
fn term_resistant_command() -> &'static str {
    "trap '' TERM; printf 'ready'; sleep 5"
}
