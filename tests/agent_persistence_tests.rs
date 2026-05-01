use std::path::PathBuf;

use alas::agent::{
    AgentThreadRecord, AgentThreadState, AgentThreadStore, AgentTranscriptEntry,
    filter_agent_thread_records, merge_agent_thread_records,
};
use tempfile::tempdir;

#[test]
fn thread_store_round_trips_persisted_thread_records() {
    let dir = tempdir().expect("tempdir");
    let store = AgentThreadStore::new(dir.path().join("agent_threads.json"));
    let mut state = AgentThreadState::new("opencode", PathBuf::from("/repo/a"));
    state.acp_session_id = Some("sess-1".to_string());
    state.transcript.push(AgentTranscriptEntry::user("hello"));

    let record = AgentThreadRecord::from_state("thread-1".to_string(), &state);
    assert_eq!(record.state.thread_id, "thread-1");
    store
        .save_records(std::slice::from_ref(&record))
        .expect("save records");

    let loaded = store.load_records().expect("load records");
    assert_eq!(loaded, vec![record]);
}

#[test]
fn thread_store_preserves_state_thread_id_across_save_load() {
    let dir = tempdir().expect("tempdir");
    let store = AgentThreadStore::new(dir.path().join("agent_threads.json"));
    let mut state = AgentThreadState::new("opencode", PathBuf::from("/repo/a"));
    state.thread_id = "stable-thread".to_string();

    store
        .save_records(&[AgentThreadRecord::from_state(
            state.thread_id.clone(),
            &state,
        )])
        .expect("save records");

    let loaded = store.load_records().expect("load records");
    assert_eq!(loaded[0].thread_id, "stable-thread");
    assert_eq!(loaded[0].state.thread_id, "stable-thread");
}

#[test]
fn missing_thread_store_loads_empty_records() {
    let dir = tempdir().expect("tempdir");
    let store = AgentThreadStore::new(dir.path().join("missing.json"));
    assert!(store.load_records().expect("load missing").is_empty());
}

#[test]
fn merge_records_preserves_cached_worktrees_and_overwrites_workspace_threads() {
    let mut cached_current = AgentThreadState::new("opencode", PathBuf::from("/repo/current"));
    cached_current.draft = "old draft".to_string();
    let mut workspace_current = cached_current.clone();
    workspace_current.draft = "new draft".to_string();
    let cached_other = AgentThreadState::new("codex", PathBuf::from("/repo/other"));

    let merged = merge_agent_thread_records(
        vec![
            AgentThreadRecord::from_state("thread-current".to_string(), &cached_current),
            AgentThreadRecord::from_state("thread-other".to_string(), &cached_other),
        ],
        vec![AgentThreadRecord::from_state(
            "thread-current".to_string(),
            &workspace_current,
        )],
        Vec::<String>::new(),
    );

    assert_eq!(merged.len(), 2);
    assert_eq!(
        merged
            .iter()
            .find(|record| record.thread_id == "thread-current")
            .expect("current record")
            .state
            .draft,
        "new draft"
    );
    assert!(
        merged
            .iter()
            .any(|record| record.thread_id == "thread-other")
    );
}

#[test]
fn filter_records_excludes_pending_load_tombstones() {
    let closed = AgentThreadState::new("opencode", PathBuf::from("/repo/current"));
    let removed_worktree = AgentThreadState::new("opencode", PathBuf::from("/repo/removed-wt"));
    let removed_repo = AgentThreadState::new("codex", PathBuf::from("/repo/removed/subtree"));
    let kept = AgentThreadState::new("codex", PathBuf::from("/repo/kept"));

    let filtered = filter_agent_thread_records(
        vec![
            AgentThreadRecord::from_state("thread-closed".to_string(), &closed),
            AgentThreadRecord::from_state("thread-removed-wt".to_string(), &removed_worktree),
            AgentThreadRecord::from_state("thread-removed-repo".to_string(), &removed_repo),
            AgentThreadRecord::from_state("thread-kept".to_string(), &kept),
        ],
        vec!["thread-closed".to_string()],
        vec![PathBuf::from("/repo/removed-wt")],
        vec![PathBuf::from("/repo/removed")],
    );

    let thread_ids = filtered
        .iter()
        .map(|record| record.thread_id.as_str())
        .collect::<Vec<_>>();
    assert_eq!(thread_ids, vec!["thread-kept"]);
}

#[test]
fn merge_records_excludes_closed_thread_from_cached_and_workspace_records() {
    let closed = AgentThreadState::new("opencode", PathBuf::from("/repo/current"));
    let open = AgentThreadState::new("opencode", PathBuf::from("/repo/current"));
    let other = AgentThreadState::new("codex", PathBuf::from("/repo/other"));

    let merged = merge_agent_thread_records(
        vec![
            AgentThreadRecord::from_state("thread-closed".to_string(), &closed),
            AgentThreadRecord::from_state("thread-other".to_string(), &other),
        ],
        vec![
            AgentThreadRecord::from_state("thread-closed".to_string(), &closed),
            AgentThreadRecord::from_state("thread-open".to_string(), &open),
        ],
        vec!["thread-closed".to_string()],
    );

    let thread_ids = merged
        .iter()
        .map(|record| record.thread_id.as_str())
        .collect::<Vec<_>>();
    assert_eq!(thread_ids, vec!["thread-open", "thread-other"]);
}
