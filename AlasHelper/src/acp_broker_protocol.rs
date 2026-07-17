use crate::acp_broker::{
    ACPBrokerSnapshot, AdapterRequestId, BrokerGeneration, BrokerId, EventCursor, OperationKey,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

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

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcpRespondParams {
    pub broker_id: BrokerId,
    pub generation: BrokerGeneration,
    pub request_id: AdapterRequestId,
    pub operation_key: OperationKey,
    pub result: Value,
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
