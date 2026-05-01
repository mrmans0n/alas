use std::path::PathBuf;

use anyhow::{Result, bail};

use super::{AcpConnection, AgentEventSink, AgentRuntimeEvent};

#[derive(Clone, Debug, Default)]
pub struct FakeAcpConnection {
    new_session_id: Option<String>,
    new_session_events: Vec<AgentRuntimeEvent>,
    prompt_events: Vec<AgentRuntimeEvent>,
    prompt_error: Option<String>,
    resume_error: Option<String>,
    resume_events: Vec<AgentRuntimeEvent>,
    cancelled_sessions: Vec<String>,
    set_modes: Vec<(String, String)>,
    set_mode_error: Option<String>,
    set_config_options: Vec<(String, String, String)>,
    set_config_option_error: Option<String>,
    auth_error: Option<String>,
    authenticated_methods: Vec<String>,
}

impl FakeAcpConnection {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_new_session(
        mut self,
        session_id: impl Into<String>,
        events: Vec<AgentRuntimeEvent>,
    ) -> Self {
        self.new_session_id = Some(session_id.into());
        self.new_session_events = events;
        self
    }

    pub fn with_prompt_update(mut self, events: Vec<AgentRuntimeEvent>) -> Self {
        self.prompt_events = events;
        self
    }

    pub fn with_prompt_error(mut self, message: impl Into<String>) -> Self {
        self.prompt_error = Some(message.into());
        self
    }

    pub fn with_resume_update(mut self, events: Vec<AgentRuntimeEvent>) -> Self {
        self.resume_events = events;
        self
    }

    pub fn with_resume_error(mut self, message: impl Into<String>) -> Self {
        self.resume_error = Some(message.into());
        self
    }

    pub fn with_set_mode_error(mut self, message: impl Into<String>) -> Self {
        self.set_mode_error = Some(message.into());
        self
    }

    pub fn with_set_config_option_error(mut self, message: impl Into<String>) -> Self {
        self.set_config_option_error = Some(message.into());
        self
    }

    pub fn with_auth_error(mut self, message: impl Into<String>) -> Self {
        self.auth_error = Some(message.into());
        self
    }

    pub fn cancelled_sessions(&self) -> &[String] {
        &self.cancelled_sessions
    }

    pub fn authenticated_methods(&self) -> &[String] {
        &self.authenticated_methods
    }

    pub fn set_modes(&self) -> &[(String, String)] {
        &self.set_modes
    }

    pub fn set_config_options(&self) -> &[(String, String, String)] {
        &self.set_config_options
    }
}

impl AcpConnection for FakeAcpConnection {
    fn initialize(&mut self, sink: &mut dyn AgentEventSink) -> Result<()> {
        sink.emit(AgentRuntimeEvent::Initialized);
        Ok(())
    }

    fn new_session(
        &mut self,
        _worktree_path: PathBuf,
        sink: &mut dyn AgentEventSink,
    ) -> Result<Option<String>> {
        for event in self.new_session_events.clone() {
            sink.emit(event);
        }
        Ok(self.new_session_id.clone())
    }

    fn resume_session(&mut self, _session_id: String, sink: &mut dyn AgentEventSink) -> Result<()> {
        if let Some(error) = &self.resume_error {
            bail!(error.clone());
        }

        for event in self.resume_events.clone() {
            sink.emit(event);
        }
        Ok(())
    }

    fn prompt(
        &mut self,
        _session_id: String,
        _prompt: String,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()> {
        if let Some(error) = &self.prompt_error {
            bail!(error.clone());
        }

        for event in self.prompt_events.clone() {
            sink.emit(event);
        }
        Ok(())
    }

    fn cancel(&mut self, session_id: String) -> Result<()> {
        self.cancelled_sessions.push(session_id);
        Ok(())
    }

    fn set_mode(
        &mut self,
        session_id: String,
        mode_id: String,
        sink: &mut dyn AgentEventSink,
    ) -> Result<()> {
        if let Some(error) = &self.set_mode_error {
            bail!(error.clone());
        }
        self.set_modes.push((session_id, mode_id.clone()));
        sink.emit(AgentRuntimeEvent::CurrentMode(mode_id));
        Ok(())
    }

    fn set_config_option(
        &mut self,
        session_id: String,
        config_id: String,
        value_id: String,
        _sink: &mut dyn AgentEventSink,
    ) -> Result<()> {
        if let Some(error) = &self.set_config_option_error {
            bail!(error.clone());
        }
        self.set_config_options
            .push((session_id, config_id, value_id));
        Ok(())
    }

    fn authenticate(&mut self, method_id: String, _sink: &mut dyn AgentEventSink) -> Result<()> {
        if let Some(error) = &self.auth_error {
            bail!(error.clone());
        }
        self.authenticated_methods.push(method_id);
        Ok(())
    }
}
