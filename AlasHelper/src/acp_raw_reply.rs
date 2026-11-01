use crate::acp_broker::{
    BrokerGeneration, BrokerId, EventCursor, OperationKey, PendingClientRequest,
};
use crate::acp_broker_protocol::{AcpRawJSONPayload, BrokerWireContext};
use serde::{Deserialize, Serialize};
use serde_json::{Value, value::RawValue};
use std::collections::HashMap;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RespondExactParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub pending_request_id: String,
    pub origin_cursor: EventCursor,
    pub operation_key: OperationKey,
    pub frame: AcpRawJSONPayload,
    pub wire_context: BrokerWireContext,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReplyStatus {
    InFlight,
    Written,
    WriteUncertain,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplyResult {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub pending_request_id: String,
    pub origin_cursor: EventCursor,
    pub operation_key: OperationKey,
    pub status: ReplyStatus,
}
impl RespondExactParams {
    pub fn result(&self, status: ReplyStatus) -> ReplyResult {
        ReplyResult {
            broker_id: self.broker_id.clone(),
            generation: self.generation,
            pending_request_id: self.pending_request_id.clone(),
            origin_cursor: self.origin_cursor,
            operation_key: self.operation_key.clone(),
            status,
        }
    }
    pub fn validate(&self) -> Result<Value, ReplyRejection> {
        if self.wire_context != BrokerWireContext::RawV2
            || self.generation.0 == 0
            || self.generation.0 > i64::MAX as u64
            || self.origin_cursor.0 == 0
            || self.origin_cursor.0 > i64::MAX as u64
            || self.operation_key.0.is_empty()
            || self.broker_id.0.is_empty()
        {
            return Err(ReplyRejection::Invalid);
        }
        validate_frame(self.frame.bytes())
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReplyRejection {
    Invalid,
    StaleOrigin,
    Conflict,
    Unavailable,
}
impl ReplyRejection {
    pub fn code(self) -> i64 {
        match self {
            Self::Invalid => -32077,
            Self::StaleOrigin => -32078,
            Self::Conflict => -32079,
            Self::Unavailable => -32080,
        }
    }
}

// Only envelope fields are interpreted. RawValue validates opaque JSON without
// projecting its number tokens into bounded numeric types.
fn fields(bytes: &[u8]) -> Result<HashMap<String, Box<RawValue>>, ReplyRejection> {
    struct Unique;
    impl<'de> serde::de::Visitor<'de> for Unique {
        type Value = HashMap<String, Box<RawValue>>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("a unique-key object")
        }
        fn visit_map<M: serde::de::MapAccess<'de>>(
            self,
            mut map: M,
        ) -> Result<Self::Value, M::Error> {
            let mut fields = HashMap::new();
            while let Some((key, value)) = map.next_entry::<String, Box<RawValue>>()? {
                if fields.insert(key, value).is_some() {
                    return Err(serde::de::Error::custom("duplicate envelope key"));
                }
            }
            Ok(fields)
        }
    }
    let mut decoder = serde_json::Deserializer::from_slice(bytes);
    let value = serde::de::Deserializer::deserialize_map(&mut decoder, Unique)
        .map_err(|_| ReplyRejection::Invalid)?;
    decoder.end().map_err(|_| ReplyRejection::Invalid)?;
    Ok(value)
}
pub fn validate_frame(bytes: &[u8]) -> Result<Value, ReplyRejection> {
    if bytes.iter().any(|b| *b == b'\r' || *b == b'\n') {
        return Err(ReplyRejection::Invalid);
    }
    let fields = fields(bytes)?;
    let version = fields
        .get("jsonrpc")
        .and_then(|v| serde_json::from_str::<String>(v.get()).ok());
    if version.as_deref() != Some("2.0")
        || fields.contains_key("method")
        || fields.contains_key("result") == fields.contains_key("error")
    {
        return Err(ReplyRejection::Invalid);
    }
    let id = fields.get("id").ok_or(ReplyRejection::Invalid)?;
    let id = serde_json::from_str::<String>(id.get())
        .ok()
        .map(Value::String)
        .or_else(|| serde_json::from_str::<i64>(id.get()).ok().map(Value::from))
        .ok_or(ReplyRejection::Invalid)?;
    if let Some(error) = fields.get("error") {
        let error_fields = self::fields(error.get().as_bytes())?;
        if error_fields
            .get("code")
            .and_then(|v| serde_json::from_str::<i32>(v.get()).ok())
            .is_none()
            || error_fields
                .get("message")
                .and_then(|v| serde_json::from_str::<String>(v.get()).ok())
                .is_none()
        {
            return Err(ReplyRejection::Invalid);
        }
    }
    Ok(id)
}

#[derive(Default)]
pub struct ReplyAttempts {
    attempts: HashMap<OperationKey, (RespondExactParams, ReplyStatus)>,
    origins: HashMap<(String, u64), OperationKey>,
}
impl ReplyAttempts {
    pub fn lookup(&self, p: &RespondExactParams) -> Result<Option<ReplyStatus>, ReplyRejection> {
        if let Some((original, status)) = self.attempts.get(&p.operation_key) {
            if original != p {
                return Err(ReplyRejection::Conflict);
            }
            return Ok(Some(*status));
        }
        if self
            .origins
            .contains_key(&(p.pending_request_id.clone(), p.origin_cursor.0))
        {
            return Err(ReplyRejection::Conflict);
        }
        Ok(None)
    }
    pub fn claim(
        &mut self,
        p: &RespondExactParams,
        pending: &PendingClientRequest,
    ) -> Result<(), ReplyRejection> {
        let id = p.validate()?;
        if self.lookup(p)?.is_some() {
            return Err(ReplyRejection::Conflict);
        }
        if pending.raw_frame.is_none()
            || pending.origin_cursor != Some(p.origin_cursor)
            || pending.request_id != p.pending_request_id
            || pending.adapter_request_id != id
        {
            return Err(ReplyRejection::StaleOrigin);
        }
        self.origins.insert(
            (p.pending_request_id.clone(), p.origin_cursor.0),
            p.operation_key.clone(),
        );
        self.attempts
            .insert(p.operation_key.clone(), (p.clone(), ReplyStatus::InFlight));
        Ok(())
    }
    pub fn is_in_flight_origin(&self, request_id: &str, cursor: EventCursor) -> bool {
        self.origins
            .get(&(request_id.to_owned(), cursor.0))
            .and_then(|key| self.attempts.get(key))
            .is_some_and(|(_, status)| *status == ReplyStatus::InFlight)
    }

    pub fn finish(&mut self, key: &OperationKey, status: ReplyStatus) {
        if let Some((_, current)) = self.attempts.get_mut(key) {
            if *current == ReplyStatus::InFlight {
                *current = status;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::acp_broker::{PendingClientRequest, PendingClientRequestKind};
    use serde_json::json;

    fn params() -> RespondExactParams {
        serde_json::from_value(json!({"brokerId":"b","generation":1,"pendingRequestId":"7","originCursor":1,
            "operationKey":"answer", "frame":AcpRawJSONPayload::new(br#" {"jsonrpc":"2.0","id":7,"result":{"n":1e999,"big":123456789012345678901234567890}} "#.to_vec()),
            "wireContext":{"acpVersion":2,"payloadFormat":"alas.acp.raw-json.v1"}})).unwrap()
    }
    fn pending() -> PendingClientRequest {
        PendingClientRequest {
            request_id: "7".into(),
            adapter_request_id: json!(7),
            origin_cursor: Some(EventCursor(1)),
            raw_frame: Some(AcpRawJSONPayload::new(vec![])),
            kind: PendingClientRequestKind::Permission,
            payload: Value::Null,
        }
    }
    #[test]
    fn exact_reply_identity_and_opaque_values_survive_validation() {
        let p = params();
        assert_eq!(validate_frame(p.frame.bytes()).unwrap(), json!(7));
        let mut attempts = ReplyAttempts::default();
        attempts.claim(&p, &pending()).unwrap();
        assert_eq!(attempts.lookup(&p).unwrap(), Some(ReplyStatus::InFlight));
        attempts.finish(&p.operation_key, ReplyStatus::Written);
        assert_eq!(attempts.lookup(&p).unwrap(), Some(ReplyStatus::Written));
        let mut changed = p.clone();
        changed.frame =
            AcpRawJSONPayload::new(br#"{"jsonrpc":"2.0","id":7,"result":null}"#.to_vec());
        assert_eq!(attempts.lookup(&changed), Err(ReplyRejection::Conflict));
        changed = p.clone();
        changed.operation_key = OperationKey::new("other");
        assert_eq!(
            attempts.claim(&changed, &pending()),
            Err(ReplyRejection::Conflict)
        );
        changed = p.clone();
        changed.origin_cursor = EventCursor(2);
        assert_eq!(attempts.lookup(&changed), Err(ReplyRejection::Conflict));
    }
    #[test]
    fn stale_origin_or_wire_id_never_claims_a_reused_pending_key() {
        for (cursor, id) in [(2, json!(7)), (1, json!("7"))] {
            let mut original = pending();
            original.origin_cursor = Some(EventCursor(cursor));
            original.adapter_request_id = id;
            let mut attempts = ReplyAttempts::default();
            assert_eq!(
                attempts.claim(&params(), &original),
                Err(ReplyRejection::StaleOrigin)
            );
            assert_eq!(attempts.lookup(&params()).unwrap(), None);
        }
    }
    #[test]
    fn shared_envelope_cases_agree_before_handoff() {
        #[derive(Deserialize)]
        struct Fixture {
            name: String,
            frame: String,
            valid: bool,
        }
        let fixtures: Vec<Fixture> = serde_json::from_str(include_str!(
            "../../Packages/AlasCore/Tests/AlasCoreTests/Fixtures/acp-raw-replies.json"
        ))
        .unwrap();
        for fixture in fixtures {
            assert_eq!(
                validate_frame(fixture.frame.as_bytes()).is_ok(),
                fixture.valid,
                "{}",
                fixture.name
            );
        }
    }
}
