mod parse;

use alas_client::{dispatch, logical_base, resolve_target, DispatchError, Target};
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
            let (msg, code) = describe(&err, &target);
            eprintln!("alas: {msg}");
            ExitCode::from(code)
        }
    }
}

fn describe(err: &DispatchError, target: &Target) -> (String, u8) {
    match err {
        DispatchError::NoAlas => ("no running Alas found".into(), 2),
        DispatchError::NotInWorktree => ("not inside an Alas worktree".into(), 2),
        DispatchError::Ambiguous => (
            "multiple running Alas instances own this directory".into(),
            1,
        ),
        DispatchError::Transport(_) => match target {
            Target::Session { .. } => ("could not reach Alas".into(), 1),
            Target::Directory { .. } => ("could not reach Alas".into(), 1),
        },
    }
}
