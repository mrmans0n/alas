use crate::acp_broker::{
    ACPBrokerSnapshot, AdapterRPCOutcome, BrokerGeneration, BrokerId, EventCursor,
    JSONRPCErrorObject, OperationKey,
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum BrokerWireContext {
    #[default]
    LegacyV1,
    RawV2,
}

impl Serialize for BrokerWireContext {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut object = serializer.serialize_struct("BrokerWireContext", 2)?;
        object.serialize_field("acpVersion", &(if *self == Self::RawV2 { 2 } else { 1 }))?;
        object.serialize_field(
            "payloadFormat",
            if *self == Self::RawV2 {
                "alas.acp.raw-json.v1"
            } else {
                "structured"
            },
        )?;
        object.end()
    }
}

impl<'de> Deserialize<'de> for BrokerWireContext {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Context {
            acp_version: u32,
            payload_format: String,
        }
        let context = Context::deserialize(deserializer)?;
        match (context.acp_version, context.payload_format.as_str()) {
            (1, "structured") => Ok(Self::LegacyV1),
            (2, "alas.acp.raw-json.v1") => Ok(Self::RawV2),
            _ => Err(serde::de::Error::custom(
                "unsupported ACP broker wire context",
            )),
        }
    }
}

/// Opaque source bytes for a future broker boundary. Successful decoding
/// validates only this wrapper, not its contents as JSON or ACP data.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AcpRawJSONPayload {
    bytes: Vec<u8>,
}

impl AcpRawJSONPayload {
    const FORMAT: &'static str = "alas.acp.raw-json.v1";

    pub fn new(bytes: Vec<u8>) -> Self {
        Self { bytes }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

impl Serialize for AcpRawJSONPayload {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        (Self::FORMAT, STANDARD.encode(&self.bytes)).serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for AcpRawJSONPayload {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let (format, encoded) = <(String, String)>::deserialize(deserializer)?;
        if format != Self::FORMAT {
            return Err(serde::de::Error::custom(
                "unsupported raw broker payload format",
            ));
        }
        let bytes = STANDARD
            .decode(&encoded)
            .map_err(serde::de::Error::custom)?;
        if STANDARD.encode(&bytes) != encoded {
            return Err(serde::de::Error::custom("expected canonical padded base64"));
        }
        Ok(Self::new(bytes))
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpOpenParams {
    pub broker_id: BrokerId,
    pub session_id: String,
    pub command: String,
    pub args: Vec<String>,
    pub cwd: String,
    pub env: Value,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpOpenResult {
    pub snapshot: ACPBrokerSnapshot,
    pub adopted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpAttachParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub acknowledged_cursor: EventCursor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_after_cursor: Option<EventCursor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_replay_bytes: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot_on_last_page_only: Option<bool>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpSendParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub operation_key: OperationKey,
    pub method: String,
    pub params: Value,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpNotifyParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub method: String,
    pub params: Value,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpRespondParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub request_id: Value,
    pub operation_key: OperationKey,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JSONRPCErrorObject>,
}

impl<'de> Deserialize<'de> for AcpRespondParams {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let mut object = Value::deserialize(deserializer)?
            .as_object()
            .cloned()
            .ok_or_else(|| serde::de::Error::custom("AcpRespondParams must be an object"))?;
        let result = if object.contains_key("result") {
            Some(object.remove("result").unwrap_or(Value::Null))
        } else {
            None
        };
        let error = match object.remove("error") {
            Some(Value::Null) | None => None,
            Some(value) => Some(serde_json::from_value(value).map_err(serde::de::Error::custom)?),
        };
        Ok(Self {
            broker_id: serde_json::from_value(
                object
                    .remove("brokerId")
                    .ok_or_else(|| serde::de::Error::missing_field("brokerId"))?,
            )
            .map_err(serde::de::Error::custom)?,
            generation: serde_json::from_value(
                object
                    .remove("generation")
                    .ok_or_else(|| serde::de::Error::missing_field("generation"))?,
            )
            .map_err(serde::de::Error::custom)?,
            request_id: object
                .remove("requestId")
                .ok_or_else(|| serde::de::Error::missing_field("requestId"))?,
            operation_key: serde_json::from_value(
                object
                    .remove("operationKey")
                    .ok_or_else(|| serde::de::Error::missing_field("operationKey"))?,
            )
            .map_err(serde::de::Error::custom)?,
            result,
            error,
        })
    }
}

impl AcpRespondParams {
    pub fn outcome(&self) -> Option<AdapterRPCOutcome> {
        match (&self.result, &self.error) {
            (Some(result), None) => Some(AdapterRPCOutcome::result(result.clone())),
            (None, Some(error)) => Some(AdapterRPCOutcome::error(error.clone())),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpAckParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub cursor: EventCursor,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpDetachParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpCloseParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpListResult {
    pub brokers: Vec<ACPBrokerSnapshot>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AcpBrokerMethod {
    Open,
    Attach,
    Send,
    Notify,
    Respond,
    Ack,
    Detach,
    Close,
    List,
}

impl AcpBrokerMethod {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "acp/open",
            Self::Attach => "acp/attach",
            Self::Send => "acp/send",
            Self::Notify => "acp/notify",
            Self::Respond => "acp/respond",
            Self::Ack => "acp/ack",
            Self::Detach => "acp/detach",
            Self::Close => "acp/close",
            Self::List => "acp/list",
        }
    }
}
