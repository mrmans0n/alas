use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

const DEFAULT_MAX_NODES: usize = 2_000;
const DEFAULT_MAX_ENTRIES_PER_DIRECTORY: usize = 250;
const IGNORED_NAMES: &[&str] = &[".git", "target", "node_modules", ".DS_Store"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTreeNode {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    pub children: Vec<FileTreeNode>,
    pub truncated: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct FileTreeService {
    max_nodes: usize,
    max_entries_per_directory: usize,
}

impl Default for FileTreeService {
    fn default() -> Self {
        Self::new()
    }
}

impl FileTreeService {
    pub fn new() -> Self {
        Self {
            max_nodes: DEFAULT_MAX_NODES,
            max_entries_per_directory: DEFAULT_MAX_ENTRIES_PER_DIRECTORY,
        }
    }

    pub fn with_limits(max_nodes: usize, max_entries_per_directory: usize) -> Self {
        Self {
            max_nodes: max_nodes.max(1),
            max_entries_per_directory,
        }
    }

    pub fn load(&self, root: &Path, max_depth: usize) -> Result<FileTreeNode> {
        let mut budget = LoadBudget {
            loaded_nodes: 0,
            max_nodes: self.max_nodes,
        };
        self.load_node(root, root, max_depth, &mut budget)
    }

    fn load_node(
        &self,
        root: &Path,
        path: &Path,
        depth_remaining: usize,
        budget: &mut LoadBudget,
    ) -> Result<FileTreeNode> {
        budget.loaded_nodes += 1;

        let file_type = std::fs::metadata(path)
            .with_context(|| format!("failed to read metadata for {}", path.display()))?;
        let is_dir = file_type.is_dir();
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| path.display().to_string());
        let mut children = Vec::new();
        let mut truncated = false;

        if is_dir && depth_remaining > 0 {
            for entry in std::fs::read_dir(path)
                .with_context(|| format!("failed to read directory {}", path.display()))?
            {
                let entry = entry.with_context(|| {
                    format!(
                        "failed to read directory entry in {} while loading {}",
                        path.display(),
                        root.display()
                    )
                })?;
                let child_name = entry.file_name();

                if should_ignore(&child_name.to_string_lossy()) {
                    continue;
                }

                if children.len() >= self.max_entries_per_directory
                    || budget.loaded_nodes >= budget.max_nodes
                {
                    truncated = true;
                    break;
                }

                let child_path = entry.path();
                children.push(self.load_node(root, &child_path, depth_remaining - 1, budget)?);
            }

            children.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.cmp(&b.name)));
        }

        Ok(FileTreeNode {
            name,
            path: path.to_path_buf(),
            is_dir,
            children,
            truncated,
        })
    }
}

#[derive(Debug)]
struct LoadBudget {
    loaded_nodes: usize,
    max_nodes: usize,
}

fn should_ignore(name: &str) -> bool {
    IGNORED_NAMES.contains(&name)
}
