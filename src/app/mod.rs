pub mod action_registry;
pub mod actions;
pub mod inspector_state;
pub mod model;
pub mod workspace;

pub use action_registry::{
    ActionAvailability, ActionDefinition, ActionHandlerId, ActionId, ActionRegistry, ActionScope,
};
pub use actions::AppAction;
pub use inspector_state::{InspectorPaneState, InspectorTab};
pub use model::{AlasModel, RepositoryNode, SelectedWorktree, WorktreeNode};
pub use workspace::WorkspaceTabId as TerminalTabId;
pub use workspace::{
    FILE_TAB_MAX_BYTES, FileTabLoadState, FileTabState, TerminalTabKind, TerminalTabState,
    TerminalTabStatus, WorkspaceSession, WorkspaceTab, WorkspaceTabContent, WorkspaceTabId,
    WorkspaceTabKind, WorktreeKey,
};
