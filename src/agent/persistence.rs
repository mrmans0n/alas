use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use super::AgentThreadState;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentThreadRecord {
    pub thread_id: String,
    pub state: AgentThreadState,
}

impl AgentThreadRecord {
    pub fn from_state(thread_id: String, state: &AgentThreadState) -> Self {
        let mut state = state.clone();
        state.thread_id = thread_id.clone();
        Self { thread_id, state }
    }
}

pub fn merge_agent_thread_records(
    cached_records: impl IntoIterator<Item = AgentThreadRecord>,
    workspace_records: impl IntoIterator<Item = AgentThreadRecord>,
    excluded_thread_ids: impl IntoIterator<Item = String>,
) -> Vec<AgentThreadRecord> {
    let excluded_thread_ids = excluded_thread_ids.into_iter().collect::<BTreeSet<_>>();
    let mut records = cached_records
        .into_iter()
        .filter(|record| !excluded_thread_ids.contains(&record.thread_id))
        .map(|record| (record.thread_id.clone(), record))
        .collect::<BTreeMap<_, _>>();

    for record in workspace_records {
        if !excluded_thread_ids.contains(&record.thread_id) {
            records.insert(record.thread_id.clone(), record);
        }
    }

    records.into_values().collect()
}

pub fn filter_agent_thread_records(
    records: impl IntoIterator<Item = AgentThreadRecord>,
    excluded_thread_ids: impl IntoIterator<Item = String>,
    removed_worktree_paths: impl IntoIterator<Item = PathBuf>,
    removed_repo_paths: impl IntoIterator<Item = PathBuf>,
) -> Vec<AgentThreadRecord> {
    let excluded_thread_ids = excluded_thread_ids.into_iter().collect::<BTreeSet<_>>();
    let removed_worktree_paths = removed_worktree_paths.into_iter().collect::<BTreeSet<_>>();
    let removed_repo_paths = removed_repo_paths.into_iter().collect::<Vec<_>>();

    records
        .into_iter()
        .filter(|record| {
            !excluded_thread_ids.contains(&record.thread_id)
                && !removed_worktree_paths.contains(&record.state.worktree_path)
                && !removed_repo_paths
                    .iter()
                    .any(|repo_path| record.state.worktree_path.starts_with(repo_path))
        })
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentThreadStore {
    path: PathBuf,
}

impl AgentThreadStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load_records(&self) -> Result<Vec<AgentThreadRecord>> {
        if !self.path.exists() {
            return Ok(Vec::new());
        }

        let contents = std::fs::read_to_string(&self.path).with_context(|| {
            format!("failed to read agent thread store {}", self.path.display())
        })?;
        serde_json::from_str(&contents)
            .with_context(|| format!("failed to parse agent thread store {}", self.path.display()))
    }

    pub fn save_records(&self, records: &[AgentThreadRecord]) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create agent thread store directory {}",
                    parent.display()
                )
            })?;
        }

        let contents = serde_json::to_string_pretty(records).with_context(|| {
            format!(
                "failed to serialize agent thread store {}",
                self.path.display()
            )
        })?;
        std::fs::write(&self.path, contents)
            .with_context(|| format!("failed to write agent thread store {}", self.path.display()))
    }
}
