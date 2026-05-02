use serde_json::Value;

use crate::app::{TerminalTabId, TerminalTabStatus, WorkspaceSession};
use crate::notifications::{
    AppFocusState, HarnessCompletionContext, HarnessCompletionOutcome, HookProvider,
    NotificationController, NotificationSink, parse_hook_signal,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HarnessCompletionIngestionResult {
    IgnoredUnsupportedPayload,
    NotifiedWithoutTab,
    CompletedTab { tab_id: TerminalTabId },
    FailedTab { tab_id: TerminalTabId },
    IgnoredUnknownTab { tab_id: TerminalTabId },
    IgnoredNonRunningTab { tab_id: TerminalTabId },
    IgnoredDuplicate { tab_id: TerminalTabId },
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
        notification_controller.handle_hook_signal(signal)?;
        return Ok(HarnessCompletionIngestionResult::NotifiedWithoutTab);
    };

    let Some(status) = workspace_session.terminal_tab_status_by_id(tab_id) else {
        notification_controller.handle_hook_signal(signal)?;
        return Ok(HarnessCompletionIngestionResult::IgnoredUnknownTab { tab_id });
    };
    let context = workspace_session
        .terminal_tab_context(tab_id)
        .map(HarnessCompletionContext::from)
        .unwrap_or_else(|| HarnessCompletionContext::unresolved(Some(tab_id)));

    match status {
        TerminalTabStatus::Exited(_) | TerminalTabStatus::Failed => {
            Ok(HarnessCompletionIngestionResult::IgnoredDuplicate { tab_id })
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

            workspace_session.set_terminal_tab_status_by_id(tab_id, status)?;
            notification_controller.handle_hook_signal_with_context(signal, context)?;
            Ok(result)
        }
    }
}
