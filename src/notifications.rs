use serde_json::Value;

use crate::app::TerminalTabId;
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
    pub title: String,
    pub body: String,
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
}

#[derive(Clone, Debug, Default)]
pub struct NotificationService;

impl NotificationService {
    pub fn harness_completion_decision(
        &self,
        prefs: &NotificationPrefs,
        event: &HarnessCompletionNotificationEvent,
    ) -> NotificationDecision {
        let completion_prefs = &prefs.harness_completion;
        if !completion_prefs.enabled {
            return NotificationDecision::Disabled;
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
}

pub trait NotificationSink {
    fn notify_harness_completed(&mut self, event: HarnessCompletionEvent) -> anyhow::Result<()>;
}

impl NotificationSink for NotificationService {
    fn notify_harness_completed(&mut self, _event: HarnessCompletionEvent) -> anyhow::Result<()> {
        Ok(())
    }
}

#[derive(Debug)]
pub struct NotificationController<N> {
    notifier: N,
    preferences: NotificationPrefs,
    notification_service: NotificationService,
}

impl<N> NotificationController<N> {
    pub fn new(notifier: N) -> Self {
        Self::new_with_preferences(notifier, NotificationPrefs::default())
    }

    pub fn new_with_preferences(notifier: N, preferences: NotificationPrefs) -> Self {
        Self {
            notifier,
            preferences,
            notification_service: NotificationService,
        }
    }

    pub fn notifier(&self) -> &N {
        &self.notifier
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

impl<N: NotificationSink> NotificationController<N> {
    pub fn handle_hook_signal(&mut self, signal: HookSignal) -> anyhow::Result<()> {
        let notification_event = notification_event(&signal);
        if self
            .notification_service
            .harness_completion_decision(&self.preferences, &notification_event)
            != NotificationDecision::Allowed
        {
            return Ok(());
        }

        self.notifier
            .notify_harness_completed(completion_event(signal))
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

fn completion_event(signal: HookSignal) -> HarnessCompletionEvent {
    HarnessCompletionEvent {
        harness: signal.harness,
        source: signal.source,
        outcome: signal.outcome,
        terminal_tab_id: signal.terminal_tab_id,
        title: format!("{} completed", signal.harness.display_name()),
        body: completion_body(signal.source),
    }
}

fn notification_event(signal: &HookSignal) -> HarnessCompletionNotificationEvent {
    HarnessCompletionNotificationEvent {
        source: HarnessNotificationSource::HookBacked(match signal.harness {
            HarnessKind::ClaudeCode => HookBackedHarness::ClaudeCode,
            HarnessKind::Codex => HookBackedHarness::Codex,
        }),
        outcome: signal.outcome,
        title: format!("{} completed", signal.harness.display_name()),
        body: completion_body(signal.source),
        repo_id: None,
        worktree_path: None,
    }
}

fn completion_body(source: HarnessCompletionSource) -> String {
    match source {
        HarnessCompletionSource::ClaudeCodeStop => "Claude Code stopped.".to_string(),
        HarnessCompletionSource::ClaudeCodeSubagentStop => {
            "Claude Code subagent stopped.".to_string()
        }
        HarnessCompletionSource::CodexAgentTurnComplete => {
            "Codex agent turn completed.".to_string()
        }
    }
}
