use serde_json::Value;

use crate::app::{TerminalTabId, TerminalTabStatus, WorkspaceSession};
use crate::notifications::{
    AppFocusState, HarnessCompletionContext, HarnessCompletionOutcome, HarnessCompletionSource,
    HookProvider, NotificationController, NotificationSink, parse_hook_signal,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HarnessCompletionIngestionResult {
    IgnoredUnsupportedPayload,
    NotifiedWithoutTab,
    IgnoredDuplicateWithoutTab,
    CompletedTab { tab_id: TerminalTabId },
    FailedTab { tab_id: TerminalTabId },
    NotifiedWithoutTerminalTransition { tab_id: TerminalTabId },
    IgnoredUnknownTab { tab_id: TerminalTabId },
    IgnoredNonRunningTab { tab_id: TerminalTabId },
    IgnoredDuplicate { tab_id: TerminalTabId },
}

impl HarnessCompletionIngestionResult {
    pub fn should_notify_shell(self) -> bool {
        matches!(
            self,
            Self::NotifiedWithoutTab
                | Self::CompletedTab { .. }
                | Self::FailedTab { .. }
                | Self::NotifiedWithoutTerminalTransition { .. }
                | Self::IgnoredUnknownTab { .. }
        )
    }
}

pub fn ingest_harness_completion_hook<N: NotificationSink, F: AppFocusState>(
    provider: HookProvider,
    payload: &Value,
    workspace_session: &mut WorkspaceSession,
    notification_controller: &mut NotificationController<N, F>,
) -> anyhow::Result<HarnessCompletionIngestionResult> {
    let Some(signal) = parse_hook_signal(provider, payload) else {
        return Ok(HarnessCompletionIngestionResult::IgnoredUnsupportedPayload);
    };

    let Some(tab_id) = signal.terminal_tab_id else {
        return if notification_controller.handle_hook_signal(signal)? {
            Ok(HarnessCompletionIngestionResult::NotifiedWithoutTab)
        } else {
            Ok(HarnessCompletionIngestionResult::IgnoredDuplicateWithoutTab)
        };
    };

    let Some(status) = workspace_session.terminal_tab_status_by_id(tab_id) else {
        return if notification_controller.handle_hook_signal(signal)? {
            Ok(HarnessCompletionIngestionResult::IgnoredUnknownTab { tab_id })
        } else {
            Ok(HarnessCompletionIngestionResult::IgnoredDuplicate { tab_id })
        };
    };
    let context = workspace_session
        .terminal_tab_context(tab_id)
        .map(HarnessCompletionContext::from)
        .unwrap_or_else(|| HarnessCompletionContext::unresolved(Some(tab_id)));

    if !is_terminal_completion_source(signal.source) {
        return if notification_controller.handle_hook_signal_with_context(signal, context)? {
            Ok(HarnessCompletionIngestionResult::NotifiedWithoutTerminalTransition { tab_id })
        } else {
            Ok(HarnessCompletionIngestionResult::IgnoredDuplicate { tab_id })
        };
    }

    match status {
        TerminalTabStatus::Exited(_) | TerminalTabStatus::Failed => {
            if notification_controller.handle_hook_signal_with_context(signal, context)? {
                Ok(HarnessCompletionIngestionResult::NotifiedWithoutTerminalTransition { tab_id })
            } else {
                Ok(HarnessCompletionIngestionResult::IgnoredDuplicate { tab_id })
            }
        }
        TerminalTabStatus::NotStarted => {
            Ok(HarnessCompletionIngestionResult::IgnoredNonRunningTab { tab_id })
        }
        TerminalTabStatus::Running => {
            let (status, result) = match signal.outcome {
                HarnessCompletionOutcome::Success => (
                    TerminalTabStatus::Exited(Some(0)),
                    HarnessCompletionIngestionResult::CompletedTab { tab_id },
                ),
                HarnessCompletionOutcome::Failure => (
                    TerminalTabStatus::Failed,
                    HarnessCompletionIngestionResult::FailedTab { tab_id },
                ),
            };

            match status {
                TerminalTabStatus::Failed => workspace_session
                    .set_terminal_tab_failure_by_id(tab_id, "Harness completed with failure")?,
                _ => workspace_session.set_terminal_tab_status_by_id(tab_id, status)?,
            }
            if notification_controller.handle_hook_signal_with_context(signal, context)? {
                Ok(result)
            } else {
                Ok(HarnessCompletionIngestionResult::IgnoredDuplicate { tab_id })
            }
        }
    }
}

fn is_terminal_completion_source(source: HarnessCompletionSource) -> bool {
    matches!(
        source,
        HarnessCompletionSource::ClaudeCodeStop | HarnessCompletionSource::CodexAgentTurnComplete
    )
}
