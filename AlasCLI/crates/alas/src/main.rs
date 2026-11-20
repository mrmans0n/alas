mod mcp;
mod output;
mod parse;
mod skill;
mod tool;

use alas_client::{dispatch, logical_base, resolve_target, Command, DispatchError, TransportError};
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
    match args.first().map(String::as_str) {
        Some("tool") => return run_tool(&args[1..], &base),
        Some("skill") => return run_skill(&args[1..], &base),
        _ => {}
    }
    let command = match parse(&args, &base) {
        Ok(command) => command,
        Err(usage) => {
            eprintln!("{usage}");
            return ExitCode::from(2);
        }
    };
    run(&command, false)
}

/// Sends `command` to Alas and prints its reply. `confirm_empty` prints the
/// MCP server's confirmation when the app replies with no lines.
fn run(command: &Command, confirm_empty: bool) -> ExitCode {
    let target = resolve_target();
    match dispatch(command, &target) {
        Ok(resp) if resp.ok => {
            match output::success_lines(command, resp.lines, confirm_empty, &std::env::temp_dir()) {
                Ok(lines) => {
                    for line in lines {
                        println!("{line}");
                    }
                    ExitCode::SUCCESS
                }
                Err(message) => {
                    eprintln!("alas: {message}");
                    ExitCode::FAILURE
                }
            }
        }
        Ok(resp) => {
            eprintln!("alas: {}", resp.error.unwrap_or_else(|| "request failed".into()));
            ExitCode::from(resp.exit_code.unwrap_or(1))
        }
        Err(err) => {
            let (msg, code) = match &err {
                DispatchError::Transport(transport) => mcp::unanswered_call_message(command, transport)
                    .map_or_else(|| describe(&err), |message| (message, 1)),
                _ => describe(&err),
            };
            eprintln!("alas: {msg}");
            ExitCode::from(code)
        }
    }
}

/// `alas skill …`: prints a guide, or installs, removes or reports the Alas
/// agent skills. Runs locally; Alas need not be running.
fn run_skill(args: &[String], base: &std::path::Path) -> ExitCode {
    let command = match skill::parse(args, base) {
        Ok(command) => command,
        Err(usage) => {
            eprintln!("{usage}");
            return ExitCode::from(2);
        }
    };
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_default();
    let result = match command {
        skill::SkillCommand::Guide(topic) => {
            let parent = std::env::var("ALAS_PARENT_SESSION_ID").ok().filter(|id| !id.is_empty());
            skill::guide(topic.as_deref(), &mcp::session_tool_definitions(parent.as_deref())).map(|text| vec![text])
        }
        skill::SkillCommand::Install(dirs) => skill::install(&skill::target_dirs(dirs, &home)),
        skill::SkillCommand::Remove(dirs) => skill::remove(&skill::target_dirs(dirs, &home)),
        skill::SkillCommand::Status { dirs, json } => Ok(skill::status(&skill::target_dirs(dirs, &home), json)),
    };
    match result {
        Ok(lines) => {
            for line in lines {
                println!("{line}");
            }
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("alas: {message}");
            ExitCode::FAILURE
        }
    }
}

/// `alas tool …`: lists the built-in MCP tools, or calls one with its JSON
/// arguments. Relative paths in them resolve against `base`, like `alas open`.
fn run_tool(args: &[String], base: &std::path::Path) -> ExitCode {
    let invocation = match tool::parse(args, || std::io::read_to_string(std::io::stdin())) {
        Ok(invocation) => invocation,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(2);
        }
    };
    let parent = std::env::var("ALAS_PARENT_SESSION_ID").ok().filter(|id| !id.is_empty());
    let tools = mcp::session_tool_definitions(parent.as_deref());
    match invocation {
        tool::ToolCommand::List => {
            for line in tool::list_lines(&tools) {
                println!("{line}");
            }
            ExitCode::SUCCESS
        }
        tool::ToolCommand::Schema(name) => match tool::schema(&tools, &name) {
            Ok(schema) => {
                println!("{schema}");
                ExitCode::SUCCESS
            }
            Err(message) => {
                eprintln!("alas: {message}");
                ExitCode::from(2)
            }
        },
        tool::ToolCommand::Call { name, args } => {
            match mcp::command_for_tool(&name, &args, &base.to_string_lossy()) {
                Ok(command) => run(&command, true),
                Err(message) => {
                    eprintln!("alas: {message}");
                    ExitCode::from(2)
                }
            }
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
        DispatchError::Transport(TransportError::ResponseTooLarge) => {
            ("response from Alas exceeded 12 MiB".into(), 1)
        }
        DispatchError::Transport(_) => ("could not reach Alas".into(), 1),
    }
}

#[derive(Debug, PartialEq)]
enum McpMode {
    Stdio,
    Http(mcp::HttpOptions),
    Relay(mcp::RelayScope),
}

/// `alas mcp` runs the stdio MCP server; `alas mcp --http [--port <n>]
/// [--exit-with-parent]` runs the same server over localhost HTTP;
/// `alas mcp --visual-only` runs the stdio server exposing only
/// `visual_show`, and `alas mcp --remote` adds `pr_create`/`pr_status`; both
/// back the SSH session relay. Anything else falls through to the normal
/// parser, which rejects it with usage text.
fn mcp_mode(args: &[String]) -> Option<McpMode> {
    match args {
        [only] if only == "mcp" => Some(McpMode::Stdio),
        [first, second] if first == "mcp" && second == "--visual-only" => {
            Some(McpMode::Relay(mcp::RelayScope::Visual))
        }
        [first, second] if first == "mcp" && second == "--remote" => {
            Some(McpMode::Relay(mcp::RelayScope::Remote))
        }
        [first, second, rest @ ..] if first == "mcp" && second == "--http" => {
            http_options(rest).map(McpMode::Http)
        }
        _ => None,
    }
}

/// Parses the flags after `mcp --http`; each may appear at most once.
fn http_options(args: &[String]) -> Option<mcp::HttpOptions> {
    let mut options = mcp::HttpOptions::default();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--port" if options.port.is_none() => {
                options.port = Some(iter.next()?.parse().ok().filter(|&port: &u16| port != 0)?);
            }
            "--exit-with-parent" if !options.exit_with_parent => options.exit_with_parent = true,
            _ => return None,
        }
    }
    Some(options)
}

fn run_mcp(mode: McpMode) -> ExitCode {
    let mut env = match mcp::env_from(|key| std::env::var(key).ok()) {
        Ok(env) => env,
        Err(message) => {
            eprintln!("alas: {message}");
            return ExitCode::from(2);
        }
    };
    match mode {
        McpMode::Http(_) => env.transport = "http",
        McpMode::Relay(relay) => env.relay = Some(relay),
        McpMode::Stdio => {}
    }
    let result = match mode {
        McpMode::Stdio | McpMode::Relay(_) => mcp::serve(&env),
        McpMode::Http(options) => mcp::serve_http(&env, &options),
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
        assert_eq!(
            mcp_mode(&["mcp".into(), "--http".into()]),
            Some(McpMode::Http(mcp::HttpOptions::default()))
        );
        assert_eq!(
            mcp_mode(&[
                "mcp".into(),
                "--http".into(),
                "--port".into(),
                "41234".into(),
                "--exit-with-parent".into(),
            ]),
            Some(McpMode::Http(mcp::HttpOptions {
                port: Some(41234),
                exit_with_parent: true,
            }))
        );
        assert_eq!(
            mcp_mode(&["mcp".into(), "--visual-only".into()]),
            Some(McpMode::Relay(mcp::RelayScope::Visual))
        );
        assert_eq!(
            mcp_mode(&["mcp".into(), "--remote".into()]),
            Some(McpMode::Relay(mcp::RelayScope::Remote))
        );
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
        for rest in [
            vec!["--visual-only"],
            vec!["--port"],
            vec!["--port", "0"],
            vec!["--port", "nope"],
            vec!["--port", "1", "--port", "2"],
        ] {
            let mut args: Vec<String> = vec!["mcp".into(), "--http".into()];
            args.extend(rest.iter().map(|arg| arg.to_string()));
            assert_eq!(mcp_mode(&args), None, "{rest:?}");
        }
    }
}
