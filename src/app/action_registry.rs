#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActionId {
    AddRepository,
    RemoveRepository,
    SelectWorktree,
    CreateWorktree,
    RemoveWorktree,
    ArchiveWorktree,
    UnarchiveWorktree,
    PruneWorktrees,
    ToggleArchivedWorktrees,
    CommandSettings,
    NotificationPreferences,
    OpenPath,
    CopyPath,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActionScope {
    Global,
    Repository,
    Worktree,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActionAvailability {
    Always,
    WhenRepositoryAvailable,
    WhenWorktreeAvailable,
    WhenWorktreeIsArchived,
    WhenWorktreeIsNotArchived,
    WhenWorktreeIsLinked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActionHandlerId {
    AddRepository,
    RemoveRepository,
    SelectWorktree,
    CreateWorktree,
    RemoveWorktree,
    ArchiveWorktree,
    UnarchiveWorktree,
    PruneWorktrees,
    ToggleArchivedWorktrees,
    CommandSettings,
    NotificationPreferences,
    OpenPath,
    CopyPath,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActionDefinition {
    pub id: ActionId,
    pub label: &'static str,
    pub scope: ActionScope,
    pub availability: ActionAvailability,
    pub handler: ActionHandlerId,
    pub destructive: bool,
    pub requires_confirmation: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActionRegistry {
    actions: Vec<ActionDefinition>,
}

impl Default for ActionRegistry {
    fn default() -> Self {
        Self {
            actions: vec![
                ActionDefinition {
                    id: ActionId::AddRepository,
                    label: "Add Repository",
                    scope: ActionScope::Global,
                    availability: ActionAvailability::Always,
                    handler: ActionHandlerId::AddRepository,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::RemoveRepository,
                    label: "Remove from Alas",
                    scope: ActionScope::Repository,
                    availability: ActionAvailability::Always,
                    handler: ActionHandlerId::RemoveRepository,
                    destructive: true,
                    requires_confirmation: true,
                },
                ActionDefinition {
                    id: ActionId::SelectWorktree,
                    label: "Open Worktree",
                    scope: ActionScope::Worktree,
                    availability: ActionAvailability::WhenWorktreeAvailable,
                    handler: ActionHandlerId::SelectWorktree,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::CreateWorktree,
                    label: "Create Worktree",
                    scope: ActionScope::Repository,
                    availability: ActionAvailability::WhenRepositoryAvailable,
                    handler: ActionHandlerId::CreateWorktree,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::RemoveWorktree,
                    label: "Remove Worktree",
                    scope: ActionScope::Worktree,
                    availability: ActionAvailability::WhenWorktreeIsLinked,
                    handler: ActionHandlerId::RemoveWorktree,
                    destructive: true,
                    requires_confirmation: true,
                },
                ActionDefinition {
                    id: ActionId::ArchiveWorktree,
                    label: "Archive Worktree",
                    scope: ActionScope::Worktree,
                    availability: ActionAvailability::WhenWorktreeIsNotArchived,
                    handler: ActionHandlerId::ArchiveWorktree,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::UnarchiveWorktree,
                    label: "Unarchive Worktree",
                    scope: ActionScope::Worktree,
                    availability: ActionAvailability::WhenWorktreeIsArchived,
                    handler: ActionHandlerId::UnarchiveWorktree,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::PruneWorktrees,
                    label: "Prune Worktrees",
                    scope: ActionScope::Repository,
                    availability: ActionAvailability::WhenRepositoryAvailable,
                    handler: ActionHandlerId::PruneWorktrees,
                    destructive: true,
                    requires_confirmation: true,
                },
                ActionDefinition {
                    id: ActionId::ToggleArchivedWorktrees,
                    label: "Show/Hide Archived",
                    scope: ActionScope::Repository,
                    availability: ActionAvailability::Always,
                    handler: ActionHandlerId::ToggleArchivedWorktrees,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::CommandSettings,
                    label: "Command Settings",
                    scope: ActionScope::Repository,
                    availability: ActionAvailability::WhenRepositoryAvailable,
                    handler: ActionHandlerId::CommandSettings,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::NotificationPreferences,
                    label: "Notification Preferences",
                    scope: ActionScope::Global,
                    availability: ActionAvailability::Always,
                    handler: ActionHandlerId::NotificationPreferences,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::OpenPath,
                    label: "Open Path",
                    scope: ActionScope::Worktree,
                    availability: ActionAvailability::WhenWorktreeAvailable,
                    handler: ActionHandlerId::OpenPath,
                    destructive: false,
                    requires_confirmation: false,
                },
                ActionDefinition {
                    id: ActionId::CopyPath,
                    label: "Copy Path",
                    scope: ActionScope::Worktree,
                    availability: ActionAvailability::WhenWorktreeAvailable,
                    handler: ActionHandlerId::CopyPath,
                    destructive: false,
                    requires_confirmation: false,
                },
            ],
        }
    }
}

impl ActionRegistry {
    pub fn actions(&self) -> &[ActionDefinition] {
        &self.actions
    }

    pub fn get(&self, id: ActionId) -> Option<&ActionDefinition> {
        self.actions.iter().find(|action| action.id == id)
    }

    pub fn for_scope(&self, scope: ActionScope) -> Vec<&ActionDefinition> {
        self.actions
            .iter()
            .filter(|action| action.scope == scope)
            .collect()
    }
}
