//! What a shell caller sees for a successful reply. Images the app sends
//! inline (screenshots, captures) go to a file, since neither a terminal nor
//! an agent's shell tool can show base64; the metadata line names the file.

use alas_client::Command;
use serde_json::Value;
use std::path::{Path, PathBuf};

/// The lines to print for an ok reply to `command`, or the error to report.
/// `confirm_empty` turns an empty reply into the confirmation the MCP server
/// gives. Images are written to `image_dir`.
pub fn success_lines(
    command: &Command,
    lines: Option<Vec<String>>,
    confirm_empty: bool,
    image_dir: &Path,
) -> Result<Vec<String>, String> {
    if matches!(command, Command::VisualShow { .. }) {
        return crate::mcp::visual_show_message(lines.as_deref()).map(|text| vec![text]);
    }
    let mut lines = lines.unwrap_or_default();
    if crate::mcp::returns_image(command) {
        if let Some(first) = lines.first_mut() {
            if let Some(saved) = save_image(first, image_dir)? {
                *first = saved;
            }
        }
    }
    if lines.is_empty() && confirm_empty {
        lines.push(crate::mcp::success_message(command));
    }
    Ok(lines)
}

/// Writes the `image` of a JSON metadata line to a file in `dir` and returns
/// the line with `image_path` in its place; None when the line has no image.
fn save_image(line: &str, dir: &Path) -> Result<Option<String>, String> {
    let Ok(Value::Object(mut metadata)) = serde_json::from_str::<Value>(line) else {
        return Ok(None);
    };
    let Some(image) = metadata.remove("image") else {
        return Ok(None);
    };
    let bytes = image
        .get("data")
        .and_then(Value::as_str)
        .and_then(decode_base64)
        .ok_or("malformed image from Alas")?;
    let extension = match image.get("mime_type").and_then(Value::as_str) {
        Some("image/jpeg") => "jpg",
        _ => "png",
    };
    let path = image_path(dir, extension);
    write_private(&path, &bytes)
        .map_err(|err| format!("could not write {}: {err}", path.display()))?;
    metadata.insert(
        "image_path".into(),
        Value::String(path.to_string_lossy().into_owned()),
    );
    Ok(Some(Value::Object(metadata).to_string()))
}

/// Screenshots show the user's apps, so only the user may read them, even in
/// a shared temp directory. `create_new` also refuses a file or symlink
/// another user planted at the path.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?
        .write_all(bytes)
}

/// A fresh file name: one process writes at most one image.
fn image_path(dir: &Path, extension: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    dir.join(format!("alas-image-{}-{nanos}.{extension}", std::process::id()))
}

/// Standard base64, padded or not, as the app's `base64EncodedString()` writes it.
fn decode_base64(input: &str) -> Option<Vec<u8>> {
    let input = input.trim_end_matches('=').as_bytes();
    let mut out = Vec::with_capacity(input.len() * 3 / 4);
    let (mut buffer, mut bits) = (0u32, 0u32);
    for &byte in input {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "alas-output-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn screenshot_image_goes_to_a_file_named_in_the_metadata() {
        let dir = temp_dir();
        let command = Command::Computer(
            alas_client::ComputerCommand::Screenshot { window_id: 3, call_id: None },
            None,
        );
        // "hello" in base64, without and with padding.
        for data in ["aGVsbG8", "aGVsbG8="] {
            let line = json!({
                "width": 10,
                "image": { "mime_type": "image/png", "data": data }
            })
            .to_string();
            let lines = success_lines(&command, Some(vec![line, "extra".into()]), false, &dir).unwrap();
            let metadata: Value = serde_json::from_str(&lines[0]).unwrap();
            assert_eq!(metadata["width"], json!(10));
            assert!(metadata.get("image").is_none());
            let path = metadata["image_path"].as_str().unwrap();
            assert!(path.ends_with(".png"));
            assert_eq!(std::fs::read(path).unwrap(), b"hello");
            // Owner-only whatever the umask: the capture shows the user's apps.
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
            assert_eq!(lines[1], "extra");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn malformed_image_data_is_an_error() {
        let command = Command::Preview(alas_client::PreviewCommand::Capture {
            preview_id: "p".into(),
            target: alas_client::PreviewCaptureTarget::Viewport,
        });
        let line = json!({ "image": { "mime_type": "image/png", "data": "not base64!" } }).to_string();
        assert_eq!(
            success_lines(&command, Some(vec![line]), false, &temp_dir()),
            Err("malformed image from Alas".into())
        );
    }

    #[test]
    fn empty_reply_is_confirmed_only_when_asked() {
        let command = Command::Notify {
            body: "b".into(),
            title: None,
            level: None,
        };
        let dir = temp_dir();
        assert_eq!(success_lines(&command, None, false, &dir), Ok(vec![]));
        assert_eq!(
            success_lines(&command, None, true, &dir),
            Ok(vec!["Notification sent.".into()])
        );
    }
}
