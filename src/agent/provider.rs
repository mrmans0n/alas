use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::agent::{AgentProviderSuggestion, AgentTrustMode, CredentialStore, CredentialStoreKey};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentAuthStatus {
    #[default]
    Unknown,
    Authenticated,
    Required {
        instructions: String,
    },
    Failed {
        message: String,
        instructions: String,
    },
}

impl AgentAuthStatus {
    pub fn instructions(&self) -> Option<&str> {
        match self {
            Self::Required { instructions } | Self::Failed { instructions, .. } => {
                Some(instructions.as_str())
            }
            Self::Unknown | Self::Authenticated => None,
        }
    }

    pub fn label(&self) -> &str {
        match self {
            Self::Unknown => "Authentication unknown",
            Self::Authenticated => "Authenticated",
            Self::Required { .. } => "Authentication required",
            Self::Failed { .. } => "Authentication failed",
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ProviderSettingsState {
    pub providers: Vec<AgentProviderConfig>,
    pub selected_provider_id: Option<String>,
    pub error: Option<String>,
    pub discovery_suggestions: Vec<AgentProviderSuggestion>,
    pub auth_statuses: HashMap<String, AgentAuthStatus>,
    pub auth_env_values: HashMap<(String, String), String>,
}

impl ProviderSettingsState {
    pub fn add_provider(&mut self, provider: AgentProviderConfig) {
        let provider_id = provider.id.clone();
        if let Some(existing) = self
            .providers
            .iter_mut()
            .find(|existing| existing.id == provider_id)
        {
            *existing = provider;
        } else {
            self.providers.push(provider);
        }
        self.selected_provider_id = Some(provider_id);
        self.error = None;
    }

    pub fn remove_provider(&mut self, provider_id: &str) {
        let Some(provider_index) = self
            .providers
            .iter()
            .position(|provider| provider.id == provider_id)
        else {
            return;
        };

        let was_selected = self.selected_provider_id.as_deref() == Some(provider_id);
        self.providers.remove(provider_index);
        self.auth_statuses.remove(provider_id);
        if was_selected {
            self.selected_provider_id = self.providers.first().map(|provider| provider.id.clone());
        }
        self.error = None;
    }

    pub fn update_display_name(&mut self, provider_id: &str, display_name: impl Into<String>) {
        if let Some(provider) = self.provider_mut(provider_id) {
            provider.display_name = display_name.into();
            self.error = None;
        }
    }

    pub fn update_command(&mut self, provider_id: &str, command: impl Into<String>) {
        if let Some(provider) = self.provider_mut(provider_id) {
            provider.command = command.into();
            self.error = None;
        }
    }

    pub fn update_args(&mut self, provider_id: &str, args: Vec<String>) {
        if let Some(provider) = self.provider_mut(provider_id) {
            provider.args = args;
            self.error = None;
        }
    }

    pub fn edit_args_json(
        &mut self,
        provider_id: &str,
        edit: impl FnOnce(&mut String),
    ) -> Result<(), serde_json::Error> {
        let Some(provider) = self
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
        else {
            return Ok(());
        };

        let mut value = serde_json::to_string(&provider.args).unwrap_or_else(|_| "[]".to_string());
        edit(&mut value);
        match serde_json::from_str::<Vec<String>>(&value) {
            Ok(args) => {
                self.update_args(provider_id, args);
                Ok(())
            }
            Err(error) => {
                self.error = Some(format!("Args must be a JSON array of strings: {error}"));
                Err(error)
            }
        }
    }

    pub fn args_json(&self, provider_id: &str) -> Option<String> {
        self.providers
            .iter()
            .find(|provider| provider.id == provider_id)
            .map(|provider| {
                serde_json::to_string(&provider.args).unwrap_or_else(|_| "[]".to_string())
            })
    }

    pub fn update_plain_env(&mut self, provider_id: &str, env: Vec<(String, String)>) {
        if let Some(provider) = self.provider_mut(provider_id) {
            let mut updated_env = env
                .into_iter()
                .filter(|(name, _)| !name.trim().is_empty())
                .map(|(name, value)| AgentProviderEnvVar {
                    name,
                    value: Some(value),
                    secure_ref: None,
                })
                .collect::<Vec<_>>();
            updated_env.extend(
                provider
                    .env
                    .iter()
                    .filter(|entry| entry.secure_ref.is_some())
                    .cloned(),
            );
            provider.env = updated_env;
            self.error = None;
        }
    }

    pub fn update_enabled(&mut self, provider_id: &str, enabled: bool) {
        if let Some(provider) = self.provider_mut(provider_id) {
            provider.enabled = enabled;
            self.error = None;
        }
    }

    pub fn update_trust_mode(&mut self, provider_id: &str, trust_mode: AgentTrustMode) {
        if let Some(provider) = self.provider_mut(provider_id) {
            provider.trust_mode = trust_mode;
            self.error = None;
        }
    }

    pub fn update_auth_status(&mut self, provider_id: &str, status: AgentAuthStatus) {
        self.auth_statuses.insert(provider_id.to_string(), status);
        self.error = None;
    }

    pub fn update_auth_env_value(
        &mut self,
        provider_id: &str,
        env_name: &str,
        value: impl Into<String>,
    ) {
        self.auth_env_values.insert(
            (provider_id.to_string(), env_name.to_string()),
            value.into(),
        );
        self.error = None;
    }

    pub fn auth_env_value(&self, provider_id: &str, env_name: &str) -> String {
        self.auth_env_values
            .get(&(provider_id.to_string(), env_name.to_string()))
            .cloned()
            .unwrap_or_default()
    }

    pub fn auth_env_display_value(&self, provider_id: &str, field: &AgentAuthField) -> String {
        let value = self.auth_env_value(provider_id, &field.env_name);
        if field.secret && !value.is_empty() {
            "••••••••".to_string()
        } else {
            value
        }
    }

    pub fn save_pending_env_auth_values(
        &mut self,
        provider_id: &str,
        store: &dyn CredentialStore,
    ) -> anyhow::Result<()> {
        let values = self
            .auth_env_values
            .iter()
            .filter(|((saved_provider_id, _), _)| saved_provider_id == provider_id)
            .map(|((_, field), value)| (field.clone(), value.clone()))
            .collect::<Vec<_>>();
        self.save_env_auth_values(provider_id, &values, store)
    }

    pub fn save_env_auth_values(
        &mut self,
        provider_id: &str,
        values: &[(String, String)],
        store: &dyn CredentialStore,
    ) -> anyhow::Result<()> {
        let fields = self.env_auth_fields(provider_id);
        for field in fields.iter().filter(|field| !field.optional) {
            let value = values
                .iter()
                .find(|(name, _)| name == &field.env_name)
                .map(|(_, value)| value.as_str())
                .unwrap_or_default();
            if value.is_empty() {
                let message = format!("Missing required auth env value for {}", field.env_name);
                self.update_auth_status(
                    provider_id,
                    AgentAuthStatus::Failed {
                        message: message.clone(),
                        instructions: field.label.clone(),
                    },
                );
                anyhow::bail!(message);
            }
        }

        for (field, value) in values {
            let key = CredentialStoreKey::new(provider_id, field);
            if value.is_empty() {
                store.delete_secret(&key)?;
            } else {
                store.write_secret(&key, value)?;
            }
        }
        if let Some(provider) = self.provider_mut(provider_id) {
            let value_names = values
                .iter()
                .filter(|(_, value)| !value.is_empty())
                .map(|(name, _)| name.as_str())
                .collect::<std::collections::HashSet<_>>();
            let mut refs = provider
                .auth_methods
                .iter()
                .flat_map(|method| method.secure_env_refs(provider_id))
                .filter(|entry| value_names.contains(entry.name.as_str()))
                .collect::<Vec<_>>();
            provider.env.retain(|entry| entry.secure_ref.is_none());
            provider.env.append(&mut refs);
        }
        self.update_auth_status(provider_id, AgentAuthStatus::Authenticated);
        Ok(())
    }

    pub fn clear_env_auth_values(
        &mut self,
        provider_id: &str,
        store: &dyn CredentialStore,
    ) -> anyhow::Result<()> {
        let fields = self.env_auth_fields(provider_id);
        let auth_env_names = fields
            .iter()
            .map(|field| field.env_name.as_str())
            .collect::<std::collections::HashSet<_>>();
        for field in &fields {
            store.delete_secret(&CredentialStoreKey::new(provider_id, &field.env_name))?;
            self.auth_env_values
                .remove(&(provider_id.to_string(), field.env_name.clone()));
        }
        if let Some(provider) = self.provider_mut(provider_id) {
            provider.env.retain(|entry| {
                entry.secure_ref.is_none() || !auth_env_names.contains(entry.name.as_str())
            });
        }
        self.update_auth_status(
            provider_id,
            AgentAuthStatus::Required {
                instructions: "Credentials cleared. Enter credentials and authenticate again."
                    .to_string(),
            },
        );
        Ok(())
    }

    pub fn authenticate_with_available_method(
        &mut self,
        provider_id: &str,
        store: &dyn CredentialStore,
    ) -> anyhow::Result<()> {
        let Some(provider) = self
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
        else {
            return Ok(());
        };
        if provider
            .auth_methods
            .iter()
            .any(|method| matches!(method, AgentAuthMethod::EnvVar { .. }))
        {
            self.save_pending_env_auth_values(provider_id, store)?;
            return Ok(());
        }
        if let Some(instructions) = provider
            .auth_methods
            .iter()
            .find_map(|method| method.instructions())
        {
            self.update_auth_status(
                provider_id,
                AgentAuthStatus::Required {
                    instructions: instructions.to_string(),
                },
            );
        } else {
            self.update_auth_status(provider_id, AgentAuthStatus::Authenticated);
        }
        Ok(())
    }

    pub fn show_auth_instructions(&mut self, provider_id: &str) {
        let instructions = self
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
            .and_then(|provider| {
                provider
                    .auth_methods
                    .iter()
                    .find_map(|method| method.instructions())
            })
            .unwrap_or("No authentication instructions are advertised by this provider.")
            .to_string();
        self.update_auth_status(provider_id, AgentAuthStatus::Required { instructions });
    }

    pub fn apply_auth_io_result(&mut self, provider_id: &str, result: &ProviderSettingsState) {
        if let Some(status) = result.auth_statuses.get(provider_id).cloned() {
            self.auth_statuses.insert(provider_id.to_string(), status);
        }
        self.error = result.error.clone();

        let auth_env_names = self
            .env_auth_fields(provider_id)
            .into_iter()
            .map(|field| field.env_name)
            .collect::<std::collections::HashSet<_>>();
        if auth_env_names.is_empty() {
            return;
        }

        let Some(current_provider) = self.provider_mut(provider_id) else {
            return;
        };
        current_provider.env.retain(|entry| {
            entry.secure_ref.is_none() || !auth_env_names.contains(entry.name.as_str())
        });
        if let Some(result_provider) = result
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
        {
            current_provider.env.extend(
                result_provider
                    .env
                    .iter()
                    .filter(|entry| {
                        entry.secure_ref.is_some() && auth_env_names.contains(entry.name.as_str())
                    })
                    .cloned(),
            );
        }
    }

    pub fn apply_clear_auth_io_result(
        &mut self,
        provider_id: &str,
        result: &ProviderSettingsState,
    ) {
        if let Some(status) = result.auth_statuses.get(provider_id).cloned() {
            self.auth_statuses.insert(provider_id.to_string(), status);
        }
        self.error = result.error.clone();

        let auth_env_names = self
            .env_auth_fields(provider_id)
            .into_iter()
            .map(|field| field.env_name)
            .collect::<std::collections::HashSet<_>>();
        if let Some(current_provider) = self.provider_mut(provider_id) {
            current_provider.env.retain(|entry| {
                entry.secure_ref.is_none() || !auth_env_names.contains(entry.name.as_str())
            });
        }
        for field in auth_env_names {
            self.auth_env_values
                .remove(&(provider_id.to_string(), field));
        }
    }

    pub fn mark_terminal_auth_unavailable(&mut self, provider_id: &str) {
        if let Some((command, args, env)) = self.terminal_auth_command(provider_id) {
            let env_names = env.into_iter().map(|entry| entry.name).collect::<Vec<_>>();
            self.update_auth_status(
                provider_id,
                AgentAuthStatus::Failed {
                    message: "Terminal auth runtime is not connected from provider settings."
                        .to_string(),
                    instructions: format!(
                        "Run terminal auth manually: {} {}{}",
                        command,
                        args.join(" "),
                        if env_names.is_empty() {
                            String::new()
                        } else {
                            format!(" (with env: {})", env_names.join(", "))
                        }
                    ),
                },
            );
        } else {
            self.update_auth_status(
                provider_id,
                AgentAuthStatus::Failed {
                    message: "Provider does not advertise terminal authentication.".to_string(),
                    instructions: "Use another advertised authentication method.".to_string(),
                },
            );
        }
    }

    pub fn env_auth_fields(&self, provider_id: &str) -> Vec<AgentAuthField> {
        self.providers
            .iter()
            .find(|provider| provider.id == provider_id)
            .map(|provider| {
                provider
                    .auth_methods
                    .iter()
                    .flat_map(|method| match method {
                        AgentAuthMethod::EnvVar { fields, .. } => fields.clone(),
                        AgentAuthMethod::Agent { .. } | AgentAuthMethod::Terminal { .. } => {
                            Vec::new()
                        }
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn terminal_auth_command(
        &self,
        provider_id: &str,
    ) -> Option<(String, Vec<String>, Vec<AgentProviderEnvVar>)> {
        let provider = self
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)?;
        let method = provider
            .auth_methods
            .iter()
            .find(|method| matches!(method, AgentAuthMethod::Terminal { .. }))?;
        let (auth_args, auth_env) = method.terminal_args_env()?;
        let mut args = provider.args.clone();
        args.extend(auth_args.iter().cloned());
        Some((provider.command.clone(), args, auth_env.to_vec()))
    }

    pub fn auth_status_label(&self, provider_id: &str) -> String {
        self.auth_statuses
            .get(provider_id)
            .unwrap_or(&AgentAuthStatus::Unknown)
            .label()
            .to_string()
    }

    fn provider_mut(&mut self, provider_id: &str) -> Option<&mut AgentProviderConfig> {
        self.providers
            .iter_mut()
            .find(|provider| provider.id == provider_id)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentProviderConfig {
    pub id: String,
    pub display_name: String,
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: Vec<AgentProviderEnvVar>,
    #[serde(default)]
    pub auth_methods: Vec<AgentAuthMethod>,
    #[serde(default)]
    pub cwd_policy: ProviderCwdPolicy,
    #[serde(default)]
    pub trust_mode: AgentTrustMode,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

impl AgentProviderConfig {
    pub fn new(
        id: impl Into<String>,
        display_name: impl Into<String>,
        command: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            command: command.into(),
            args: Vec::new(),
            env: Vec::new(),
            auth_methods: Vec::new(),
            cwd_policy: ProviderCwdPolicy::default(),
            trust_mode: AgentTrustMode::default(),
            enabled: true,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentProviderEnvVar {
    pub name: String,
    #[serde(default)]
    pub value: Option<String>,
    #[serde(default)]
    pub secure_ref: Option<String>,
}

impl AgentProviderEnvVar {
    pub fn secure_ref(name: impl Into<String>, secure_ref: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            value: None,
            secure_ref: Some(secure_ref.into()),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case", tag = "type")]
pub enum AgentAuthMethod {
    Agent {
        instructions: String,
    },
    EnvVar {
        fields: Vec<AgentAuthField>,
        #[serde(default)]
        link: Option<String>,
    },
    Terminal {
        args: Vec<String>,
        env: Vec<AgentProviderEnvVar>,
    },
}

impl Default for AgentAuthMethod {
    fn default() -> Self {
        Self::Agent {
            instructions: String::new(),
        }
    }
}

impl AgentAuthMethod {
    pub fn secure_env_refs(&self, provider_id: &str) -> Vec<AgentProviderEnvVar> {
        match self {
            Self::EnvVar { fields, .. } => fields
                .iter()
                .map(|field| {
                    AgentProviderEnvVar::secure_ref(
                        field.env_name.clone(),
                        format!("{provider_id}/{}", field.env_name),
                    )
                })
                .collect(),
            Self::Agent { .. } | Self::Terminal { .. } => Vec::new(),
        }
    }

    pub fn terminal_args_env(&self) -> Option<(&[String], &[AgentProviderEnvVar])> {
        match self {
            Self::Terminal { args, env } => Some((args.as_slice(), env.as_slice())),
            Self::Agent { .. } | Self::EnvVar { .. } => None,
        }
    }

    pub fn instructions(&self) -> Option<&str> {
        match self {
            Self::Agent { instructions } if !instructions.is_empty() => Some(instructions),
            Self::EnvVar {
                link: Some(link), ..
            } if !link.is_empty() => Some(link),
            Self::Agent { .. } | Self::EnvVar { .. } | Self::Terminal { .. } => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentAuthField {
    pub label: String,
    pub env_name: String,
    #[serde(default)]
    pub secret: bool,
    #[serde(default)]
    pub optional: bool,
}

impl AgentAuthField {
    pub fn secret(label: impl Into<String>, env_name: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            env_name: env_name.into(),
            secret: true,
            optional: false,
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderCwdPolicy {
    #[default]
    SelectedWorktree,
    RepositoryRoot,
    Fixed(std::path::PathBuf),
}

fn default_enabled() -> bool {
    true
}
