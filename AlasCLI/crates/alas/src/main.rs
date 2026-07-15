mod parse;
mod mcp;

use alas_client::{dispatch, logical_base, resolve_target, DispatchError, TransportError};
use parse::{is_ao, parse};
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut argv = std::env::args();
    let argv0 = argv.next().unwrap_or_default();
    let mut args: Vec<String> = argv.collect();

    // `ao` is `alas open` with argv shifted so the user's args become paths.
    if is_ao(&argv0) {
        let mut rewritten = vec!["open".to_string()];
        rewritten.append(&mut args);
        args = rewritten;
    }

    if is_mcp_invocation(&args) {
        return run_mcp();
    }

    let base = logical_base();
    let command = match parse(&args, &base) {
        Ok(command) => command,
        Err(usage) => {
            eprintln!("{usage}");
            return ExitCode::from(2);
        }
    };

    let target = resolve_target();
    match dispatch(&command, &target) {
        Ok(resp) => {
            if resp.ok {
                if let Some(lines) = resp.lines {
                    for line in lines {
                        println!("{line}");
                    }
                }
                ExitCode::SUCCESS
            } else {
                eprintln!("alas: {}", resp.error.unwrap_or_else(|| "request failed".into()));
                ExitCode::FAILURE
            }
        }
        Err(err) => {
            let (msg, code) = describe(&err);
            eprintln!("alas: {msg}");
            ExitCode::from(code)
        }
    }
}

fn describe(err: &DispatchError) -> (String, u8) {
    match err {
        DispatchError::NoAlas => ("no running Alas found".into(), 2),
        DispatchError::NotInWorktree => ("not inside an Alas worktree".into(), 2),
        DispatchError::Ambiguous => (
            "multiple running Alas instances own this directory".into(),
            1,
        ),
        // A reply that didn't parse is a distinct failure mode from a socket
        // we couldn't connect to or write/read at all — surface it
        // separately so a corrupted/incompatible app reply isn't confused
        // with "Alas isn't running".
        DispatchError::Transport(TransportError::Malformed) => {
            ("malformed response from Alas".into(), 1)
        }
        DispatchError::Transport(_) => ("could not reach Alas".into(), 1),
    }
}

/// `alas mcp` takes no further arguments; anything else falls through to
/// the normal parser, which rejects it with usage text.
fn is_mcp_invocation(args: &[String]) -> bool {
    args.len() == 1 && args[0] == "mcp"
}

fn run_mcp() -> ExitCode {
    let env = match mcp::env_from(|key| std::env::var(key).ok()) {
        Ok(env) => env,
        Err(message) => {
            eprintln!("alas: {message}");
            return ExitCode::from(2);
        }
    };
    match mcp::serve(&env) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("alas: mcp io error: {err}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_maps_not_in_worktree_to_exit_code_2() {
        let (msg, code) = describe(&DispatchError::NotInWorktree);
        assert_eq!(msg, "not inside an Alas worktree");
        assert_eq!(code, 2);
    }

    #[test]
    fn describe_maps_no_alas_to_exit_code_2() {
        let (_, code) = describe(&DispatchError::NoAlas);
        assert_eq!(code, 2);
    }

    #[test]
    fn describe_maps_ambiguous_to_exit_code_1() {
        let (_, code) = describe(&DispatchError::Ambiguous);
        assert_eq!(code, 1);
    }

    #[test]
    fn describe_gives_malformed_replies_a_distinct_message() {
        let (msg, code) = describe(&DispatchError::Transport(TransportError::Malformed));
        assert_eq!(msg, "malformed response from Alas");
        assert_eq!(code, 1);
    }

    #[test]
    fn describe_keeps_generic_message_for_connect_and_io_failures() {
        let (connect_msg, connect_code) = describe(&DispatchError::Transport(TransportError::Connect));
        assert_eq!(connect_msg, "could not reach Alas");
        assert_eq!(connect_code, 1);

        let (io_msg, io_code) = describe(&DispatchError::Transport(TransportError::Io));
        assert_eq!(io_msg, "could not reach Alas");
        assert_eq!(io_code, 1);

        // The two must stay distinguishable from the malformed-reply case.
        assert_ne!(connect_msg, "malformed response from Alas");
    }

    #[test]
    fn mcp_mode_is_detected_only_as_sole_argument() {
        assert!(is_mcp_invocation(&["mcp".to_string()]));
        assert!(!is_mcp_invocation(&["mcp".to_string(), "extra".to_string()]));
        assert!(!is_mcp_invocation(&["open".to_string(), "mcp".to_string()]));
        assert!(!is_mcp_invocation(&[]));
    }
}
