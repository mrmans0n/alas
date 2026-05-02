use alas::{
    config::NotificationPrefs,
    notifications::{
        HarnessCompletionContext, HarnessCompletionNotificationEvent, HarnessCompletionOutcome,
        HarnessCompletionSource, HarnessNotificationSource, HookBackedHarness, HookSignal,
        NotificationDecision, NotificationService, NotificationSound,
    },
    terminal::HarnessKind,
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
        service.harness_completion_decision(&NotificationPrefs::default(), &event, false),
        NotificationDecision::UnsupportedHarness
    );
}

#[test]
fn focused_app_suppresses_supported_completion() {
    assert_eq!(
        decision_with_focus(
            NotificationPrefs::default(),
            HarnessCompletionOutcome::Success,
            true
        ),
        NotificationDecision::Focused
    );
}

#[test]
fn success_completion_format_uses_success_title_body_and_sound() {
    let service = NotificationService;
    let event = service.build_harness_completion_event(
        HookSignal {
            harness: HarnessKind::ClaudeCode,
            source: HarnessCompletionSource::ClaudeCodeStop,
            outcome: HarnessCompletionOutcome::Success,
            terminal_tab_id: None,
        },
        HarnessCompletionContext::default(),
    );

    assert_eq!(event.title, "Claude Code completed");
    assert_eq!(event.body, "Claude Code finished successfully.");
    assert_eq!(event.sound, NotificationSound::Success);
}

#[test]
fn failure_completion_format_uses_failure_title_body_and_sound() {
    let service = NotificationService;
    let event = service.build_harness_completion_event(
        HookSignal {
            harness: HarnessKind::Codex,
            source: HarnessCompletionSource::CodexAgentTurnComplete,
            outcome: HarnessCompletionOutcome::Failure,
            terminal_tab_id: None,
        },
        HarnessCompletionContext::default(),
    );

    assert_eq!(event.title, "Codex failed");
    assert_eq!(event.body, "Codex agent turn failed.");
    assert_eq!(event.sound, NotificationSound::Failure);
}

#[test]
fn completion_format_includes_tab_and_workspace_context() {
    let service = NotificationService;
    let event = service.build_harness_completion_event(
        HookSignal {
            harness: HarnessKind::ClaudeCode,
            source: HarnessCompletionSource::ClaudeCodeSubagentStop,
            outcome: HarnessCompletionOutcome::Success,
            terminal_tab_id: None,
        },
        HarnessCompletionContext {
            terminal_tab_id: None,
            tab_name: Some("Review".to_string()),
            repo_id: Some("alas".to_string()),
            worktree_path: Some("/repo/alas".into()),
        },
    );

    assert_eq!(
        event.body,
        "Claude Code subagent finished successfully in Review - alas."
    );
}

#[test]
fn unresolved_context_does_not_invent_tab_or_workspace() {
    let service = NotificationService;
    let event = service.build_harness_completion_event(
        HookSignal {
            harness: HarnessKind::ClaudeCode,
            source: HarnessCompletionSource::ClaudeCodeStop,
            outcome: HarnessCompletionOutcome::Failure,
            terminal_tab_id: None,
        },
        HarnessCompletionContext {
            terminal_tab_id: None,
            tab_name: None,
            repo_id: Some("alas".to_string()),
            worktree_path: Some("/repo/alas".into()),
        },
    );

    assert_eq!(event.body, "Claude Code failed.");
}

fn decision(prefs: NotificationPrefs, outcome: HarnessCompletionOutcome) -> NotificationDecision {
    decision_with_focus(prefs, outcome, false)
}

fn decision_with_focus(
    prefs: NotificationPrefs,
    outcome: HarnessCompletionOutcome,
    app_is_active: bool,
) -> NotificationDecision {
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
        app_is_active,
    )
}
