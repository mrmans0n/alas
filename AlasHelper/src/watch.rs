use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::Sender;

use crate::ServerMessage;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum WatchKind {
    Files,
    Git,
}

impl WatchKind {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "files" => Some(Self::Files),
            "git" => Some(Self::Git),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Files => "files",
            Self::Git => "git",
        }
    }
}

#[derive(Debug)]
pub struct WatchNotification {
    pub subscription_id: String,
    pub kind: WatchKind,
    pub paths: Vec<String>,
}

pub struct SubscriptionWatcher {
    _watcher: RecommendedWatcher,
}

impl SubscriptionWatcher {
    pub fn new(
        subscription_id: String,
        root: PathBuf,
        kinds: HashSet<WatchKind>,
        sender: Sender<ServerMessage>,
    ) -> Result<Self, String> {
        let git_info = resolve_git_info(&root);
        let callback_root = root.clone();
        let callback_git_info = git_info.clone();
        let mut watcher = notify::recommended_watcher(move |result: notify::Result<Event>| {
            let Ok(event) = result else { return };
            if matches!(event.kind, EventKind::Access(_)) {
                return;
            }
            let (file_paths, git_paths) = classify_paths(
                event.paths,
                &callback_root,
                callback_git_info.as_ref(),
                &kinds,
            );
            for (kind, paths) in [(WatchKind::Files, file_paths), (WatchKind::Git, git_paths)] {
                if paths.is_empty() {
                    continue;
                }
                let _ = sender.send(ServerMessage::Watch(WatchNotification {
                    subscription_id: subscription_id.clone(),
                    kind,
                    paths: paths.into_iter().collect(),
                }));
            }
        })
        .map_err(|error| format!("watcher creation failed: {error}"))?;

        watcher
            .watch(&root, RecursiveMode::Recursive)
            .map_err(|error| format!("watch root failed: {error}"))?;
        if let Some(info) = git_info {
            if !info.common_dir.starts_with(&root) {
                watcher
                    .watch(&info.common_dir, RecursiveMode::Recursive)
                    .map_err(|error| format!("watch git dir failed: {error}"))?;
            }
        }
        Ok(Self { _watcher: watcher })
    }
}

#[derive(Clone, Debug)]
struct GitInfo {
    common_dir: PathBuf,
}

fn resolve_git_info(root: &Path) -> Option<GitInfo> {
    let output = Command::new("git")
        .args(["rev-parse", "--git-common-dir"])
        .current_dir(root)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8(output.stdout).ok()?;
    let mut lines = stdout.lines();
    let common = lines.next()?.trim();
    if common.is_empty() {
        return None;
    }
    let common_dir = if Path::new(common).is_absolute() {
        PathBuf::from(common)
    } else {
        root.join(common)
    };
    Some(GitInfo {
        common_dir: canonical_or_normalized(&common_dir),
    })
}

fn canonical_or_normalized(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| normalize_event_path(path))
}

fn normalize_event_path(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    }
}

fn classify_paths(
    paths: Vec<PathBuf>,
    root: &Path,
    git_info: Option<&GitInfo>,
    kinds: &HashSet<WatchKind>,
) -> (HashSet<String>, HashSet<String>) {
    let mut file_paths = HashSet::new();
    let mut git_paths = HashSet::new();
    for path in paths {
        let path = normalize_event_path(&path);
        if kinds.contains(&WatchKind::Git)
            && git_info.is_some_and(|info| is_relevant_git_path(&path, info))
        {
            git_paths.insert(path.display().to_string());
            continue;
        }
        if kinds.contains(&WatchKind::Files)
            && path.starts_with(root)
            && !git_info.is_some_and(|info| path.starts_with(&info.common_dir))
        {
            file_paths.insert(path.display().to_string());
        }
    }
    (file_paths, git_paths)
}

fn is_relevant_git_path(path: &Path, info: &GitInfo) -> bool {
    let Ok(relative) = path.strip_prefix(&info.common_dir) else {
        return false;
    };
    let relative = relative.to_string_lossy();
    let relative = relative.trim_matches('/');
    if relative.ends_with(".lock") {
        return false;
    }
    if relative == "HEAD" {
        return true;
    }
    if relative == "packed-refs" || relative.starts_with("refs/heads/") {
        return true;
    }
    if relative == "worktrees" {
        return true;
    }
    if let Some(rest) = relative.strip_prefix("worktrees/") {
        let parts: Vec<_> = rest.split('/').filter(|part| !part.is_empty()).collect();
        return parts.len() == 1 || (parts.len() == 2 && parts[1] == "HEAD");
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git_info(root: &Path) -> GitInfo {
        GitInfo {
            common_dir: root.join(".git"),
        }
    }

    #[test]
    fn git_filter_matches_local_head_and_topology_rules() {
        let root = Path::new("/repo");
        let info = git_info(root);
        assert!(is_relevant_git_path(&root.join(".git/HEAD"), &info));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/HEAD"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/refs/heads/main"),
            &info
        ));
        assert!(is_relevant_git_path(&root.join(".git/packed-refs"), &info));
        assert!(!is_relevant_git_path(&root.join(".git/index"), &info));
        assert!(!is_relevant_git_path(&root.join(".git/index.lock"), &info));
        assert!(!is_relevant_git_path(&root.join("src/main.rs"), &info));
    }

    #[test]
    fn paths_are_partitioned_into_file_and_filtered_git_events() {
        let root = Path::new("/repo");
        let info = git_info(root);
        let (files, git) = classify_paths(
            vec![
                root.join("README.md"),
                root.join(".git/HEAD"),
                root.join(".git/index"),
                root.join(".git/index.lock"),
            ],
            root,
            Some(&info),
            &HashSet::from([WatchKind::Files, WatchKind::Git]),
        );

        assert_eq!(files, HashSet::from(["/repo/README.md".to_string()]));
        assert_eq!(git, HashSet::from(["/repo/.git/HEAD".to_string()]));
    }
}
