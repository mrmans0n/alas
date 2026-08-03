use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fmt;

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct BrokerId(pub String);

impl BrokerId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
pub struct BrokerGeneration(pub u64);

impl BrokerGeneration {
    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
pub struct EventCursor(pub u64);

impl EventCursor {
    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub fn value(self) -> u64 {
        self.0
    }

    fn next(self) -> Self {
        Self(self.0 + 1)
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct OperationKey(pub String);

impl OperationKey {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
pub struct AdapterRequestId(pub u64);

impl AdapterRequestId {
    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JSONRPCErrorObject {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdapterRPCOutcome {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JSONRPCErrorObject>,
}

impl AdapterRPCOutcome {
    pub fn result(result: Value) -> Self {
        Self {
            result: Some(result),
            error: None,
        }
    }

    pub fn error(error: JSONRPCErrorObject) -> Self {
        Self {
            result: None,
            error: Some(error),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BrokerTurnState {
    Idle,
    Sending,
    Streaming,
    AwaitingInput,
    Cancelling,
    Completed,
    Ambiguous,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PendingClientRequestKind {
    Permission,
    Question,
    Elicitation,
    File,
    Terminal,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ACPBrokerMetadata {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub alas_session_id: String,
    pub adapter_program: String,
    pub adapter_args: Vec<String>,
    pub cwd: String,
    pub env_keys: Vec<String>,
    pub created_at_millis: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationStart {
    pub operation_key: OperationKey,
    pub adapter_request_id: AdapterRequestId,
    pub replayed: bool,
    pub terminal_outcome: Option<AdapterRPCOutcome>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingClientRequest {
    pub request_id: String,
    pub adapter_request_id: Value,
    pub kind: PendingClientRequestKind,
    pub payload: Value,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrokerEvent {
    pub cursor: EventCursor,
    pub kind: BrokerEventKind,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    tag = "type"
)]
pub enum BrokerEventKind {
    Initialized {
        result: Value,
    },
    RemoteSessionReady {
        result: Value,
    },
    TurnStateChanged {
        state: BrokerTurnState,
    },
    PendingRequest {
        request: PendingClientRequest,
    },
    PendingRequestResolved {
        request_id: String,
        response: AdapterRPCOutcome,
    },
    OperationStarted {
        operation_key: OperationKey,
        adapter_request_id: AdapterRequestId,
        method: String,
        /// Always null. See `OperationSnapshot::params`.
        params: Value,
    },
    OperationCompleted {
        operation_key: OperationKey,
        outcome: AdapterRPCOutcome,
    },
    AdapterNotification {
        method: String,
        params: Value,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ACPBrokerSnapshot {
    pub metadata: ACPBrokerMetadata,
    pub initialize_result: Option<Value>,
    pub remote_session_result: Option<Value>,
    pub turn_state: BrokerTurnState,
    pub acknowledged_cursor: EventCursor,
    pub journal_tail: EventCursor,
    pub pending_requests: Vec<PendingClientRequest>,
    pub operations: Vec<OperationSnapshot>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationSnapshot {
    pub operation_key: OperationKey,
    pub adapter_request_id: AdapterRequestId,
    pub method: String,
    /// Always null, and deliberately still emitted.
    ///
    /// The real params are not sent — nothing reads them, and a prompt's can
    /// run to hundreds of megabytes that the reply would otherwise carry (see
    /// `snapshot`). Dropping the key outright is what cannot be done: a
    /// broker outlives the app that started it, so a client from an earlier
    /// build can adopt this one, and its decoder requires the key to be
    /// present. Six bytes buys that; omitting them would leave such a client
    /// unable to adopt or even close the broker.
    pub params: Value,
    pub terminal_outcome: Option<AdapterRPCOutcome>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BrokerErrorKind {
    AlreadyInitialized,
    AlreadyHasRemoteSession,
    CursorBeyondJournalTail,
    CursorBehindAcknowledged,
    OperationKeyPayloadMismatch,
    OperationNotFound,
    OperationAlreadyCompletedWithDifferentResult,
    PendingRequestAlreadyExists,
    PendingRequestAlreadyResolved,
    PendingRequestNotFound,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BrokerError {
    kind: BrokerErrorKind,
    message: String,
}

impl BrokerError {
    pub fn kind(&self) -> BrokerErrorKind {
        self.kind
    }

    fn new(kind: BrokerErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

impl fmt::Display for BrokerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for BrokerError {}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OperationFingerprint {
    method: String,
    params: Value,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OperationRecord {
    key: OperationKey,
    fingerprint: OperationFingerprint,
    adapter_request_id: AdapterRequestId,
    terminal_outcome: Option<AdapterRPCOutcome>,
    completed_cursor: Option<EventCursor>,
}

#[derive(Clone, Debug)]
pub struct ACPBrokerState {
    metadata: ACPBrokerMetadata,
    initialize_result: Option<Value>,
    remote_session_result: Option<Value>,
    next_event_cursor: EventCursor,
    acknowledged_cursor: EventCursor,
    next_adapter_request_id: u64,
    turn_state: BrokerTurnState,
    journal: Vec<BrokerEvent>,
    operations: HashMap<OperationKey, OperationRecord>,
    pending_requests: HashMap<String, PendingClientRequest>,
    resolved_requests: HashSet<String>,
}

impl ACPBrokerState {
    pub fn new(metadata: ACPBrokerMetadata) -> Self {
        Self {
            metadata,
            initialize_result: None,
            remote_session_result: None,
            next_event_cursor: EventCursor(1),
            acknowledged_cursor: EventCursor(0),
            next_adapter_request_id: 1,
            turn_state: BrokerTurnState::Idle,
            journal: Vec::new(),
            operations: HashMap::new(),
            pending_requests: HashMap::new(),
            resolved_requests: HashSet::new(),
        }
    }

    pub fn metadata(&self) -> &ACPBrokerMetadata {
        &self.metadata
    }

    pub fn acknowledged_cursor(&self) -> EventCursor {
        self.acknowledged_cursor
    }

    pub fn journal_tail(&self) -> EventCursor {
        EventCursor(self.next_event_cursor.0.saturating_sub(1))
    }

    pub fn record_initialize_result(&mut self, result: Value) -> Result<EventCursor, BrokerError> {
        if self.initialize_result.is_some() {
            return Err(BrokerError::new(
                BrokerErrorKind::AlreadyInitialized,
                "broker generation already recorded initialize result",
            ));
        }
        self.initialize_result = Some(result.clone());
        Ok(self.push_event(BrokerEventKind::Initialized { result }))
    }

    pub fn record_remote_session_result(
        &mut self,
        result: Value,
    ) -> Result<EventCursor, BrokerError> {
        if self.remote_session_result.is_some() {
            return Err(BrokerError::new(
                BrokerErrorKind::AlreadyHasRemoteSession,
                "broker generation already recorded remote session result",
            ));
        }
        self.remote_session_result = Some(result.clone());
        Ok(self.push_event(BrokerEventKind::RemoteSessionReady { result }))
    }

    pub fn begin_operation(
        &mut self,
        operation_key: OperationKey,
        method: impl Into<String>,
        params: Value,
    ) -> Result<OperationStart, BrokerError> {
        let fingerprint = OperationFingerprint {
            method: method.into(),
            params,
        };

        if let Some(record) = self.operations.get(&operation_key) {
            if record.fingerprint != fingerprint {
                return Err(BrokerError::new(
                    BrokerErrorKind::OperationKeyPayloadMismatch,
                    "operation key was reused with a different payload",
                ));
            }
            return Ok(OperationStart {
                operation_key,
                adapter_request_id: record.adapter_request_id,
                replayed: true,
                terminal_outcome: record.terminal_outcome.clone(),
            });
        }

        let adapter_request_id = AdapterRequestId(self.next_adapter_request_id);
        self.next_adapter_request_id += 1;
        let record = OperationRecord {
            key: operation_key.clone(),
            fingerprint,
            adapter_request_id,
            terminal_outcome: None,
            completed_cursor: None,
        };
        self.push_event(BrokerEventKind::OperationStarted {
            operation_key: operation_key.clone(),
            adapter_request_id,
            method: record.fingerprint.method.clone(),
            params: Value::Null,
        });
        self.operations.insert(operation_key.clone(), record);

        Ok(OperationStart {
            operation_key,
            adapter_request_id,
            replayed: false,
            terminal_outcome: None,
        })
    }

    pub fn complete_operation(
        &mut self,
        operation_key: &OperationKey,
        outcome: AdapterRPCOutcome,
    ) -> Result<AdapterRPCOutcome, BrokerError> {
        let record = self.operations.get_mut(operation_key).ok_or_else(|| {
            BrokerError::new(
                BrokerErrorKind::OperationNotFound,
                "operation key was not registered",
            )
        })?;

        if let Some(existing_outcome) = &record.terminal_outcome {
            if existing_outcome == &outcome {
                return Ok(existing_outcome.clone());
            }
            return Err(BrokerError::new(
                BrokerErrorKind::OperationAlreadyCompletedWithDifferentResult,
                "operation was already completed with a different result",
            ));
        }

        record.terminal_outcome = Some(outcome.clone());
        let cursor = self.push_event(BrokerEventKind::OperationCompleted {
            operation_key: operation_key.clone(),
            outcome: outcome.clone(),
        });
        if let Some(record) = self.operations.get_mut(operation_key) {
            record.completed_cursor = Some(cursor);
        }
        Ok(outcome)
    }

    pub fn set_turn_state(&mut self, state: BrokerTurnState) -> Result<EventCursor, BrokerError> {
        self.turn_state = state;
        Ok(self.push_event(BrokerEventKind::TurnStateChanged { state }))
    }

    pub fn add_adapter_notification(
        &mut self,
        method: impl Into<String>,
        params: Value,
    ) -> EventCursor {
        self.push_event(BrokerEventKind::AdapterNotification {
            method: method.into(),
            params,
        })
    }

    pub fn add_pending_request(
        &mut self,
        request_id: impl Into<String>,
        adapter_request_id: Value,
        kind: PendingClientRequestKind,
        payload: Value,
    ) -> Result<EventCursor, BrokerError> {
        let request_id = request_id.into();
        if self.pending_requests.contains_key(&request_id) {
            return Err(BrokerError::new(
                BrokerErrorKind::PendingRequestAlreadyExists,
                "pending request already exists",
            ));
        }
        self.resolved_requests.remove(&request_id);

        let request = PendingClientRequest {
            request_id: request_id.clone(),
            adapter_request_id,
            kind,
            payload,
        };
        self.pending_requests.insert(request_id, request.clone());
        Ok(self.push_event(BrokerEventKind::PendingRequest { request }))
    }

    pub fn respond_to_pending_request(
        &mut self,
        request_id: &str,
        response: AdapterRPCOutcome,
    ) -> Result<EventCursor, BrokerError> {
        if self.resolved_requests.contains(request_id) {
            return Err(BrokerError::new(
                BrokerErrorKind::PendingRequestAlreadyResolved,
                "pending request was already resolved",
            ));
        }
        if self.pending_requests.remove(request_id).is_none() {
            return Err(BrokerError::new(
                BrokerErrorKind::PendingRequestNotFound,
                "pending request was not found",
            ));
        }

        self.resolved_requests.insert(request_id.to_string());
        Ok(self.push_event(BrokerEventKind::PendingRequestResolved {
            request_id: request_id.to_string(),
            response,
        }))
    }

    pub fn ack(&mut self, cursor: EventCursor) -> Result<(), BrokerError> {
        if cursor > self.journal_tail() {
            return Err(BrokerError::new(
                BrokerErrorKind::CursorBeyondJournalTail,
                "acknowledged cursor is beyond the journal tail",
            ));
        }
        if cursor < self.acknowledged_cursor {
            return Err(BrokerError::new(
                BrokerErrorKind::CursorBehindAcknowledged,
                "acknowledged cursor moved backwards",
            ));
        }
        self.acknowledged_cursor = cursor;
        self.journal.retain(|event| event.cursor > cursor);
        self.operations.retain(|_, record| {
            record
                .completed_cursor
                .map(|completed_cursor| completed_cursor > cursor)
                .unwrap_or(true)
        });
        Ok(())
    }

    pub fn replay_after_ack(&self) -> Vec<BrokerEvent> {
        self.replay_after(self.acknowledged_cursor)
            .expect("acknowledged cursor is always within the journal")
    }

    pub fn replay_after(&self, cursor: EventCursor) -> Result<Vec<BrokerEvent>, BrokerError> {
        if cursor > self.journal_tail() {
            return Err(BrokerError::new(
                BrokerErrorKind::CursorBeyondJournalTail,
                "replay cursor is beyond the journal tail",
            ));
        }
        Ok(self
            .journal
            .iter()
            .filter(|event| event.cursor > cursor)
            .cloned()
            .collect())
    }

    pub fn snapshot(&self) -> ACPBrokerSnapshot {
        let mut pending_requests: Vec<_> = self.pending_requests.values().cloned().collect();
        pending_requests.sort_by(|lhs, rhs| lhs.request_id.cmp(&rhs.request_id));

        let mut operations: Vec<_> = self
            .operations
            .values()
            .map(|record| OperationSnapshot {
                operation_key: record.key.clone(),
                adapter_request_id: record.adapter_request_id,
                method: record.fingerprint.method.clone(),
                params: Value::Null,
                terminal_outcome: record.terminal_outcome.clone(),
            })
            .collect();
        operations.sort_by(|lhs, rhs| lhs.operation_key.as_str().cmp(rhs.operation_key.as_str()));

        ACPBrokerSnapshot {
            metadata: self.metadata.clone(),
            initialize_result: self.initialize_result.clone(),
            remote_session_result: self.remote_session_result.clone(),
            turn_state: self.turn_state,
            acknowledged_cursor: self.acknowledged_cursor,
            journal_tail: self.journal_tail(),
            pending_requests,
            operations,
        }
    }

    fn push_event(&mut self, kind: BrokerEventKind) -> EventCursor {
        let cursor = self.next_event_cursor;
        self.next_event_cursor = self.next_event_cursor.next();
        self.journal.push(BrokerEvent { cursor, kind });
        cursor
    }
}
