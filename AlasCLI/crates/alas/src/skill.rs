//! `alas skill`: agent skills that teach any harness to drive Alas with this
//! CLI, for agents whose MCP policy blocks or caps the built-in server.
//!
//! The installed skills are stubs, like Rex's: each one only tells the agent
//! to run `alas skill guide <topic>`, so the guide always matches the
//! installed Alas and the files on disk never go stale. `alas` routes to the
//! specialist skills, the way a routing skill does in a skill pack.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub const USAGE: &str = "\
usage: alas skill guide [review|delegation|preview|computer|devices]
usage: alas skill install [--dir <skills-dir>]...
usage: alas skill remove [--dir <skills-dir>]...
usage: alas skill status [--dir <skills-dir>]... [--json]
  (the skills go to ~/.agents/skills, and to ~/.claude/skills when Claude Code is set up)";

/// Bumped when a stub's wording changes, so `status` reports older ones as
/// outdated and `install` rewrites them.
const STUB_VERSION: u32 = 1;
const MARKER_KEY: &str = "alas-skill";

struct Skill {
    name: &'static str,
    /// None for the router, which `alas skill guide` prints with no topic.
    topic: Option<&'static str>,
    description: &'static str,
    guide: &'static str,
    /// Prefixes of the tools a topic guide lists after its text.
    tool_prefixes: &'static [&'static str],
}

const SKILLS: [Skill; 6] = [
    Skill {
        name: "alas",
        topic: None,
        description: "Use when working inside Alas, the user's macOS workspace app, or when Alas's MCP tools are missing: drives Alas with the alas CLI (open files, notify, worktrees, visuals) and routes to the other Alas skills.",
        guide: include_str!("skills/router.md"),
        tool_prefixes: &[],
    },
    Skill {
        name: "alas-review",
        topic: Some("review"),
        description: "Use for Alas's review pane (opening reviews, filing, replying to and resolving comments, verdicts) and for opening or checking pull requests and shipping gg stacks through Alas.",
        guide: include_str!("skills/review.md"),
        tool_prefixes: &["review", "pr_", "stack_"],
    },
    Skill {
        name: "alas-delegation",
        topic: Some("delegation"),
        description: "Use to delegate work to child agent sessions in Alas, message a parent or child session, wait on children, or read their transcripts.",
        guide: include_str!("skills/delegation.md"),
        tool_prefixes: &["agent_", "session_"],
    },
    Skill {
        name: "alas-preview",
        topic: Some("preview"),
        description: "Use to drive the user's web preview tabs in Alas: open, navigate, inspect, click, type, wait, capture, console.",
        guide: include_str!("skills/preview.md"),
        tool_prefixes: &["preview_"],
    },
    Skill {
        name: "alas-computer-use",
        topic: Some("computer"),
        description: "Use to see and operate macOS apps, or run commands in a worktree VM, through Alas: screenshots, accessibility inspection, click, type, keys, scroll, drag, vm run.",
        guide: include_str!("skills/computer.md"),
        tool_prefixes: &["computer_", "vm_"],
    },
    Skill {
        name: "alas-devices",
        topic: Some("devices"),
        description: "Use to drive iOS simulators and Android devices through Alas: install and launch apps, tap, swipe, type, screenshots, logs, appearance, permissions, location, push, deep links, flows.",
        guide: include_str!("skills/devices.md"),
        tool_prefixes: &["device_"],
    },
];

#[derive(Debug, PartialEq)]
pub enum SkillCommand {
    Guide(Option<String>),
    Install(Vec<PathBuf>),
    Remove(Vec<PathBuf>),
    Status { dirs: Vec<PathBuf>, json: bool },
}

/// Parses the arguments after `skill`. Relative `--dir` values resolve
/// against `base`.
pub fn parse(args: &[String], base: &Path) -> Result<SkillCommand, String> {
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let dirs_and_json = |rest: &[&str], allow_json: bool| -> Result<(Vec<PathBuf>, bool), String> {
        let (mut dirs, mut json) = (Vec::new(), false);
        let mut i = 0;
        while i < rest.len() {
            match rest[i] {
                "--dir" => {
                    let dir = rest.get(i + 1).filter(|dir| !dir.is_empty()).ok_or(USAGE)?;
                    dirs.push(PathBuf::from(alas_client::absolutize(base, dir)));
                    i += 2;
                }
                "--json" if allow_json && !json => {
                    json = true;
                    i += 1;
                }
                _ => return Err(USAGE.into()),
            }
        }
        Ok((dirs, json))
    };
    match args.split_first() {
        Some((&"guide", [])) => Ok(SkillCommand::Guide(None)),
        Some((&"guide", [topic])) => Ok(SkillCommand::Guide(Some(topic.to_string()))),
        Some((&"install", rest)) => Ok(SkillCommand::Install(dirs_and_json(rest, false)?.0)),
        Some((&"remove", rest)) => Ok(SkillCommand::Remove(dirs_and_json(rest, false)?.0)),
        Some((&"status", rest)) => {
            let (dirs, json) = dirs_and_json(rest, true)?;
            Ok(SkillCommand::Status { dirs, json })
        }
        _ => Err(USAGE.into()),
    }
}

/// The guide for `topic`, or the router without one. A topic guide ends with
/// its tools, read from the tool definitions so the list cannot drift.
pub fn guide(topic: Option<&str>, tools: &[Value]) -> Result<String, String> {
    let skill = SKILLS
        .iter()
        .find(|skill| skill.topic == topic)
        .ok_or_else(|| format!("unknown guide: {}\n{USAGE}", topic.unwrap_or_default()))?;
    let mut text = skill.guide.trim_end().to_string();
    let listed: Vec<Value> = tools
        .iter()
        .filter(|tool| {
            tool["name"]
                .as_str()
                .is_some_and(|name| skill.tool_prefixes.iter().any(|prefix| name.starts_with(prefix)))
        })
        .cloned()
        .collect();
    if !listed.is_empty() {
        text.push_str("\n\n## Tools\n\nEach also runs as `alas tool call <name> '<json-arguments>'`; `alas tool schema <name>` prints its arguments.\n\n```\n");
        text.push_str(&crate::tool::list_lines(&listed).join("\n"));
        text.push_str("\n```");
    }
    Ok(text)
}

/// The skills directories to use: `explicit` when given, else
/// `~/.agents/skills` (read by Codex, Cursor, Gemini, OpenCode and Pi) and
/// `~/.claude/skills` when Claude Code is set up. One directory reached
/// through a symlink counts once.
pub fn target_dirs(explicit: Vec<PathBuf>, home: &Path) -> Vec<PathBuf> {
    let candidates = if explicit.is_empty() {
        let mut dirs = vec![home.join(".agents/skills")];
        if home.join(".claude").is_dir() {
            dirs.push(home.join(".claude/skills"));
        }
        dirs
    } else {
        explicit
    };
    let mut seen = Vec::new();
    let mut dirs = Vec::new();
    for dir in candidates {
        let identity = std::fs::canonicalize(&dir).unwrap_or_else(|_| dir.clone());
        if !seen.contains(&identity) {
            seen.push(identity);
            dirs.push(dir);
        }
    }
    dirs
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum State {
    Missing,
    Outdated,
    Installed,
    /// A skill of the same name that Alas did not install is in the way.
    Conflict,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Missing => "missing",
            State::Outdated => "outdated",
            State::Installed => "installed",
            State::Conflict => "conflict",
        }
    }
}

fn stub(skill: &Skill) -> String {
    let guide = match skill.topic {
        Some(topic) => format!("alas skill guide {topic}"),
        None => "alas skill guide".into(),
    };
    format!(
        "---\nname: {name}\ndescription: {description}\nmetadata:\n  {MARKER_KEY}: \"{STUB_VERSION}\"\n---\n\
<!-- Installed by Alas. Remove it with \"alas skill remove\" or from Alas Settings > Agents. -->\n\n\
Run `{guide}` and follow the guide it prints. The guide comes from the\n\
installed `alas` CLI, so it describes the Alas version you are driving.\n\n\
If the command fails, this Alas predates the guide: run `alas tool list`, then\n\
`alas tool schema <name>` and `alas tool call <name> '<json-arguments>'`.\n",
        name = skill.name,
        // Quoted: a plain YAML scalar cannot hold the ": " the descriptions use.
        description = Value::from(skill.description),
    )
}

/// The stub version an installed SKILL.md carries, or None when Alas did not
/// write it.
fn installed_version(text: &str) -> Option<u32> {
    let frontmatter = text.strip_prefix("---\n")?.split("\n---").next()?;
    frontmatter.lines().find_map(|line| {
        let value = line.trim().strip_prefix(MARKER_KEY)?.strip_prefix(':')?;
        value.trim().trim_matches('"').parse().ok()
    })
}

fn skill_state(dir: &Path, skill: &Skill) -> State {
    match std::fs::read_to_string(dir.join(skill.name).join("SKILL.md")) {
        Err(_) if !dir.join(skill.name).exists() => State::Missing,
        Err(_) => State::Conflict,
        Ok(text) => match installed_version(&text) {
            None => State::Conflict,
            Some(STUB_VERSION) => State::Installed,
            Some(_) => State::Outdated,
        },
    }
}

/// One directory's state: a conflict wins, then all installed, then any
/// trace of an older or partial install.
pub fn dir_state(dir: &Path) -> State {
    let states: Vec<State> = SKILLS.iter().map(|skill| skill_state(dir, skill)).collect();
    if states.contains(&State::Conflict) {
        State::Conflict
    } else if states.iter().all(|state| *state == State::Installed) {
        State::Installed
    } else if states.iter().all(|state| *state == State::Missing) {
        State::Missing
    } else {
        State::Outdated
    }
}

/// Writes every stub into each directory, leaving skills Alas did not
/// install alone. Returns one line per directory.
pub fn install(dirs: &[PathBuf]) -> Result<Vec<String>, String> {
    let mut lines = Vec::new();
    for dir in dirs {
        let mut skipped = Vec::new();
        for skill in &SKILLS {
            if skill_state(dir, skill) == State::Conflict {
                skipped.push(skill.name);
                continue;
            }
            let folder = dir.join(skill.name);
            std::fs::create_dir_all(&folder)
                .and_then(|()| std::fs::write(folder.join("SKILL.md"), stub(skill)))
                .map_err(|err| format!("could not write {}: {err}", folder.display()))?;
        }
        lines.push(if skipped.is_empty() {
            format!("installed Alas skills in {}", dir.display())
        } else {
            format!(
                "installed Alas skills in {}, except {}: a skill Alas did not install has that name",
                dir.display(),
                skipped.join(", ")
            )
        });
    }
    Ok(lines)
}

/// Deletes the stubs Alas installed, and their folders when nothing else is
/// in them.
pub fn remove(dirs: &[PathBuf]) -> Result<Vec<String>, String> {
    let mut lines = Vec::new();
    for dir in dirs {
        let mut removed = 0;
        for skill in &SKILLS {
            if !matches!(skill_state(dir, skill), State::Installed | State::Outdated) {
                continue;
            }
            let folder = dir.join(skill.name);
            std::fs::remove_file(folder.join("SKILL.md"))
                .map_err(|err| format!("could not remove {}: {err}", folder.display()))?;
            let _ = std::fs::remove_dir(&folder);
            removed += 1;
        }
        lines.push(format!("removed {removed} Alas skill(s) from {}", dir.display()));
    }
    Ok(lines)
}

/// The state of each directory, plus the overall one the app shows.
pub fn status(dirs: &[PathBuf], json_output: bool) -> Vec<String> {
    let states: Vec<(String, State)> = dirs
        .iter()
        .map(|dir| (dir.to_string_lossy().into_owned(), dir_state(dir)))
        .collect();
    if json_output {
        let overall = overall_state(states.iter().map(|(_, state)| *state));
        let dirs: Vec<Value> = states
            .iter()
            .map(|(path, state)| json!({ "path": path, "state": state.name() }))
            .collect();
        return vec![json!({ "version": 1, "state": overall.name(), "dirs": dirs }).to_string()];
    }
    states.iter().map(|(path, state)| format!("{}: {path}", state.name())).collect()
}

/// Installed only when every directory is; a conflict anywhere needs the
/// user; nothing anywhere is missing.
fn overall_state(states: impl Iterator<Item = State>) -> State {
    let states: Vec<State> = states.collect();
    if states.contains(&State::Conflict) {
        State::Conflict
    } else if !states.is_empty() && states.iter().all(|state| *state == State::Installed) {
        State::Installed
    } else if states.iter().all(|state| *state == State::Missing) {
        State::Missing
    } else {
        State::Outdated
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("alas-skill-test-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn install_status_and_remove_round_trip_without_touching_other_skills() {
        let home = temp_home("round-trip");
        let skills = home.join(".agents/skills");
        // Someone else's skill named like one of Alas's stays untouched.
        std::fs::create_dir_all(skills.join("alas-devices")).unwrap();
        std::fs::write(skills.join("alas-devices/SKILL.md"), "---\nname: alas-devices\n---\nmine").unwrap();
        std::fs::create_dir_all(skills.join("rex")).unwrap();
        let dirs = target_dirs(Vec::new(), &home);
        assert_eq!(dirs, vec![skills.clone()]);
        assert_eq!(dir_state(&skills), State::Conflict);

        let lines = install(&dirs).unwrap();
        assert!(lines[0].contains("except alas-devices"), "{lines:?}");
        assert_eq!(installed_version(&std::fs::read_to_string(skills.join("alas/SKILL.md")).unwrap()), Some(STUB_VERSION));
        assert_eq!(std::fs::read_to_string(skills.join("alas-devices/SKILL.md")).unwrap(), "---\nname: alas-devices\n---\nmine");

        std::fs::remove_dir_all(skills.join("alas-devices")).unwrap();
        assert_eq!(dir_state(&skills), State::Outdated);
        install(&dirs).unwrap();
        assert_eq!(dir_state(&skills), State::Installed);
        let status: Value = serde_json::from_str(&status(&dirs, true)[0]).unwrap();
        assert_eq!(status["state"], json!("installed"));

        remove(&dirs).unwrap();
        assert_eq!(dir_state(&skills), State::Missing);
        assert!(!skills.join("alas").exists());
        assert!(skills.join("rex").exists());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn an_older_stub_is_outdated_and_install_rewrites_it() {
        let home = temp_home("outdated");
        let dirs = target_dirs(Vec::new(), &home);
        install(&dirs).unwrap();
        let path = dirs[0].join("alas/SKILL.md");
        let older = std::fs::read_to_string(&path)
            .unwrap()
            .replace(&format!("{MARKER_KEY}: \"{STUB_VERSION}\""), &format!("{MARKER_KEY}: \"0\""));
        std::fs::write(&path, older).unwrap();
        assert_eq!(dir_state(&dirs[0]), State::Outdated);
        install(&dirs).unwrap();
        assert_eq!(dir_state(&dirs[0]), State::Installed);
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn claude_skills_join_only_when_claude_is_set_up_and_count_once_through_a_symlink() {
        let home = temp_home("claude");
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        assert_eq!(
            target_dirs(Vec::new(), &home),
            vec![home.join(".agents/skills"), home.join(".claude/skills")]
        );
        std::fs::create_dir_all(home.join(".agents/skills")).unwrap();
        std::os::unix::fs::symlink("../.agents/skills", home.join(".claude/skills")).unwrap();
        assert_eq!(target_dirs(Vec::new(), &home), vec![home.join(".agents/skills")]);
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn every_stub_routes_to_a_guide_that_exists() {
        let tools = crate::mcp::session_tool_definitions(None);
        for skill in &SKILLS {
            assert!(guide(skill.topic, &tools).is_ok(), "{}", skill.name);
            let text = stub(skill);
            assert_eq!(installed_version(&text), Some(STUB_VERSION));
            // The router names every specialist it routes to.
            assert!(SKILLS[0].guide.contains(&format!("`{}` skill", skill.name)) || skill.topic.is_none());
        }
        assert!(guide(Some("nope"), &tools).is_err());
    }

    #[test]
    fn topic_guides_list_their_tools_from_the_definitions() {
        let tools = crate::mcp::session_tool_definitions(None);
        let devices = guide(Some("devices"), &tools).unwrap();
        assert!(devices.contains("device_set_route"));
        assert!(!devices.contains("computer_click"));
        let router = guide(None, &tools).unwrap();
        assert!(!router.contains("## Tools"));
    }

    #[test]
    fn parse_reads_dirs_and_json() {
        let args = |values: &[&str]| values.iter().map(|value| value.to_string()).collect::<Vec<_>>();
        let base = Path::new("/b");
        assert_eq!(parse(&args(&["guide"]), base), Ok(SkillCommand::Guide(None)));
        assert_eq!(
            parse(&args(&["install", "--dir", "s", "--dir", "/abs"]), base),
            Ok(SkillCommand::Install(vec![PathBuf::from("/b/s"), PathBuf::from("/abs")]))
        );
        assert_eq!(
            parse(&args(&["status", "--json"]), base),
            Ok(SkillCommand::Status { dirs: vec![], json: true })
        );
        for bad in [&["install", "--json"][..], &["status", "--json", "--json"], &["guide", "a", "b"], &["install", "--dir"]] {
            assert_eq!(parse(&args(bad), base), Err(USAGE.into()), "{bad:?}");
        }
    }
}
