use std::path::Path;

use crate::terminal::CommandSpec;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HarnessKind {
    ClaudeCode,
    Codex,
    CursorAgent,
    Pi,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HarnessState {
    Supported(HarnessKind),
    Unsupported,
}

impl HarnessState {
    pub fn detect(command: &CommandSpec) -> Self {
        if let Some(kind) = detect_from_command_spec(command) {
            Self::Supported(kind)
        } else {
            Self::Unsupported
        }
    }

    pub fn is_supported(&self) -> bool {
        matches!(self, Self::Supported(_))
    }

    pub fn kind(&self) -> Option<HarnessKind> {
        match self {
            Self::Supported(kind) => Some(*kind),
            Self::Unsupported => None,
        }
    }
}

fn detect_from_command_spec(command: &CommandSpec) -> Option<HarnessKind> {
    let program_basename = basename(&command.program);
    if !is_shell(program_basename) {
        return harness_for_executable(program_basename);
    }

    shell_command_arg(&command.args)
        .and_then(detect_from_shell_command)
        .or_else(|| detect_from_shell_command(&command.display))
}

fn shell_command_arg(args: &[String]) -> Option<&str> {
    args.windows(2)
        .find(|window| is_shell_command_flag(&window[0]))
        .map(|window| window[1].as_str())
}

fn is_shell_command_flag(flag: &str) -> bool {
    flag.starts_with('-') && flag.contains('c')
}

fn detect_from_shell_command(command: &str) -> Option<HarnessKind> {
    let tokens = shell_tokens(command);
    let executable = first_executable_token(&tokens)?;
    harness_for_executable(basename(executable))
}

fn first_executable_token(tokens: &[String]) -> Option<&str> {
    let mut index = 0;

    while let Some(token) = tokens.get(index) {
        if is_env_assignment(token) {
            index += 1;
        } else {
            break;
        }
    }

    match tokens.get(index).map(String::as_str) {
        Some("exec") => {
            index += 1;
            while let Some(token) = tokens.get(index) {
                if token.starts_with('-') {
                    index += 1;
                } else {
                    break;
                }
            }
        }
        Some("env") => {
            index += 1;
            while let Some(token) = tokens.get(index) {
                if is_env_assignment(token) || token.starts_with('-') {
                    index += 1;
                } else {
                    break;
                }
            }
        }
        _ => {}
    }

    tokens.get(index).map(String::as_str)
}

fn shell_tokens(command: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut chars = command.trim_start().chars().peekable();
    let mut quote = None;

    while let Some(ch) = chars.next() {
        match (quote, ch) {
            (None, '\'') => quote = Some('\''),
            (None, '"') => quote = Some('"'),
            (Some('\''), '\'') => quote = None,
            (Some('"'), '"') => quote = None,
            (None, ch) if ch.is_whitespace() => {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            }
            (_, '\\') => {
                if let Some(next) = chars.next() {
                    current.push(next);
                }
            }
            _ => current.push(ch),
        }
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    tokens
}

fn is_env_assignment(token: &str) -> bool {
    let Some((name, _)) = token.split_once('=') else {
        return false;
    };

    let mut chars = name.chars();
    matches!(chars.next(), Some('_') | Some('A'..='Z') | Some('a'..='z'))
        && chars.all(|ch| matches!(ch, '_' | 'A'..='Z' | 'a'..='z' | '0'..='9'))
}

fn harness_for_executable(executable: &str) -> Option<HarnessKind> {
    match executable {
        "claude" => Some(HarnessKind::ClaudeCode),
        "codex" => Some(HarnessKind::Codex),
        "cursor-agent" => Some(HarnessKind::CursorAgent),
        "pi" => Some(HarnessKind::Pi),
        _ => None,
    }
}

fn basename(program: &str) -> &str {
    Path::new(program)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(program)
}

fn is_shell(program: &str) -> bool {
    matches!(program, "sh" | "bash" | "zsh" | "fish")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn cwd() -> PathBuf {
        PathBuf::from("/repo/wt")
    }

    fn direct(program: &str, args: &[&str]) -> CommandSpec {
        CommandSpec {
            display: program.to_string(),
            program: program.to_string(),
            args: args.iter().map(|arg| arg.to_string()).collect(),
            cwd: cwd(),
        }
    }

    #[test]
    fn detects_supported_shell_commands() {
        assert_eq!(
            HarnessState::detect(&CommandSpec::shell_command("claude", cwd())),
            HarnessState::Supported(HarnessKind::ClaudeCode)
        );
        assert_eq!(
            HarnessState::detect(&CommandSpec::shell_command("codex", cwd())),
            HarnessState::Supported(HarnessKind::Codex)
        );
        assert_eq!(
            HarnessState::detect(&CommandSpec::shell_command("cursor-agent", cwd())),
            HarnessState::Supported(HarnessKind::CursorAgent)
        );
        assert_eq!(
            HarnessState::detect(&CommandSpec::shell_command("pi", cwd())),
            HarnessState::Supported(HarnessKind::Pi)
        );
    }

    #[test]
    fn detects_direct_programs_and_paths() {
        assert_eq!(
            HarnessState::detect(&direct("claude", &[])),
            HarnessState::Supported(HarnessKind::ClaudeCode)
        );
        assert_eq!(
            HarnessState::detect(&direct("/opt/homebrew/bin/codex", &[])),
            HarnessState::Supported(HarnessKind::Codex)
        );
    }

    #[test]
    fn detects_shell_wrappers_and_prefixes() {
        assert_eq!(
            HarnessState::detect(&direct("/bin/zsh", &["-lc", "OPENAI_API_KEY=x codex exec"])),
            HarnessState::Supported(HarnessKind::Codex)
        );
        assert_eq!(
            HarnessState::detect(&direct("bash", &["-c", "env FOO=bar claude"])),
            HarnessState::Supported(HarnessKind::ClaudeCode)
        );
        assert_eq!(
            HarnessState::detect(&direct("sh", &["-c", "exec cursor-agent"])),
            HarnessState::Supported(HarnessKind::CursorAgent)
        );
        assert_eq!(
            HarnessState::detect(&direct("fish", &["-c", "exec pi"])),
            HarnessState::Supported(HarnessKind::Pi)
        );
    }

    #[test]
    fn leaves_non_harness_commands_unsupported() {
        for command in [
            "$SHELL",
            "cargo test",
            "npm test",
            "git status",
            "echo claude",
            "picard",
            "my-claude-wrapper",
            "cargo test && claude",
            "command claude",
            "command -v claude",
            "command -V codex",
            "command --help cursor-agent",
        ] {
            assert_eq!(
                HarnessState::detect(&CommandSpec::shell_command(command, cwd())),
                HarnessState::Unsupported,
                "{command}"
            );
        }
    }

    #[test]
    fn exposes_supported_helpers() {
        let state = HarnessState::Supported(HarnessKind::ClaudeCode);

        assert!(state.is_supported());
        assert_eq!(state.kind(), Some(HarnessKind::ClaudeCode));
        assert!(!HarnessState::Unsupported.is_supported());
        assert_eq!(HarnessState::Unsupported.kind(), None);
    }
}
