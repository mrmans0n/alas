use std::sync::Arc;

use crate::{
    agent::{AgentThreadState, AgentThreadStatus, AgentTranscriptEntry, AgentTranscriptRole},
    ui::theme::{DANGER, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
};
use gpui::{
    AnyElement, App, InteractiveElement, IntoElement, ParentElement, SharedString,
    StatefulInteractiveElement, Styled, Window, div, prelude::*, rgb,
};

type ClickHandler = Arc<dyn Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static>;
type PermissionClickHandler =
    Arc<dyn Fn(String, &gpui::ClickEvent, &mut Window, &mut App) + 'static>;
type ConfigClickHandler = Arc<dyn Fn(String, &gpui::ClickEvent, &mut Window, &mut App) + 'static>;

pub struct AgentPaneHandlers {
    pub on_send: ClickHandler,
    pub on_cancel: ClickHandler,
    pub on_focus_composer: ClickHandler,
    pub on_allow_permission: PermissionClickHandler,
    pub on_deny_permission: PermissionClickHandler,
    pub on_cycle_mode: ClickHandler,
    pub on_cycle_config: ConfigClickHandler,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentComposerViewModel {
    pub enabled: bool,
    pub action_enabled: bool,
    pub action_label: &'static str,
    pub auth_action: bool,
    pub display_text: String,
    pub showing_placeholder: bool,
    pub slash_commands: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentHeaderViewModel {
    pub status_label: String,
    pub provider_label: String,
    pub mode_label: Option<String>,
    pub mode_interactive: bool,
    pub config_labels: Vec<AgentConfigLabelViewModel>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentConfigLabelViewModel {
    pub id: String,
    pub label: String,
    pub interactive: bool,
}

pub fn agent_status_label(thread: &AgentThreadState) -> String {
    match &thread.status {
        AgentThreadStatus::Disconnected => "Disconnected".to_string(),
        AgentThreadStatus::Starting => "Starting".to_string(),
        AgentThreadStatus::AuthRequired => "Authentication required".to_string(),
        AgentThreadStatus::Ready => "Ready".to_string(),
        AgentThreadStatus::Running => "Running".to_string(),
        AgentThreadStatus::Failed { message } => format!("Failed: {message}"),
        AgentThreadStatus::ReadOnly { reason } => format!("Read-only: {reason}"),
    }
}

pub fn agent_composer_view_model(thread: &AgentThreadState) -> AgentComposerViewModel {
    let is_running = matches!(thread.status, AgentThreadStatus::Running);
    let has_draft = !thread.draft.trim().is_empty();

    AgentComposerViewModel {
        enabled: matches!(thread.status, AgentThreadStatus::Ready),
        action_enabled: is_running
            || (matches!(thread.status, AgentThreadStatus::Ready) && has_draft),
        action_label: match thread.status {
            AgentThreadStatus::Running => "Cancel",
            _ => "Send",
        },
        auth_action: matches!(thread.status, AgentThreadStatus::AuthRequired),
        display_text: if thread.draft.is_empty() {
            "Type a prompt for the agent…".to_string()
        } else {
            thread.draft.clone()
        },
        showing_placeholder: thread.draft.is_empty(),
        slash_commands: thread
            .available_commands
            .iter()
            .map(|command| format!("/{}", command.name))
            .collect(),
    }
}

pub fn agent_header_view_model(thread: &AgentThreadState) -> AgentHeaderViewModel {
    let current_mode_name = thread.current_mode.as_ref().and_then(|current| {
        thread
            .available_modes
            .iter()
            .find(|mode| &mode.id == current)
            .map(|mode| mode.name.clone())
            .or_else(|| Some(current.clone()))
    });

    AgentHeaderViewModel {
        status_label: agent_status_label(thread),
        provider_label: format!("Provider: {}", thread.provider_id),
        mode_label: current_mode_name.map(|mode| {
            if thread.available_modes.len() > 1 {
                format!("Mode: {mode} ▾")
            } else {
                format!("Mode: {mode}")
            }
        }),
        mode_interactive: thread.available_modes.len() > 1,
        config_labels: thread
            .config_options
            .iter()
            .map(|option| {
                let value_label = option.value.as_ref().and_then(|value| {
                    option
                        .options
                        .iter()
                        .find(|candidate| &candidate.id == value)
                        .map(|candidate| candidate.label.clone())
                        .or_else(|| Some(value.clone()))
                });
                let mut label = match value_label {
                    Some(value) if !value.is_empty() => format!("{}: {value}", option.label),
                    _ => option.label.clone(),
                };
                let interactive = option.options.len() > 1;
                if interactive {
                    label.push_str(" ▾");
                }
                AgentConfigLabelViewModel {
                    id: option.id.clone(),
                    label,
                    interactive,
                }
            })
            .collect(),
    }
}

pub fn render_agent_pane(
    thread: &AgentThreadState,
    handlers: AgentPaneHandlers,
) -> impl IntoElement {
    div()
        .id("agent-pane")
        .flex()
        .flex_col()
        .flex_1()
        .size_full()
        .bg(PANEL_BG)
        .text_color(TEXT)
        .child(render_header(
            thread,
            handlers.on_cycle_mode,
            handlers.on_cycle_config,
        ))
        .child(render_permissions(
            thread,
            handlers.on_allow_permission,
            handlers.on_deny_permission,
        ))
        .child(render_transcript(thread))
        .child(render_composer(
            thread,
            handlers.on_send,
            handlers.on_cancel,
            handlers.on_focus_composer,
        ))
}

fn render_header(
    thread: &AgentThreadState,
    on_cycle_mode: ClickHandler,
    on_cycle_config: ConfigClickHandler,
) -> impl IntoElement {
    let vm = agent_header_view_model(thread);
    div()
        .flex()
        .items_center()
        .justify_between()
        .px_3()
        .py_2()
        .border_b_1()
        .border_color(PANEL_BORDER)
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child(SharedString::from(thread.title.clone())),
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .text_xs()
                .text_color(TEXT_MUTED)
                .child(vm.status_label)
                .child(vm.provider_label)
                .children(vm.mode_label.map(|label| {
                    if vm.mode_interactive {
                        div()
                            .id("agent-mode-selector")
                            .cursor_pointer()
                            .on_click(move |event, window, cx| {
                                on_cycle_mode(event, window, cx);
                            })
                            .child(label)
                            .into_any_element()
                    } else {
                        div().child(label).into_any_element()
                    }
                }))
                .children(vm.config_labels.into_iter().map(|config| {
                    if config.interactive {
                        let handler = Arc::clone(&on_cycle_config);
                        let config_id = config.id.clone();
                        div()
                            .id(SharedString::from(format!(
                                "agent-config-selector-{}",
                                config.id
                            )))
                            .cursor_pointer()
                            .on_click(move |event, window, cx| {
                                handler(config_id.clone(), event, window, cx);
                            })
                            .child(config.label)
                            .into_any_element()
                    } else {
                        div().child(config.label).into_any_element()
                    }
                })),
        )
}

fn render_permissions(
    thread: &AgentThreadState,
    on_allow_permission: PermissionClickHandler,
    on_deny_permission: PermissionClickHandler,
) -> impl IntoElement {
    div()
        .id("agent-permissions")
        .flex()
        .flex_col()
        .gap_2()
        .px_3()
        .py_2()
        .children(thread.pending_permissions.iter().map(|request| {
            let allow_id = request.id.clone();
            let deny_id = request.id.clone();
            let on_allow_permission = Arc::clone(&on_allow_permission);
            let on_deny_permission = Arc::clone(&on_deny_permission);
            div()
                .border_1()
                .border_color(PANEL_BORDER)
                .rounded_md()
                .p_2()
                .flex()
                .items_center()
                .justify_between()
                .gap_2()
                .child(
                    div()
                        .text_sm()
                        .child(SharedString::from(request.description.clone())),
                )
                .child(
                    div()
                        .flex()
                        .gap_2()
                        .child(
                            div()
                                .id(SharedString::from(format!("allow-{allow_id}")))
                                .px_2()
                                .py_1()
                                .rounded_md()
                                .text_sm()
                                .bg(rgb(0x2563eb))
                                .text_color(rgb(0xffffff))
                                .child("Allow")
                                .on_click(move |event, window, app| {
                                    on_allow_permission(allow_id.clone(), event, window, app)
                                }),
                        )
                        .child(
                            div()
                                .id(SharedString::from(format!("deny-{deny_id}")))
                                .px_2()
                                .py_1()
                                .rounded_md()
                                .text_sm()
                                .bg(rgb(0xe5e7eb))
                                .text_color(rgb(0x111827))
                                .child("Deny")
                                .on_click(move |event, window, app| {
                                    on_deny_permission(deny_id.clone(), event, window, app)
                                }),
                        ),
                )
        }))
}

fn render_transcript(thread: &AgentThreadState) -> impl IntoElement {
    div()
        .id("agent-transcript")
        .flex()
        .flex_col()
        .flex_1()
        .min_h(gpui::px(0.0))
        .overflow_scroll()
        .p_3()
        .gap_3()
        .children(thread.transcript.iter().map(render_transcript_entry))
}

fn render_transcript_entry(entry: &AgentTranscriptEntry) -> AnyElement {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(TEXT_MUTED)
                .child(role_label(&entry.role)),
        )
        .child(
            div()
                .text_sm()
                .line_height(gpui::px(21.0))
                .child(SharedString::from(entry.text.clone())),
        )
        .into_any_element()
}

fn render_composer(
    thread: &AgentThreadState,
    on_send: ClickHandler,
    on_cancel: ClickHandler,
    on_focus_composer: ClickHandler,
) -> impl IntoElement {
    let vm = agent_composer_view_model(thread);
    let action = if vm.action_label == "Cancel" {
        on_cancel
    } else {
        on_send
    };
    div()
        .id("agent-composer")
        .border_t_1()
        .border_color(PANEL_BORDER)
        .px_3()
        .py_2()
        .flex()
        .flex_col()
        .gap_2()
        .on_click(move |event, window, app| on_focus_composer(event, window, app))
        .child(match &thread.status {
            AgentThreadStatus::ReadOnly { reason } => div()
                .text_sm()
                .text_color(DANGER)
                .child(format!("Read-only: {reason}"))
                .into_any_element(),
            AgentThreadStatus::AuthRequired => div()
                .text_sm()
                .text_color(DANGER)
                .child("Authentication required")
                .into_any_element(),
            _ => div()
                .text_sm()
                .text_color(if vm.showing_placeholder {
                    TEXT_MUTED
                } else {
                    TEXT
                })
                .child(vm.display_text.clone())
                .into_any_element(),
        })
        .when(!vm.slash_commands.is_empty(), |element| {
            element.child(
                div()
                    .id("agent-slash-commands")
                    .flex()
                    .gap_2()
                    .text_xs()
                    .text_color(TEXT_MUTED)
                    .children(vm.slash_commands),
            )
        })
        .child(
            div()
                .id("agent-composer-action")
                .px_3()
                .py_2()
                .rounded_md()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(if vm.action_enabled {
                    rgb(0xffffff)
                } else {
                    TEXT_MUTED
                })
                .bg(if vm.action_enabled {
                    rgb(0x2563eb)
                } else {
                    rgb(0xe5e7eb)
                })
                .child(vm.action_label)
                .when(vm.action_enabled, |element| {
                    element.on_click(move |event, window, app| action(event, window, app))
                }),
        )
}

fn role_label(role: &AgentTranscriptRole) -> &'static str {
    match role {
        AgentTranscriptRole::User => "You",
        AgentTranscriptRole::Agent => "Agent",
        AgentTranscriptRole::Thought => "Thought",
        AgentTranscriptRole::System => "System",
        AgentTranscriptRole::Tool => "Tool",
    }
}
