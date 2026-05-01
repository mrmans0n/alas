use alas::app::{ActionAvailability, ActionHandlerId, ActionId, ActionRegistry, ActionScope};

#[test]
fn registry_contains_all_current_repo_and_worktree_actions() {
    let registry = ActionRegistry::default();
    let action_ids: Vec<ActionId> = registry.actions().iter().map(|action| action.id).collect();

    assert_eq!(
        action_ids,
        vec![
            ActionId::AddRepository,
            ActionId::RemoveRepository,
            ActionId::SelectWorktree,
            ActionId::CreateWorktree,
            ActionId::RemoveWorktree,
            ActionId::ArchiveWorktree,
            ActionId::UnarchiveWorktree,
            ActionId::PruneWorktrees,
            ActionId::ToggleArchivedWorktrees,
            ActionId::CommandSettings,
            ActionId::NotificationPreferences,
            ActionId::OpenPath,
            ActionId::CopyPath,
        ]
    );

    for action_id in action_ids {
        assert!(registry.get(action_id).is_some(), "missing {action_id:?}");
    }
}

#[test]
fn destructive_actions_require_confirmation_metadata() {
    let registry = ActionRegistry::default();
    let destructive_actions: Vec<ActionId> = registry
        .actions()
        .iter()
        .filter(|action| action.destructive)
        .map(|action| {
            assert!(
                action.requires_confirmation,
                "destructive action {:?} should require confirmation",
                action.id
            );
            action.id
        })
        .collect();

    assert_eq!(
        destructive_actions,
        vec![
            ActionId::RemoveRepository,
            ActionId::RemoveWorktree,
            ActionId::PruneWorktrees,
        ]
    );
}

#[test]
fn actions_are_scoped_for_context_menus() {
    let registry = ActionRegistry::default();

    assert_eq!(
        ids_for_scope(&registry, ActionScope::Global),
        vec![ActionId::AddRepository, ActionId::NotificationPreferences]
    );
    assert_eq!(
        ids_for_scope(&registry, ActionScope::Repository),
        vec![
            ActionId::RemoveRepository,
            ActionId::CreateWorktree,
            ActionId::PruneWorktrees,
            ActionId::ToggleArchivedWorktrees,
            ActionId::CommandSettings,
        ]
    );
    assert_eq!(
        ids_for_scope(&registry, ActionScope::Worktree),
        vec![
            ActionId::SelectWorktree,
            ActionId::RemoveWorktree,
            ActionId::ArchiveWorktree,
            ActionId::UnarchiveWorktree,
            ActionId::OpenPath,
            ActionId::CopyPath,
        ]
    );
}

#[test]
fn actions_include_availability_and_handler_identity() {
    let registry = ActionRegistry::default();

    assert_action(
        &registry,
        ActionId::AddRepository,
        ActionAvailability::Always,
        ActionHandlerId::AddRepository,
    );
    assert_action(
        &registry,
        ActionId::RemoveRepository,
        ActionAvailability::Always,
        ActionHandlerId::RemoveRepository,
    );
    assert_action(
        &registry,
        ActionId::SelectWorktree,
        ActionAvailability::WhenWorktreeAvailable,
        ActionHandlerId::SelectWorktree,
    );
    assert_action(
        &registry,
        ActionId::CreateWorktree,
        ActionAvailability::WhenRepositoryAvailable,
        ActionHandlerId::CreateWorktree,
    );
    assert_action(
        &registry,
        ActionId::RemoveWorktree,
        ActionAvailability::WhenWorktreeIsLinked,
        ActionHandlerId::RemoveWorktree,
    );
    assert_action(
        &registry,
        ActionId::ArchiveWorktree,
        ActionAvailability::WhenWorktreeIsNotArchived,
        ActionHandlerId::ArchiveWorktree,
    );
    assert_action(
        &registry,
        ActionId::UnarchiveWorktree,
        ActionAvailability::WhenWorktreeIsArchived,
        ActionHandlerId::UnarchiveWorktree,
    );
    assert_action(
        &registry,
        ActionId::PruneWorktrees,
        ActionAvailability::WhenRepositoryAvailable,
        ActionHandlerId::PruneWorktrees,
    );
    assert_action(
        &registry,
        ActionId::ToggleArchivedWorktrees,
        ActionAvailability::Always,
        ActionHandlerId::ToggleArchivedWorktrees,
    );
    assert_action(
        &registry,
        ActionId::CommandSettings,
        ActionAvailability::WhenRepositoryAvailable,
        ActionHandlerId::CommandSettings,
    );
    assert_action(
        &registry,
        ActionId::NotificationPreferences,
        ActionAvailability::Always,
        ActionHandlerId::NotificationPreferences,
    );
    assert_action(
        &registry,
        ActionId::OpenPath,
        ActionAvailability::WhenWorktreeAvailable,
        ActionHandlerId::OpenPath,
    );
    assert_action(
        &registry,
        ActionId::CopyPath,
        ActionAvailability::WhenWorktreeAvailable,
        ActionHandlerId::CopyPath,
    );

    assert!(
        registry
            .actions()
            .iter()
            .all(|action| !action.label.trim().is_empty())
    );
}

fn ids_for_scope(registry: &ActionRegistry, scope: ActionScope) -> Vec<ActionId> {
    registry
        .for_scope(scope)
        .into_iter()
        .map(|action| action.id)
        .collect()
}

fn assert_action(
    registry: &ActionRegistry,
    id: ActionId,
    availability: ActionAvailability,
    handler: ActionHandlerId,
) {
    let action = registry.get(id).expect("registered action");
    assert_eq!(action.availability, availability);
    assert_eq!(action.handler, handler);
}
