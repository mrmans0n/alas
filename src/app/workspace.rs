use std::collections::HashMap;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use crate::app::{DetectedLanguage, HighlightedSource, detect_language};
use crate::terminal::{CommandSpec, TerminalBackendSession};

pub const FILE_TAB_MAX_BYTES: u64 = 2 * 1024 * 1024;
pub const IMAGE_ZOOM_MIN: f32 = 0.10;
pub const IMAGE_ZOOM_MAX: f32 = 10.0;
pub const IMAGE_ZOOM_STEP: f32 = 0.25;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WorkspaceTabId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TerminalTabKind {
    Shell,
    Command,
    Agent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WorkspaceTabKind {
    Terminal(TerminalTabKind),
    File,
    Image,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkdownViewMode {
    Code,
    Preview,
    Split,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalTabStatus {
    NotStarted,
    Running,
    Exited(Option<i32>),
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileTabLoadState {
    Loading,
    Loaded {
        content: String,
        size_bytes: u64,
        line_count: usize,
        highlight: Option<HighlightedSource>,
        highlight_error: Option<String>,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WorktreeKey {
    pub repo_id: String,
    pub path: PathBuf,
}

impl WorktreeKey {
    pub fn new(repo_id: impl Into<String>, path: PathBuf) -> Self {
        Self {
            repo_id: repo_id.into(),
            path,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalTabState {
    pub terminal_kind: TerminalTabKind,
    pub command: CommandSpec,
    pub backend_session: Option<TerminalBackendSession>,
    pub status: TerminalTabStatus,
    pub failure_cause: Option<String>,
    pub scroll_offset_rows: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTabState {
    pub file_path: PathBuf,
    pub language: DetectedLanguage,
    pub load_state: FileTabLoadState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownTabState {
    pub file: FileTabState,
    pub view_mode: MarkdownViewMode,
    pub preview_scroll_offset_rows: usize,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ImageZoom {
    Fit,
    Fixed(f32),
}

impl ImageZoom {
    pub fn zoom_in(self) -> Self {
        Self::Fixed((self.fixed_start() + IMAGE_ZOOM_STEP).clamp(IMAGE_ZOOM_MIN, IMAGE_ZOOM_MAX))
    }

    pub fn zoom_out(self) -> Self {
        Self::Fixed((self.fixed_start() - IMAGE_ZOOM_STEP).clamp(IMAGE_ZOOM_MIN, IMAGE_ZOOM_MAX))
    }

    pub fn is_min(self) -> bool {
        matches!(self, Self::Fixed(value) if value <= IMAGE_ZOOM_MIN)
    }

    pub fn is_max(self) -> bool {
        matches!(self, Self::Fixed(value) if value >= IMAGE_ZOOM_MAX)
    }

    pub fn label(self) -> String {
        match self {
            Self::Fit => "Fit".to_string(),
            Self::Fixed(value) => format!("{:.0}%", value * 100.0),
        }
    }

    fn fixed_start(self) -> f32 {
        match self {
            Self::Fit => 1.0,
            Self::Fixed(value) => value,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImagePreflight {
    Ready,
    UnsupportedExtension(String),
    NotFound,
    PermissionDenied,
    NotAFile,
    IoError(String),
}

impl ImagePreflight {
    pub fn title(&self) -> &'static str {
        match self {
            Self::Ready => "Image ready",
            Self::UnsupportedExtension(_) => "Unsupported image format",
            Self::NotFound => "Image file not found",
            Self::PermissionDenied => "Image file is not readable",
            Self::NotAFile => "Selected path is not a file",
            Self::IoError(_) => "Image file could not be opened",
        }
    }

    pub fn detail(&self) -> String {
        match self {
            Self::Ready => "Ready".to_string(),
            Self::UnsupportedExtension(extension) if extension.is_empty() => {
                "The file has no extension supported by the image viewer.".to_string()
            }
            Self::UnsupportedExtension(extension) => {
                format!("'.{extension}' is not supported by the image viewer.")
            }
            Self::NotFound => "The file no longer exists at this path.".to_string(),
            Self::PermissionDenied => {
                "The app does not have permission to read this file.".to_string()
            }
            Self::NotAFile => {
                "Directories and special files cannot be previewed as images.".to_string()
            }
            Self::IoError(error) => error.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ImageTabState {
    pub path: PathBuf,
    pub display_path: PathBuf,
    pub path_key: PathBuf,
    pub zoom: ImageZoom,
    pub preflight: ImagePreflight,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WorkspaceTabContent {
    Terminal(TerminalTabState),
    File(FileTabState),
    Markdown(MarkdownTabState),
    Image(ImageTabState),
}

#[derive(Debug, Clone, PartialEq)]
pub struct WorkspaceTab {
    pub id: WorkspaceTabId,
    pub name: String,
    pub kind: WorkspaceTabKind,
    pub content: WorkspaceTabContent,
}

impl WorkspaceTab {
    pub fn terminal_tab_state(&self) -> Option<&TerminalTabState> {
        match &self.content {
            WorkspaceTabContent::Terminal(state) => Some(state),
            WorkspaceTabContent::File(_)
            | WorkspaceTabContent::Markdown(_)
            | WorkspaceTabContent::Image(_) => None,
        }
    }

    pub fn terminal_tab_state_mut(&mut self) -> Option<&mut TerminalTabState> {
        match &mut self.content {
            WorkspaceTabContent::Terminal(state) => Some(state),
            WorkspaceTabContent::File(_)
            | WorkspaceTabContent::Markdown(_)
            | WorkspaceTabContent::Image(_) => None,
        }
    }

    pub fn terminal_kind(&self) -> Option<TerminalTabKind> {
        match self.kind {
            WorkspaceTabKind::Terminal(kind) => Some(kind),
            WorkspaceTabKind::File | WorkspaceTabKind::Image => None,
        }
    }

    pub fn is_terminal(&self) -> bool {
        matches!(self.kind, WorkspaceTabKind::Terminal(_))
    }

    pub fn is_file(&self) -> bool {
        matches!(self.kind, WorkspaceTabKind::File)
    }

    pub fn is_image(&self) -> bool {
        matches!(self.kind, WorkspaceTabKind::Image)
    }

    pub fn image_tab_state(&self) -> Option<&ImageTabState> {
        match &self.content {
            WorkspaceTabContent::Image(state) => Some(state),
            WorkspaceTabContent::Terminal(_)
            | WorkspaceTabContent::File(_)
            | WorkspaceTabContent::Markdown(_) => None,
        }
    }

    pub fn image_tab_state_mut(&mut self) -> Option<&mut ImageTabState> {
        match &mut self.content {
            WorkspaceTabContent::Image(state) => Some(state),
            WorkspaceTabContent::Terminal(_)
            | WorkspaceTabContent::File(_)
            | WorkspaceTabContent::Markdown(_) => None,
        }
    }

    pub fn file_tab_path(&self) -> Option<&PathBuf> {
        match &self.content {
            WorkspaceTabContent::File(state) => Some(&state.file_path),
            WorkspaceTabContent::Markdown(state) => Some(&state.file.file_path),
            WorkspaceTabContent::Terminal(_) | WorkspaceTabContent::Image(_) => None,
        }
    }
}

#[derive(Debug, Default)]
pub struct WorkspaceSession {
    next_tab_id: u64,
    tabs: HashMap<WorktreeKey, Vec<WorkspaceTab>>,
    active_tabs: HashMap<WorktreeKey, WorkspaceTabId>,
}

impl WorkspaceSession {
    pub fn ensure_default_terminal_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: PathBuf,
        command: CommandSpec,
    ) -> WorkspaceTabId {
        let key = WorktreeKey::new(repo_id, path);
        if let Some(active) = self.active_tabs.get(&key).copied()
            && self
                .tab(&key.repo_id, &key.path, active)
                .is_some_and(|tab| tab.is_terminal())
        {
            return active;
        }
        if let Some(existing) = self
            .tabs
            .get(&key)
            .and_then(|tabs| tabs.iter().find(|tab| tab.is_terminal()))
        {
            self.active_tabs.insert(key, existing.id);
            return existing.id;
        }

        self.create_terminal_tab_for_key(key, "Shell".to_string(), TerminalTabKind::Shell, command)
    }

    pub fn create_terminal_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: PathBuf,
        name: String,
        kind: TerminalTabKind,
        command: CommandSpec,
    ) -> WorkspaceTabId {
        let key = WorktreeKey::new(repo_id, path);
        self.create_terminal_tab_for_key(key, name, kind, command)
    }

    fn create_terminal_tab_for_key(
        &mut self,
        key: WorktreeKey,
        name: String,
        kind: TerminalTabKind,
        command: CommandSpec,
    ) -> WorkspaceTabId {
        self.next_tab_id += 1;
        let id = WorkspaceTabId(self.next_tab_id);
        let tab = WorkspaceTab {
            id,
            name,
            kind: WorkspaceTabKind::Terminal(kind),
            content: WorkspaceTabContent::Terminal(TerminalTabState {
                terminal_kind: kind,
                command,
                backend_session: None,
                status: TerminalTabStatus::NotStarted,
                failure_cause: None,
                scroll_offset_rows: 0,
            }),
        };

        self.tabs.entry(key.clone()).or_default().push(tab);
        self.active_tabs.insert(key, id);
        id
    }

    pub fn open_file_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: PathBuf,
        file_path: PathBuf,
    ) -> WorkspaceTabId {
        let key = WorktreeKey::new(repo_id, path.clone());
        let normalized = normalize_file_path(&file_path);

        if let Some(existing) = self.tabs.get(&key).and_then(|tabs| {
            tabs.iter().find(|tab| {
                tab.is_file()
                    && tab
                        .file_tab_path()
                        .is_some_and(|path| normalize_file_path(path) == normalized)
            })
        }) {
            self.active_tabs.insert(key, existing.id);
            return existing.id;
        }

        self.next_tab_id += 1;
        let id = WorkspaceTabId(self.next_tab_id);
        let name = file_path
            .file_name()
            .and_then(|n| n.to_str())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| file_path.display().to_string());

        let file = FileTabState {
            language: detect_language(&file_path),
            file_path,
            load_state: FileTabLoadState::Loading,
        };
        let content = if is_markdown_path(&normalized) {
            WorkspaceTabContent::Markdown(MarkdownTabState {
                file,
                view_mode: MarkdownViewMode::Split,
                preview_scroll_offset_rows: 0,
            })
        } else {
            WorkspaceTabContent::File(file)
        };

        let tab = WorkspaceTab {
            id,
            name,
            kind: WorkspaceTabKind::File,
            content,
        };

        self.tabs.entry(key.clone()).or_default().push(tab);
        self.active_tabs.insert(key, id);
        id
    }

    pub fn open_or_focus_image_tab(
        &mut self,
        repo_id: impl Into<String>,
        worktree_path: PathBuf,
        image_path: PathBuf,
    ) -> WorkspaceTabId {
        let key = WorktreeKey::new(repo_id, worktree_path.clone());
        let path_key = image_path_key(&worktree_path, &image_path);
        if let Some(existing_id) = self.tabs.get(&key).and_then(|tabs| {
            tabs.iter().find_map(|tab| match &tab.content {
                WorkspaceTabContent::Image(state) if state.path_key == path_key => Some(tab.id),
                _ => None,
            })
        }) {
            self.active_tabs.insert(key, existing_id);
            return existing_id;
        }

        self.next_tab_id += 1;
        let id = WorkspaceTabId(self.next_tab_id);
        let name = image_path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("Image")
            .to_string();
        let tab = WorkspaceTab {
            id,
            name,
            kind: WorkspaceTabKind::Image,
            content: WorkspaceTabContent::Image(ImageTabState {
                path: image_path.clone(),
                display_path: image_path.clone(),
                path_key,
                zoom: ImageZoom::Fit,
                preflight: preflight_image_path(&image_path),
            }),
        };

        self.tabs.entry(key.clone()).or_default().push(tab);
        self.active_tabs.insert(key, id);
        id
    }

    pub fn tabs_for_worktree(&self, repo_id: impl Into<String>, path: &Path) -> &[WorkspaceTab] {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        self.tabs.get(&key).map_or(&[], Vec::as_slice)
    }

    pub fn active_tab(&self, repo_id: impl Into<String>, path: &Path) -> Option<&WorkspaceTab> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let active_id = self.active_tabs.get(&key)?;
        self.tabs.get(&key)?.iter().find(|tab| tab.id == *active_id)
    }

    pub fn tab(
        &self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
    ) -> Option<&WorkspaceTab> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        self.tabs.get(&key)?.iter().find(|tab| tab.id == tab_id)
    }

    pub fn tab_mut(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
    ) -> Option<&mut WorkspaceTab> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        self.tab_mut_for_key(&key, tab_id)
    }

    pub fn active_terminal_tab(
        &self,
        repo_id: impl Into<String>,
        path: &Path,
    ) -> Option<&WorkspaceTab> {
        self.active_tab(repo_id, path)
            .filter(|tab| tab.is_terminal())
    }

    pub fn terminal_tab(
        &self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
    ) -> Option<&WorkspaceTab> {
        self.tab(repo_id, path, tab_id)
            .filter(|tab| tab.is_terminal())
    }

    pub fn terminal_tab_state(
        &self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
    ) -> Option<&TerminalTabState> {
        self.tab(repo_id, path, tab_id)
            .and_then(|tab| tab.terminal_tab_state())
    }

    pub fn set_active_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        if self.tab_mut_for_key(&key, tab_id).is_none() {
            anyhow::bail!(
                "unknown workspace tab {:?} for repo '{}' worktree {}",
                tab_id,
                key.repo_id,
                key.path.display()
            );
        }

        self.active_tabs.insert(key, tab_id);
        Ok(())
    }

    pub fn set_tab_backend_session(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        backend_session: Option<TerminalBackendSession>,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.known_terminal_tab_mut(&key, tab_id)?;
        tab.backend_session = backend_session;
        Ok(())
    }

    pub fn set_tab_status(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        status: TerminalTabStatus,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.known_terminal_tab_mut(&key, tab_id)?;
        tab.status = status;
        Ok(())
    }

    pub fn set_tab_failure(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        cause: impl Into<String>,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.known_terminal_tab_mut(&key, tab_id)?;
        tab.status = TerminalTabStatus::Failed;
        tab.failure_cause = Some(cause.into());
        Ok(())
    }

    pub fn clear_tab_failure(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.known_terminal_tab_mut(&key, tab_id)?;
        tab.failure_cause = None;
        Ok(())
    }

    pub fn set_tab_scroll_offset(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        scroll_offset_rows: usize,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.known_terminal_tab_mut(&key, tab_id)?;
        tab.scroll_offset_rows = scroll_offset_rows;
        Ok(())
    }

    pub fn set_image_zoom(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        zoom: ImageZoom,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.tab_mut_for_key(&key, tab_id).ok_or_else(|| {
            anyhow::anyhow!(
                "unknown workspace tab {:?} for repo '{}' worktree {}",
                tab_id,
                key.repo_id,
                key.path.display()
            )
        })?;
        let Some(state) = tab.image_tab_state_mut() else {
            anyhow::bail!("workspace tab {:?} is not an image tab", tab_id);
        };
        state.zoom = match zoom {
            ImageZoom::Fit => ImageZoom::Fit,
            ImageZoom::Fixed(value) => {
                ImageZoom::Fixed(value.clamp(IMAGE_ZOOM_MIN, IMAGE_ZOOM_MAX))
            }
        };
        Ok(())
    }

    pub fn set_file_tab_load_state(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        load_state: FileTabLoadState,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.known_file_tab_mut(&key, tab_id)?;
        match tab {
            FileTabHandle::Text(tab) => tab.load_state = load_state,
            FileTabHandle::Markdown(tab) => tab.file.load_state = load_state,
        }
        Ok(())
    }

    pub fn set_markdown_view_mode(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        view_mode: MarkdownViewMode,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.known_markdown_tab_mut(&key, tab_id)?;
        tab.view_mode = view_mode;
        Ok(())
    }

    pub fn set_markdown_preview_scroll_offset(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        scroll_offset_rows: usize,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tab = self.known_markdown_tab_mut(&key, tab_id)?;
        tab.preview_scroll_offset_rows = scroll_offset_rows;
        Ok(())
    }

    pub fn close_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
    ) -> Option<WorkspaceTabId> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tabs = self.tabs.get_mut(&key)?;
        let index = tabs.iter().position(|tab| tab.id == tab_id)?;
        let was_active = self
            .active_tabs
            .get(&key)
            .is_some_and(|active_id| *active_id == tab_id);

        tabs.remove(index);

        if !was_active {
            return self.active_tabs.get(&key).copied();
        }

        let fallback = if index < tabs.len() {
            Some(tabs[index].id)
        } else if index > 0 {
            Some(tabs[index - 1].id)
        } else {
            None
        };

        match fallback {
            Some(id) => {
                self.active_tabs.insert(key, id);
                Some(id)
            }
            None => {
                self.active_tabs.remove(&key);
                None
            }
        }
    }

    pub fn move_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: WorkspaceTabId,
        to_index: usize,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let tabs = self.tabs.get_mut(&key).ok_or_else(|| {
            anyhow::anyhow!(
                "no tabs for repo '{}' worktree {}",
                key.repo_id,
                key.path.display()
            )
        })?;

        let from_index = tabs
            .iter()
            .position(|tab| tab.id == tab_id)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "unknown workspace tab {:?} for repo '{}' worktree {}",
                    tab_id,
                    key.repo_id,
                    key.path.display()
                )
            })?;

        let to_index = to_index.min(tabs.len().saturating_sub(1));
        let tab = tabs.remove(from_index);
        tabs.insert(to_index, tab);
        Ok(())
    }

    pub fn remove_worktree(&mut self, repo_id: &str, path: &Path) {
        let key = WorktreeKey::new(repo_id.to_string(), path.to_path_buf());
        self.tabs.remove(&key);
        self.active_tabs.remove(&key);
    }

    pub fn remove_repository(&mut self, repo_id: &str) {
        self.tabs.retain(|key, _| key.repo_id != repo_id);
        self.active_tabs.retain(|key, _| key.repo_id != repo_id);
    }

    fn known_terminal_tab_mut(
        &mut self,
        key: &WorktreeKey,
        tab_id: WorkspaceTabId,
    ) -> anyhow::Result<&mut TerminalTabState> {
        let tab = self.tab_mut_for_key(key, tab_id).ok_or_else(|| {
            anyhow::anyhow!(
                "unknown workspace tab {:?} for repo '{}' worktree {}",
                tab_id,
                key.repo_id,
                key.path.display()
            )
        })?;

        tab.terminal_tab_state_mut()
            .ok_or_else(|| anyhow::anyhow!("workspace tab {:?} is not a terminal tab", tab_id))
    }

    fn known_file_tab_mut(
        &mut self,
        key: &WorktreeKey,
        tab_id: WorkspaceTabId,
    ) -> anyhow::Result<FileTabHandle<'_>> {
        let tab = self.tab_mut_for_key(key, tab_id).ok_or_else(|| {
            anyhow::anyhow!(
                "unknown workspace tab {:?} for repo '{}' worktree {}",
                tab_id,
                key.repo_id,
                key.path.display()
            )
        })?;

        match &mut tab.content {
            WorkspaceTabContent::File(state) => Ok(FileTabHandle::Text(state)),
            WorkspaceTabContent::Markdown(state) => Ok(FileTabHandle::Markdown(state)),
            WorkspaceTabContent::Terminal(_) | WorkspaceTabContent::Image(_) => {
                anyhow::bail!("workspace tab {:?} is not a file tab", tab_id)
            }
        }
    }

    fn known_markdown_tab_mut(
        &mut self,
        key: &WorktreeKey,
        tab_id: WorkspaceTabId,
    ) -> anyhow::Result<&mut MarkdownTabState> {
        let tab = self.tab_mut_for_key(key, tab_id).ok_or_else(|| {
            anyhow::anyhow!(
                "unknown workspace tab {:?} for repo '{}' worktree {}",
                tab_id,
                key.repo_id,
                key.path.display()
            )
        })?;

        match &mut tab.content {
            WorkspaceTabContent::Markdown(state) => Ok(state),
            WorkspaceTabContent::File(_)
            | WorkspaceTabContent::Terminal(_)
            | WorkspaceTabContent::Image(_) => {
                anyhow::bail!("workspace tab {:?} is not a markdown tab", tab_id)
            }
        }
    }

    fn tab_mut_for_key(
        &mut self,
        key: &WorktreeKey,
        tab_id: WorkspaceTabId,
    ) -> Option<&mut WorkspaceTab> {
        self.tabs
            .get_mut(key)?
            .iter_mut()
            .find(|tab| tab.id == tab_id)
    }
}

enum FileTabHandle<'a> {
    Text(&'a mut FileTabState),
    Markdown(&'a mut MarkdownTabState),
}

pub fn is_markdown_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("md") || extension.eq_ignore_ascii_case("markdown")
        })
}

pub fn is_supported_image_path(path: &Path) -> bool {
    let Some(extension) = normalized_extension(path) else {
        return false;
    };
    gpui::Img::extensions()
        .iter()
        .any(|supported| supported.eq_ignore_ascii_case(&extension))
}

pub fn preflight_image_path(path: &Path) -> ImagePreflight {
    let Some(extension) = normalized_extension(path) else {
        return ImagePreflight::UnsupportedExtension(String::new());
    };
    if !gpui::Img::extensions()
        .iter()
        .any(|supported| supported.eq_ignore_ascii_case(&extension))
    {
        return ImagePreflight::UnsupportedExtension(extension);
    }

    match std::fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => ImagePreflight::Ready,
        Ok(_) => ImagePreflight::NotAFile,
        Err(error) => match error.kind() {
            ErrorKind::NotFound => ImagePreflight::NotFound,
            ErrorKind::PermissionDenied => ImagePreflight::PermissionDenied,
            _ => ImagePreflight::IoError(error.to_string()),
        },
    }
}

fn normalized_extension(path: &Path) -> Option<String> {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
}

fn image_path_key(worktree_path: &Path, image_path: &Path) -> PathBuf {
    if let Ok(path) = std::fs::canonicalize(image_path) {
        return path;
    }

    let absolute = if image_path.is_absolute() {
        image_path.to_path_buf()
    } else {
        worktree_path.join(image_path)
    };
    normalize_file_path(&absolute)
}

fn normalize_file_path(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                result.pop();
            }
            std::path::Component::CurDir => {}
            other => {
                result.push(other);
            }
        }
    }
    result
}
