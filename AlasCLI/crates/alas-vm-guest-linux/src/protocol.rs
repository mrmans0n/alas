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

/// The reply to `hello`. Computer use is advertised only while Cua Driver answers.
pub fn hello_reply(computer_use: bool) -> Message {
    let mut capabilities = vec!["run".to_string()];
    if computer_use {
        capabilities.push("computer_use".to_string());
    }
    Message::HelloReply {
        guest_version: env!("CARGO_PKG_VERSION").to_string(),
        protocol_revision: REVISION,
        accessibility: false,
        screen_recording: false,
        guest_kind: Some("linux".to_string()),
        capabilities: Some(capabilities),
    }
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding, what Swift's `JSONEncoder` produces for `Data`.
pub fn base64(bytes: &[u8]) -> String {
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

/// Decodes `base64`'s output: padded standard base64. None for anything else.
pub fn unbase64(text: &str) -> Option<Vec<u8>> {
    let text = text.as_bytes();
    if !text.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    for (index, chunk) in text.chunks(4).enumerate() {
        let last = index == text.len() / 4 - 1;
        let padding = chunk.iter().rev().take_while(|byte| **byte == b'=').count();
        if padding > 2 || (padding > 0 && !last) {
            return None;
        }
        let mut n = 0u32;
        for byte in &chunk[..4 - padding] {
            let value = ALPHABET.iter().position(|letter| letter == byte)?;
            n = (n << 6) | value as u32;
        }
        n <<= 6 * padding as u32;
        out.extend_from_slice(&n.to_be_bytes()[1..4 - padding]);
    }
    Some(out)
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
    fn base64_round_trips_every_padding() {
        let bytes = b"\x00\xff{\"ok\":true}";
        for length in 0..=bytes.len() {
            let text = base64(&bytes[..length]);
            assert_eq!(unbase64(&text).as_deref(), Some(&bytes[..length]), "{text}");
        }
        for invalid in ["abc", "a===", "ab=c", "ab==abcd", "ab!d"] {
            assert_eq!(unbase64(invalid), None, "{invalid}");
        }
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
