//! `alas tool`: every built-in MCP tool from the shell, for harnesses that
//! cap, defer or drop MCP servers. A call takes the tool's JSON arguments and
//! goes through the same `mcp::command_for_tool` the server uses, so the two
//! surfaces cannot drift apart.

use serde_json::Value;

pub const USAGE: &str = "\
usage: alas tool list
usage: alas tool schema <name>
usage: alas tool call <name> [<json-arguments> | -]  (- reads the arguments from stdin)";

#[derive(Debug, PartialEq)]
pub enum ToolCommand {
    List,
    Schema(String),
    Call { name: String, args: Value },
}

/// Parses the arguments after `tool`. `read_stdin` runs only for `-`.
pub fn parse(
    args: &[String],
    read_stdin: impl FnOnce() -> std::io::Result<String>,
) -> Result<ToolCommand, String> {
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["list"] => Ok(ToolCommand::List),
        ["schema", name] => Ok(ToolCommand::Schema(name.to_string())),
        ["call", name] => Ok(ToolCommand::Call {
            name: name.to_string(),
            args: Value::Object(Default::default()),
        }),
        ["call", name, raw] => {
            let raw = if *raw == "-" {
                read_stdin().map_err(|err| format!("could not read arguments from stdin: {err}"))?
            } else {
                raw.to_string()
            };
            let args = serde_json::from_str::<Value>(&raw)
                .ok()
                .filter(Value::is_object)
                .ok_or("tool arguments must be a JSON object")?;
            Ok(ToolCommand::Call {
                name: name.to_string(),
                args,
            })
        }
        _ => Err(USAGE.into()),
    }
}

/// One line per tool: its name and the first sentence of its description.
pub fn list_lines(tools: &[Value]) -> Vec<String> {
    let name = |tool: &Value| tool["name"].as_str().unwrap_or_default().to_string();
    let width = tools.iter().map(|tool| name(tool).len()).max().unwrap_or(0);
    tools
        .iter()
        .map(|tool| {
            let summary = summary(tool["description"].as_str().unwrap_or_default());
            format!("{:<width$}  {summary}", name(tool))
        })
        .collect()
}

/// The tool's full definition, pretty-printed: its description and input schema.
pub fn schema(tools: &[Value], name: &str) -> Result<String, String> {
    tools
        .iter()
        .find(|tool| tool["name"] == name)
        .map(|tool| serde_json::to_string_pretty(tool).unwrap_or_else(|_| tool.to_string()))
        .ok_or_else(|| format!("unknown tool: {name}"))
}

/// The first sentence, cut at a character boundary past 160 bytes.
fn summary(description: &str) -> String {
    let sentence = description
        .find(". ")
        .map_or(description, |end| &description[..=end]);
    if sentence.len() <= 160 {
        return sentence.to_string();
    }
    let mut cut = 157;
    while !sentence.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}...", &sentence[..cut])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    fn no_stdin() -> std::io::Result<String> {
        panic!("stdin must not be read")
    }

    #[test]
    fn call_takes_inline_stdin_or_no_arguments() {
        assert_eq!(
            parse(&args(&["call", "pr_status"]), no_stdin),
            Ok(ToolCommand::Call { name: "pr_status".into(), args: json!({}) })
        );
        assert_eq!(
            parse(&args(&["call", "notify", r#"{"body":"hi"}"#]), no_stdin),
            Ok(ToolCommand::Call { name: "notify".into(), args: json!({ "body": "hi" }) })
        );
        assert_eq!(
            parse(&args(&["call", "notify", "-"]), || Ok(r#"{"body":"from stdin"}"#.into())),
            Ok(ToolCommand::Call { name: "notify".into(), args: json!({ "body": "from stdin" }) })
        );
    }

    #[test]
    fn call_arguments_must_be_a_json_object() {
        for raw in ["[1]", "\"text\"", "{not json"] {
            assert_eq!(
                parse(&args(&["call", "notify", raw]), no_stdin),
                Err("tool arguments must be a JSON object".into())
            );
        }
    }

    #[test]
    fn malformed_invocations_print_usage() {
        for invocation in [&[][..], &["call"][..], &["schema"][..], &["list", "x"][..], &["call", "a", "{}", "b"][..]] {
            assert_eq!(parse(&args(invocation), no_stdin), Err(USAGE.into()));
        }
    }

    #[test]
    fn list_shows_each_tool_with_its_first_sentence() {
        let long = "x".repeat(200);
        let tools = vec![
            json!({ "name": "notify", "description": "Post a notification. And more." }),
            json!({ "name": "pr_status", "description": long }),
        ];
        assert_eq!(
            list_lines(&tools),
            vec![
                "notify     Post a notification.".to_string(),
                format!("pr_status  {}...", "x".repeat(157)),
            ]
        );
    }

    #[test]
    fn every_session_tool_has_a_command() {
        // Arguments are tool-specific, so a call may fail validation, but
        // never as an unknown tool: the list and the dispatcher agree.
        for tool in crate::mcp::session_tool_definitions(None) {
            let name = tool["name"].as_str().unwrap();
            if let Err(message) = crate::mcp::command_for_tool(name, &json!({}), "/w") {
                assert_ne!(message, format!("unknown tool: {name}"));
            }
        }
    }
}
