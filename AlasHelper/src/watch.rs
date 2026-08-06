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
        let paths_to_watch = watch_paths(&root, git_info.as_ref(), &kinds);
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

        for path in paths_to_watch {
            watcher
                .watch(&path, RecursiveMode::Recursive)
                .map_err(|error| format!("watch path {} failed: {error}", path.display()))?;
        }
        Ok(Self { _watcher: watcher })
    }
}

#[derive(Clone, Debug)]
struct GitInfo {
    common_dir: PathBuf,
    worktree_dir: PathBuf,
}

fn resolve_git_info(root: &Path) -> Option<GitInfo> {
    let output = Command::new("git")
        .args(["rev-parse", "--git-common-dir", "--absolute-git-dir"])
        .current_dir(root)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8(output.stdout).ok()?;
    let mut lines = stdout.lines();
    let common = lines.next()?.trim();
    let worktree = lines.next()?.trim();
    if common.is_empty() || worktree.is_empty() {
        return None;
    }
    Some(GitInfo {
        common_dir: resolve_git_path(root, common),
        worktree_dir: resolve_git_path(root, worktree),
    })
}

fn resolve_git_path(root: &Path, path: &str) -> PathBuf {
    let path = Path::new(path);
    let resolved = if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    };
    canonical_or_normalized(&resolved)
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

fn watch_paths(
    root: &Path,
    git_info: Option<&GitInfo>,
    kinds: &HashSet<WatchKind>,
) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if kinds.contains(&WatchKind::Files) {
        push_unique_path(&mut paths, root);
    }
    if kinds.contains(&WatchKind::Git) {
        if let Some(info) = git_info {
            push_unique_path(&mut paths, &info.common_dir);
            push_unique_path(&mut paths, &info.worktree_dir);
        }
    }
    paths
}

fn push_unique_path(paths: &mut Vec<PathBuf>, path: &Path) {
    if !paths.iter().any(|existing| existing == path) {
        paths.push(path.to_path_buf());
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
            && !git_info.is_some_and(|info| path.starts_with(&info.worktree_dir))
        {
            file_paths.insert(path.display().to_string());
        }
    }
    (file_paths, git_paths)
}

fn is_relevant_git_path(path: &Path, info: &GitInfo) -> bool {
    if path
        .extension()
        .is_some_and(|extension| extension == "lock")
    {
        return false;
    }
    if let Ok(relative) = path.strip_prefix(&info.worktree_dir) {
        let relative = relative.to_string_lossy();
        let relative = relative.trim_matches('/');
        if matches!(relative, "HEAD" | "index")
            || is_revision_pseudo_ref(relative)
            || is_top_level_symbolic_revision(path, relative)
            || relative.starts_with("refs/")
            || relative == "rebase-merge"
            || relative.starts_with("rebase-merge/")
            || relative == "rebase-apply"
            || relative.starts_with("rebase-apply/")
        {
            return true;
        }
    }
    let Ok(relative) = path.strip_prefix(&info.common_dir) else {
        return false;
    };
    let relative = relative.to_string_lossy();
    let relative = relative.trim_matches('/');
    if relative == "config"
        || relative == "config.worktree"
        || relative == "packed-refs"
        || relative == "refs/stash"
        || relative == "shallow"
        || relative == "info/grafts"
        || relative == "objects/info/alternates"
        || relative == "logs/HEAD"
        || relative.starts_with("logs/refs/")
        || relative.starts_with("refs/")
        || is_revision_pseudo_ref(relative)
    {
        return true;
    }
    if relative == "worktrees" {
        return true;
    }
    if let Some(rest) = relative.strip_prefix("worktrees/") {
        let parts: Vec<_> = rest.split('/').filter(|part| !part.is_empty()).collect();
        return parts.len() == 1
            || (parts.len() == 2 && parts[1] == "config.worktree")
            || (parts.len() == 2 && (parts[1] == "HEAD" || is_revision_pseudo_ref(parts[1])))
            || (parts.len() >= 3 && parts[1] == "logs")
            || (parts.len() >= 3 && parts[1] == "refs")
            || (parts.len() >= 2 && (parts[1] == "rebase-merge" || parts[1] == "rebase-apply"));
    }
    false
}

fn is_revision_pseudo_ref(relative: &str) -> bool {
    matches!(
        relative,
        "AUTO_MERGE"
            | "CHERRY_PICK_HEAD"
            | "FETCH_HEAD"
            | "MERGE_HEAD"
            | "ORIG_HEAD"
            | "REBASE_HEAD"
            | "REVERT_HEAD"
    )
}

fn is_top_level_symbolic_revision(path: &Path, relative: &str) -> bool {
    if relative.is_empty() || relative.contains('/') {
        return false;
    }
    if is_non_revision_top_level_name(relative) {
        return false;
    }
    std::fs::read_to_string(path)
        .map(|contents| is_top_level_revision_content(&contents))
        .unwrap_or(true)
}

fn is_top_level_revision_content(contents: &str) -> bool {
    let line = contents.lines().next().unwrap_or("").trim();
    line.starts_with("ref: refs/")
        || ((line.len() == 40 || line.len() == 64)
            && line.chars().all(|char| char.is_ascii_hexdigit()))
}

fn is_non_revision_top_level_name(relative: &str) -> bool {
    matches!(
        relative,
        "branches"
            | "COMMIT_EDITMSG"
            | "commondir"
            | "config"
            | "config.worktree"
            | "description"
            | "gc.log"
            | "gitdir"
            | "hooks"
            | "index"
            | "info"
            | "logs"
            | "MERGE_MSG"
            | "modules"
            | "objects"
            | "packed-refs"
            | "refs"
            | "SQUASH_MSG"
            | "TAG_EDITMSG"
            | "worktrees"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git_info(root: &Path) -> GitInfo {
        GitInfo {
            common_dir: root.join(".git"),
            worktree_dir: root.join(".git"),
        }
    }

    #[test]
    fn file_only_watch_registers_root_without_git_dirs() {
        let root = Path::new("/repo");
        let info = git_info(root);

        assert_eq!(
            watch_paths(root, Some(&info), &HashSet::from([WatchKind::Files])),
            vec![root.to_path_buf()]
        );
    }

    #[test]
    fn git_only_watch_registers_git_dirs_without_root() {
        let root = Path::new("/repo");
        let info = GitInfo {
            common_dir: PathBuf::from("/repos/shared/.git"),
            worktree_dir: PathBuf::from("/repos/shared/.git/worktrees/feature"),
        };

        assert_eq!(
            watch_paths(root, Some(&info), &HashSet::from([WatchKind::Git])),
            vec![info.common_dir.clone(), info.worktree_dir.clone()]
        );
    }

    #[test]
    fn file_and_git_watch_registers_root_and_git_dirs_once() {
        let root = Path::new("/repo");
        let info = git_info(root);

        assert_eq!(
            watch_paths(
                root,
                Some(&info),
                &HashSet::from([WatchKind::Files, WatchKind::Git])
            ),
            vec![root.to_path_buf(), root.join(".git")]
        );
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
        assert!(is_relevant_git_path(&root.join(".git/FETCH_HEAD"), &info));
        assert!(is_relevant_git_path(&root.join(".git/ORIG_HEAD"), &info));
        assert!(is_relevant_git_path(&root.join(".git/AUTO_MERGE"), &info));
        assert!(is_relevant_git_path(&root.join(".git/config"), &info));
        assert!(is_relevant_git_path(
            &root.join(".git/config.worktree"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/refs/remotes/origin/main"),
            &info
        ));
        assert!(is_relevant_git_path(&root.join(".git/refs/tags/v1"), &info));
        assert!(is_relevant_git_path(&root.join(".git/refs/stash"), &info));
        assert!(is_relevant_git_path(&root.join(".git/shallow"), &info));
        assert!(is_relevant_git_path(&root.join(".git/info/grafts"), &info));
        assert!(is_relevant_git_path(
            &root.join(".git/objects/info/alternates"),
            &info
        ));
        assert!(is_relevant_git_path(&root.join(".git/logs/HEAD"), &info));
        assert!(is_relevant_git_path(
            &root.join(".git/logs/refs/stash"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/logs/refs/heads/main"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/logs/refs/tags/v1"),
            &info
        ));
        assert!(is_relevant_git_path(&root.join(".git/packed-refs"), &info));
        assert!(is_relevant_git_path(&root.join(".git/index"), &info));
        assert!(is_relevant_git_path(&root.join(".git/MERGE_HEAD"), &info));
        assert!(!is_relevant_git_path(&root.join(".git/index.lock"), &info));
        assert!(!is_relevant_git_path(&root.join("src/main.rs"), &info));
    }

    #[test]
    fn top_level_symbolic_refs_are_git_events() {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("time")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "alas-helper-symbolic-ref-{}-{nonce}",
            std::process::id(),
        ));
        let _ = std::fs::remove_dir_all(&root);
        let git_dir = root.join(".git");
        std::fs::create_dir_all(&git_dir).expect("git dir");
        let symbolic = git_dir.join("FOO");
        std::fs::write(&symbolic, "ref: refs/heads/main\n").expect("symbolic ref");
        let direct = git_dir.join("DIRECT");
        std::fs::write(&direct, "0123456789abcdef0123456789abcdef01234567\n").expect("direct ref");
        let non_ref = git_dir.join("BAR");
        std::fs::write(&non_ref, "not a ref\n").expect("non ref");
        let deleted_symbolic = git_dir.join("DELETED_FOO");
        let info = git_info(&root);

        assert!(is_relevant_git_path(&symbolic, &info));
        assert!(is_relevant_git_path(&direct, &info));
        assert!(!is_relevant_git_path(&non_ref, &info));
        assert!(is_relevant_git_path(&deleted_symbolic, &info));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn linked_worktree_index_and_operation_state_are_git_events() {
        let root = Path::new("/repo");
        let info = GitInfo {
            common_dir: root.join(".git"),
            worktree_dir: root.join(".git/worktrees/feature"),
        };

        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/index"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/CHERRY_PICK_HEAD"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/ORIG_HEAD"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/FETCH_HEAD"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/config.worktree"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/logs/HEAD"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/logs/refs/heads/topic"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/refs/worktree/follow"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/refs/bisect/good-abc"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/refs/rewritten/main"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/rebase-merge/git-rebase-todo"),
            &info
        ));
        assert!(is_relevant_git_path(
            &root.join(".git/worktrees/feature/rebase-apply/rebasing"),
            &info
        ));
        assert!(!is_relevant_git_path(
            &root.join(".git/worktrees/other/index"),
            &info
        ));
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
        assert_eq!(
            git,
            HashSet::from([
                "/repo/.git/HEAD".to_string(),
                "/repo/.git/index".to_string()
            ])
        );
    }
}
