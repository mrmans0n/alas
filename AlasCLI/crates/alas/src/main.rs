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

    if let Some(mode) = mcp_mode(&args) {
        return run_mcp(mode);
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
                ExitCode::from(resp.exit_code.unwrap_or(1))
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

#[derive(Debug, PartialEq)]
enum McpMode {
    Stdio,
    Http,
}

/// `alas mcp` runs the stdio MCP server; `alas mcp --http` runs the same
/// server over localhost HTTP. Anything else falls through to the normal
/// parser, which rejects it with usage text.
fn mcp_mode(args: &[String]) -> Option<McpMode> {
    match args {
        [only] if only == "mcp" => Some(McpMode::Stdio),
        [first, second] if first == "mcp" && second == "--http" => Some(McpMode::Http),
        _ => None,
    }
}

fn run_mcp(mode: McpMode) -> ExitCode {
    let env = match mcp::env_from(|key| std::env::var(key).ok()) {
        Ok(env) => env,
        Err(message) => {
            eprintln!("alas: {message}");
            return ExitCode::from(2);
        }
    };
    let result = match mode {
        McpMode::Stdio => mcp::serve(&env),
        McpMode::Http => mcp::serve_http(&env),
    };
    match result {
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
    fn mcp_mode_detection() {
        assert_eq!(mcp_mode(&["mcp".into()]), Some(McpMode::Stdio));
        assert_eq!(mcp_mode(&["mcp".into(), "--http".into()]), Some(McpMode::Http));
        assert_eq!(mcp_mode(&["open".into()]), None);
    }

    #[test]
    fn mcp_mode_rejects_unexpected_shapes() {
        assert_eq!(mcp_mode(&["mcp".into(), "extra".into()]), None);
        assert_eq!(mcp_mode(&["open".into(), "mcp".into()]), None);
        assert_eq!(mcp_mode(&[]), None);
        assert_eq!(
            mcp_mode(&["mcp".into(), "--http".into(), "extra".into()]),
            None
        );
    }
}
