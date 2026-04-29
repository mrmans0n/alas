use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTreeNode {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    pub children: Vec<FileTreeNode>,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct FileTreeService;

impl FileTreeService {
    pub fn new() -> Self {
        Self
    }

    pub fn load(&self, root: &Path, max_depth: usize) -> Result<FileTreeNode> {
        Self::load_node(root, root, max_depth)
    }

    fn load_node(root: &Path, path: &Path, depth_remaining: usize) -> Result<FileTreeNode> {
        let file_type = std::fs::metadata(path)
            .with_context(|| format!("failed to read metadata for {}", path.display()))?;
        let is_dir = file_type.is_dir();
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| path.display().to_string());
        let mut children = Vec::new();

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
                let child_path = entry.path();
                let child_name = entry.file_name();

                if child_name.to_string_lossy() == ".git" {
                    continue;
                }

                children.push(Self::load_node(root, &child_path, depth_remaining - 1)?);
            }

            children.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| a.name.cmp(&b.name)));
        }

        Ok(FileTreeNode {
            name,
            path: path.to_path_buf(),
            is_dir,
            children,
        })
    }
}
