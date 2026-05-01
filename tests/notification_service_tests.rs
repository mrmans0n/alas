use alas::{
    config::NotificationPrefs,
    notifications::{
        HarnessCompletionNotificationEvent, HarnessCompletionOutcome, HarnessNotificationSource,
        HookBackedHarness, NotificationDecision, NotificationService,
    },
};

#[test]
fn supported_success_completion_is_allowed_by_default() {
    assert_eq!(
        decision(
            NotificationPrefs::default(),
            HarnessCompletionOutcome::Success
        ),
        NotificationDecision::Allowed
    );
}

#[test]
fn supported_failure_completion_is_allowed_by_default() {
    assert_eq!(
        decision(
            NotificationPrefs::default(),
            HarnessCompletionOutcome::Failure
        ),
        NotificationDecision::Allowed
    );
}

#[test]
fn global_disabled_suppresses_supported_completions() {
    let mut prefs = NotificationPrefs::default();
    prefs.harness_completion.enabled = false;

    assert_eq!(
        decision(prefs.clone(), HarnessCompletionOutcome::Success),
        NotificationDecision::Disabled
    );
    assert_eq!(
        decision(prefs, HarnessCompletionOutcome::Failure),
        NotificationDecision::Disabled
    );
}

#[test]
fn success_disabled_suppresses_success_only() {
    let mut prefs = NotificationPrefs::default();
    prefs.harness_completion.success = false;

    assert_eq!(
        decision(prefs.clone(), HarnessCompletionOutcome::Success),
        NotificationDecision::SuccessDisabled
    );
    assert_eq!(
        decision(prefs, HarnessCompletionOutcome::Failure),
        NotificationDecision::Allowed
    );
}

#[test]
fn failure_disabled_suppresses_failure_only() {
    let mut prefs = NotificationPrefs::default();
    prefs.harness_completion.failure = false;

    assert_eq!(
        decision(prefs.clone(), HarnessCompletionOutcome::Failure),
        NotificationDecision::FailureDisabled
    );
    assert_eq!(
        decision(prefs, HarnessCompletionOutcome::Success),
        NotificationDecision::Allowed
    );
}

#[test]
fn unsupported_harness_is_suppressed_when_notifications_are_enabled() {
    let service = NotificationService;
    let event = HarnessCompletionNotificationEvent {
        source: HarnessNotificationSource::Unsupported("plain shell".to_string()),
        outcome: HarnessCompletionOutcome::Success,
        title: "Done".to_string(),
        body: String::new(),
        repo_id: None,
        worktree_path: None,
    };

    assert_eq!(
        service.harness_completion_decision(&NotificationPrefs::default(), &event),
        NotificationDecision::UnsupportedHarness
    );
}

fn decision(prefs: NotificationPrefs, outcome: HarnessCompletionOutcome) -> NotificationDecision {
    let service = NotificationService;
    service.harness_completion_decision(
        &prefs,
        &HarnessCompletionNotificationEvent {
            source: HarnessNotificationSource::HookBacked(HookBackedHarness::ClaudeCode),
            outcome,
            title: "Done".to_string(),
            body: String::new(),
            repo_id: None,
            worktree_path: None,
        },
    )
}
