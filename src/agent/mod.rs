pub mod credentials;
mod discovery;
pub mod fake;
pub mod filesystem;
pub mod permission;
pub mod persistence;
pub mod provider;
pub mod runtime;
pub mod terminal;
pub mod types;

pub use credentials::{
    CredentialStore, CredentialStoreKey, MemoryCredentialStore, OsCredentialStore,
    resolve_secure_env_values,
};
pub use discovery::{
    AgentProviderSuggestion, ProviderDiscoveryResult, ProviderDiscoveryStartupResult,
    apply_provider_discovery_to_config, discover_agent_providers,
    discover_agent_providers_from_path, filtered_provider_suggestions,
    ignore_discovered_provider_id, is_known_discoverable_provider_id,
    merge_discovered_agent_providers, remove_provider_and_record_discovery_ignore,
};
pub use fake::FakeAcpConnection;
pub use filesystem::FilesystemCallbackService;
pub use permission::{PermissionDecision, PermissionPolicy, PermissionRequestKind};
pub use persistence::{
    AgentThreadRecord, AgentThreadStore, filter_agent_thread_records, merge_agent_thread_records,
};
pub use provider::{
    AgentAuthField, AgentAuthMethod, AgentAuthStatus, AgentProviderConfig, AgentProviderEnvVar,
    ProviderCwdPolicy, ProviderSettingsState,
};
pub use runtime::{
    AcpCancelHandle, AcpConnection, AcpProcessConnection, AgentEventSink, AgentRuntime,
    AgentRuntimeEvent, AgentUpdate, agent_update_from_acp_session_update, apply_agent_update,
    apply_runtime_event, resolve_provider_cwd,
};
pub use terminal::{
    AgentTerminalHandle, AgentTerminalResult, AgentTerminalService, AgentTerminalStatus,
};
pub use types::{
    AgentConfigOption, AgentConfigValueOption, AgentDebugEvent, AgentModeOption,
    AgentPermissionRequest, AgentPlanState, AgentResumeState, AgentSlashCommand, AgentThreadState,
    AgentThreadStatus, AgentToolCallState, AgentTranscriptEntry, AgentTranscriptRole,
    AgentTrustMode, redact_debug_message, redact_debug_value,
};
