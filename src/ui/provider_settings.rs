use std::sync::Arc;

use crate::{
    agent::{
        AgentAuthField, AgentProviderConfig, AgentProviderEnvVar, AgentTrustMode,
        ProviderSettingsState,
    },
    ui::theme::{DANGER, PANEL_BORDER, TEXT, TEXT_MUTED, sidebar_background},
};

use gpui::{
    App, FontWeight, InteractiveElement, IntoElement, ParentElement, SharedString,
    StatefulInteractiveElement, Styled, Window, div, prelude::FluentBuilder, px, rgb,
};

type ClickHandler = Arc<dyn Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static>;
type ProviderClickHandler = Arc<dyn Fn(String, &gpui::ClickEvent, &mut Window, &mut App) + 'static>;
type ProviderFieldHandler =
    Arc<dyn Fn(ProviderSettingsField, &gpui::ClickEvent, &mut Window, &mut App) + 'static>;
type ProviderToggleHandler =
    Arc<dyn Fn(String, &gpui::ClickEvent, &mut Window, &mut App) + 'static>;

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum ProviderSettingsField {
    DisplayName(String),
    Command(String),
    Args(String),
    EnvKey(String),
    EnvValue(String),
    AuthEnvValue {
        provider_id: String,
        env_name: String,
    },
}

pub struct ProviderSettingsHandlers {
    pub on_close: ClickHandler,
    pub on_add_provider: ClickHandler,
    pub on_save: ClickHandler,
    pub on_cancel: ClickHandler,
    pub on_select_field: ProviderFieldHandler,
    pub on_toggle_enabled: ProviderToggleHandler,
    pub on_cycle_trust_mode: ProviderToggleHandler,
    pub on_remove_provider: ProviderClickHandler,
    pub on_authenticate: ProviderClickHandler,
    pub on_run_terminal_auth: ProviderClickHandler,
    pub on_clear_credentials: ProviderClickHandler,
    pub on_view_auth_instructions: ProviderClickHandler,
}

pub fn render_provider_settings(
    state: &ProviderSettingsState,
    active_field: Option<&ProviderSettingsField>,
    handlers: ProviderSettingsHandlers,
) -> impl IntoElement {
    div()
        .id("provider-settings")
        .flex()
        .flex_col()
        .size_full()
        .w(px(360.0))
        .px_4()
        .py_3()
        .gap_3()
        .border_l_1()
        .border_color(PANEL_BORDER)
        .bg(sidebar_background())
        .text_color(TEXT)
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_lg()
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("Provider Settings"),
                )
                .child(
                    div()
                        .id("close-provider-settings")
                        .text_sm()
                        .text_color(TEXT_MUTED)
                        .child("Close")
                        .on_click({
                            let handler = Arc::clone(&handlers.on_close);
                            move |event, window, app| handler(event, window, app)
                        }),
                ),
        )
        .when_some(state.error.as_ref(), |this, error| {
            this.child(
                div()
                    .text_sm()
                    .text_color(DANGER)
                    .child(SharedString::from(error.clone())),
            )
        })
        .child(render_provider_rows(state, active_field, &handlers))
        .when(!state.discovery_suggestions.is_empty(), |this| {
            this.child(render_discovery_suggestions(state))
        })
        .child(
            div()
                .flex()
                .gap_2()
                .child(button(
                    "add-provider",
                    "Add Provider",
                    handlers.on_add_provider,
                ))
                .child(primary_button(
                    "save-provider-settings",
                    "Save",
                    handlers.on_save,
                ))
                .child(button(
                    "cancel-provider-settings",
                    "Cancel",
                    handlers.on_cancel,
                )),
        )
}

fn render_provider_rows(
    state: &ProviderSettingsState,
    active_field: Option<&ProviderSettingsField>,
    handlers: &ProviderSettingsHandlers,
) -> impl IntoElement {
    if state.providers.is_empty() {
        return div()
            .text_sm()
            .text_color(TEXT_MUTED)
            .child("No providers configured.");
    }

    div().flex().flex_col().gap_3().children(
        state
            .providers
            .iter()
            .map(|provider| render_provider_card(state, provider, active_field, handlers))
            .collect::<Vec<_>>(),
    )
}

fn render_discovery_suggestions(state: &ProviderSettingsState) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .text_sm()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(TEXT)
                .child("Discovered tools"),
        )
        .children(state.discovery_suggestions.iter().map(|suggestion| {
            div()
                .id(SharedString::from(format!(
                    "provider-discovery-suggestion-{}",
                    suggestion.id
                )))
                .flex()
                .flex_col()
                .gap_1()
                .p_3()
                .rounded_md()
                .border_1()
                .border_color(PANEL_BORDER)
                .child(
                    div()
                        .text_sm()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(TEXT)
                        .child(SharedString::from(format!(
                            "{} found",
                            suggestion.display_name
                        ))),
                )
                .child(
                    div()
                        .text_sm()
                        .text_color(TEXT_MUTED)
                        .child(SharedString::from(suggestion.message.clone())),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(TEXT_MUTED)
                        .child(SharedString::from(format!(
                            "Command: {}",
                            suggestion.command
                        ))),
                )
        }))
}

fn render_provider_card(
    state: &ProviderSettingsState,
    provider: &AgentProviderConfig,
    active_field: Option<&ProviderSettingsField>,
    handlers: &ProviderSettingsHandlers,
) -> impl IntoElement {
    let provider_id = provider.id.clone();
    let (plain_env_key, plain_env_value) = first_plain_env(provider);
    div()
        .id(SharedString::from(format!("provider-row-{}", provider.id)))
        .flex()
        .flex_col()
        .gap_2()
        .p_3()
        .rounded_md()
        .border_1()
        .border_color(PANEL_BORDER)
        .child(editable_field(
            format!("provider-display-name-{}", provider.id),
            "Display name",
            &provider.display_name,
            ProviderSettingsField::DisplayName(provider.id.clone()),
            active_field,
            &handlers.on_select_field,
        ))
        .child(editable_field(
            format!("provider-command-{}", provider.id),
            "Command",
            &provider.command,
            ProviderSettingsField::Command(provider.id.clone()),
            active_field,
            &handlers.on_select_field,
        ))
        .child(editable_field(
            format!("provider-args-{}", provider.id),
            "Args (JSON array)",
            &serde_json::to_string(&provider.args).unwrap_or_else(|_| "[]".to_string()),
            ProviderSettingsField::Args(provider.id.clone()),
            active_field,
            &handlers.on_select_field,
        ))
        .child(
            div()
                .flex()
                .gap_2()
                .child(editable_field(
                    format!("provider-env-key-{}", provider.id),
                    "Plain env key",
                    &plain_env_key,
                    ProviderSettingsField::EnvKey(provider.id.clone()),
                    active_field,
                    &handlers.on_select_field,
                ))
                .child(editable_field(
                    format!("provider-env-value-{}", provider.id),
                    "Plain env value",
                    &plain_env_value,
                    ProviderSettingsField::EnvValue(provider.id.clone()),
                    active_field,
                    &handlers.on_select_field,
                )),
        )
        .child(field("Secure env refs", &secure_env_summary(&provider.env)))
        .child(render_auth_env_fields(
            state,
            provider,
            active_field,
            handlers,
        ))
        .child(toggle_row(
            format!("provider-enabled-{}", provider.id),
            "Enabled",
            if provider.enabled { "Yes" } else { "No" },
            provider_id.clone(),
            &handlers.on_toggle_enabled,
        ))
        .child(toggle_row(
            format!("provider-trust-mode-{}", provider.id),
            "Trust mode",
            trust_mode_label(&provider.trust_mode),
            provider_id.clone(),
            &handlers.on_cycle_trust_mode,
        ))
        .child(field("Auth status", &state.auth_status_label(&provider.id)))
        .child(
            div()
                .flex()
                .flex_wrap()
                .gap_2()
                .child(provider_button(
                    format!("remove-provider-{}", provider.id),
                    "Remove",
                    provider_id.clone(),
                    &handlers.on_remove_provider,
                ))
                .child(provider_button(
                    format!("authenticate-provider-{}", provider.id),
                    "Authenticate",
                    provider_id.clone(),
                    &handlers.on_authenticate,
                ))
                .child(provider_button(
                    format!("terminal-auth-provider-{}", provider.id),
                    "Terminal Auth",
                    provider_id.clone(),
                    &handlers.on_run_terminal_auth,
                ))
                .child(provider_button(
                    format!("clear-credentials-provider-{}", provider.id),
                    "Clear Credentials",
                    provider_id.clone(),
                    &handlers.on_clear_credentials,
                ))
                .child(provider_button(
                    format!("auth-instructions-provider-{}", provider.id),
                    "Auth Instructions",
                    provider_id,
                    &handlers.on_view_auth_instructions,
                )),
        )
}

pub fn auth_env_field_render_value(
    state: &ProviderSettingsState,
    provider_id: &str,
    field: &AgentAuthField,
    _active: bool,
) -> String {
    state.auth_env_display_value(provider_id, field)
}

fn render_auth_env_fields(
    state: &ProviderSettingsState,
    provider: &AgentProviderConfig,
    active_field: Option<&ProviderSettingsField>,
    handlers: &ProviderSettingsHandlers,
) -> impl IntoElement {
    let fields = state.env_auth_fields(&provider.id);
    if fields.is_empty() {
        return div().flex().flex_col().gap_1();
    }
    div()
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .text_xs()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(TEXT_MUTED)
                .child("Authentication env fields"),
        )
        .children(fields.into_iter().map(|field| {
            let label = format!(
                "{} ({}){}{}",
                field.label,
                field.env_name,
                if field.optional { " optional" } else { "" },
                if field.secret { " secret" } else { "" }
            );
            let field_id = ProviderSettingsField::AuthEnvValue {
                provider_id: provider.id.clone(),
                env_name: field.env_name.clone(),
            };
            let value = auth_env_field_render_value(
                state,
                &provider.id,
                &field,
                active_field == Some(&field_id),
            );
            editable_field(
                format!("provider-auth-env-{}-{}", provider.id, field.env_name),
                SharedString::from(label),
                value,
                field_id,
                active_field,
                &handlers.on_select_field,
            )
        }))
}

fn editable_field(
    id: String,
    label: impl Into<SharedString>,
    value: impl Into<SharedString>,
    field: ProviderSettingsField,
    active_field: Option<&ProviderSettingsField>,
    on_select_field: &ProviderFieldHandler,
) -> impl IntoElement {
    let is_active = active_field == Some(&field);
    let label = label.into();
    let value = value.into();
    let handler = Arc::clone(on_select_field);
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .text_xs()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(TEXT_MUTED)
                .child(label),
        )
        .child(
            div()
                .id(SharedString::from(id))
                .px_2()
                .py_1()
                .min_h(px(28.0))
                .rounded_md()
                .border_1()
                .border_color(if is_active {
                    rgb(0x2563eb)
                } else {
                    PANEL_BORDER
                })
                .bg(rgb(0xffffff))
                .text_sm()
                .child(if value.is_empty() {
                    SharedString::from(" ")
                } else {
                    value.clone()
                })
                .on_click(move |event, window, app| {
                    handler(field.clone(), event, window, app);
                }),
        )
}

fn toggle_row(
    id: String,
    label: &'static str,
    value: &'static str,
    provider_id: String,
    on_click: &ProviderToggleHandler,
) -> impl IntoElement {
    let handler = Arc::clone(on_click);
    div()
        .flex()
        .items_center()
        .justify_between()
        .child(
            div()
                .text_xs()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(TEXT_MUTED)
                .child(label),
        )
        .child(
            div()
                .id(SharedString::from(id))
                .px_2()
                .py_1()
                .rounded_md()
                .border_1()
                .border_color(PANEL_BORDER)
                .text_sm()
                .child(value)
                .on_click(move |event, window, app| {
                    handler(provider_id.clone(), event, window, app);
                }),
        )
}

fn field(label: &'static str, value: &str) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .text_xs()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(TEXT_MUTED)
                .child(label),
        )
        .child(div().text_sm().child(SharedString::from(value.to_string())))
}

fn first_plain_env(provider: &AgentProviderConfig) -> (String, String) {
    provider
        .env
        .iter()
        .find(|entry| entry.secure_ref.is_none())
        .map(|entry| {
            (
                entry.name.clone(),
                entry.value.clone().unwrap_or_else(String::new),
            )
        })
        .unwrap_or_else(|| (String::new(), String::new()))
}

fn secure_env_summary(env: &[AgentProviderEnvVar]) -> String {
    let refs = env
        .iter()
        .filter_map(|entry| {
            entry
                .secure_ref
                .as_ref()
                .map(|secure_ref| format!("{}=<secure:{}>", entry.name, secure_ref))
        })
        .collect::<Vec<_>>();
    if refs.is_empty() {
        "None".to_string()
    } else {
        refs.join(", ")
    }
}

fn trust_mode_label(trust_mode: &AgentTrustMode) -> &'static str {
    match trust_mode {
        AgentTrustMode::AllowEverything => "Allow everything",
        AgentTrustMode::Ask => "Ask",
        AgentTrustMode::WorktreeOnly => "Worktree only",
        AgentTrustMode::Deny => "Deny",
    }
}

fn button(id: &'static str, label: &'static str, on_click: ClickHandler) -> impl IntoElement {
    div()
        .id(id)
        .px_3()
        .py_2()
        .rounded_md()
        .text_sm()
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(rgb(0x374151))
        .bg(rgb(0xe5e7eb))
        .child(label)
        .on_click({
            let handler = Arc::clone(&on_click);
            move |event, window, app| handler(event, window, app)
        })
}

fn primary_button(
    id: &'static str,
    label: &'static str,
    on_click: ClickHandler,
) -> impl IntoElement {
    div()
        .id(id)
        .px_3()
        .py_2()
        .rounded_md()
        .text_sm()
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(rgb(0xffffff))
        .bg(rgb(0x2563eb))
        .child(label)
        .on_click({
            let handler = Arc::clone(&on_click);
            move |event, window, app| handler(event, window, app)
        })
}

fn provider_button(
    id: String,
    label: &'static str,
    provider_id: String,
    on_click: &ProviderClickHandler,
) -> impl IntoElement {
    let on_click = {
        let provider_id = provider_id.clone();
        let handler = Arc::clone(on_click);
        move |event: &gpui::ClickEvent, window: &mut Window, app: &mut App| {
            handler(provider_id.clone(), event, window, app);
        }
    };
    div()
        .id(SharedString::from(id))
        .px_2()
        .py_1()
        .rounded_md()
        .text_xs()
        .text_color(TEXT_MUTED)
        .bg(rgb(0xf3f4f6))
        .child(label)
        .on_click(on_click)
}
