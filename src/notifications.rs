use std::path::PathBuf;

use serde_json::Value;

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "macos")]
pub use macos::{MacOsAppFocusState, MacOsNotificationSink};

#[cfg(target_os = "macos")]
pub type DefaultAppFocusState = MacOsAppFocusState;
#[cfg(target_os = "macos")]
pub type DefaultNotificationSink = MacOsNotificationSink;

#[cfg(not(target_os = "macos"))]
pub type DefaultAppFocusState = NeverFocusedAppFocusState;
#[cfg(not(target_os = "macos"))]
pub type DefaultNotificationSink = NotificationService;

use crate::app::{TerminalTabId, WorkspaceTabContext};
use crate::config::NotificationPrefs;
use crate::terminal::HarnessKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HookProvider {
    ClaudeCode,
    Codex,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HarnessCompletionSource {
    ClaudeCodeStop,
    ClaudeCodeSubagentStop,
    CodexAgentTurnComplete,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookSignal {
    pub harness: HarnessKind,
    pub source: HarnessCompletionSource,
    pub outcome: HarnessCompletionOutcome,
    pub terminal_tab_id: Option<TerminalTabId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HarnessCompletionEvent {
    pub harness: HarnessKind,
    pub source: HarnessCompletionSource,
    pub outcome: HarnessCompletionOutcome,
    pub terminal_tab_id: Option<TerminalTabId>,
    pub context: HarnessCompletionContext,
    pub title: String,
    pub body: String,
    pub sound: NotificationSound,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HarnessCompletionContext {
    pub terminal_tab_id: Option<TerminalTabId>,
    pub tab_name: Option<String>,
    pub repo_id: Option<String>,
    pub worktree_path: Option<PathBuf>,
}

impl HarnessCompletionContext {
    pub fn unresolved(terminal_tab_id: Option<TerminalTabId>) -> Self {
        Self {
            terminal_tab_id,
            ..Self::default()
        }
    }
}

impl From<WorkspaceTabContext> for HarnessCompletionContext {
    fn from(context: WorkspaceTabContext) -> Self {
        Self {
            terminal_tab_id: Some(context.tab_id),
            tab_name: Some(context.tab_name),
            repo_id: Some(context.repo_id),
            worktree_path: Some(context.worktree_path),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationSound {
    Success,
    Failure,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HookBackedHarness {
    ClaudeCode,
    Codex,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HarnessCompletionOutcome {
    Success,
    Failure,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HarnessNotificationSource {
    HookBacked(HookBackedHarness),
    Unsupported(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HarnessCompletionNotificationEvent {
    pub source: HarnessNotificationSource,
    pub outcome: HarnessCompletionOutcome,
    pub title: String,
    pub body: String,
    pub repo_id: Option<String>,
    pub worktree_path: Option<std::path::PathBuf>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationDecision {
    Allowed,
    Disabled,
    SuccessDisabled,
    FailureDisabled,
    UnsupportedHarness,
    Focused,
}

#[derive(Clone, Debug, Default)]
pub struct NotificationService;

impl NotificationService {
    pub fn harness_completion_decision(
        &self,
        prefs: &NotificationPrefs,
        event: &HarnessCompletionNotificationEvent,
        app_is_active: bool,
    ) -> NotificationDecision {
        let completion_prefs = &prefs.harness_completion;
        if !completion_prefs.enabled {
            return NotificationDecision::Disabled;
        }
        if app_is_active {
            return NotificationDecision::Focused;
        }
        if matches!(event.source, HarnessNotificationSource::Unsupported(_)) {
            return NotificationDecision::UnsupportedHarness;
        }

        match event.outcome {
            HarnessCompletionOutcome::Success if !completion_prefs.success => {
                NotificationDecision::SuccessDisabled
            }
            HarnessCompletionOutcome::Failure if !completion_prefs.failure => {
                NotificationDecision::FailureDisabled
            }
            HarnessCompletionOutcome::Success | HarnessCompletionOutcome::Failure => {
                NotificationDecision::Allowed
            }
        }
    }

    pub fn build_harness_completion_event(
        &self,
        signal: HookSignal,
        context: HarnessCompletionContext,
    ) -> HarnessCompletionEvent {
        let title = completion_title(signal.harness, signal.outcome);
        let body = completion_body(signal.source, signal.outcome, &context);
        let sound = match signal.outcome {
            HarnessCompletionOutcome::Success => NotificationSound::Success,
            HarnessCompletionOutcome::Failure => NotificationSound::Failure,
        };

        HarnessCompletionEvent {
            harness: signal.harness,
            source: signal.source,
            outcome: signal.outcome,
            terminal_tab_id: signal.terminal_tab_id,
            context,
            title,
            body,
            sound,
        }
    }
}

pub trait NotificationSink {
    fn notify_harness_completed(&mut self, event: HarnessCompletionEvent) -> anyhow::Result<()>;
}

pub trait AppFocusState {
    fn is_app_active(&self) -> bool;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct NeverFocusedAppFocusState;

impl AppFocusState for NeverFocusedAppFocusState {
    fn is_app_active(&self) -> bool {
        false
    }
}

impl NotificationSink for NotificationService {
    fn notify_harness_completed(&mut self, _event: HarnessCompletionEvent) -> anyhow::Result<()> {
        Ok(())
    }
}

#[derive(Debug)]
pub struct NotificationController<N, F = NeverFocusedAppFocusState> {
    notifier: N,
    focus_state: F,
    preferences: NotificationPrefs,
    notification_service: NotificationService,
}

impl<N> NotificationController<N> {
    pub fn new(notifier: N) -> Self {
        Self::new_with_preferences(notifier, NotificationPrefs::default())
    }

    pub fn new_with_preferences(notifier: N, preferences: NotificationPrefs) -> Self {
        Self::new_with_preferences_and_focus(notifier, preferences, NeverFocusedAppFocusState)
    }
}

impl<N, F> NotificationController<N, F> {
    pub fn new_with_preferences_and_focus(
        notifier: N,
        preferences: NotificationPrefs,
        focus_state: F,
    ) -> Self {
        Self {
            notifier,
            focus_state,
            preferences,
            notification_service: NotificationService,
        }
    }

    pub fn notifier(&self) -> &N {
        &self.notifier
    }

    pub fn focus_state(&self) -> &F {
        &self.focus_state
    }

    pub fn preferences(&self) -> &NotificationPrefs {
        &self.preferences
    }

    pub fn update_preferences(&mut self, preferences: NotificationPrefs) {
        self.preferences = preferences;
    }

    pub fn into_notifier(self) -> N {
        self.notifier
    }
}

impl<N: NotificationSink, F: AppFocusState> NotificationController<N, F> {
    pub fn handle_hook_signal(&mut self, signal: HookSignal) -> anyhow::Result<()> {
        let context = HarnessCompletionContext::unresolved(signal.terminal_tab_id);
        self.handle_hook_signal_with_context(signal, context)
    }

    pub fn handle_hook_signal_with_context(
        &mut self,
        signal: HookSignal,
        context: HarnessCompletionContext,
    ) -> anyhow::Result<()> {
        let notification_event = notification_event(&signal);
        if self.notification_service.harness_completion_decision(
            &self.preferences,
            &notification_event,
            self.focus_state.is_app_active(),
        ) != NotificationDecision::Allowed
        {
            return Ok(());
        }

        self.notifier.notify_harness_completed(
            self.notification_service
                .build_harness_completion_event(signal, context),
        )
    }

    pub fn handle_raw_hook_payload(
        &mut self,
        provider: HookProvider,
        payload: &Value,
    ) -> anyhow::Result<()> {
        if let Some(signal) = parse_hook_signal(provider, payload) {
            self.handle_hook_signal(signal)?;
        }

        Ok(())
    }

    pub fn handle_raw_hook_payload_with_context(
        &mut self,
        provider: HookProvider,
        payload: &Value,
        context: HarnessCompletionContext,
    ) -> anyhow::Result<()> {
        if let Some(signal) = parse_hook_signal(provider, payload) {
            self.handle_hook_signal_with_context(signal, context)?;
        }

        Ok(())
    }
}

pub fn parse_hook_signal(provider: HookProvider, payload: &Value) -> Option<HookSignal> {
    match provider {
        HookProvider::ClaudeCode => parse_claude_code_hook(payload),
        HookProvider::Codex => parse_codex_notify(payload),
    }
}

fn parse_claude_code_hook(payload: &Value) -> Option<HookSignal> {
    let source = match payload.get("hook_event_name")?.as_str()? {
        "Stop" => HarnessCompletionSource::ClaudeCodeStop,
        "SubagentStop" => HarnessCompletionSource::ClaudeCodeSubagentStop,
        _ => return None,
    };

    Some(HookSignal {
        harness: HarnessKind::ClaudeCode,
        source,
        outcome: hook_outcome(payload)?,
        terminal_tab_id: terminal_tab_id(payload),
    })
}

fn parse_codex_notify(payload: &Value) -> Option<HookSignal> {
    let source = match payload.get("type")?.as_str()? {
        "agent-turn-complete" => HarnessCompletionSource::CodexAgentTurnComplete,
        _ => return None,
    };

    Some(HookSignal {
        harness: HarnessKind::Codex,
        source,
        outcome: hook_outcome(payload)?,
        terminal_tab_id: terminal_tab_id(payload),
    })
}

fn hook_outcome(payload: &Value) -> Option<HarnessCompletionOutcome> {
    payload
        .get("success")
        .and_then(Value::as_bool)
        .map(|success| {
            if success {
                HarnessCompletionOutcome::Success
            } else {
                HarnessCompletionOutcome::Failure
            }
        })
        .or_else(|| string_outcome(payload.get("outcome").and_then(Value::as_str)))
        .or_else(|| string_outcome(payload.get("status").and_then(Value::as_str)))
        .or_else(|| exit_code_outcome(payload.get("exit_code").and_then(Value::as_i64)))
        .or_else(|| exit_code_outcome(payload.get("code").and_then(Value::as_i64)))
}

fn string_outcome(value: Option<&str>) -> Option<HarnessCompletionOutcome> {
    match value?.to_ascii_lowercase().as_str() {
        "success" | "succeeded" | "ok" | "complete" | "completed" | "passed" => {
            Some(HarnessCompletionOutcome::Success)
        }
        "failure" | "failed" | "error" | "errored" | "cancelled" | "canceled" => {
            Some(HarnessCompletionOutcome::Failure)
        }
        _ => None,
    }
}

fn exit_code_outcome(value: Option<i64>) -> Option<HarnessCompletionOutcome> {
    value.map(|code| {
        if code == 0 {
            HarnessCompletionOutcome::Success
        } else {
            HarnessCompletionOutcome::Failure
        }
    })
}

fn terminal_tab_id(payload: &Value) -> Option<TerminalTabId> {
    payload
        .get("terminal_tab_id")
        .and_then(Value::as_u64)
        .or_else(|| payload.get("alas_terminal_tab_id").and_then(Value::as_u64))
        .map(TerminalTabId)
}

fn notification_event(signal: &HookSignal) -> HarnessCompletionNotificationEvent {
    HarnessCompletionNotificationEvent {
        source: HarnessNotificationSource::HookBacked(match signal.harness {
            HarnessKind::ClaudeCode => HookBackedHarness::ClaudeCode,
            HarnessKind::Codex => HookBackedHarness::Codex,
        }),
        outcome: signal.outcome,
        title: completion_title(signal.harness, signal.outcome),
        body: String::new(),
        repo_id: None,
        worktree_path: None,
    }
}

fn completion_title(harness: HarnessKind, outcome: HarnessCompletionOutcome) -> String {
    match outcome {
        HarnessCompletionOutcome::Success => format!("{} completed", harness.display_name()),
        HarnessCompletionOutcome::Failure => format!("{} failed", harness.display_name()),
    }
}

fn completion_body(
    source: HarnessCompletionSource,
    outcome: HarnessCompletionOutcome,
    context: &HarnessCompletionContext,
) -> String {
    let context = context_display(context);
    match source {
        HarnessCompletionSource::ClaudeCodeStop => outcome_body("Claude Code", outcome, context),
        HarnessCompletionSource::ClaudeCodeSubagentStop => {
            outcome_body("Claude Code subagent", outcome, context)
        }
        HarnessCompletionSource::CodexAgentTurnComplete => {
            outcome_body("Codex agent turn", outcome, context)
        }
    }
}

fn outcome_body(
    source_label: &str,
    outcome: HarnessCompletionOutcome,
    context: Option<String>,
) -> String {
    let verb = match outcome {
        HarnessCompletionOutcome::Success => "finished successfully",
        HarnessCompletionOutcome::Failure => "failed",
    };

    match context {
        Some(context) => format!("{source_label} {verb} in {context}."),
        None => format!("{source_label} {verb}."),
    }
}

fn context_display(context: &HarnessCompletionContext) -> Option<String> {
    let tab_name = context.tab_name.as_deref()?.trim();
    if tab_name.is_empty() {
        return None;
    }

    let workspace = context
        .repo_id
        .as_deref()
        .map(str::trim)
        .filter(|repo_id| !repo_id.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            context
                .worktree_path
                .as_ref()
                .and_then(|path| path.file_name())
                .and_then(|name| name.to_str())
                .filter(|name| !name.is_empty())
                .map(ToOwned::to_owned)
        })
        .or_else(|| {
            context
                .worktree_path
                .as_ref()
                .map(|path| path.display().to_string())
                .filter(|path| !path.is_empty())
        });

    match workspace {
        Some(workspace) => Some(format!("{tab_name} - {workspace}")),
        None => Some(tab_name.to_string()),
    }
}
