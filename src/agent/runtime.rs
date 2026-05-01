use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};

use agent_client_protocol::{JsonRpcMessage, JsonRpcRequest, JsonRpcResponse};
use anyhow::{Context, Result};
use serde::de::DeserializeOwned;
use serde_json::json;

use super::{
    AgentAuthStatus, AgentConfigOption, AgentConfigValueOption, AgentDebugEvent, AgentModeOption,
    AgentPermissionRequest, AgentPlanState, AgentProviderConfig, AgentSlashCommand,
    AgentTerminalHandle, AgentTerminalResult, AgentTerminalService, AgentTerminalStatus,
    AgentThreadState, AgentThreadStatus, AgentToolCallState, AgentTranscriptEntry,
    AgentTranscriptRole, CredentialStore, FilesystemCallbackService, PermissionDecision,
    PermissionPolicy, PermissionRequestKind, ProviderCwdPolicy, resolve_secure_env_values,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentUpdate {
    AgentMessageChunk(String),
    ThoughtChunk(String),
    ToolCall {
        id: String,
        title: String,
        status: String,
    },
    ToolCallUpdate {
        id: String,
        title: Option<String>,
        status: Option<String>,
    },
    Plan(Vec<String>),
    AvailableCommands(Vec<AgentSlashCommand>),
    AvailableModes {
        modes: Vec<AgentModeOption>,
        current: Option<String>,
    },
    CurrentMode(String),
    ConfigOptions(Vec<AgentConfigOption>),
    NeedsPermission {
        id: String,
        description: String,
    },
    Error(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentRuntimeEvent {
    Initialized,
    AuthRequired {
        instructions: String,
    },
    Ready,
    AgentMessageChunk(String),
    ThoughtChunk(String),
    ToolCall {
        id: String,
        title: String,
        status: String,
    },
    ToolCallUpdate {
        id: String,
        title: Option<String>,
        status: Option<String>,
    },
    Plan(Vec<String>),
    AvailableCommands(Vec<AgentSlashCommand>),
    AvailableModes {
        modes: Vec<AgentModeOption>,
        current: Option<String>,
    },
    ConfigOptions(Vec<AgentConfigOption>),
    CurrentMode(String),
    NeedsPermission {
        id: String,
        description: String,
    },
    Failed(String),
}

pub trait AgentEventSink {
    fn emit(&mut self, event: AgentRuntimeEvent);
}

pub trait AcpConnection {
    fn initialize(&mut self, sink: &mut dyn AgentEventSink) -> Result<()>;

    fn new_session(
        &mut self,
        worktree_path: PathBuf,
        sink: &mut dyn AgentEventSink,
    ) -> Result<Option<String>>;

    fn resume_session(&mut self, session_id: String, sink: &mut dyn AgentEventSink) -> Result<()>;

    fn prompt(
        &mut self,
        session_id: String,
        prompt: String,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()>;

    fn cancel(&mut self, session_id: String) -> Result<()>;

    fn set_mode(
        &mut self,
        session_id: String,
        mode_id: String,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()>;

    fn set_config_option(
        &mut self,
        session_id: String,
        config_id: String,
        value_id: String,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()>;

    fn authenticate(&mut self, method_id: String, sink: &mut dyn AgentEventSink) -> Result<()>;
}

#[derive(Debug)]
pub struct AcpProcessConnection {
    child: Child,
    stdin: Arc<Mutex<ChildStdin>>,
    stdout: BufReader<ChildStdout>,
    next_request_id: u64,
    cwd: PathBuf,
    filesystem: Option<FilesystemCallbackService>,
    terminal: Option<AgentTerminalService>,
    permission_policy: Option<PermissionPolicy>,
}

#[derive(Clone, Debug)]
pub struct AcpCancelHandle {
    stdin: Arc<Mutex<ChildStdin>>,
}

impl AcpCancelHandle {
    pub fn cancel(&self, session_id: String) -> Result<()> {
        let notification = agent_client_protocol::schema::CancelNotification::new(session_id);
        let message = json!({
            "jsonrpc": "2.0",
            "method": notification.method(),
            "params": notification,
        });
        write_acp_notification(&self.stdin, message, "ACP cancel notification")
    }
}

fn write_acp_notification(
    stdin: &Arc<Mutex<ChildStdin>>,
    message: serde_json::Value,
    context: &str,
) -> Result<()> {
    let mut stdin = stdin.lock().expect("ACP stdin mutex poisoned");
    writeln!(stdin, "{message}").with_context(|| format!("failed to write {context}"))?;
    stdin
        .flush()
        .with_context(|| format!("failed to flush {context}"))?;
    Ok(())
}

pub fn resolve_provider_cwd(
    provider: &AgentProviderConfig,
    selected_worktree: &Path,
    repository_root: &Path,
) -> PathBuf {
    match &provider.cwd_policy {
        ProviderCwdPolicy::SelectedWorktree => selected_worktree.to_path_buf(),
        ProviderCwdPolicy::RepositoryRoot => repository_root.to_path_buf(),
        ProviderCwdPolicy::Fixed(path) => path.clone(),
    }
}

impl Drop for AcpProcessConnection {
    fn drop(&mut self) {
        match self.child.try_wait() {
            Ok(Some(_)) => {}
            Ok(None) => {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
            Err(_) => {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
    }
}

impl AcpProcessConnection {
    pub fn spawn(provider: &AgentProviderConfig, cwd: PathBuf) -> Result<Self> {
        Self::spawn_with_env(provider, cwd, &[])
    }

    pub fn spawn_with_credentials(
        provider: &AgentProviderConfig,
        cwd: PathBuf,
        credential_store: &dyn CredentialStore,
    ) -> Result<Self> {
        let env = resolve_secure_env_values(&provider.id, &provider.env, credential_store)?;
        Self::spawn_with_resolved_provider_env(provider, cwd, &[], &env)
    }

    pub fn spawn_with_env(
        provider: &AgentProviderConfig,
        cwd: PathBuf,
        env: &[(String, String)],
    ) -> Result<Self> {
        Self::spawn_with_resolved_provider_env(provider, cwd, env, &[])
    }

    fn spawn_with_resolved_provider_env(
        provider: &AgentProviderConfig,
        cwd: PathBuf,
        env: &[(String, String)],
        resolved_provider_env: &[(String, String)],
    ) -> Result<Self> {
        let mut command = Command::new(&provider.command);
        command
            .args(&provider.args)
            .current_dir(&cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        for (name, value) in env {
            command.env(name, value);
        }

        for (name, value) in resolved_provider_env {
            command.env(name, value);
        }

        for env_var in &provider.env {
            if let Some(value) = &env_var.value {
                command.env(&env_var.name, value);
            } else if env_var.secure_ref.is_some()
                && !resolved_provider_env
                    .iter()
                    .any(|(name, _)| name == &env_var.name)
            {
                anyhow::bail!(
                    "provider '{}' env var '{}' requires credential resolution before launch",
                    provider.id,
                    env_var.name
                );
            }
        }

        let mut child = command.spawn().with_context(|| {
            format!(
                "failed to spawn ACP provider '{}' with command '{}' in '{}'",
                provider.id,
                provider.command,
                cwd.display()
            )
        })?;

        let stdin = child
            .stdin
            .take()
            .context("spawned ACP provider without stdin")?;
        let stdout = child
            .stdout
            .take()
            .context("spawned ACP provider without stdout")?;

        Ok(Self {
            child,
            stdin: Arc::new(Mutex::new(stdin)),
            stdout: BufReader::new(stdout),
            next_request_id: 1,
            cwd,
            filesystem: None,
            terminal: None,
            permission_policy: None,
        })
    }

    pub fn cancel_handle(&self) -> AcpCancelHandle {
        AcpCancelHandle {
            stdin: Arc::clone(&self.stdin),
        }
    }

    pub fn with_callback_services(
        mut self,
        filesystem: FilesystemCallbackService,
        terminal: AgentTerminalService,
    ) -> Self {
        self.permission_policy = Some(filesystem.policy.clone());
        self.filesystem = Some(filesystem);
        self.terminal = Some(terminal);
        self
    }

    fn send_request<T>(&mut self, request: T, sink: &mut dyn AgentEventSink) -> Result<T::Response>
    where
        T: JsonRpcRequest + serde::Serialize,
        T::Response: JsonRpcResponse + DeserializeOwned,
    {
        let id = self.next_request_id;
        self.next_request_id += 1;
        let message = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": request.method(),
            "params": request,
        });
        {
            let mut stdin = self.stdin.lock().expect("ACP stdin mutex poisoned");
            writeln!(stdin, "{message}").context("failed to write ACP request")?;
            stdin.flush().context("failed to flush ACP request")?;
        }
        self.read_response::<T>(id, sink)
    }

    fn send_notification<T>(&mut self, notification: T) -> Result<()>
    where
        T: JsonRpcMessage + serde::Serialize,
    {
        let message = json!({
            "jsonrpc": "2.0",
            "method": notification.method(),
            "params": notification,
        });
        write_acp_notification(&self.stdin, message, "ACP notification")
    }

    fn read_response<T>(&mut self, id: u64, sink: &mut dyn AgentEventSink) -> Result<T::Response>
    where
        T: JsonRpcRequest,
        T::Response: JsonRpcResponse + DeserializeOwned,
    {
        loop {
            let mut line = String::new();
            let bytes = self
                .stdout
                .read_line(&mut line)
                .context("failed to read ACP message")?;
            if bytes == 0 {
                anyhow::bail!("ACP provider closed stdout while waiting for response");
            }
            let value: serde_json::Value = serde_json::from_str(line.trim())
                .with_context(|| format!("failed to parse ACP JSON-RPC message: {line}"))?;
            if value.get("id").and_then(|value| value.as_u64()) == Some(id) {
                if let Some(error) = value.get("error") {
                    anyhow::bail!("ACP request failed: {error}");
                }
                let result = value
                    .get("result")
                    .cloned()
                    .unwrap_or(serde_json::Value::Null);
                return serde_json::from_value(result).context("failed to decode ACP response");
            }
            self.handle_incoming(value, sink)?;
        }
    }

    fn handle_incoming(
        &mut self,
        value: serde_json::Value,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()> {
        let Some(method) = value.get("method").and_then(|method| method.as_str()) else {
            return Ok(());
        };
        let params = value
            .get("params")
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        if method == "session/update" {
            let notification: agent_client_protocol::schema::SessionNotification =
                serde_json::from_value(params).context("failed to decode ACP session update")?;
            if let Some(update) = agent_update_from_acp_session_update(notification.update) {
                sink.emit(agent_runtime_event_from_update(update));
            }
        } else if let Some(request_id) = value.get("id").cloned() {
            let response = match self.dispatch_client_request(method, params) {
                Ok(result) => json!({ "jsonrpc": "2.0", "id": request_id, "result": result }),
                Err(error) => {
                    let code = if is_client_callback_method(method) {
                        -32000
                    } else {
                        -32601
                    };
                    json!({
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": { "code": code, "message": error.to_string() }
                    })
                }
            };
            write_acp_notification(&self.stdin, response, "ACP client response")?;
        }
        Ok(())
    }

    pub fn dispatch_client_request(
        &mut self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<serde_json::Value> {
        use agent_client_protocol::schema as acp;

        match method {
            "session/request_permission" => {
                let request: acp::RequestPermissionRequest = serde_json::from_value(params)
                    .context("failed to decode session/request_permission")?;
                let trust_mode = self
                    .permission_policy
                    .as_ref()
                    .map(|policy| &policy.trust_mode);
                if matches!(trust_mode, Some(super::AgentTrustMode::Ask)) {
                    anyhow::bail!(
                        "permission request requires user approval and cannot be continued in process callbacks: {}",
                        request
                            .tool_call
                            .fields
                            .title
                            .as_deref()
                            .unwrap_or("ACP permission request")
                    );
                }
                let allow = matches!(trust_mode, Some(super::AgentTrustMode::AllowEverything));
                if request.options.is_empty() {
                    anyhow::bail!("permission request did not include options");
                }
                let preferred = request.options.iter().find(|option| {
                    matches!(
                        (allow, option.kind),
                        (
                            true,
                            acp::PermissionOptionKind::AllowOnce
                                | acp::PermissionOptionKind::AllowAlways
                        ) | (
                            false,
                            acp::PermissionOptionKind::RejectOnce
                                | acp::PermissionOptionKind::RejectAlways
                        )
                    )
                });
                let option_id = preferred
                    .map(|option| option.option_id.clone())
                    .ok_or_else(|| {
                        anyhow::anyhow!("permission request did not include a compatible option")
                    })?;
                Ok(serde_json::to_value(acp::RequestPermissionResponse::new(
                    acp::RequestPermissionOutcome::Selected(acp::SelectedPermissionOutcome::new(
                        option_id,
                    )),
                ))?)
            }
            "fs/read_text_file" => {
                let request: acp::ReadTextFileRequest =
                    serde_json::from_value(params).context("failed to decode fs/read_text_file")?;
                self.ensure_permission(PermissionRequestKind::ReadFile(request.path.clone()))?;
                let content = self
                    .filesystem
                    .as_ref()
                    .ok_or_else(|| {
                        anyhow::anyhow!("filesystem callback service is not configured")
                    })?
                    .read_text_file(&request.path)?;
                Ok(serde_json::to_value(acp::ReadTextFileResponse::new(
                    content,
                ))?)
            }
            "fs/write_text_file" => {
                let request: acp::WriteTextFileRequest = serde_json::from_value(params)
                    .context("failed to decode fs/write_text_file")?;
                self.ensure_permission(PermissionRequestKind::WriteFile(request.path.clone()))?;
                self.filesystem
                    .as_ref()
                    .ok_or_else(|| {
                        anyhow::anyhow!("filesystem callback service is not configured")
                    })?
                    .write_text_file(&request.path, &request.content)?;
                Ok(serde_json::to_value(acp::WriteTextFileResponse::new())?)
            }
            "terminal/create" => {
                let request: acp::CreateTerminalRequest =
                    serde_json::from_value(params).context("failed to decode terminal/create")?;
                let command = terminal_command(&request.command, &request.args);
                self.ensure_permission(PermissionRequestKind::RunTerminal {
                    command: command.clone(),
                })?;
                let cwd = request.cwd.as_deref().unwrap_or(&self.cwd);
                let handle = self
                    .terminal
                    .as_mut()
                    .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
                    .create(&command, cwd)?;
                Ok(serde_json::to_value(acp::CreateTerminalResponse::new(
                    handle.0.to_string(),
                ))?)
            }
            "terminal/output" => {
                let request: acp::TerminalOutputRequest =
                    serde_json::from_value(params).context("failed to decode terminal/output")?;
                let output = self
                    .terminal
                    .as_ref()
                    .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
                    .output(parse_terminal_id(&request.terminal_id.0)?)?;
                Ok(serde_json::to_value(acp::TerminalOutputResponse::new(
                    output, false,
                ))?)
            }
            "terminal/wait_for_exit" => {
                let request: acp::WaitForTerminalExitRequest = serde_json::from_value(params)
                    .context("failed to decode terminal/wait_for_exit")?;
                let result = self
                    .terminal
                    .as_mut()
                    .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
                    .wait_for_exit(parse_terminal_id(&request.terminal_id.0)?)?;
                Ok(serde_json::to_value(
                    acp::WaitForTerminalExitResponse::new(terminal_exit_status(result.status)),
                )?)
            }
            "terminal/kill" => {
                let request: acp::KillTerminalRequest =
                    serde_json::from_value(params).context("failed to decode terminal/kill")?;
                self.terminal
                    .as_mut()
                    .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
                    .kill(parse_terminal_id(&request.terminal_id.0)?)?;
                Ok(serde_json::to_value(acp::KillTerminalResponse::new())?)
            }
            "terminal/release" => {
                let request: acp::ReleaseTerminalRequest =
                    serde_json::from_value(params).context("failed to decode terminal/release")?;
                self.terminal
                    .as_mut()
                    .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
                    .release(parse_terminal_id(&request.terminal_id.0)?)?;
                Ok(serde_json::to_value(acp::ReleaseTerminalResponse::new())?)
            }
            _ => anyhow::bail!("ACP client method not implemented: {method}"),
        }
    }

    fn ensure_permission(&self, request: PermissionRequestKind) -> Result<()> {
        match self
            .permission_policy
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("permission callback service is not configured"))?
            .decide(&request)
        {
            PermissionDecision::Allow => Ok(()),
            PermissionDecision::Deny => {
                anyhow::bail!("permission denied: {}", permission_description(&request))
            }
            PermissionDecision::Ask => anyhow::bail!(
                "permission requires user approval and cannot be continued in process callbacks: {}",
                permission_description(&request)
            ),
        }
    }

    fn emit_session_metadata(
        &self,
        modes: Option<agent_client_protocol::schema::SessionModeState>,
        config_options: Option<Vec<agent_client_protocol::schema::SessionConfigOption>>,
        sink: &mut dyn AgentEventSink,
    ) {
        if let Some(modes) = modes {
            sink.emit(AgentRuntimeEvent::AvailableModes {
                modes: modes
                    .available_modes
                    .into_iter()
                    .map(|mode| AgentModeOption {
                        id: mode.id.0.to_string(),
                        name: mode.name,
                    })
                    .collect(),
                current: Some(modes.current_mode_id.0.to_string()),
            });
        }
        if let Some(config_options) = config_options {
            sink.emit(AgentRuntimeEvent::ConfigOptions(
                config_options
                    .into_iter()
                    .map(agent_config_option_from_acp)
                    .collect(),
            ));
        }
    }
}

impl AcpConnection for AcpProcessConnection {
    fn initialize(&mut self, sink: &mut dyn AgentEventSink) -> Result<()> {
        let request = agent_client_protocol::schema::InitializeRequest::new(
            agent_client_protocol::schema::ProtocolVersion::LATEST,
        )
        .client_capabilities(agent_client_protocol::schema::ClientCapabilities::new())
        .client_info(
            agent_client_protocol::schema::Implementation::new("alas", env!("CARGO_PKG_VERSION"))
                .title("Alas"),
        );
        let response = self.send_request(request, sink)?;
        if !response.auth_methods.is_empty() {
            sink.emit(AgentRuntimeEvent::AuthRequired {
                instructions: "ACP provider requires authentication".to_string(),
            });
        } else {
            sink.emit(AgentRuntimeEvent::Initialized);
        }
        Ok(())
    }

    fn new_session(
        &mut self,
        worktree_path: PathBuf,
        sink: &mut dyn AgentEventSink,
    ) -> Result<Option<String>> {
        let request = agent_client_protocol::schema::NewSessionRequest::new(worktree_path);
        let response = self.send_request(request, sink)?;
        let session_id = response.session_id.0.to_string();
        self.emit_session_metadata(response.modes, response.config_options, sink);
        sink.emit(AgentRuntimeEvent::Ready);
        Ok(Some(session_id))
    }

    fn resume_session(&mut self, session_id: String, sink: &mut dyn AgentEventSink) -> Result<()> {
        let request =
            agent_client_protocol::schema::LoadSessionRequest::new(session_id, self.cwd.clone());
        let response = self.send_request(request, sink)?;
        self.emit_session_metadata(response.modes, response.config_options, sink);
        sink.emit(AgentRuntimeEvent::Ready);
        Ok(())
    }

    fn prompt(
        &mut self,
        session_id: String,
        prompt: String,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()> {
        let request = agent_client_protocol::schema::PromptRequest::new(
            session_id,
            vec![agent_client_protocol::schema::ContentBlock::Text(
                agent_client_protocol::schema::TextContent::new(prompt),
            )],
        );
        let _response: agent_client_protocol::schema::PromptResponse =
            self.send_request(request, sink)?;
        sink.emit(AgentRuntimeEvent::Ready);
        Ok(())
    }

    fn cancel(&mut self, session_id: String) -> Result<()> {
        self.send_notification(agent_client_protocol::schema::CancelNotification::new(
            session_id,
        ))
    }

    fn set_mode(
        &mut self,
        session_id: String,
        mode_id: String,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()> {
        let request =
            agent_client_protocol::schema::SetSessionModeRequest::new(session_id, mode_id.clone());
        let _response: agent_client_protocol::schema::SetSessionModeResponse =
            self.send_request(request, sink)?;
        sink.emit(AgentRuntimeEvent::CurrentMode(mode_id));
        Ok(())
    }

    fn set_config_option(
        &mut self,
        session_id: String,
        config_id: String,
        value_id: String,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()> {
        let request = agent_client_protocol::schema::SetSessionConfigOptionRequest::new(
            session_id, config_id, value_id,
        );
        let response: agent_client_protocol::schema::SetSessionConfigOptionResponse =
            self.send_request(request, sink)?;
        sink.emit(AgentRuntimeEvent::ConfigOptions(
            response
                .config_options
                .into_iter()
                .map(agent_config_option_from_acp)
                .collect(),
        ));
        Ok(())
    }

    fn authenticate(&mut self, method_id: String, sink: &mut dyn AgentEventSink) -> Result<()> {
        let request = agent_client_protocol::schema::AuthenticateRequest::new(method_id);
        let _response: agent_client_protocol::schema::AuthenticateResponse =
            self.send_request(request, sink)?;
        sink.emit(AgentRuntimeEvent::Ready);
        Ok(())
    }
}

pub struct AgentRuntime<C> {
    thread: AgentThreadState,
    connection: C,
    filesystem: Option<FilesystemCallbackService>,
    terminal: Option<AgentTerminalService>,
    permission_policy: Option<PermissionPolicy>,
    next_permission_request_id: u64,
}

impl<C> AgentRuntime<C> {
    pub fn with_connection(thread: AgentThreadState, connection: C) -> Self {
        Self {
            thread,
            connection,
            filesystem: None,
            terminal: None,
            permission_policy: None,
            next_permission_request_id: 1,
        }
    }

    pub fn with_callback_services(
        mut self,
        filesystem: FilesystemCallbackService,
        terminal: AgentTerminalService,
    ) -> Self {
        self.permission_policy = Some(filesystem.policy.clone());
        self.filesystem = Some(filesystem);
        self.terminal = Some(terminal);
        self
    }

    pub fn handle_request_permission(&mut self, request: PermissionRequestKind) -> Result<bool> {
        let policy = self
            .permission_policy
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("permission callback service is not configured"))?;
        let description = permission_description(&request);
        match policy.decide(&request) {
            PermissionDecision::Allow => {
                self.thread.push_debug_event(AgentDebugEvent {
                    message: format!("Permission allowed: {description}"),
                });
                Ok(true)
            }
            PermissionDecision::Deny => {
                let message = format!("permission denied: {description}");
                self.thread.push_debug_event(AgentDebugEvent {
                    message: message.clone(),
                });
                Err(anyhow::anyhow!(message))
            }
            PermissionDecision::Ask => {
                let id = format!("permission-{}", self.next_permission_request_id);
                self.next_permission_request_id = self
                    .next_permission_request_id
                    .checked_add(1)
                    .ok_or_else(|| anyhow::anyhow!("permission request id overflow"))?;
                self.thread.push_debug_event(AgentDebugEvent {
                    message: format!("Permission requested: {description}"),
                });
                self.thread
                    .pending_permissions
                    .push(AgentPermissionRequest {
                        id: id.clone(),
                        description,
                    });
                Err(anyhow::anyhow!("permission request pending: {id}"))
            }
        }
    }

    pub fn resolve_permission_request(&mut self, id: &str, allow: bool) -> Result<bool> {
        let Some(index) = self
            .thread
            .pending_permissions
            .iter()
            .position(|request| request.id == id)
        else {
            anyhow::bail!("permission request {id} not found");
        };
        let request = self.thread.pending_permissions.remove(index);
        self.thread.push_debug_event(AgentDebugEvent {
            message: format!(
                "Permission {}: {}",
                if allow { "allowed" } else { "denied" },
                request.description
            ),
        });
        Ok(allow)
    }

    pub fn handle_read_text_file(&mut self, path: &Path) -> Result<String> {
        if let Err(error) =
            self.handle_request_permission(PermissionRequestKind::ReadFile(path.to_path_buf()))
        {
            self.record_callback_error("read_text_file", error.to_string());
            return Err(error);
        }
        let result = self
            .filesystem
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("filesystem callback service is not configured"))?
            .read_text_file(path);
        match result {
            Ok(content) => {
                self.record_tool_entry("read_text_file", format!("Read {}", path.display()));
                Ok(content)
            }
            Err(error) => {
                self.record_callback_error("read_text_file", error.to_string());
                Err(error)
            }
        }
    }

    pub fn handle_write_text_file(&mut self, path: &Path, content: &str) -> Result<()> {
        if let Err(error) =
            self.handle_request_permission(PermissionRequestKind::WriteFile(path.to_path_buf()))
        {
            self.record_callback_error("write_text_file", error.to_string());
            return Err(error);
        }
        let result = self
            .filesystem
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("filesystem callback service is not configured"))?
            .write_text_file(path, content);
        match result {
            Ok(()) => {
                self.record_tool_entry("write_text_file", format!("Wrote {}", path.display()));
                Ok(())
            }
            Err(error) => {
                self.record_callback_error("write_text_file", error.to_string());
                Err(error)
            }
        }
    }

    pub fn handle_terminal_create(
        &mut self,
        command: &str,
        cwd: &Path,
    ) -> Result<AgentTerminalHandle> {
        if let Err(error) = self.handle_request_permission(PermissionRequestKind::RunTerminal {
            command: command.to_string(),
        }) {
            self.record_callback_error("terminal_create", error.to_string());
            return Err(error);
        }
        let result = self
            .terminal
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
            .create(command, cwd);
        match result {
            Ok(handle) => {
                self.record_tool_entry(
                    "terminal_create",
                    format!("Started terminal command: {command}"),
                );
                Ok(handle)
            }
            Err(error) => {
                self.record_callback_error("terminal_create", error.to_string());
                Err(error)
            }
        }
    }

    pub fn handle_terminal_output(&mut self, handle: AgentTerminalHandle) -> Result<String> {
        let result = self
            .terminal
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
            .output(handle);
        match result {
            Ok(output) => {
                self.record_tool_entry("terminal_output", output.clone());
                Ok(output)
            }
            Err(error) => {
                self.record_callback_error("terminal_output", error.to_string());
                Err(error)
            }
        }
    }

    pub fn handle_terminal_wait_for_exit(
        &mut self,
        handle: AgentTerminalHandle,
    ) -> Result<AgentTerminalResult> {
        let result = self
            .terminal
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
            .wait_for_exit(handle);
        match result {
            Ok(result) => {
                self.record_tool_entry(
                    "terminal_wait_for_exit",
                    format!("Terminal exited: {:?}", result.status),
                );
                Ok(result)
            }
            Err(error) => {
                self.record_callback_error("terminal_wait_for_exit", error.to_string());
                Err(error)
            }
        }
    }

    pub fn handle_terminal_kill(
        &mut self,
        handle: AgentTerminalHandle,
    ) -> Result<AgentTerminalResult> {
        let result = self
            .terminal
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
            .kill(handle);
        match result {
            Ok(result) => {
                self.record_tool_entry(
                    "terminal_kill",
                    format!("Terminal killed: {:?}", result.status),
                );
                Ok(result)
            }
            Err(error) => {
                self.record_callback_error("terminal_kill", error.to_string());
                Err(error)
            }
        }
    }

    pub fn handle_terminal_release(&mut self, handle: AgentTerminalHandle) -> Result<()> {
        let result = self
            .terminal
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("terminal callback service is not configured"))?
            .release(handle);
        match result {
            Ok(()) => {
                self.record_tool_entry(
                    "terminal_release",
                    format!("Released terminal {}", handle.0),
                );
                Ok(())
            }
            Err(error) => {
                self.record_callback_error("terminal_release", error.to_string());
                Err(error)
            }
        }
    }

    fn record_tool_entry(&mut self, id: &str, text: String) {
        self.thread.tool_calls.push(AgentToolCallState {
            id: format!("{id}-{}", self.thread.tool_calls.len() + 1),
            title: id.replace('_', " "),
            status: "completed".to_string(),
        });
        self.thread.transcript.push(AgentTranscriptEntry {
            role: AgentTranscriptRole::Tool,
            text,
        });
    }

    fn record_callback_error(&mut self, callback: &str, message: String) {
        self.thread.push_debug_event(AgentDebugEvent {
            message: format!("{callback} failed: {message}"),
        });
    }

    pub fn thread(&self) -> &AgentThreadState {
        &self.thread
    }

    pub fn thread_mut(&mut self) -> &mut AgentThreadState {
        &mut self.thread
    }

    pub fn connection(&self) -> &C {
        &self.connection
    }
}

impl<C: AcpConnection> AgentRuntime<C> {
    pub fn initialize(&mut self) -> Result<()> {
        self.thread.status = AgentThreadStatus::Starting;
        let thread = &mut self.thread;
        let mut sink = ThreadEventSink { thread };
        self.connection.initialize(&mut sink)?;
        if matches!(sink.thread.status, AgentThreadStatus::Starting) {
            sink.thread.status = AgentThreadStatus::Ready;
        }
        Ok(())
    }

    pub fn create_session(&mut self) -> Result<()> {
        self.thread.status = AgentThreadStatus::Starting;
        let worktree_path = self.thread.worktree_path.clone();
        let thread = &mut self.thread;
        let mut sink = ThreadEventSink { thread };
        let session_id = self.connection.new_session(worktree_path, &mut sink)?;
        sink.thread.acp_session_id = session_id;
        Ok(())
    }

    pub fn resume_existing_session(&mut self, session_id: impl Into<String>) -> Result<()> {
        self.thread.status = AgentThreadStatus::Starting;
        let session_id = session_id.into();
        self.thread.acp_session_id = Some(session_id.clone());
        let thread = &mut self.thread;
        let mut sink = ThreadEventSink { thread };
        match self.connection.resume_session(session_id, &mut sink) {
            Ok(()) => {
                sink.thread.resume = super::AgentResumeState::Resumed;
                if matches!(sink.thread.status, AgentThreadStatus::Starting) {
                    sink.thread.status = AgentThreadStatus::Ready;
                }
                Ok(())
            }
            Err(error) => {
                let message = error.to_string();
                sink.thread.resume = super::AgentResumeState::Failed {
                    message: message.clone(),
                };
                sink.thread.status = AgentThreadStatus::ReadOnly { reason: message };
                Ok(())
            }
        }
    }

    pub fn prompt(&mut self, prompt: impl Into<String>) -> Result<()> {
        if let AgentThreadStatus::ReadOnly { reason } = &self.thread.status {
            anyhow::bail!("cannot prompt read-only ACP session: {reason}");
        }
        let session_id = self
            .thread
            .acp_session_id
            .clone()
            .ok_or_else(|| anyhow::anyhow!("cannot prompt without an active ACP session"))?;
        self.thread.status = AgentThreadStatus::Running;
        self.thread
            .transcript
            .push(AgentTranscriptEntry::user(prompt.into()));
        let prompt = self
            .thread
            .transcript
            .last()
            .map(|entry| entry.text.clone())
            .unwrap_or_default();
        let thread = &mut self.thread;
        let mut sink = ThreadEventSink { thread };
        match self.connection.prompt(session_id, prompt, &mut sink) {
            Ok(()) => Ok(()),
            Err(error) => {
                let message = error.to_string();
                sink.thread.status = AgentThreadStatus::Failed { message };
                Err(error)
            }
        }
    }

    pub fn cancel(&mut self) -> Result<()> {
        let session_id = self
            .thread
            .acp_session_id
            .clone()
            .ok_or_else(|| anyhow::anyhow!("cannot cancel without an active ACP session"))?;
        self.connection.cancel(session_id)?;
        self.thread.status = AgentThreadStatus::Ready;
        Ok(())
    }

    pub fn set_mode(&mut self, mode_id: impl Into<String>) -> Result<()> {
        if let AgentThreadStatus::ReadOnly { reason } = &self.thread.status {
            anyhow::bail!("cannot change mode for read-only ACP session: {reason}");
        }
        let session_id =
            self.thread.acp_session_id.clone().ok_or_else(|| {
                anyhow::anyhow!("cannot change mode without an active ACP session")
            })?;
        let mode_id = mode_id.into();
        let previous_mode = self.thread.current_mode.clone();
        let thread = &mut self.thread;
        let mut sink = ThreadEventSink { thread };
        match self
            .connection
            .set_mode(session_id, mode_id.clone(), &mut sink)
        {
            Ok(()) => {
                if sink.thread.current_mode == previous_mode {
                    sink.thread.current_mode = Some(mode_id);
                }
                Ok(())
            }
            Err(error) => {
                sink.thread.current_mode = previous_mode;
                Err(error)
            }
        }
    }

    pub fn set_config_option(
        &mut self,
        config_id: impl Into<String>,
        value_id: impl Into<String>,
    ) -> Result<()> {
        if let AgentThreadStatus::ReadOnly { reason } = &self.thread.status {
            anyhow::bail!("cannot change config for read-only ACP session: {reason}");
        }
        let session_id =
            self.thread.acp_session_id.clone().ok_or_else(|| {
                anyhow::anyhow!("cannot change config without an active ACP session")
            })?;
        let config_id = config_id.into();
        let value_id = value_id.into();
        let previous_value = self
            .thread
            .config_options
            .iter()
            .find(|option| option.id == config_id)
            .and_then(|option| option.value.clone());
        let thread = &mut self.thread;
        let mut sink = ThreadEventSink { thread };
        match self.connection.set_config_option(
            session_id,
            config_id.clone(),
            value_id.clone(),
            &mut sink,
        ) {
            Ok(()) => {
                if let Some(option) = sink
                    .thread
                    .config_options
                    .iter_mut()
                    .find(|option| option.id == config_id)
                    && option.value == previous_value
                {
                    option.value = Some(value_id);
                }
                Ok(())
            }
            Err(error) => {
                if let Some(option) = sink
                    .thread
                    .config_options
                    .iter_mut()
                    .find(|option| option.id == config_id)
                {
                    option.value = previous_value;
                }
                Err(error)
            }
        }
    }

    pub fn authenticate(&mut self, method_id: impl Into<String>) -> Result<()> {
        let method_id = method_id.into();
        self.thread.push_debug_event(AgentDebugEvent {
            message: format!("Authenticating with auth method '{method_id}'"),
        });
        let thread = &mut self.thread;
        let mut sink = ThreadEventSink { thread };
        match self.connection.authenticate(method_id, &mut sink) {
            Ok(()) => {
                sink.thread.auth_status = AgentAuthStatus::Authenticated;
                sink.thread.status = AgentThreadStatus::Ready;
                sink.thread.push_debug_event(AgentDebugEvent {
                    message: "Authentication succeeded".to_string(),
                });
                Ok(())
            }
            Err(error) => {
                let message = error.to_string();
                let instructions = sink
                    .thread
                    .auth_status
                    .instructions()
                    .unwrap_or_default()
                    .to_string();
                sink.thread.auth_status = AgentAuthStatus::Failed {
                    message: message.clone(),
                    instructions,
                };
                sink.thread.push_debug_event(AgentDebugEvent {
                    message: "Authentication failed".to_string(),
                });
                Err(error)
            }
        }
    }
}

struct ThreadEventSink<'a> {
    thread: &'a mut AgentThreadState,
}

impl AgentEventSink for ThreadEventSink<'_> {
    fn emit(&mut self, event: AgentRuntimeEvent) {
        apply_runtime_event(self.thread, event);
    }
}

pub fn apply_runtime_event(thread: &mut AgentThreadState, event: AgentRuntimeEvent) {
    match event {
        AgentRuntimeEvent::Initialized => thread.status = AgentThreadStatus::Starting,
        AgentRuntimeEvent::AuthRequired { instructions } => {
            thread.status = AgentThreadStatus::AuthRequired;
            thread.auth_status = AgentAuthStatus::Required {
                instructions: instructions.clone(),
            };
            thread.push_debug_event(AgentDebugEvent {
                message: "Authentication required".to_string(),
            });
            thread
                .transcript
                .push(AgentTranscriptEntry::agent(instructions));
        }
        AgentRuntimeEvent::Ready => {
            thread.status = AgentThreadStatus::Ready;
            thread.auth_status = AgentAuthStatus::Authenticated;
        }
        AgentRuntimeEvent::AgentMessageChunk(text) => {
            apply_agent_update(thread, AgentUpdate::AgentMessageChunk(text));
        }
        AgentRuntimeEvent::ThoughtChunk(text) => {
            apply_agent_update(thread, AgentUpdate::ThoughtChunk(text));
        }
        AgentRuntimeEvent::ToolCall { id, title, status } => {
            apply_agent_update(thread, AgentUpdate::ToolCall { id, title, status });
        }
        AgentRuntimeEvent::ToolCallUpdate { id, title, status } => {
            apply_agent_update(thread, AgentUpdate::ToolCallUpdate { id, title, status });
        }
        AgentRuntimeEvent::Plan(entries) => apply_agent_update(thread, AgentUpdate::Plan(entries)),
        AgentRuntimeEvent::AvailableCommands(commands) => {
            apply_agent_update(thread, AgentUpdate::AvailableCommands(commands));
        }
        AgentRuntimeEvent::AvailableModes { modes, current } => {
            apply_agent_update(thread, AgentUpdate::AvailableModes { modes, current });
        }
        AgentRuntimeEvent::ConfigOptions(options) => {
            apply_agent_update(thread, AgentUpdate::ConfigOptions(options));
        }
        AgentRuntimeEvent::CurrentMode(current) => {
            apply_agent_update(thread, AgentUpdate::CurrentMode(current));
        }
        AgentRuntimeEvent::NeedsPermission { id, description } => {
            apply_agent_update(thread, AgentUpdate::NeedsPermission { id, description });
        }
        AgentRuntimeEvent::Failed(message) => {
            thread.status = AgentThreadStatus::Failed { message };
        }
    }
}

pub fn apply_agent_update(thread: &mut AgentThreadState, update: AgentUpdate) {
    match update {
        AgentUpdate::AgentMessageChunk(text) => {
            thread.transcript.push(AgentTranscriptEntry::agent(text));
        }
        AgentUpdate::ThoughtChunk(text) => {
            thread.transcript.push(AgentTranscriptEntry {
                role: super::AgentTranscriptRole::Thought,
                text,
            });
        }
        AgentUpdate::ToolCall { id, title, status } => {
            if let Some(tool_call) = thread.tool_calls.iter_mut().find(|call| call.id == id) {
                tool_call.title = title;
                tool_call.status = status;
            } else {
                thread
                    .tool_calls
                    .push(AgentToolCallState { id, title, status });
            }
        }
        AgentUpdate::ToolCallUpdate { id, title, status } => {
            if let Some(tool_call) = thread.tool_calls.iter_mut().find(|call| call.id == id) {
                if let Some(title) = title {
                    tool_call.title = title;
                }
                if let Some(status) = status {
                    tool_call.status = status;
                }
            } else {
                thread.tool_calls.push(AgentToolCallState {
                    id,
                    title: title.unwrap_or_default(),
                    status: status.unwrap_or_default(),
                });
            }
        }
        AgentUpdate::Plan(entries) => thread.plans.push(AgentPlanState { entries }),
        AgentUpdate::AvailableCommands(commands) => thread.available_commands = commands,
        AgentUpdate::AvailableModes { modes, current } => {
            thread.available_modes = modes;
            thread.current_mode = current;
        }
        AgentUpdate::CurrentMode(current) => thread.current_mode = Some(current),
        AgentUpdate::ConfigOptions(options) => thread.config_options = options,
        AgentUpdate::NeedsPermission { id, description } => {
            thread
                .pending_permissions
                .push(AgentPermissionRequest { id, description });
        }
        AgentUpdate::Error(message) => {
            thread.push_debug_event(AgentDebugEvent { message });
        }
    }
}

fn is_client_callback_method(method: &str) -> bool {
    matches!(
        method,
        "session/request_permission"
            | "fs/read_text_file"
            | "fs/write_text_file"
            | "terminal/create"
            | "terminal/output"
            | "terminal/wait_for_exit"
            | "terminal/kill"
            | "terminal/release"
    )
}

fn terminal_command(command: &str, args: &[String]) -> String {
    if args.is_empty() {
        command.to_string()
    } else {
        // TODO: Quote arguments for display/permission prompts instead of flattening with spaces.
        std::iter::once(command)
            .chain(args.iter().map(String::as_str))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

fn parse_terminal_id(id: &str) -> Result<AgentTerminalHandle> {
    Ok(AgentTerminalHandle(
        id.parse()
            .with_context(|| format!("invalid terminal id '{id}'"))?,
    ))
}

fn terminal_exit_status(
    status: AgentTerminalStatus,
) -> agent_client_protocol::schema::TerminalExitStatus {
    let acp_status = agent_client_protocol::schema::TerminalExitStatus::new();
    match status {
        AgentTerminalStatus::Running => acp_status,
        AgentTerminalStatus::Exited(code) => acp_status.exit_code(code.map(|code| code as u32)),
        AgentTerminalStatus::Failed => acp_status.signal("failed"),
    }
}

fn permission_description(request: &PermissionRequestKind) -> String {
    match request {
        PermissionRequestKind::ReadFile(path) => format!("read file {}", path.display()),
        PermissionRequestKind::WriteFile(path) => format!("write file {}", path.display()),
        PermissionRequestKind::RunTerminal { command } => format!("run terminal command {command}"),
    }
}

fn agent_runtime_event_from_update(update: AgentUpdate) -> AgentRuntimeEvent {
    match update {
        AgentUpdate::AgentMessageChunk(text) => AgentRuntimeEvent::AgentMessageChunk(text),
        AgentUpdate::ThoughtChunk(text) => AgentRuntimeEvent::ThoughtChunk(text),
        AgentUpdate::ToolCall { id, title, status } => {
            AgentRuntimeEvent::ToolCall { id, title, status }
        }
        AgentUpdate::ToolCallUpdate { id, title, status } => {
            AgentRuntimeEvent::ToolCallUpdate { id, title, status }
        }
        AgentUpdate::Plan(entries) => AgentRuntimeEvent::Plan(entries),
        AgentUpdate::AvailableCommands(commands) => AgentRuntimeEvent::AvailableCommands(commands),
        AgentUpdate::AvailableModes { modes, current } => {
            AgentRuntimeEvent::AvailableModes { modes, current }
        }
        AgentUpdate::CurrentMode(current) => AgentRuntimeEvent::CurrentMode(current),
        AgentUpdate::ConfigOptions(options) => AgentRuntimeEvent::ConfigOptions(options),
        AgentUpdate::NeedsPermission { id, description } => {
            AgentRuntimeEvent::NeedsPermission { id, description }
        }
        AgentUpdate::Error(message) => AgentRuntimeEvent::Failed(message),
    }
}

fn agent_config_option_from_acp(
    option: agent_client_protocol::schema::SessionConfigOption,
) -> AgentConfigOption {
    use agent_client_protocol::schema::SessionConfigKind;

    let mut value = None;
    let mut options = Vec::new();
    if let SessionConfigKind::Select(select) = option.kind {
        value = Some(select.current_value.0.to_string());
        options = match select.options {
            agent_client_protocol::schema::SessionConfigSelectOptions::Ungrouped(options) => {
                options
                    .into_iter()
                    .map(|option| AgentConfigValueOption {
                        id: option.value.0.to_string(),
                        label: option.name,
                    })
                    .collect()
            }
            agent_client_protocol::schema::SessionConfigSelectOptions::Grouped(groups) => groups
                .into_iter()
                .flat_map(|group| group.options)
                .map(|option| AgentConfigValueOption {
                    id: option.value.0.to_string(),
                    label: option.name,
                })
                .collect(),
            #[allow(unreachable_patterns)]
            _ => Vec::new(),
        };
    }

    AgentConfigOption {
        id: option.id.0.to_string(),
        label: option.name,
        value,
        options,
    }
}

/// Converts ACP `SessionUpdate` notifications into Alas-owned updates.
///
/// ACP 0.11 sends available modes on session creation/resume responses and only sends current mode
/// changes through `SessionUpdate`, so callers should map response `modes` separately into
/// `AgentUpdate::AvailableModes` when wiring the real process connection.
pub fn agent_update_from_acp_session_update(
    update: agent_client_protocol::schema::SessionUpdate,
) -> Option<AgentUpdate> {
    use agent_client_protocol::schema::{ContentBlock, SessionUpdate};

    match update {
        SessionUpdate::AgentMessageChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => Some(AgentUpdate::AgentMessageChunk(text.text)),
            other => Some(AgentUpdate::Error(format!(
                "Unsupported ACP agent message content: {other:?}"
            ))),
        },
        SessionUpdate::AgentThoughtChunk(chunk) => match chunk.content {
            ContentBlock::Text(text) => Some(AgentUpdate::ThoughtChunk(text.text)),
            other => Some(AgentUpdate::Error(format!(
                "Unsupported ACP thought content: {other:?}"
            ))),
        },
        SessionUpdate::ToolCall(tool_call) => Some(AgentUpdate::ToolCall {
            id: tool_call.tool_call_id.0.to_string(),
            title: tool_call.title,
            status: format!("{:?}", tool_call.status),
        }),
        SessionUpdate::ToolCallUpdate(update) => Some(AgentUpdate::ToolCallUpdate {
            id: update.tool_call_id.0.to_string(),
            title: update.fields.title,
            status: update.fields.status.map(|status| format!("{status:?}")),
        }),
        SessionUpdate::Plan(plan) => Some(AgentUpdate::Plan(
            plan.entries
                .into_iter()
                .map(|entry| entry.content)
                .collect(),
        )),
        SessionUpdate::AvailableCommandsUpdate(update) => Some(AgentUpdate::AvailableCommands(
            update
                .available_commands
                .into_iter()
                .map(|command| AgentSlashCommand {
                    name: command.name,
                    description: Some(command.description),
                })
                .collect(),
        )),
        SessionUpdate::CurrentModeUpdate(update) => Some(AgentUpdate::CurrentMode(
            update.current_mode_id.0.to_string(),
        )),
        SessionUpdate::ConfigOptionUpdate(update) => Some(AgentUpdate::ConfigOptions(
            update
                .config_options
                .into_iter()
                .map(agent_config_option_from_acp)
                .collect(),
        )),
        SessionUpdate::UserMessageChunk(_) => None,
        SessionUpdate::SessionInfoUpdate(update) => update
            .title
            .take()
            .map(|title| AgentUpdate::Error(format!("ACP session title update ignored: {title}"))),
        #[allow(unreachable_patterns)]
        other => Some(AgentUpdate::Error(format!(
            "Unsupported ACP session update: {other:?}"
        ))),
    }
}
