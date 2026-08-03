use alas_helper::acp_broker::{
    ACPBrokerMetadata, ACPBrokerState, AdapterRPCOutcome, AdapterRequestId, BrokerErrorKind,
    BrokerEventKind, BrokerGeneration, BrokerId, BrokerTurnState, EventCursor, JSONRPCErrorObject,
    OperationKey, PendingClientRequestKind,
};
use alas_helper::acp_broker_protocol::{
    AcpAckParams, AcpAttachParams, AcpBrokerMethod, AcpCloseParams, AcpDetachParams, AcpListResult,
    AcpOpenParams, AcpOpenResult, AcpRespondParams, AcpSendParams,
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Value, json};

fn metadata() -> ACPBrokerMetadata {
    ACPBrokerMetadata {
        broker_id: BrokerId::new("session-local-1"),
        generation: BrokerGeneration::new(7),
        alas_session_id: "alas-session-1".to_string(),
        adapter_program: "codex-acp".to_string(),
        adapter_args: vec!["--stdio".to_string()],
        cwd: "/tmp/project".to_string(),
        env_keys: vec!["OPENAI_API_KEY".to_string(), "SECRET_TOKEN".to_string()],
        created_at_millis: 123,
    }
}

fn broker() -> ACPBrokerState {
    ACPBrokerState::new(metadata())
}

fn round_trip<T>(value: &T) -> T
where
    T: Serialize + DeserializeOwned,
{
    serde_json::from_value(serde_json::to_value(value).unwrap()).unwrap()
}

#[test]
fn records_initialize_and_session_once_per_generation() {
    let mut broker = broker();

    broker
        .record_initialize_result(json!({"protocolVersion": 1}))
        .unwrap();
    broker
        .record_remote_session_result(json!({"sessionId": "remote-1"}))
        .unwrap();

    assert_eq!(
        broker
            .record_initialize_result(json!({"protocolVersion": 1}))
            .unwrap_err()
            .kind(),
        BrokerErrorKind::AlreadyInitialized
    );
    assert_eq!(
        broker
            .record_remote_session_result(json!({"sessionId": "remote-1"}))
            .unwrap_err()
            .kind(),
        BrokerErrorKind::AlreadyHasRemoteSession
    );

    let snapshot = broker.snapshot();
    assert_eq!(
        snapshot.initialize_result,
        Some(json!({"protocolVersion": 1}))
    );
    assert_eq!(
        snapshot.remote_session_result,
        Some(json!({"sessionId": "remote-1"}))
    );
}

#[test]
fn stable_request_ids_are_owned_by_operations_not_attachments() {
    let mut broker = broker();

    let first = broker
        .begin_operation(
            OperationKey::new("queue-item-1"),
            "session/prompt",
            json!({"prompt": "a"}),
        )
        .unwrap();
    let retried = broker
        .begin_operation(
            OperationKey::new("queue-item-1"),
            "session/prompt",
            json!({"prompt": "a"}),
        )
        .unwrap();
    let second = broker
        .begin_operation(
            OperationKey::new("queue-item-2"),
            "session/prompt",
            json!({"prompt": "b"}),
        )
        .unwrap();

    assert_eq!(first.adapter_request_id, retried.adapter_request_id);
    assert!(retried.replayed);
    assert_eq!(first.adapter_request_id.value(), 1);
    assert_eq!(second.adapter_request_id.value(), 2);
}

#[test]
fn operation_key_reuse_with_different_payload_is_rejected() {
    let mut broker = broker();
    broker
        .begin_operation(
            OperationKey::new("stable-key"),
            "session/prompt",
            json!({"prompt": "a"}),
        )
        .unwrap();

    assert_eq!(
        broker
            .begin_operation(
                OperationKey::new("stable-key"),
                "session/prompt",
                json!({"prompt": "b"}),
            )
            .unwrap_err()
            .kind(),
        BrokerErrorKind::OperationKeyPayloadMismatch
    );
}

#[test]
fn completed_operations_return_the_original_terminal_result_on_retry() {
    let mut broker = broker();
    broker
        .begin_operation(
            OperationKey::new("stable-key"),
            "session/prompt",
            json!({"prompt": "a"}),
        )
        .unwrap();
    broker
        .complete_operation(
            &OperationKey::new("stable-key"),
            AdapterRPCOutcome::result(json!({"ok": true})),
        )
        .unwrap();

    let retried = broker
        .begin_operation(
            OperationKey::new("stable-key"),
            "session/prompt",
            json!({"prompt": "a"}),
        )
        .unwrap();

    assert!(retried.replayed);
    assert_eq!(
        retried.terminal_outcome,
        Some(AdapterRPCOutcome::result(json!({"ok": true})))
    );
}

#[test]
fn completed_operations_replay_jsonrpc_errors() {
    let mut broker = broker();
    broker
        .begin_operation(
            OperationKey::new("stable-key"),
            "session/prompt",
            json!({"prompt": "a"}),
        )
        .unwrap();
    broker
        .complete_operation(
            &OperationKey::new("stable-key"),
            AdapterRPCOutcome::error(JSONRPCErrorObject {
                code: -32001,
                message: "denied".to_string(),
                data: None,
            }),
        )
        .unwrap();

    let retried = broker
        .begin_operation(
            OperationKey::new("stable-key"),
            "session/prompt",
            json!({"prompt": "a"}),
        )
        .unwrap();

    assert!(retried.replayed);
    assert_eq!(
        retried.terminal_outcome,
        Some(AdapterRPCOutcome::error(JSONRPCErrorObject {
            code: -32001,
            message: "denied".to_string(),
            data: None,
        }))
    );
}

#[test]
fn completing_operation_twice_with_different_result_is_rejected() {
    let mut broker = broker();
    broker
        .begin_operation(
            OperationKey::new("stable-key"),
            "session/prompt",
            json!({"prompt": "a"}),
        )
        .unwrap();
    broker
        .complete_operation(
            &OperationKey::new("stable-key"),
            AdapterRPCOutcome::result(json!({"ok": true})),
        )
        .unwrap();

    assert_eq!(
        broker
            .complete_operation(
                &OperationKey::new("stable-key"),
                AdapterRPCOutcome::result(json!({"ok": false})),
            )
            .unwrap_err()
            .kind(),
        BrokerErrorKind::OperationAlreadyCompletedWithDifferentResult
    );
}

#[test]
fn turn_state_covers_recovery_states() {
    let mut broker = broker();
    let states = [
        BrokerTurnState::Idle,
        BrokerTurnState::Sending,
        BrokerTurnState::Streaming,
        BrokerTurnState::AwaitingInput,
        BrokerTurnState::Cancelling,
        BrokerTurnState::Completed,
        BrokerTurnState::Ambiguous,
    ];

    for state in states {
        broker.set_turn_state(state).unwrap();
        assert_eq!(broker.snapshot().turn_state, state);
    }
}

#[test]
fn event_journal_replays_strictly_after_acknowledged_cursor() {
    let mut broker = broker();
    let first = broker.add_adapter_notification(
        "session/update",
        json!({"sessionId": "remote-1", "update": {"kind": "one"}}),
    );
    let second = broker.add_adapter_notification("session/update", json!({"kind": "two"}));
    let third = broker.set_turn_state(BrokerTurnState::Completed).unwrap();

    assert_eq!(first.value(), 1);
    assert_eq!(second.value(), 2);
    assert_eq!(third.value(), 3);

    let replay = broker.replay_after(EventCursor::new(1)).unwrap();
    assert_eq!(replay.len(), 2);
    assert_eq!(replay[0].cursor, second);
    assert_eq!(replay[1].cursor, third);
}

#[test]
fn acknowledgement_is_monotonic_and_bounded_by_journal_tail() {
    let mut broker = broker();
    broker.add_adapter_notification("session/update", json!({"kind": "one"}));
    broker.add_adapter_notification("session/update", json!({"kind": "two"}));

    broker.ack(EventCursor::new(1)).unwrap();
    assert_eq!(broker.acknowledged_cursor(), EventCursor::new(1));
    assert_eq!(broker.replay_after(EventCursor::new(0)).unwrap().len(), 1);
    assert_eq!(
        broker.ack(EventCursor::new(0)).unwrap_err().kind(),
        BrokerErrorKind::CursorBehindAcknowledged
    );
    assert_eq!(
        broker.ack(EventCursor::new(3)).unwrap_err().kind(),
        BrokerErrorKind::CursorBeyondJournalTail
    );
    assert_eq!(
        broker.replay_after(EventCursor::new(3)).unwrap_err().kind(),
        BrokerErrorKind::CursorBeyondJournalTail
    );
}

#[test]
fn acknowledgement_prunes_events_without_reusing_cursors() {
    let mut broker = broker();
    broker.add_adapter_notification("session/update", json!({"kind": "one"}));
    broker.add_adapter_notification("session/update", json!({"kind": "two"}));

    broker.ack(EventCursor::new(2)).unwrap();
    assert!(broker.replay_after(EventCursor::new(0)).unwrap().is_empty());
    assert_eq!(broker.snapshot().journal_tail, EventCursor::new(2));

    let third = broker.add_adapter_notification("session/update", json!({"kind": "three"}));
    assert_eq!(third, EventCursor::new(3));
    let replay = broker.replay_after(EventCursor::new(2)).unwrap();
    assert_eq!(replay.len(), 1);
    assert_eq!(replay[0].cursor, third);
}

#[test]
fn acknowledgement_prunes_completed_operation_records() {
    let mut broker = broker();
    let key = OperationKey::new("prompt-1");
    broker
        .begin_operation(key.clone(), "session/prompt", json!({"prompt": "large"}))
        .unwrap();
    broker
        .complete_operation(
            &key,
            AdapterRPCOutcome::result(json!({"stopReason": "end_turn"})),
        )
        .unwrap();

    let completed_tail = broker.journal_tail();
    assert_eq!(broker.snapshot().operations.len(), 1);

    broker.ack(completed_tail).unwrap();
    assert!(broker.snapshot().operations.is_empty());
    assert_eq!(broker.journal_tail(), completed_tail);
}

#[test]
fn pending_request_variants_are_snapshotted_and_answered_once() {
    let mut broker = broker();
    let variants = [
        ("permission", PendingClientRequestKind::Permission),
        ("question", PendingClientRequestKind::Question),
        ("elicitation", PendingClientRequestKind::Elicitation),
        ("file", PendingClientRequestKind::File),
        ("terminal", PendingClientRequestKind::Terminal),
    ];

    for (request_id, kind) in variants {
        broker
            .add_pending_request(
                request_id,
                json!(request_id),
                kind,
                json!({"requestId": request_id}),
            )
            .unwrap();
    }

    assert_eq!(broker.snapshot().pending_requests.len(), 5);

    broker
        .respond_to_pending_request(
            "permission",
            AdapterRPCOutcome::result(json!({"outcome": "approved"})),
        )
        .unwrap();
    assert_eq!(
        broker
            .respond_to_pending_request(
                "permission",
                AdapterRPCOutcome::result(json!({"outcome": "approved"})),
            )
            .unwrap_err()
            .kind(),
        BrokerErrorKind::PendingRequestAlreadyResolved
    );
    broker
        .add_pending_request(
            "permission",
            json!("permission"),
            PendingClientRequestKind::Permission,
            json!({"requestId": "permission", "attempt": 2}),
        )
        .unwrap();
    broker
        .respond_to_pending_request(
            "permission",
            AdapterRPCOutcome::result(json!({"outcome": "approved-again"})),
        )
        .unwrap();

    let snapshot = broker.snapshot();
    assert_eq!(snapshot.pending_requests.len(), 4);
    assert_eq!(
        snapshot
            .pending_requests
            .iter()
            .map(|request| request.kind)
            .collect::<Vec<_>>(),
        vec![
            PendingClientRequestKind::Elicitation,
            PendingClientRequestKind::File,
            PendingClientRequestKind::Question,
            PendingClientRequestKind::Terminal
        ]
    );
}

#[test]
fn missing_pending_request_response_fails_closed() {
    let mut broker = broker();

    assert_eq!(
        broker
            .respond_to_pending_request("missing", AdapterRPCOutcome::result(json!({"ok": true})))
            .unwrap_err()
            .kind(),
        BrokerErrorKind::PendingRequestNotFound
    );
}

#[test]
fn duplicate_pending_request_ids_are_rejected() {
    let mut broker = broker();
    broker
        .add_pending_request(
            "permission",
            json!(1),
            PendingClientRequestKind::Permission,
            json!({}),
        )
        .unwrap();

    assert_eq!(
        broker
            .add_pending_request(
                "permission",
                json!(2),
                PendingClientRequestKind::Permission,
                json!({}),
            )
            .unwrap_err()
            .kind(),
        BrokerErrorKind::PendingRequestAlreadyExists
    );
}

/// A broker outlives the app build that started it, so a client from an
/// earlier build can adopt this one — and that client's decoder requires
/// `params` to be present on both wire shapes. The value is deliberately
/// null (the real params are hundreds of megabytes and nothing reads them),
/// but the key has to stay, or such a client cannot adopt or even close the
/// broker. Tidying the null away would be silently breaking.
#[test]
fn operation_params_stay_on_the_wire_as_a_null_placeholder() {
    let mut broker = broker();
    broker
        .begin_operation(
            OperationKey::new("prompt-1"),
            "session/prompt".to_string(),
            json!({"prompt": "hello"}),
        )
        .unwrap();

    let snapshot = serde_json::to_value(broker.snapshot()).unwrap();
    let operation = &snapshot["operations"][0];
    assert!(
        operation.get("params").is_some(),
        "snapshot operation dropped the params key: {operation}"
    );
    assert_eq!(operation["params"], Value::Null);

    let events = serde_json::to_value(broker.replay_after(EventCursor::new(0)).unwrap()).unwrap();
    let started = events
        .as_array()
        .unwrap()
        .iter()
        .find(|event| event["kind"]["type"] == "operationStarted")
        .expect("operationStarted event");
    assert!(
        started["kind"].get("params").is_some(),
        "operationStarted dropped the params key: {started}"
    );
    assert_eq!(started["kind"]["params"], Value::Null);
}

#[test]
fn snapshot_round_trip_excludes_secret_environment_values() {
    let mut broker = broker();
    broker
        .record_initialize_result(json!({"capabilities": {"tools": true}}))
        .unwrap();
    broker
        .begin_operation(
            OperationKey::new("secret-bearing-prompt"),
            "session/prompt",
            json!({"promptFingerprint": "canonical"}),
        )
        .unwrap();

    let snapshot = broker.snapshot();
    let encoded = serde_json::to_string(&snapshot).unwrap();
    let decoded = round_trip(&snapshot);

    assert_eq!(decoded, snapshot);
    assert!(encoded.contains("codex-acp"));
    assert!(encoded.contains("OPENAI_API_KEY"));
    assert!(!encoded.contains("sk-test"));
    assert!(encoded.contains("SECRET_TOKEN"));
    assert!(!encoded.contains("secret-value"));
}

#[test]
fn protocol_dtos_use_stable_wire_field_names() {
    let snapshot = broker().snapshot();
    let open = AcpOpenParams {
        broker_id: BrokerId::new("local-session"),
        session_id: "alas-session".to_string(),
        command: "codex-acp".to_string(),
        args: vec!["--stdio".to_string()],
        cwd: "/tmp/project".to_string(),
        env: json!({"OPENAI_API_KEY": "sk-test"}),
    };
    let send = AcpSendParams {
        broker_id: BrokerId::new("local-session"),
        generation: BrokerGeneration::new(1),
        operation_key: OperationKey::new("queue-item"),
        method: "session/prompt".to_string(),
        params: json!({"prompt": "hi"}),
    };

    assert_eq!(AcpBrokerMethod::Open.as_str(), "acp/open");
    assert_eq!(AcpBrokerMethod::Attach.as_str(), "acp/attach");
    assert_eq!(AcpBrokerMethod::Send.as_str(), "acp/send");
    assert_eq!(AcpBrokerMethod::Notify.as_str(), "acp/notify");
    assert_eq!(AcpBrokerMethod::Respond.as_str(), "acp/respond");
    assert_eq!(AcpBrokerMethod::Ack.as_str(), "acp/ack");
    assert_eq!(AcpBrokerMethod::Detach.as_str(), "acp/detach");
    assert_eq!(AcpBrokerMethod::Close.as_str(), "acp/close");
    assert_eq!(AcpBrokerMethod::List.as_str(), "acp/list");

    assert_eq!(
        serde_json::to_value(&open).unwrap(),
        json!({
            "brokerId": "local-session",
            "sessionId": "alas-session",
            "command": "codex-acp",
            "args": ["--stdio"],
            "cwd": "/tmp/project",
            "env": {"OPENAI_API_KEY": "sk-test"}
        })
    );
    assert_eq!(
        serde_json::to_value(&send).unwrap(),
        json!({
            "brokerId": "local-session",
            "generation": 1,
            "operationKey": "queue-item",
            "method": "session/prompt",
            "params": {"prompt": "hi"}
        })
    );

    let _: AcpOpenResult = round_trip(&AcpOpenResult {
        snapshot: snapshot.clone(),
        adopted: false,
    });
    let _: AcpAttachParams = round_trip(&AcpAttachParams {
        broker_id: BrokerId::new("local-session"),
        generation: BrokerGeneration::new(1),
        acknowledged_cursor: EventCursor::new(0),
    });
    let _: AcpRespondParams = round_trip(&AcpRespondParams {
        broker_id: BrokerId::new("local-session"),
        generation: BrokerGeneration::new(1),
        request_id: json!(1),
        operation_key: OperationKey::new("answer"),
        result: Some(Value::Null),
        error: None,
    });
    let _: AcpAckParams = round_trip(&AcpAckParams {
        broker_id: BrokerId::new("local-session"),
        generation: BrokerGeneration::new(1),
        cursor: EventCursor::new(0),
    });
    let _: AcpDetachParams = round_trip(&AcpDetachParams {
        broker_id: BrokerId::new("local-session"),
        generation: BrokerGeneration::new(1),
    });
    let _: AcpCloseParams = round_trip(&AcpCloseParams {
        broker_id: BrokerId::new("local-session"),
        generation: BrokerGeneration::new(1),
    });
    let _: AcpListResult = round_trip(&AcpListResult {
        brokers: vec![snapshot],
    });
}

#[test]
fn journal_contains_semantic_events_for_protocol_replay() {
    let mut broker = broker();
    broker
        .record_initialize_result(json!({"protocolVersion": 1}))
        .unwrap();
    broker
        .begin_operation(
            OperationKey::new("queue-item"),
            "session/prompt",
            json!({"prompt": "hi"}),
        )
        .unwrap();
    broker
        .complete_operation(
            &OperationKey::new("queue-item"),
            AdapterRPCOutcome::result(json!({"stopReason": "end_turn"})),
        )
        .unwrap();

    let replay = broker.replay_after(EventCursor::new(0)).unwrap();
    assert!(matches!(
        replay[0].kind,
        BrokerEventKind::Initialized { .. }
    ));
    assert!(matches!(
        replay[1].kind,
        BrokerEventKind::OperationStarted { .. }
    ));
    assert!(matches!(
        replay[2].kind,
        BrokerEventKind::OperationCompleted { .. }
    ));
}
