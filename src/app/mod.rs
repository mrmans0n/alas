pub mod action_registry;
pub mod actions;
pub mod file_loader;
pub mod inspector_state;
pub mod language;
pub mod model;
pub mod syntax;
pub mod workspace;

pub use action_registry::{
    ActionAvailability, ActionDefinition, ActionHandlerId, ActionId, ActionRegistry, ActionScope,
};
pub use actions::AppAction;
pub use file_loader::{FileLoadError, FileLoader, LoadedSourceFile};
pub use inspector_state::{InspectorPaneState, InspectorTab};
pub use language::{DetectedLanguage, detect_language};
pub use model::{AlasModel, RepositoryNode, SelectedWorktree, WorktreeNode};
pub use syntax::{
    HighlightError, HighlightedLine, HighlightedSource, HighlightedSpan, SourceTokenStyle,
    highlight_source,
};
pub use workspace::WorkspaceTabId as TerminalTabId;
pub use workspace::{
    FILE_TAB_MAX_BYTES, FileTabLoadState, FileTabState, ImagePreflight, ImageTabState, ImageZoom,
    MarkdownTabState, MarkdownViewMode, TerminalTabKind, TerminalTabState, TerminalTabStatus,
    WorkspaceSession, WorkspaceTab, WorkspaceTabContent, WorkspaceTabId, WorkspaceTabKind,
    WorktreeKey, is_supported_image_path, preflight_image_path,
};
