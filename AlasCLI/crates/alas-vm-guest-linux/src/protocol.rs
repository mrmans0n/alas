//! The host/guest vsock protocol, mirroring `VMGuestMessage` and `VMGuestFramer` in
//! `Packages/AlasCore/Sources/AlasPlatform/VM/VMGuestProtocol.swift`. Field names and tags match
//! the Swift Codable output; `Data` fields travel as base64 strings.

use serde::{Deserialize, Serialize};

/// The vsock port the host connects to.
pub const PORT: u32 = 7041;
/// `VMGuestProtocol.revision`.
pub const REVISION: i64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LifecycleEvent {
    Stop,
    Resume,
    TurnEnded,
    SessionEnded,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Message {
    // Host to guest.
    Hello {
        #[serde(rename = "hostVersion")]
        host_version: String,
    },
    Command {
        id: u64,
        #[serde(rename = "sessionID")]
        session_id: String,
        /// Base64 of a `ComputerUseCommand` request.
        request: String,
    },
    Cancel {
        id: u64,
    },
    Lifecycle {
        #[serde(rename = "sessionID")]
        session_id: String,
        event: LifecycleEvent,
    },
    Run {
        id: u64,
        command: String,
        #[serde(rename = "timeoutSeconds")]
        timeout_seconds: i64,
    },
    // Guest to host.
    HelloReply {
        #[serde(rename = "guestVersion")]
        guest_version: String,
        #[serde(rename = "protocolRevision", default)]
        protocol_revision: i64,
        accessibility: bool,
        #[serde(rename = "screenRecording")]
        screen_recording: bool,
        #[serde(rename = "guestKind", default, skip_serializing_if = "Option::is_none")]
        guest_kind: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        capabilities: Option<Vec<String>>,
    },
    Response {
        id: u64,
        /// Base64 of an `AlasCLIResponse` encoding.
        body: String,
    },
    RunResult {
        id: u64,
        #[serde(rename = "exitCode", default, skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
        stdout: String,
        stderr: String,
        truncated: bool,
        #[serde(rename = "timedOut")]
        timed_out: bool,
    },
}

/// A 4-byte big-endian payload length, then the JSON message.
pub fn frame(message: &Message) -> Vec<u8> {
    let payload = serde_json::to_vec(message).expect("a message always encodes");
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&payload);
    out
}

/// Buffers partial frames. A complete frame that is not a valid message is skipped and counted,
/// so it never costs the good messages around it.
#[derive(Default)]
pub struct Framer {
    buffer: Vec<u8>,
}

#[derive(Debug, Default, PartialEq)]
pub struct FramerOutput {
    pub messages: Vec<Message>,
    pub malformed_frames: usize,
}

impl Framer {
    pub fn append(&mut self, bytes: &[u8]) -> FramerOutput {
        self.buffer.extend_from_slice(bytes);
        let mut output = FramerOutput::default();
        let mut start = 0;
        while self.buffer.len() - start >= 4 {
            let header: [u8; 4] = self.buffer[start..start + 4].try_into().unwrap();
            let end = start + 4 + u32::from_be_bytes(header) as usize;
            if self.buffer.len() < end {
                break;
            }
            match serde_json::from_slice::<Message>(&self.buffer[start + 4..end]) {
                Ok(message) => output.messages.push(message),
                Err(_) => output.malformed_frames += 1,
            }
            start = end;
        }
        self.buffer.drain(..start);
        output
    }
}

/// The reply to `hello`: this helper runs commands and has no computer use yet.
pub fn hello_reply() -> Message {
    Message::HelloReply {
        guest_version: env!("CARGO_PKG_VERSION").to_string(),
        protocol_revision: REVISION,
        accessibility: false,
        screen_recording: false,
        guest_kind: Some("linux".to_string()),
        capabilities: Some(vec!["run".to_string()]),
    }
}

/// The reply to any computer-use `command`: an `AlasCLIResponse` error.
pub fn unsupported_command_response(id: u64) -> Message {
    const BODY: &str = r#"{"ok":false,"error":"computer_vm_unsupported: Computer use isn't available in Linux VMs yet."}"#;
    Message::Response {
        id,
        body: base64(BODY.as_bytes()),
    }
}

/// Standard base64 with padding, what Swift's `JSONEncoder` produces for `Data`.
pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i)) as usize & 63] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const FIXTURE: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../Packages/AlasCore/Tests/AlasCoreTests/Fixtures/vm-guest-protocol.json"
    );

    /// The Swift `VMGuestProtocolTests` round-trip the same file, so both sides agree on the wire.
    #[test]
    fn shared_fixture_round_trips_every_message() {
        let text = std::fs::read_to_string(FIXTURE).expect("fixture is readable");
        let samples: Vec<Value> = serde_json::from_str(&text).expect("fixture is a JSON array");
        assert!(!samples.is_empty());
        for sample in samples {
            let message: Message = serde_json::from_value(sample.clone())
                .unwrap_or_else(|error| panic!("{sample} does not decode: {error}"));
            assert_eq!(serde_json::to_value(&message).unwrap(), sample);
        }
    }

    #[test]
    fn unsupported_command_response_matches_the_fixture() {
        let text = std::fs::read_to_string(FIXTURE).unwrap();
        let samples: Vec<Value> = serde_json::from_str(&text).unwrap();
        let fixture = samples
            .iter()
            .find(|sample| sample["type"] == "response")
            .unwrap();
        let reply = serde_json::to_value(unsupported_command_response(9)).unwrap();
        assert_eq!(&reply, fixture);
    }

    #[test]
    fn framer_skips_malformed_frames_across_split_reads() {
        let mut stream = frame(&Message::Cancel { id: 1 });
        stream.extend_from_slice(&[0, 0, 0, 3]);
        stream.extend_from_slice(b"{x}");
        stream.extend(frame(&Message::Cancel { id: 2 }));
        let mut framer = Framer::default();
        let mut output = FramerOutput::default();
        for byte in stream {
            let next = framer.append(&[byte]);
            output.messages.extend(next.messages);
            output.malformed_frames += next.malformed_frames;
        }
        assert_eq!(
            output.messages,
            vec![Message::Cancel { id: 1 }, Message::Cancel { id: 2 }]
        );
        assert_eq!(output.malformed_frames, 1);
    }
}
