# ACP Visual Aids Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any ACP agent show sandboxed HTML visual aids inline in the Alas transcript through a `visual_show` tool on the built-in `alas` MCP server, with an optional question the user answers from a native card.

**Architecture:** `visual_show` (Rust, `mcp.rs`) validates arguments and sends a `visual_show` socket request. `AlasCLIRequest` decodes it, `AlasCLICommandRouter` requires an ACP caller, AppState authorizes the session and calls `ACPSessionManager.showVisualAid`, which appends a persisted `ACPMessage.visualAid` row. `ACPVisualAidCard` renders the row through a sandboxed `WKWebView` (`alas-visual:` scheme, CSP, content rules, isolated bridge world) and, when the visual has a question, an `ACPUserInputPrompt` whose submit stores the answer and sends it as a normal user prompt.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, WebKit, Swift Testing; Rust (`alas`, `alas-client` crates), serde_json.

**Spec:** `docs/superpowers/specs/2026-10-07-acp-visual-aids-design.md`

## Global Constraints

- Keep code, comments, logs and UI strings in English.
- Tests use Swift Testing (`import Testing`), never XCTest. Extend the named existing suites; create only `VisualAidWebPolicyTests` and `ACPVisualAidTests`.
- No `.serialized`, `@MainActor` or CI subprocess policy entries on new suites unless a step says so.
- After adding any Swift file or resource, or editing `project.yml`, run `xcodegen` and commit `project.yml` and `Alas.xcodeproj` with the change.
- Commit titles follow Conventional Commits (`feat(acp): …`, `test(acp): …`). No AI attribution anywhere.
- Limits, verbatim from the spec: `title` 1 to 120 characters; `html` non-empty, at most 512 KiB (524288 bytes) of UTF-8; question `prompt` 1 to 500 characters; 2 to 8 options; option `id` unique, 1 to 64 characters of `[A-Za-z0-9_-]`; option `label` 1 to 200 characters; `allow_multiple` optional, default false.
- CSP, verbatim: `default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'`
- Error strings, verbatim: `visual_show is only available to ACP agent sessions`; `This session can't show visuals right now.`; `Couldn't set up the visual's sandbox`; `Visual stopped`; `Visual unavailable`.
- Tool result text, verbatim: `Shown to the user as visual <uuid>. Their selection, if any, arrives as their next message. End your turn unless you have more to show.`
- Card height clamps to 120 to 720 points. At most 4 live visual pages app-wide.
- Focused Swift test command (replace the suite names):

  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -skipPackagePluginValidation -skipMacroValidation \
    -only-testing AlasTests/<SuiteName> test
  ```

  Check the `Test run with N tests in M suites` line; a misspelled suite runs nothing and still passes.
- Build-only command: same flags with `-quiet build` instead of `-only-testing … test`.
- Rust tests: `cd AlasCLI && cargo test -p alas mcp::tests` and `cd AlasCLI && cargo test -p alas-client`.

## Review Focus

1. A full HTML document with no `<head>` (`<html><body>…`) must still be served intact with the theme variables appended, not wrapped in the frame template. Pinned in Task 6.
2. A fragment that itself contains the literal text `{{CONTENT}}` or `{{HEAD}}` must come through verbatim, not be expanded again. Pinned in Task 6.
3. A `data-choice` value that differs from an option id only by case or whitespace (`"A"`, `" a"`) must select nothing. Pinned in Task 2.
4. A multi-select answer lists options in the question's order, not click order, both on the row and in the prompt text. Pinned in Task 2.
5. HTML with leading or trailing whitespace reaches the transcript byte-for-byte (no trimming on the Rust side). Pinned in Task 1.

Not covered by unit tests, verified in the Task 10 smoke run: clearing the answer when `sendPrompt` fails, the 4-page eviction in a real window, and `fetch()` being blocked inside the page.

---

### Task 1: `visual_show` MCP tool (Rust)

**Files:**
- Modify: `AlasCLI/crates/alas-client/src/lib.rs` (`Command` enum near line 124; `build_request` near lines 360-668; tests module)
- Modify: `AlasCLI/crates/alas/src/mcp.rs` (imports line 6; doc comment line 155; `all_tool_definitions` after the `notify` entry at line 218; `command_for_tool`; `tool_result` line 1327; `success_message` line 1347; `MAX_REQUEST_BYTES` line 1953; tests module)

**Interfaces:**
- Produces: socket request `{"command":"visual_show","params":{"title":String,"html":String,"question"?:{"prompt":String,"options":[{"id":String,"label":String}],"allow_multiple":Bool}}}` with the usual top-level `session_id`/`cwd`. Consumed by Task 5.
- Consumes from the app: success reply `{"ok":true,"lines":["{\"visual_id\":\"<uuid>\"}"]}`.

- [ ] **Step 1: Add the command and its value types to `alas-client`**

In `AlasCLI/crates/alas-client/src/lib.rs`, add next to the `Command` enum:

```rust
/// The optional question a visual aid asks; see `Command::VisualShow`.
#[derive(Debug, Clone, PartialEq)]
pub struct VisualQuestion {
    pub prompt: String,
    pub options: Vec<VisualOption>,
    pub allow_multiple: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct VisualOption {
    pub id: String,
    pub label: String,
}
```

Add the variant to `Command` (after `SessionSend`):

```rust
    /// MCP-only: show an HTML visual aid in the calling ACP session's transcript.
    VisualShow {
        title: String,
        html: String,
        question: Option<VisualQuestion>,
    },
```

Add the arm to `build_request` (after the `Command::SessionSend` arm):

```rust
        Command::VisualShow { title, html, question } => {
            let mut r = Request::new("visual_show");
            let mut params = serde_json::json!({ "title": title, "html": html });
            if let Some(question) = question {
                params["question"] = serde_json::json!({
                    "prompt": question.prompt,
                    "options": question
                        .options
                        .iter()
                        .map(|option| serde_json::json!({ "id": option.id, "label": option.label }))
                        .collect::<Vec<_>>(),
                    "allow_multiple": question.allow_multiple,
                });
            }
            r.params = Some(params);
            r
        }
```

- [ ] **Step 2: Write the failing `alas-client` request-shape test**

Add to the `alas-client` tests module:

```rust
#[test]
fn visual_show_request_carries_the_question_in_params() {
    let request = build_request(
        &Command::VisualShow {
            title: "Layouts".into(),
            html: "<h2>Pick</h2>".into(),
            question: Some(VisualQuestion {
                prompt: "Which?".into(),
                options: vec![
                    VisualOption { id: "a".into(), label: "One".into() },
                    VisualOption { id: "b".into(), label: "Two".into() },
                ],
                allow_multiple: true,
            }),
        },
        Some("acp-1".into()),
        Some("/wt".into()),
    );
    assert_eq!(request.command, "visual_show");
    assert_eq!(request.session_id.as_deref(), Some("acp-1"));
    assert_eq!(
        request.params,
        Some(serde_json::json!({
            "title": "Layouts",
            "html": "<h2>Pick</h2>",
            "question": {
                "prompt": "Which?",
                "options": [{ "id": "a", "label": "One" }, { "id": "b", "label": "Two" }],
                "allow_multiple": true
            }
        }))
    );
}
```

The same JSON literal is decoded on the Swift side in Task 5; keep them identical.

- [ ] **Step 3: Run the client tests**

Run: `cd AlasCLI && cargo test -p alas-client`
Expected: PASS (Step 1 already added the arm). If it fails to compile because `mcp.rs` has a non-exhaustive `success_message`, that is fixed in Step 6; run `cargo test -p alas-client` alone, which builds only the client crate.

- [ ] **Step 4: Write the failing MCP tests**

In `mcp.rs` tests module, add:

```rust
#[test]
fn visual_show_maps_arguments_and_keeps_html_bytes() {
    let cmd = command_for_tool(
        "visual_show",
        &json!({
            "title": " Layouts ",
            "html": "  <h2>Pick</h2>\n",
            "question": {
                "prompt": "Which?",
                "options": [{ "id": "a", "label": "One" }, { "id": "b", "label": "Two" }],
                "allow_multiple": true
            }
        }),
        "/wt",
    )
    .unwrap();
    assert_eq!(
        cmd,
        Command::VisualShow {
            title: "Layouts".into(),
            html: "  <h2>Pick</h2>\n".into(),
            question: Some(VisualQuestion {
                prompt: "Which?".into(),
                options: vec![
                    VisualOption { id: "a".into(), label: "One".into() },
                    VisualOption { id: "b".into(), label: "Two".into() },
                ],
                allow_multiple: true,
            }),
        }
    );
}

#[test]
fn visual_show_rejects_out_of_contract_arguments() {
    let one = json!([{ "id": "a", "label": "One" }]);
    let duplicate = json!([{ "id": "a", "label": "One" }, { "id": "a", "label": "Two" }]);
    let bad_id = json!([{ "id": "a b", "label": "One" }, { "id": "b", "label": "Two" }]);
    let cases = [
        json!({ "title": "T" }),
        json!({ "title": "T", "html": "   " }),
        json!({ "title": "T", "html": "x".repeat(512 * 1024 + 1) }),
        json!({ "title": "x".repeat(121), "html": "<p>" }),
        json!({ "title": "T", "html": "<p>", "question": { "prompt": "Q", "options": one } }),
        json!({ "title": "T", "html": "<p>", "question": { "prompt": "Q", "options": duplicate } }),
        json!({ "title": "T", "html": "<p>", "question": { "prompt": "Q", "options": bad_id } }),
        json!({ "title": "T", "html": "<p>", "question": "Which?" }),
    ];
    for args in cases {
        assert!(command_for_tool("visual_show", &args, "/wt").is_err(), "accepted {args}");
    }
}

#[test]
fn visual_show_result_reports_the_visual_id() {
    let cmd = Command::VisualShow { title: "T".into(), html: "<p>".into(), question: None };
    let result = tool_result(
        &cmd,
        Response {
            ok: true,
            lines: Some(vec![r#"{"visual_id":"ABC"}"#.into()]),
            error: None,
            exit_code: None,
        },
    );
    assert_eq!(result["isError"], json!(false));
    assert_eq!(
        result["content"][0]["text"],
        json!("Shown to the user as visual ABC. Their selection, if any, arrives as their next message. End your turn unless you have more to show.")
    );
}
```

Update `tools_list_returns_all_tools` (line 2328): insert `"visual_show"` into the expected ordered array directly after `"notify"`.

- [ ] **Step 5: Run to verify failure**

Run: `cd AlasCLI && cargo test -p alas mcp::tests`
Expected: compile errors (`VisualQuestion` not imported, no `visual_show` mapping, non-exhaustive `success_message`).

- [ ] **Step 6: Implement the tool**

Change the import on line 6:

```rust
use alas_client::{Command, Response, TransportError, VisualOption, VisualQuestion};
```

Replace the doc comment on line 155 so it stops claiming a 1:1 CLI mirror:

```rust
/// The agent-facing tools. Most mirror a CLI command; `visual_show` is
/// MCP-only because a terminal caller has no transcript to show it in.
/// Descriptions make explicit that these act on the user's Alas UI — that is
/// what makes the agent-side permission prompt legible. `resolve` is internal
/// and not exposed.
```

In `all_tool_definitions()`, directly after the `notify` entry:

```rust
        json!({
            "name": "visual_show",
            "description": "Show the user an HTML visual aid inline in their Alas transcript: UI prototypes, layouts, diagrams, side-by-side comparisons. Use it when seeing beats reading; answer in text otherwise. `html` may be a fragment, which Alas wraps in a themed frame providing these classes: options/option (with letter and content children) for A/B/C choices, cards/card/card-image/card-body, mockup/mockup-header/mockup-body, split (side by side), pros-cons/pros/cons, mock-nav, mock-sidebar, mock-content, mock-button, mock-input, placeholder, subtitle, section, label. A document starting with <!DOCTYPE or <html is used as is. Scripts, styles, fonts and images may load from https CDNs; fetch, XHR and WebSockets are blocked. To ask the user to pick, pass `question` and put data-choice=\"<option id>\" on the matching elements: clicking one selects that option on a native card under the visual. The tool returns at once; the user's answer, if any, arrives as their next message, so end your turn after asking.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "title": { "type": "string", "maxLength": 120, "description": "Short title shown above the visual." },
                    "html": { "type": "string", "description": "HTML fragment or full document, at most 512 KiB of UTF-8." },
                    "question": {
                        "type": "object",
                        "description": "Optional single question answered from a native card.",
                        "properties": {
                            "prompt": { "type": "string", "maxLength": 500 },
                            "options": {
                                "type": "array",
                                "minItems": 2,
                                "maxItems": 8,
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "id": { "type": "string", "pattern": "^[A-Za-z0-9_-]{1,64}$" },
                                        "label": { "type": "string", "maxLength": 200 }
                                    },
                                    "required": ["id", "label"]
                                }
                            },
                            "allow_multiple": { "type": "boolean" }
                        },
                        "required": ["prompt", "options"]
                    }
                },
                "required": ["title", "html"]
            }
        }),
```

In `command_for_tool`, add an arm next to `"session_send"`:

```rust
        "visual_show" => visual_show_command(args),
```

Add these helpers next to the other argument helpers (near `required_exact_string`, line 1105):

```rust
const VISUAL_TITLE_MAX_CHARS: usize = 120;
const VISUAL_HTML_MAX_BYTES: usize = 512 * 1024;
const VISUAL_PROMPT_MAX_CHARS: usize = 500;
const VISUAL_OPTION_ID_MAX_CHARS: usize = 64;
const VISUAL_OPTION_LABEL_MAX_CHARS: usize = 200;

fn visual_show_command(args: &Value) -> Result<Command, String> {
    let title = required_string(args, "title")?;
    if title.chars().count() > VISUAL_TITLE_MAX_CHARS {
        return Err(format!("title must be at most {VISUAL_TITLE_MAX_CHARS} characters"));
    }
    // Exact: the HTML reaches the page byte for byte.
    let html = required_exact_string(args, "html")?;
    if html.trim().is_empty() {
        return Err("html must be non-empty".into());
    }
    if html.len() > VISUAL_HTML_MAX_BYTES {
        return Err(format!("html must be at most {VISUAL_HTML_MAX_BYTES} bytes"));
    }
    let question = match args.get("question") {
        None | Some(Value::Null) => None,
        Some(value @ Value::Object(_)) => Some(visual_question(value)?),
        Some(_) => return Err("question must be an object".into()),
    };
    Ok(Command::VisualShow { title, html, question })
}

fn visual_question(value: &Value) -> Result<VisualQuestion, String> {
    let prompt = required_string(value, "prompt")
        .map_err(|_| "question.prompt is required".to_string())?;
    if prompt.chars().count() > VISUAL_PROMPT_MAX_CHARS {
        return Err(format!("question.prompt must be at most {VISUAL_PROMPT_MAX_CHARS} characters"));
    }
    let raw_options = value
        .get("options")
        .and_then(Value::as_array)
        .ok_or("question.options must be an array")?;
    if !(2..=8).contains(&raw_options.len()) {
        return Err("question.options must have 2 to 8 items".into());
    }
    let mut seen = std::collections::HashSet::new();
    let mut options = Vec::with_capacity(raw_options.len());
    for option in raw_options {
        let id = option.get("id").and_then(Value::as_str).unwrap_or_default();
        let valid_id = (1..=VISUAL_OPTION_ID_MAX_CHARS).contains(&id.chars().count())
            && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
        if !valid_id {
            return Err(format!(
                "question option id '{id}' must be 1 to {VISUAL_OPTION_ID_MAX_CHARS} characters of A-Z, a-z, 0-9, '-' or '_'"
            ));
        }
        if !seen.insert(id.to_string()) {
            return Err(format!("question option id '{id}' is duplicated"));
        }
        let label = option.get("label").and_then(Value::as_str).map(str::trim).unwrap_or_default();
        if !(1..=VISUAL_OPTION_LABEL_MAX_CHARS).contains(&label.chars().count()) {
            return Err(format!(
                "question option '{id}' label must be 1 to {VISUAL_OPTION_LABEL_MAX_CHARS} characters"
            ));
        }
        options.push(VisualOption { id: id.into(), label: label.into() });
    }
    let allow_multiple = match value.get("allow_multiple") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(flag)) => *flag,
        Some(_) => return Err("question.allow_multiple must be a boolean".into()),
    };
    Ok(VisualQuestion { prompt, options, allow_multiple })
}
```

In `tool_result`, directly after the `if !resp.ok { … }` block:

```rust
    if matches!(command, Command::VisualShow { .. }) {
        return visual_show_result(resp.lines.as_deref());
    }
```

And add:

```rust
fn visual_show_result(lines: Option<&[String]>) -> Value {
    let visual_id = lines
        .and_then(|lines| lines.first())
        .and_then(|line| serde_json::from_str::<Value>(line).ok())
        .and_then(|reply| reply.get("visual_id").and_then(Value::as_str).map(String::from));
    match visual_id {
        Some(id) => text_result(
            format!(
                "Shown to the user as visual {id}. Their selection, if any, arrives as their next message. End your turn unless you have more to show."
            ),
            false,
        ),
        None => text_result("Alas did not confirm the visual.".into(), true),
    }
}
```

In `success_message`, add the arm (unreachable on success because of the branch above, required for exhaustiveness):

```rust
        Command::VisualShow { .. } => "Visual shown.".into(),
```

Raise the HTTP request cap (line 1953) and say why:

```rust
    // A 512 KiB `visual_show` html argument can grow several-fold under JSON
    // escaping; 4 MiB keeps every schema-valid call transportable.
    const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
```

- [ ] **Step 7: Run the tests**

Run: `cd AlasCLI && cargo test -p alas mcp::tests && cargo test -p alas-client`
Expected: PASS, including `tools_list_returns_all_tools` and `delegated_child_discovery_omits_session_new_but_calls_still_reach_alas` (the child list now includes `visual_show` because it is not child-only).

- [ ] **Step 8: Commit**

```bash
git add AlasCLI/crates/alas-client/src/lib.rs AlasCLI/crates/alas/src/mcp.rs
git commit -m "feat(mcp): add visual_show tool"
```

---

### Task 2: `ACPVisualAid` model and question form

**Files:**
- Create: `Alas/Sources/ACP/Session/ACPVisualAid.swift`
- Create: `Alas/Sources/ACP/Session/ACPVisualAidQuestionForm.swift`
- Modify: `Alas/Sources/ACP/Session/ACPUserInput.swift:4-7` (`Source`)
- Modify: `Alas/Sources/ACP/Session/ACPElicitationCoordinator.swift:101-125, 342-349, 383-389`
- Test: `AlasTests/ACP/Session/ACPVisualAidTests.swift` (new suite)

**Interfaces:**
- Produces:
  - `struct ACPVisualAid: Codable, Equatable, Sendable { id: UUID; title: String; html: String; question: Question?; var answer: Answer?; createdAt: Date }`, with `Option { id, label }`, `Question { prompt, options: [Option], allowMultiple: Bool }`, `enum Answer { case answered(selectedOptionIds: [String], note: String?, at: Date); case dismissed(at: Date) }`.
  - `static func ACPVisualAid.validationFailure(title: String, html: String, question: Question?) -> String?` (nil means valid).
  - `var ACPVisualAid.transcriptSummary: String`.
  - `enum ACPVisualAidQuestionForm` with `choiceKey = "choice"`, `noteKey = "note"`, `request(for:) -> ACPUserInputRequest?`, `choiceField(for:in:) -> ACPUserInputField?`, `answer(from:question:at:) -> ACPVisualAid.Answer?`, `answerPrompt(for:answer:) -> String?`.
  - `ACPUserInputRequest.Source.visualAid(UUID)`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/ACP/Session/ACPVisualAidTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

/// File scope so `@Test(arguments:)` can use it.
private let questionOptions: [ACPVisualAid.Option] = [
    .init(id: "a", label: "One"), .init(id: "b", label: "Two"), .init(id: "c", label: "Three"),
]

struct ACPVisualAidTests {
    private static func visual(allowMultiple: Bool = false) -> ACPVisualAid {
        ACPVisualAid(
            id: UUID(), title: "Homepage layout", html: "<h2>Pick</h2>",
            question: .init(prompt: "Which layout feels right?", options: questionOptions, allowMultiple: allowMultiple),
            answer: nil, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("limits match the visual_show contract", arguments: [
        ("T", "<p>", [ACPVisualAid.Option]?.some(questionOptions), true),
        ("", "<p>", nil, false),
        (String(repeating: "x", count: 121), "<p>", nil, false),
        ("T", " \n ", nil, false),
        ("T", String(repeating: "x", count: 512 * 1024 + 1), nil, false),
        ("T", "<p>", [.init(id: "a", label: "One")], false),
        ("T", "<p>", [.init(id: "a", label: "One"), .init(id: "a", label: "Two")], false),
        ("T", "<p>", [.init(id: "a b", label: "One"), .init(id: "b", label: "Two")], false),
        ("T", "<p>", [.init(id: "a", label: ""), .init(id: "b", label: "Two")], false),
    ] as [(String, String, [ACPVisualAid.Option]?, Bool)])
    func validation(title: String, html: String, options: [ACPVisualAid.Option]?, valid: Bool) {
        let question = options.map { ACPVisualAid.Question(prompt: "Q", options: $0, allowMultiple: false) }
        #expect((ACPVisualAid.validationFailure(title: title, html: html, question: question) == nil) == valid)
    }

    @Test("a page click selects only an exact option id", arguments: [
        ("b", true), ("B", false), (" b", false), ("z", false),
    ])
    func choiceField(choice: String, matches: Bool) throws {
        let request = try #require(ACPVisualAidQuestionForm.request(for: Self.visual()))
        let field = ACPVisualAidQuestionForm.choiceField(for: choice, in: request)
        #expect((field?.key == ACPVisualAidQuestionForm.choiceKey) == matches)
    }

    @Test("a multi-select answer keeps the question's option order")
    func multiSelectAnswerOrder() throws {
        let visual = Self.visual(allowMultiple: true)
        let answer = try #require(ACPVisualAidQuestionForm.answer(
            from: [ACPVisualAidQuestionForm.choiceKey: .strings(["c", "a"]), ACPVisualAidQuestionForm.noteKey: .string("  ")],
            question: try #require(visual.question),
            at: Date(timeIntervalSince1970: 1)
        ))
        #expect(answer == .answered(selectedOptionIds: ["a", "c"], note: nil, at: Date(timeIntervalSince1970: 1)))
        #expect(ACPVisualAidQuestionForm.answerPrompt(for: visual, answer: answer)
            == "[Visual aid: Homepage layout] Which layout feels right?\nSelected: a (One), c (Three)")
    }

    @Test("the answer prompt carries a non-empty note and dismissal sends nothing")
    func answerPrompt() {
        let visual = Self.visual()
        let answered = ACPVisualAid.Answer.answered(selectedOptionIds: ["b"], note: "Keep the sidebar collapsible.", at: Date())
        #expect(ACPVisualAidQuestionForm.answerPrompt(for: visual, answer: answered)
            == "[Visual aid: Homepage layout] Which layout feels right?\nSelected: b (Two)\nNote: Keep the sidebar collapsible.")
        #expect(ACPVisualAidQuestionForm.answerPrompt(for: visual, answer: .dismissed(at: Date())) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run `xcodegen`, then the focused command with `-only-testing AlasTests/ACPVisualAidTests`.
Expected: build failure, `ACPVisualAid` not found.

- [ ] **Step 3: Implement the model**

Create `Alas/Sources/ACP/Session/ACPVisualAid.swift`:

```swift
import Foundation

/// An HTML visual an agent showed through the `visual_show` MCP tool, with an
/// optional single question the user answers from a native card.
struct ACPVisualAid: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let html: String
    let question: Question?
    var answer: Answer?
    let createdAt: Date

    struct Option: Codable, Equatable, Sendable {
        let id: String
        let label: String
    }

    struct Question: Codable, Equatable, Sendable {
        let prompt: String
        let options: [Option]
        let allowMultiple: Bool
    }

    enum Answer: Codable, Equatable, Sendable {
        case answered(selectedOptionIds: [String], note: String?, at: Date)
        case dismissed(at: Date)
    }

    /// The `visual_show` limits from `mcp.rs`. Counted in Unicode scalars so
    /// they agree with Rust's `chars().count()`.
    enum Limits {
        static let titleMaxCharacters = 120
        static let htmlMaxBytes = 512 * 1024
        static let promptMaxCharacters = 500
        static let optionCount = 2...8
        static let optionIdMaxCharacters = 64
        static let optionLabelMaxCharacters = 200
    }

    /// Why the arguments break the `visual_show` contract, or nil when they
    /// hold. The app re-checks because the socket also takes direct requests.
    static func validationFailure(title: String, html: String, question: Question?) -> String? {
        guard (1...Limits.titleMaxCharacters).contains(title.unicodeScalars.count) else {
            return "title must be 1 to \(Limits.titleMaxCharacters) characters"
        }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "html must be non-empty" }
        guard html.utf8.count <= Limits.htmlMaxBytes else { return "html must be at most \(Limits.htmlMaxBytes) bytes" }
        guard let question else { return nil }
        guard (1...Limits.promptMaxCharacters).contains(question.prompt.unicodeScalars.count) else {
            return "question.prompt must be 1 to \(Limits.promptMaxCharacters) characters"
        }
        guard Limits.optionCount.contains(question.options.count) else { return "question.options must have 2 to 8 items" }
        var seen = Set<String>()
        for option in question.options {
            let validID = (1...Limits.optionIdMaxCharacters).contains(option.id.unicodeScalars.count)
                && option.id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
            guard validID else { return "question option id '\(option.id)' is invalid" }
            guard seen.insert(option.id).inserted else { return "question option id '\(option.id)' is duplicated" }
            guard (1...Limits.optionLabelMaxCharacters).contains(option.label.unicodeScalars.count) else {
                return "question option '\(option.id)' label must be 1 to \(Limits.optionLabelMaxCharacters) characters"
            }
        }
        return nil
    }

    /// One line for `session_read`/`session_search`. Never includes the HTML.
    var transcriptSummary: String {
        var text = "visual aid: \(title)"
        switch answer {
        case .answered(let ids, let note, _):
            text += " (answered: \(ids.joined(separator: ", "))"
            if let note { text += "; note: \(note)" }
            text += ")"
        case .dismissed:
            text += " (dismissed)"
        case nil:
            break
        }
        return text
    }
}
```

- [ ] **Step 4: Add the input source and the form helpers**

In `ACPUserInput.swift`, extend `Source`:

```swift
    enum Source: Equatable {
        case cursor(id: JSONRPCID, params: ACPQuestionRequestParams)
        case elicitation(id: JSONRPCID, params: ACPElicitationRequestParams)
        /// A visual aid's question. Never queued on the elicitation coordinator.
        case visualAid(UUID)
    }
```

In `ACPElicitationCoordinator.swift`, make the three switches compile without ever answering a JSON-RPC request for a visual:

```swift
// respond(to:action:), inside `switch request.source`:
        case .visualAid:
            assertionFailure("Visual aid questions never enter the elicitation coordinator")

// cancel(_:):
        case .visualAid:
            break

// private extension ACPUserInputRequest — jsonRPCID becomes optional:
    var jsonRPCID: JSONRPCID? {
        switch source {
        case .cursor(let id, _), .elicitation(let id, _): return id
        case .visualAid: return nil
        }
    }
```

Then fix every `jsonRPCID` use the compiler reports (line ~175 calls `client.respondToElicitation(id: request.jsonRPCID, …)`): unwrap with `guard let id = request.jsonRPCID else { return false }` (or `else { continue }` inside loops), keeping the existing behavior for cursor and elicitation requests.

Create `Alas/Sources/ACP/Session/ACPVisualAidQuestionForm.swift`:

```swift
import Foundation

/// Maps a visual aid's question onto the native user-input form, and the
/// submitted form back onto an answer and the prompt the agent receives.
enum ACPVisualAidQuestionForm {
    static let choiceKey = "choice"
    static let noteKey = "note"
    static let noteMaxLength = 2000

    static func request(for visual: ACPVisualAid) -> ACPUserInputRequest? {
        guard let question = visual.question else { return nil }
        let choice = ACPUserInputField(key: choiceKey, required: true, schema: .init(
            type: question.allowMultiple ? "array" : "string",
            title: question.prompt, description: nil,
            minLength: nil, maxLength: nil, pattern: nil, format: nil, minimum: nil, maximum: nil,
            minItems: question.allowMultiple ? 1 : nil, maxItems: nil,
            options: question.options.map { ACPElicitationOption(const: $0.id, title: $0.label, description: nil) },
            defaultValue: nil, isSecret: false
        ))
        let note = ACPUserInputField(key: noteKey, required: false, schema: .init(
            type: "string", title: "Note", description: nil,
            minLength: nil, maxLength: noteMaxLength, pattern: nil, format: nil, minimum: nil, maximum: nil,
            minItems: nil, maxItems: nil, options: [], defaultValue: nil, isSecret: false
        ))
        return ACPUserInputRequest(
            id: visual.id, source: .visualAid(visual.id), title: visual.title,
            message: question.prompt, fields: [choice, note], mode: .form
        )
    }

    /// The choice field when `choice` is exactly one of the option ids.
    static func choiceField(for choice: String, in request: ACPUserInputRequest) -> ACPUserInputField? {
        guard let field = request.fields.first(where: { $0.key == choiceKey }),
              field.schema.options.contains(where: { $0.const == choice })
        else { return nil }
        return field
    }

    static func answer(
        from content: [String: ACPElicitationValue],
        question: ACPVisualAid.Question,
        at date: Date
    ) -> ACPVisualAid.Answer? {
        let picked: Set<String>
        switch content[choiceKey] {
        case .string(let id): picked = [id]
        case .strings(let ids): picked = Set(ids)
        default: return nil
        }
        let ordered = question.options.map(\.id).filter(picked.contains)
        guard !ordered.isEmpty else { return nil }
        var note: String?
        if case .string(let text) = content[noteKey] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            note = trimmed.isEmpty ? nil : trimmed
        }
        return .answered(selectedOptionIds: ordered, note: note, at: date)
    }

    /// The user prompt an answer sends; nil for a dismissal, which sends nothing.
    static func answerPrompt(for visual: ACPVisualAid, answer: ACPVisualAid.Answer) -> String? {
        guard case .answered(let ids, let note, _) = answer else { return nil }
        let labels = Dictionary(uniqueKeysWithValues: (visual.question?.options ?? []).map { ($0.id, $0.label) })
        var lines = [
            "[Visual aid: \(visual.title)] \(visual.question?.prompt ?? "")",
            "Selected: " + ids.map { "\($0) (\(labels[$0] ?? $0))" }.joined(separator: ", "),
        ]
        if let note, !note.isEmpty { lines.append("Note: \(note)") }
        return lines.joined(separator: "\n")
    }
}
```

If `ACPElicitationOption`'s value property is not named `const`, use its actual name (it is constructed as `ACPElicitationOption(const:title:description:)` in `ACPUserInput.swift:29`).

- [ ] **Step 5: Run the tests**

Run `xcodegen`, then the focused command with `-only-testing AlasTests/ACPVisualAidTests`.
Expected: PASS, 4 tests (17 cases).

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/Session/ACPVisualAid.swift Alas/Sources/ACP/Session/ACPVisualAidQuestionForm.swift \
  Alas/Sources/ACP/Session/ACPUserInput.swift Alas/Sources/ACP/Session/ACPElicitationCoordinator.swift \
  AlasTests/ACP/Session/ACPVisualAidTests.swift project.yml Alas.xcodeproj
git commit -m "feat(acp): add visual aid model and question form"
```

---

### Task 3: `.visualAid` transcript row

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPMessage.swift` (enum lines 1-10, `StableIdentityKey` 23-35, `stableIdentityKey` 37-54, `isAgentSideProgress` 61-68, `stableId(for:)` 70-84, `contentUTF8Length` 87-100, `kind` 102-112, codec 593-667)
- Modify: `Alas/Sources/ACP/Session/ACPMessageWire.swift` (cases 8-15, `isAgentSideProgress` 17-24, `decode` 34-60, `toMessage` 65-82, `toMessage(preservingIdentityFrom:)` 89-140)
- Modify: `Alas/Sources/ACP/Session/ACPSessionFork.swift:194-203, 212-227, 231-240`
- Modify: `Alas/Sources/ACP/Orchestration/ACPSessionTranscriptReader.swift:50-64`
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift:1295-1333`
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift:3667-3693` (`lastAgent`, `lastThought`)
- Modify (compiler-driven): `ACPSessionByteAccounting.swift:11-34`, `ACPSubagentRun.swift:950-961`, `ACPSubagentRowView.swift:17-26, 190-208`, `ACPTranscriptMinimap.swift:27-31, 55-72`, `ACPTranscriptRowContent.swift:176-294` (temporary `EmptyView()` branch, replaced in Task 8)
- Test: `AlasTests/ACP/Session/ACPMessageTests.swift`, `AlasTests/ACP/Session/ACPSessionForkPolicyTests.swift`, `AlasTests/ACP/Orchestration/ACPSessionTranscriptReaderTests.swift`

**Interfaces:**
- Consumes: `ACPVisualAid`, `transcriptSummary` (Task 2).
- Produces: `ACPMessage.visualAid(ACPVisualAid)`, `ACPMessageWire.visualAid(ACPVisualAid)`, persisted kind `"visual_aid"`, `ACPMessage.StableIdentityKey.visualAid(UUID)`.

- [ ] **Step 1: Write the failing tests**

Add to `ACPMessageTests`:

```swift
    @Test("visual aid round-trips with its answer state", arguments: [
        ACPVisualAid.Answer?.none,
        .answered(selectedOptionIds: ["b"], note: "Keep it", at: Date(timeIntervalSince1970: 1_700_000_000)),
        .dismissed(at: Date(timeIntervalSince1970: 1_700_000_000)),
    ])
    func visualAidRoundtrip(answer: ACPVisualAid.Answer?) throws {
        let visual = ACPVisualAid(
            id: UUID(), title: "Layouts", html: "<h2>Pick</h2>",
            question: .init(prompt: "Which?", options: [.init(id: "a", label: "One"), .init(id: "b", label: "Two")], allowMultiple: false),
            answer: answer, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let message = ACPMessage.visualAid(visual)
        let payload = try ACPMessageCodec.encode(message)
        #expect(message.kind == "visual_aid")
        #expect(try ACPMessageCodec.decode(kind: message.kind, payload: payload) == message)
        #expect(try ACPMessageWire.decode(kind: message.kind, payload: payload) == .visualAid(visual))
    }
```

In `ACPSessionForkPolicyTests.conversationOnlySnapshot`, put a visual between the tool call and the agent row so the resolver has to match it:

```swift
        let visual: ACPMessage = .visualAid(ACPVisualAid(
            id: UUID(), title: "Layouts", html: "<h2>Pick</h2>", question: nil, answer: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        ))
```

Change `[user, tool, agent]` to `[user, tool, visual, agent]` in both the `stored` mapping and `liveMessages`, and the expectation `snapshot.sourceBoundarySequence == 2` to `== 3`. The `messages`, copied kinds (`["user", "agent"]`) and seqs (`[0, 1]`) expectations stay as they are: the visual is matched, then dropped.

In `ACPSessionTranscriptReaderTests.entriesSummarizeTranscript`, append to `messages`:

```swift
            .visualAid(ACPVisualAid(
                id: UUID(), title: "Layouts", html: "<h2>secret markup</h2>", question: nil,
                answer: .answered(selectedOptionIds: ["b"], note: nil, at: Date()), createdAt: Date()
            )),
```

and extend the expectations to `["user", "tool", "tool", "agent", "tool"]`, texts `[…, "    let indented = true\n", "visual aid: Layouts (answered: b)"]`, indices `[0, 1, 2, 3, 4]`.

- [ ] **Step 2: Run to verify failure**

Run the focused command with `-only-testing AlasTests/ACPMessageTests -only-testing AlasTests/ACPSessionForkPolicyTests -only-testing AlasTests/ACPSessionTranscriptReaderTests`.
Expected: build failure, no `.visualAid` case.

- [ ] **Step 3: Add the case to `ACPMessage`**

```swift
    case systemNotice(id: UUID, text: String)
    case visualAid(ACPVisualAid)
```

`StableIdentityKey`: add `case visualAid(UUID)`. `stableIdentityKey`: `case .visualAid(let visual): .visualAid(visual.id)`. `stableId(for:)`: add `.visualAid(let id)` to the UUID group that returns `id.uuidString`. `isAgentSideProgress`: add `.visualAid` to the `true` group. `contentUTF8Length`: `case .visualAid(let visual): visual.title.utf8.count + visual.html.utf8.count`. `kind`: `case .visualAid: "visual_aid"`.

Codec `encode`: `case .visualAid(let visual): return try encoder.encode(visual)`.
Codec `decode`, before `default`:

```swift
        case "visual_aid":
            return .visualAid(try JSONDecoder().decode(ACPVisualAid.self, from: payload))
```

- [ ] **Step 4: Add the case to `ACPMessageWire`**

```swift
    case visualAid(ACPVisualAid)
```

`isAgentSideProgress`: add `.visualAid` to the `true` group. `decode`: `case "visual_aid": return .visualAid(try decoder.decode(ACPVisualAid.self, from: payload))`. `toMessage()`: `case .visualAid(let visual): return .visualAid(visual)`. `toMessage(preservingIdentityFrom:)`, before `default`:

```swift
        case let (.visualAid(visual), .visualAid(existingVisual)):
            return visual == existingVisual ? existing : .visualAid(visual)
```

- [ ] **Step 5: Fork, reader, remote and run boundaries**

`ACPSessionFork.swift`: add `.visualAid` to the `nil` list in the `conversation` compactMap (line 200) and in `forkBoundaryKind` (line 237). In `matches`, before `default`:

```swift
        case let (.visualAid(liveVisual), .visualAid(storedVisual)):
            liveVisual.id == storedVisual.id
```

`ACPSessionTranscriptReader.swift`, inside the switch:

```swift
    case .visualAid(let visual):
        append("tool", visual.transcriptSummary)
```

`RemoteSessionGateway.toWire`, before the closing brace of the switch:

```swift
        case .visualAid(let visual):
            // The phone client has no sandboxed renderer; it only learns a visual exists.
            return .init(stableId: sid, kind: "systemNotice", text: "Visual aid: \(visual.title)", json: nil, index: index)
```

`ACPSession.lastAgent()` and `lastThought()`: add `if case .visualAid = transcript.messages[i] { return nil }` next to the `.fileEdit` line, so agent text after a visual starts a new bubble.

- [ ] **Step 6: Remaining exhaustive switches**

Build. For each remaining compiler error, apply exactly:
- `ACPSessionByteAccounting.swift`: count `visual.title.utf8.count + visual.html.utf8.count`, as `contentUTF8Length` does.
- `ACPSubagentRun.swift:950-961`: put `.visualAid` with `.user, .toolCall, .fileEdit` (stops the scan).
- `ACPSubagentRowView.swift:17-26` (row identity): return the visual's `id` the same way the `.fileEdit` branch returns its UUID.
- `ACPSubagentRowView.swift:190-208` (row rendering): `case .visualAid(let visual): Label(visual.title, systemImage: "rectangle.on.rectangle").font(.callout).foregroundStyle(.secondary)`.
- `ACPTranscriptMinimap.swift:27-31`: assistant role. `:55-72`: count it the way `.fileEdit` is counted.
- `ACPTranscriptRowContent.swift` body: `case .visualAid: EmptyView()` for now; Task 8 replaces it.

- [ ] **Step 7: Run the tests**

Same command as Step 2. Expected: PASS (3 suites).

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources AlasTests
git commit -m "feat(acp): persist visual aids as transcript rows"
```

---

### Task 4: Session, runner and manager APIs

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift` (near `appendFileEdit`, line 2406; near the queue properties, line 105)
- Modify: `Alas/Sources/ACP/Session/ACPTranscript.swift` (near `replaceMessage`, line 233)
- Modify: `Alas/Sources/ACP/Session/ACPSessionRunner.swift` (lines 223-224, 4745-4797, 5176-5191)
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift` (next to `appendDelegatedNotice`, line 8678)

**Interfaces:**
- Consumes: `ACPMessage.visualAid` (Task 3), `ACPVisualAidQuestionForm` (Task 2).
- Produces:
  - `ACPTranscript.visualAid(id: UUID) -> ACPVisualAid?`
  - `ACPSession.appendVisualAid(_:)`, `ACPSession.visualAidForm(for: ACPVisualAid) -> ACPUserInputFormState?`
  - `ACPSessionRunner.appendAndPersistVisualAidAwaitingResult(_:) async -> Bool`, `ACPSessionRunner.replaceAndPersistVisualAid(_:) -> Bool`
  - `ACPSessionManager.showVisualAid(_ visual: ACPVisualAid, in sessionId: ACPSession.ID) async -> Bool`
  - `ACPSessionManager.answerVisualAid(id: UUID, answer: ACPVisualAid.Answer, in sessionId: ACPSession.ID) async -> Bool`

This task has no new unit test: the manager flow needs a live runner and lease, and the ordering is exercised in the Task 10 smoke run. Its pure pieces are pinned in Tasks 2 and 3.

- [ ] **Step 1: Transcript lookup**

In `ACPTranscript.swift`, after `replaceMessage(at:with:createdAt:)`:

```swift
    /// The visual aid with `id`, searching from the newest row.
    func visualAid(id: UUID) -> ACPVisualAid? {
        for message in messages.reversed() {
            if case .visualAid(let visual) = message, visual.id == id { return visual }
        }
        return nil
    }
```

- [ ] **Step 2: Session append and form store**

In `ACPSession.swift`, after `appendFileEdit`:

```swift
    func appendVisualAid(_ visual: ACPVisualAid) {
        clearRestoredContextRecoveryStatus()
        // Like a file edit, a visual closes the current output run.
        flushPendingReplayCandidates()
        transcript.appendMessage(.visualAid(visual))
        didAppendTranscriptMessage()
        transcript.completedOutputBoundaryMessageIds.removeAll()
    }

    /// The native form for a visual's question, created once and kept on the
    /// session so an unsent selection survives the card leaving the mount band.
    func visualAidForm(for visual: ACPVisualAid) -> ACPUserInputFormState? {
        if let form = visualAidForms[visual.id] { return form }
        guard let request = ACPVisualAidQuestionForm.request(for: visual) else { return nil }
        let form = ACPUserInputFormState(request: request)
        visualAidForms[visual.id] = form
        return form
    }
```

Next to `normalQueuedTurnIDs` (line 105):

```swift
    /// Unsent visual-aid answers by visual id. See `visualAidForm(for:)`.
    private var visualAidForms: [UUID: ACPUserInputFormState] = [:]
```

- [ ] **Step 3: Runner persistence**

Rename `awaitedNoticeRowIDs` → `awaitedRowIDs` and `writtenAwaitedNoticeRowIDs` → `writtenAwaitedRowIDs` (declarations lines 223-224, uses at 4780-4788 and 5189-5190, and the comments at 4774 and 5177): both notices and visual aids now use them.

After `appendAndPersistFileEdit` (line 4796):

```swift
    /// Append a visual aid and report whether its row reached the store, the
    /// way `appendAndPersistSystemNoticeAwaitingResult` does: `visual_show`
    /// tells the agent the visual is shown only once it would survive a reload.
    func appendAndPersistVisualAidAwaitingResult(_ visual: ACPVisualAid) async -> Bool {
        guard holdsLeaseForWrite() else { return false }
        let rowID = messageRowID(session.transcript.messages.count)
        awaitedRowIDs.insert(rowID)
        defer {
            awaitedRowIDs.remove(rowID)
            writtenAwaitedRowIDs.remove(rowID)
        }
        let before = session.transcript.messages.count
        session.appendVisualAid(visual)
        persistFromIndex(before)
        await flushPersistence()
        return writtenAwaitedRowIDs.contains(rowID)
    }

    /// Replace the visual aid with the same id in place and persist that row.
    @discardableResult
    func replaceAndPersistVisualAid(_ visual: ACPVisualAid) -> Bool {
        guard holdsLeaseForWrite(),
              let index = session.transcript.messages.firstIndex(where: {
                  if case .visualAid(let existing) = $0 { return existing.id == visual.id }
                  return false
              })
        else { return false }
        session.transcript.replaceMessage(at: index, with: .visualAid(visual))
        persistIndices([index])
        return true
    }
```

- [ ] **Step 4: Manager APIs**

In `ACPSessionManager.swift`, after `appendDelegatedNotice`:

```swift
    /// Append a visual aid an agent showed. True only once its row is written,
    /// so `visual_show` never reports a visual that a reload would lose.
    func showVisualAid(_ visual: ACPVisualAid, in sessionId: ACPSession.ID) async -> Bool {
        guard !mergingForks.contains(sessionId), sessions[sessionId] != nil else { return false }
        await awaitBackfill(id: sessionId)
        guard !mergingForks.contains(sessionId), sessions[sessionId] != nil,
              let runner = runners[sessionId], isWriter(for: sessionId)
        else { return false }
        return await runner.appendAndPersistVisualAidAwaitingResult(visual)
    }

    /// Store the user's answer on the visual, then send it to the agent as a
    /// normal prompt. The answer is stored first so a second submit finds it
    /// answered and does nothing; a failed send clears it again.
    func answerVisualAid(id visualId: UUID, answer: ACPVisualAid.Answer, in sessionId: ACPSession.ID) async -> Bool {
        guard !mergingForks.contains(sessionId), let session = sessions[sessionId],
              let runner = runners[sessionId], isWriter(for: sessionId),
              var visual = session.transcript.visualAid(id: visualId), visual.answer == nil
        else { return false }
        visual.answer = answer
        guard runner.replaceAndPersistVisualAid(visual) else { return false }
        guard let prompt = ACPVisualAidQuestionForm.answerPrompt(for: visual, answer: answer) else { return true }
        let sent = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                await self.sendPrompt(for: sessionId, text: prompt, attachments: []) { continuation.resume(returning: $0) }
            }
        }
        guard !sent else { return true }
        if var current = sessions[sessionId]?.transcript.visualAid(id: visualId), current.answer == answer {
            current.answer = nil
            runners[sessionId]?.replaceAndPersistVisualAid(current)
        }
        return false
    }
```

`sendPrompt` calls `onResult` exactly once (see its doc comment at line 401), so the continuation resumes once.

- [ ] **Step 5: Build and run the touched suites**

Run the focused command with `-only-testing AlasTests/ACPSessionManagerTests -only-testing AlasTests/ACPMessageTests`.
Expected: PASS; nothing in these suites changes behavior. The rename must not break `appendDelegatedNotice` tests.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/Session
git commit -m "feat(acp): append and answer visual aids through the session manager"
```

---

### Task 5: Socket request, router and AppState

**Files:**
- Modify: `Alas/Sources/Harness/AlasCLIRequest.swift` (`Command` lines 38-63, params structs near 211-249, command mapping near 493-524)
- Modify: `Alas/Sources/App/AlasCLICommandRouter.swift` (stored properties; `handle` lines 96-164 and 202-271)
- Modify: `Alas/Sources/App/AppState.swift` (`makeCLICommandRouter` near 7314-7472; helpers near `session(for:)` line 15466)
- Test: `AlasTests/AlasCLIRequestTests.swift`, `AlasTests/AlasCLICommandRouterTests.swift`

**Interfaces:**
- Consumes: Rust request shape (Task 1), `ACPVisualAid.validationFailure` (Task 2), `ACPSessionManager.showVisualAid` (Task 4).
- Produces: `AlasCLIRequest.Command.visualShow(title: String, html: String, question: ACPVisualAid.Question?)`; `AlasCLICommandRouter.showVisualAid: (String, ACPVisualAid) async -> AlasCLIResponse`; `AppState.isAuthorizedACPWriter(sessionID:owner:) -> Bool`; `AppState.acpManager(forSession:) -> ACPSessionManager?`.

- [ ] **Step 1: Write the failing tests**

Add to `AlasCLIRequestTests` (the JSON matches the Rust test in Task 1, Step 2):

```swift
    @Test func decodeVisualShowRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"visual_show","session_id":"acp-1","cwd":"/wt","params":{"title":"Layouts","html":"<h2>Pick</h2>","question":{"prompt":"Which?","options":[{"id":"a","label":"One"},{"id":"b","label":"Two"}],"allow_multiple":true}}}"#

        let request = try AlasCLIRequest.decode(from: Data(json.utf8))

        #expect(request.command == .visualShow(
            title: "Layouts", html: "<h2>Pick</h2>",
            question: .init(prompt: "Which?", options: [.init(id: "a", label: "One"), .init(id: "b", label: "Two")], allowMultiple: true)
        ))
    }

    @Test func visualShowOutsideTheContractIsMalformed() {
        let json = #"{"v":1,"kind":"cli","command":"visual_show","session_id":"acp-1","params":{"title":"T","html":"<p>","question":{"prompt":"Q","options":[{"id":"a","label":"One"}]}}}"#
        #expect(throws: AlasCLIRequestError.malformed) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }
```

Add to `AlasCLICommandRouterTests`:

```swift
    @Test func visualShowRequiresAnACPSession() async {
        let worktree = Self.worktree(branch: "main", path: "/tmp/repo", projectId: "p1")
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { $0 == "terminal-1" ? worktree.id : nil },
            resolveACPSessionOrigin: { _ in nil },
            originatingWorktree: { _ in worktree },
            visibleWorktrees: { [worktree] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: {}
        )
        let command = AlasCLIRequest.Command.visualShow(title: "T", html: "<p>", question: nil)

        let terminal = await router.handle(.init(version: 1, sessionId: "terminal-1", cwd: nil, command: command))
        let directory = await router.handle(.init(version: 1, sessionId: nil, cwd: worktree.path.path, command: command))

        #expect(terminal == .error("visual_show is only available to ACP agent sessions"))
        #expect(directory == .error("visual_show is only available to ACP agent sessions"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run the focused command with `-only-testing AlasTests/AlasCLIRequestTests -only-testing AlasTests/AlasCLICommandRouterTests`.
Expected: build failure, no `.visualShow`.

- [ ] **Step 3: Decode the request**

In `AlasCLIRequest.Command`, after `sessionSend`:

```swift
        /// MCP-only: show a visual aid in the calling ACP session.
        case visualShow(title: String, html: String, question: ACPVisualAid.Question?)
```

Next to the other params structs:

```swift
    private struct VisualShowParams: Decodable {
        struct Option: Decodable {
            var id: String
            var label: String
        }

        struct Question: Decodable {
            var prompt: String
            var options: [Option]
            var allow_multiple: Bool?
        }

        var title: String
        var html: String
        var question: Question?
    }
```

In the command mapping switch, next to `"session_send"`:

```swift
        case "visual_show":
            let params = try Self.decodeParams(VisualShowParams.self, from: data)
            let title = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let question = params.question.map { question in
                ACPVisualAid.Question(
                    prompt: question.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    options: question.options.map {
                        .init(id: $0.id, label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines))
                    },
                    allowMultiple: question.allow_multiple ?? false
                )
            }
            guard ACPVisualAid.validationFailure(title: title, html: params.html, question: question) == nil else {
                throw AlasCLIRequestError.malformed
            }
            command = .visualShow(title: title, html: params.html, question: question)
```

If the compiler reports another exhaustive switch over `AlasCLIRequest.Command` (for example in `virtualizingPaths(like:)`), handle `.visualShow` as a command that carries no paths.

- [ ] **Step 4: Route it**

In `AlasCLICommandRouter`, declare as the **last** stored property (so existing memberwise calls keep compiling):

```swift
    var showVisualAid: (String, ACPVisualAid) async -> AlasCLIResponse = { _, _ in
        .error("Visual aids are not available yet.")
    }
```

In `handle`, before `case .agentList, .sessionList, …` in the first switch:

```swift
        case .visualShow(let title, let html, let question):
            guard let sessionId = request.sessionId, resolveACPSessionOrigin(sessionId) != nil else {
                return .error("visual_show is only available to ACP agent sessions")
            }
            return await showVisualAid(sessionId, ACPVisualAid(
                id: UUID(), title: title, html: html, question: question, answer: nil, createdAt: Date()
            ))
```

In the second switch (after origin resolution), next to the session-command `preconditionFailure`:

```swift
        case .visualShow:
            preconditionFailure("visual_show is handled before generic origin resolution")
```

- [ ] **Step 5: Authorize and append in AppState**

Next to `session(for:)` (line 15466):

```swift
    /// The ACP half of CLI caller authorization: the session belongs to
    /// `owner`, this process drives it, and the owner still shows its ACP tab.
    func isAuthorizedACPWriter(sessionID: String, owner: SessionOwnerID) -> Bool {
        guard let session = session(for: sessionID), session.owner == owner, isWriter(for: sessionID) else { return false }
        return tabs.tabs(for: owner).contains {
            guard case .acpSession(let tab) = $0 else { return false }
            return tab.sessionId == sessionID
        }
    }

    func acpManager(forSession id: String) -> ACPSessionManager? {
        acpManagers.values.first { $0.liveSession(for: id) != nil }
    }
```

In the preview closure (lines 7460-7466), replace the inline ACP branch:

```swift
                    if self.session(for: sessionID) != nil {
                        return self.isAuthorizedACPWriter(sessionID: sessionID, owner: owner)
                    }
```

Pass the new closure as the **last** argument of the `AlasCLICommandRouter(…)` call in `makeCLICommandRouter`:

```swift
            showVisualAid: { [weak self] sessionID, visual in
                guard let self else { return .error("Alas is not available.") }
                guard let owner = sessionOwnerLookup(sessionID),
                      self.isAuthorizedACPWriter(sessionID: sessionID, owner: owner),
                      let manager = self.acpManager(forSession: sessionID),
                      await manager.showVisualAid(visual, in: sessionID)
                else { return .error("This session can't show visuals right now.") }
                return .text([#"{"visual_id":"\#(visual.id.uuidString)"}"#])
            }
```

- [ ] **Step 6: Run the tests**

Same command as Step 2, plus `-only-testing AlasTests/AppStateCLIRoutingTests` to catch a broken preview authorization.
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Harness/AlasCLIRequest.swift Alas/Sources/App/AlasCLICommandRouter.swift Alas/Sources/App/AppState.swift \
  AlasTests/AlasCLIRequestTests.swift AlasTests/AlasCLICommandRouterTests.swift
git commit -m "feat(acp): route visual_show to the calling ACP session"
```

---

### Task 6: Sandbox policy, frame template and page budget

**Files:**
- Create: `Alas/Sources/ACP/VisualAid/VisualAidWebPolicy.swift`
- Create: `Alas/Sources/ACP/VisualAid/VisualAidPageBudget.swift`
- Create: `Alas/Resources/VisualAid/frame.html`
- Modify: `project.yml` (resources list, lines 46-66)
- Test: `AlasTests/ACP/UI/VisualAidWebPolicyTests.swift` (new suite)

**Interfaces:**
- Consumes: `PluginWebPolicy.Response`, `PluginWebPolicy.cssVariables(_:)`, `PluginWebPolicy.externalLink(_:)`.
- Produces: `VisualAidWebPolicy` (`scheme`, `contentSecurityPolicy`, `contentRules`, `contentRuleListIdentifier`, `bridgeWorldName`, `bridgeHandlerName`, `bridgeScript`, `minCardHeight`, `maxCardHeight`, `maxLivePages`, `documentURL(visualID:)`, `response(for:visualID:document:)`, `allowsNavigation(to:mainFrame:visualID:)`, `isFullDocument(_:)`, `document(html:themeVariables:frameTemplate:)`, `cardHeight(forContentHeight:)`); `VisualAidFrameTemplate.html`; `VisualAidPageLRU`; `VisualAidPageBudget.shared.admit(_:onEvict:)`/`release(_:)`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/ACP/UI/VisualAidWebPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

/// File scope so `@Test(arguments:)` can interpolate it.
private let visualHost = "6f0c2d4e-8b1a-4c3d-9e5f-1a2b3c4d5e6f"

struct VisualAidWebPolicyTests {
    private static let id = UUID(uuidString: "6F0C2D4E-8B1A-4C3D-9E5F-1A2B3C4D5E6F")!
    private static let template = "<html><head>{{HEAD}}</head><body>{{CONTENT}}</body></html>"

    @Test(arguments: [
        ("alas-visual://\(visualHost)/", 200),
        ("alas-visual://\(visualHost)/other", 404),
        ("alas-visual://\(visualHost)/?x=1", 404),
        ("alas-visual://\(visualHost):80/", 404),
        ("alas-visual://u@\(visualHost)/", 404),
        ("alas-visual://00000000-0000-0000-0000-000000000000/", 404),
        ("https://\(visualHost)/", 404),
    ])
    func theSchemeHandlerServesOnlyTheDocument(url: String, status: Int) throws {
        let response = VisualAidWebPolicy.response(for: try #require(URL(string: url)), visualID: Self.id, document: Data("doc".utf8))
        #expect(response.status == status)
        #expect(response.body == (status == 200 ? Data("doc".utf8) : Data()))
        #expect(response.headers["Content-Security-Policy"] == VisualAidWebPolicy.contentSecurityPolicy)
    }

    @Test(arguments: [
        ("alas-visual://\(visualHost)/", true, true),
        ("alas-visual://\(visualHost)/#section", true, true),
        ("alas-visual://\(visualHost)/", false, false),
        ("https://example.com/", true, false),
    ])
    func navigationStaysOnTheDocument(url: String, mainFrame: Bool, allowed: Bool) {
        #expect(VisualAidWebPolicy.allowsNavigation(to: URL(string: url), mainFrame: mainFrame, visualID: Self.id) == allowed)
    }

    @Test(arguments: [
        ("<!DOCTYPE html><html></html>", true),
        ("  \n<!doctype html>", true),
        ("<!-- note --> <HTML lang=\"en\">", true),
        ("<!-- unterminated <html>", false),
        ("<div>hi</div>", false),
        ("<h2>html</h2>", false),
    ])
    func fullDocumentDetection(html: String, full: Bool) {
        #expect(VisualAidWebPolicy.isFullDocument(html) == full)
    }

    @Test("fragments go inside the template verbatim, placeholders included")
    func fragmentAssembly() {
        let html = "<p>{{CONTENT}} and {{HEAD}}</p>"
        let document = String(decoding: VisualAidWebPolicy.document(html: html, themeVariables: ["--alas-text": "red"], frameTemplate: Self.template), as: UTF8.self)
        #expect(document.contains("<body><p>{{CONTENT}} and {{HEAD}}</p></body>"))
        #expect(document.contains("--alas-text: red;"))
        #expect(document.contains(VisualAidWebPolicy.contentSecurityPolicy))
    }

    @Test("full documents are kept intact; theme variables go after <head> or at the end", arguments: [
        ("<!DOCTYPE html><html><HEAD lang=\"x\"><title>t</title></HEAD><body>b</body></html>", "<HEAD lang=\"x\"><meta"),
        ("<html><body>b</body></html>", "<html><body>b</body></html><meta"),
    ])
    func fullDocumentAssembly(html: String, expectedSubstring: String) {
        let document = String(decoding: VisualAidWebPolicy.document(html: html, themeVariables: ["--alas-text": "red"], frameTemplate: Self.template), as: UTF8.self)
        #expect(document.contains(expectedSubstring))
        #expect(!document.contains("{{CONTENT}}"))
        #expect(document.contains("--alas-text: red;"))
    }

    @Test("the sandbox never allows connections or form posts")
    func cspBlocksExfiltrationChannels() {
        #expect(VisualAidWebPolicy.contentSecurityPolicy.contains("connect-src 'none'"))
        #expect(VisualAidWebPolicy.contentSecurityPolicy.contains("form-action 'none'"))
    }

    @Test("the page budget closes the least recently admitted page")
    func pageBudgetEvictsLeastRecent() {
        var lru = VisualAidPageLRU(limit: 2)
        let a = UUID(), b = UUID(), c = UUID()
        #expect(lru.admit(a).isEmpty)
        #expect(lru.admit(b).isEmpty)
        #expect(lru.admit(a).isEmpty)
        #expect(lru.admit(c) == [b])
        lru.release(a)
        #expect(lru.admit(b).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run `xcodegen`, then the focused command with `-only-testing AlasTests/VisualAidWebPolicyTests`.
Expected: build failure, `VisualAidWebPolicy` not found.

- [ ] **Step 3: Implement the policy**

Create `Alas/Sources/ACP/VisualAid/VisualAidWebPolicy.swift`:

```swift
import Foundation

/// The sandbox a visual aid runs in: what the scheme handler serves, what may
/// load, and how agent HTML becomes a document. Pure, so it is testable without
/// a web view. Agent pages get inline scripts and https CDN loads, which the
/// plugin sandbox forbids, because they hold nothing but the agent's own HTML.
enum VisualAidWebPolicy {
    static let scheme = "alas-visual"
    static let contentRuleListIdentifier = "alas-visual-aid-v1"
    static let bridgeWorldName = "alas-visual-bridge"
    static let bridgeHandlerName = "alasVisual"
    static let minCardHeight: CGFloat = 120
    static let maxCardHeight: CGFloat = 720
    static let maxLivePages = 4

    static let contentSecurityPolicy =
        "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; "
        + "img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; "
        + "worker-src 'none'; form-action 'none'; base-uri 'none'"

    static let contentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^alas-visual:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^https:", "resource-type": ["script", "style-sheet", "image", "font"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:", "resource-type": ["image", "font"]}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    static func documentURL(visualID: UUID) -> URL {
        URL(string: "\(scheme)://\(visualID.uuidString.lowercased())/")!
    }

    static func response(for url: URL, visualID: UUID, document: Data) -> PluginWebPolicy.Response {
        var headers = [
            "Content-Security-Policy": contentSecurityPolicy,
            "X-DNS-Prefetch-Control": "off",
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
        ]
        guard url.scheme == scheme,
              url.host(percentEncoded: true) == visualID.uuidString.lowercased(),
              url.user == nil, url.port == nil,
              url.query(percentEncoded: true) == nil,
              url.path(percentEncoded: true) == "/"
        else {
            headers["Content-Type"] = "text/plain; charset=utf-8"
            return .init(status: 404, headers: headers, body: Data())
        }
        headers["Content-Type"] = "text/html; charset=utf-8"
        return .init(status: 200, headers: headers, body: document)
    }

    /// Only the document itself, in the main frame. Links reach the browser through the bridge instead.
    static func allowsNavigation(to url: URL?, mainFrame: Bool, visualID: UUID) -> Bool {
        guard mainFrame, let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.fragment = nil
        return components.url == documentURL(visualID: visualID)
    }

    /// True when `html`, after leading whitespace and comments, opens with a doctype or `<html`.
    static func isFullDocument(_ html: String) -> Bool {
        var rest = Substring(html)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard rest.hasPrefix("<!--") else { break }
            guard let end = rest.range(of: "-->") else { return false }
            rest = rest[end.upperBound...]
        }
        let opening = rest.prefix(9).lowercased()
        return opening.hasPrefix("<!doctype") || opening.hasPrefix("<html")
    }

    /// Fragments go inside the frame template. Full documents stay as written,
    /// with the CSP meta and theme variables inserted after `<head>`, or
    /// appended when there is none (the CSP header applies either way).
    static func document(html: String, themeVariables: [String: String], frameTemplate: String) -> Data {
        let css = themeVariables.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value);" }.joined(separator: " ")
        let head = #"<meta http-equiv="Content-Security-Policy" content="\#(contentSecurityPolicy)"><style>:root { \#(css) }</style>"#
        guard isFullDocument(html) else {
            // Split rather than replace so the agent's HTML is never scanned for placeholders.
            let parts = frameTemplate.replacingOccurrences(of: "{{HEAD}}", with: head).components(separatedBy: "{{CONTENT}}")
            return Data((parts.first ?? "").appending(html).appending(parts.dropFirst().joined(separator: "{{CONTENT}}")).utf8)
        }
        if let range = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            var result = html
            result.insert(contentsOf: head, at: range.upperBound)
            return Data(result.utf8)
        }
        return Data((html + head).utf8)
    }

    static func cardHeight(forContentHeight height: CGFloat) -> CGFloat {
        min(max(height, minCardHeight), maxCardHeight)
    }

    /// Runs in the isolated bridge world at document end. Page scripts cannot
    /// reach `webkit.messageHandlers` from their own world.
    static let bridgeScript = """
    (() => {
      const post = (message) => window.webkit.messageHandlers.\(bridgeHandlerName).postMessage(message);
      const reportHeight = () => post({ height: Math.ceil(document.documentElement.getBoundingClientRect().height) });
      const observer = new ResizeObserver(reportHeight);
      observer.observe(document.documentElement);
      if (document.body) observer.observe(document.body);
      addEventListener('load', reportHeight);
      document.addEventListener('click', (event) => {
        if (!event.isTrusted || !(event.target instanceof Element)) return;
        const link = event.target.closest('a[href]');
        if (link) {
          event.preventDefault();
          post({ open: link.href });
          return;
        }
        const choice = event.target.closest('[data-choice]');
        if (choice) post({ choice: String(choice.getAttribute('data-choice')).slice(0, 64) });
      }, true);
      globalThis.alasVisualSelect = (ids) => {
        for (const element of document.querySelectorAll('[data-choice]')) {
          element.classList.toggle('selected', ids.includes(element.getAttribute('data-choice')));
        }
      };
      globalThis.alasVisualTheme = (variables) => {
        for (const [name, value] of Object.entries(variables)) {
          document.documentElement.style.setProperty(name, value);
        }
      };
    })();
    """
}

/// The bundled frame template fragments are wrapped in.
enum VisualAidFrameTemplate {
    static let html: String = {
        guard let url = Bundle.main.url(forResource: "frame", withExtension: "html", subdirectory: "VisualAid"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("VisualAid/frame.html is missing from the app bundle")
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">{{HEAD}}</head><body>{{CONTENT}}</body></html>"
        }
        return text
    }()
}
```

- [ ] **Step 4: Implement the page budget**

Create `Alas/Sources/ACP/VisualAid/VisualAidPageBudget.swift`:

```swift
import Foundation

/// Least-recently-admitted order behind the live visual page cap.
struct VisualAidPageLRU: Equatable {
    let limit: Int
    private(set) var order: [UUID] = []

    /// Admits `slot` as the most recent page and returns the slots that must close.
    mutating func admit(_ slot: UUID) -> [UUID] {
        order.removeAll { $0 == slot }
        order.append(slot)
        let overflow = max(0, order.count - limit)
        let evicted = Array(order.prefix(overflow))
        order.removeFirst(overflow)
        return evicted
    }

    mutating func release(_ slot: UUID) {
        order.removeAll { $0 == slot }
    }
}

/// App-wide cap on live visual pages; each one costs a WebContent process.
/// Slots are per card instance, so an inline card and its pop-out tab count twice.
@MainActor
final class VisualAidPageBudget {
    static let shared = VisualAidPageBudget()

    private var lru = VisualAidPageLRU(limit: VisualAidWebPolicy.maxLivePages)
    private var evictors: [UUID: () -> Void] = [:]

    func admit(_ slot: UUID, onEvict: @escaping () -> Void) {
        evictors[slot] = onEvict
        for evicted in lru.admit(slot) {
            evictors.removeValue(forKey: evicted)?()
        }
    }

    func release(_ slot: UUID) {
        lru.release(slot)
        evictors.removeValue(forKey: slot)
    }
}
```

- [ ] **Step 5: Add the frame template**

Create `Alas/Resources/VisualAid/frame.html`:

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{{HEAD}}
<style>
  :root { color-scheme: light dark; font: 13px -apple-system, system-ui, sans-serif; }
  html, body { margin: 0; }
  body { padding: 16px; color: var(--alas-text, CanvasText); background: var(--alas-background, Canvas); line-height: 1.45; }
  h2 { font-size: 17px; margin: 0 0 4px; }
  h3 { font-size: 14px; margin: 0 0 4px; }
  .subtitle { color: var(--alas-dim, GrayText); margin: 0 0 14px; }
  .section { margin-bottom: 16px; }
  .label { font-size: 10.5px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--alas-dim, GrayText); }
  .options, .cards { display: grid; gap: 10px; }
  .options { grid-template-columns: 1fr; }
  .cards { grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); }
  .option, .card { border: 1px solid var(--alas-line, #8884); border-radius: 8px; cursor: pointer; transition: border-color .12s, box-shadow .12s; }
  .option { display: flex; gap: 12px; align-items: flex-start; padding: 12px; }
  .option .letter { flex: none; width: 24px; height: 24px; border-radius: 6px; display: grid; place-items: center; font-weight: 700; background: var(--alas-line, #8884); }
  .option.selected, .card.selected { border-color: var(--alas-accent, AccentColor); box-shadow: 0 0 0 1px var(--alas-accent, AccentColor); }
  .option.selected .letter { background: var(--alas-accent, AccentColor); color: var(--alas-background, Canvas); }
  .card-image { min-height: 120px; padding: 12px; border-bottom: 1px solid var(--alas-line, #8884); }
  .card-body { padding: 10px 12px; }
  .mockup { border: 1px solid var(--alas-line, #8884); border-radius: 8px; overflow: hidden; }
  .mockup-header { padding: 6px 10px; font-size: 11px; color: var(--alas-dim, GrayText); border-bottom: 1px solid var(--alas-line, #8884); }
  .mockup-body { padding: 12px; }
  .split { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .pros-cons { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .pros h4 { color: var(--alas-tone-success, green); }
  .cons h4 { color: var(--alas-tone-danger, red); }
  .mock-nav { padding: 8px 12px; border: 1px solid var(--alas-line, #8884); border-radius: 6px; margin-bottom: 8px; }
  .mock-sidebar { width: 160px; padding: 10px; border: 1px dashed var(--alas-line, #8884); border-radius: 6px; margin-right: 8px; }
  .mock-content { flex: 1; padding: 10px; border: 1px dashed var(--alas-line, #8884); border-radius: 6px; }
  .mock-button { font: inherit; padding: 6px 12px; border-radius: 6px; border: 1px solid var(--alas-accent, AccentColor); background: var(--alas-accent, AccentColor); color: var(--alas-background, Canvas); }
  .mock-input { font: inherit; padding: 6px 8px; border-radius: 6px; border: 1px solid var(--alas-line, #8884); background: transparent; color: inherit; }
  .placeholder { display: grid; place-items: center; min-height: 80px; border: 1px dashed var(--alas-line, #8884); border-radius: 6px; color: var(--alas-dim, GrayText); }
</style>
<script>
  // Agent habits from the superpowers companion call these; selection is drawn by Alas.
  function toggleSelect() {}
</script>
</head>
<body>{{CONTENT}}</body>
</html>
```

In `project.yml`, add to the app target's resources (next to `Alas/Resources/RemoteWeb`):

```yaml
      - path: Alas/Resources/VisualAid
        buildPhase: resources
        type: folder
```

- [ ] **Step 6: Run the tests**

Run `xcodegen`, then the focused command with `-only-testing AlasTests/VisualAidWebPolicyTests`.
Expected: PASS, 7 tests.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/ACP/VisualAid Alas/Resources/VisualAid AlasTests/ACP/UI/VisualAidWebPolicyTests.swift project.yml Alas.xcodeproj
git commit -m "feat(acp): add the visual aid sandbox policy and frame"
```

---

### Task 7: `VisualAidWebPage`

**Files:**
- Create: `Alas/Sources/ACP/VisualAid/VisualAidWebPage.swift`

**Interfaces:**
- Consumes: `VisualAidWebPolicy`, `VisualAidFrameTemplate` (Task 6), `PluginWebPolicy.cssVariables`, `PluginWebPolicy.externalLink`.
- Produces: `@MainActor @Observable final class VisualAidWebPage` with `init(visualID: UUID, html: String, theme: Theme)`, `webView: WKWebView`, `status: Status` (`.loading`, `.ready`, `.sandboxFailed`, `.stopped(canReload: Bool)`), `contentHeight: CGFloat`, `onChoice: (String) -> Void`, `reload()`, `setSelected(_ ids: [String])`, `applyTheme(_ theme: Theme)`, `close()`; `struct VisualAidWebSurface: NSViewRepresentable`.

No unit test: the decisions it relies on are pinned in Task 6; WebKit behavior is checked in the Task 10 smoke run.

- [ ] **Step 1: Implement the page**

Create `Alas/Sources/ACP/VisualAid/VisualAidWebPage.swift`:

```swift
import AppKit
import SwiftUI
import WebKit

/// One visual aid's page: a WKWebView with a non-persistent data store, served
/// only by its scheme handler, plus an isolated bridge that reports height,
/// `data-choice` clicks and link clicks.
@MainActor
@Observable
final class VisualAidWebPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Status: Equatable {
        case loading
        case ready
        case sandboxFailed
        case stopped(canReload: Bool)
    }

    static let maxCrashes = 3
    @ObservationIgnored private static let bridgeWorld = WKContentWorld.world(name: VisualAidWebPolicy.bridgeWorldName)
    @ObservationIgnored private static var compiledRules: Task<WKContentRuleList?, Never>?

    @ObservationIgnored let webView: WKWebView
    private(set) var status: Status = .loading
    private(set) var contentHeight: CGFloat = VisualAidWebPolicy.minCardHeight
    @ObservationIgnored var onChoice: (String) -> Void = { _ in }
    @ObservationIgnored var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored private let visualID: UUID
    @ObservationIgnored private let schemeHandler: VisualAidSchemeHandler
    @ObservationIgnored private var crashes = 0
    @ObservationIgnored private var isClosed = false

    init(visualID: UUID, html: String, theme: Theme) {
        self.visualID = visualID
        schemeHandler = VisualAidSchemeHandler(
            visualID: visualID,
            document: VisualAidWebPolicy.document(
                html: html,
                themeVariables: PluginWebPolicy.cssVariables(theme),
                frameTemplate: VisualAidFrameTemplate.html
            )
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: VisualAidWebPolicy.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.allowsLinkPreview = false
        super.init()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: VisualAidWebPolicy.bridgeScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.bridgeWorld))
        // Removed in `close`; the controller retains its handler.
        controller.add(self, contentWorld: Self.bridgeWorld, name: VisualAidWebPolicy.bridgeHandlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Task { await load() }
    }

    /// Loads the document once the content rules are in place; without them it never loads.
    private func load() async {
        guard let rules = await Self.contentRuleList() else {
            status = .sandboxFailed
            return
        }
        guard !isClosed else { return }
        webView.configuration.userContentController.add(rules)
        webView.load(URLRequest(url: VisualAidWebPolicy.documentURL(visualID: visualID)))
    }

    private static func contentRuleList() async -> WKContentRuleList? {
        if let compiledRules, let rules = await compiledRules.value { return rules }
        let task = Task { @MainActor in
            try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: VisualAidWebPolicy.contentRuleListIdentifier,
                encodedContentRuleList: VisualAidWebPolicy.contentRules)
        }
        compiledRules = task
        return await task.value
    }

    func reload() {
        guard !isClosed, case .stopped(true) = status else { return }
        status = .loading
        webView.load(URLRequest(url: VisualAidWebPolicy.documentURL(visualID: visualID)))
    }

    func setSelected(_ ids: [String]) {
        guard !isClosed, status == .ready else { return }
        webView.callAsyncJavaScript(
            "alasVisualSelect(ids)", arguments: ["ids": ids], in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    func applyTheme(_ theme: Theme) {
        guard !isClosed, status == .ready else { return }
        webView.callAsyncJavaScript(
            "alasVisualTheme(variables)", arguments: ["variables": PluginWebPolicy.cssVariables(theme)],
            in: nil, in: Self.bridgeWorld, completionHandler: nil)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let controller = webView.configuration.userContentController
        controller.removeAllScriptMessageHandlers()
        controller.removeAllUserScripts()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: Bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isClosed, message.world.name == Self.bridgeWorld.name, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any]
        else { return }
        if let height = body["height"] as? Double {
            contentHeight = max(0, CGFloat(height))
        } else if let choice = body["choice"] as? String {
            onChoice(choice)
        } else if let link = body["open"] as? String, let url = PluginWebPolicy.externalLink(link) {
            openExternal(url)
        }
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let allowed = !isClosed && !navigationAction.shouldPerformDownload && VisualAidWebPolicy.allowsNavigation(
            to: navigationAction.request.url,
            mainFrame: navigationAction.targetFrame?.isMainFrame == true,
            visualID: visualID)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(!isClosed && navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        status = .ready
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        crashes += 1
        status = .stopped(canReload: crashes < Self.maxCrashes)
    }

    /// `target=_blank` and `window.open` never get a window; https targets open in the browser.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let text = navigationAction.request.url?.absoluteString, let url = PluginWebPolicy.externalLink(text) {
            openExternal(url)
        }
        return nil
    }
}

@MainActor
private final class VisualAidSchemeHandler: NSObject, WKURLSchemeHandler {
    let visualID: UUID
    let document: Data

    init(visualID: UUID, document: Data) {
        self.visualID = visualID
        self.document = document
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let response = VisualAidWebPolicy.response(for: url, visualID: visualID, document: document)
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
        else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(http)
        task.didReceive(response.body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

struct VisualAidWebSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
```

If `@Observable` on this `NSObject` subclass does not compile with the project's toolchain, drop `@Observable` and the `@ObservationIgnored` markers, conform to `ObservableObject`, and mark `status` and `contentHeight` `@Published`. Task 8 then keeps the page in `@State` as written, but moves `surface` and the height read into a small child view that takes the page as `@ObservedObject`, so status and height changes re-render.

- [ ] **Step 2: Build**

Run `xcodegen`, then the build-only command.
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/ACP/VisualAid/VisualAidWebPage.swift project.yml Alas.xcodeproj
git commit -m "feat(acp): host visual aids in a sandboxed web view"
```

---

### Task 8: Transcript card

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPVisualAidCard.swift`
- Modify: `Alas/Sources/ACP/UI/ACPUserInputPrompt.swift:13-27` (second initializer)
- Modify: `Alas/Sources/ACP/UI/ACPTranscriptRowContent.swift` (property after `delegatedLabel`, line 75; body `.visualAid` case)
- Modify: `Alas/Sources/ACP/UI/Scroller/ACPTranscriptScroller.swift` (stored property; `messageRow` lines 845-869; parking after line 567)
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift` (property; scroller call lines 62-100)
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift` (`messageList(...)` call near lines 516-555)
- Modify: `Alas/Sources/ACP/UI/ACPToolCallPresentation.swift:43` (rule before MCP)
- Test: `AlasTests/ACP/UI/ACPToolCallPresentationTests.swift`

**Interfaces:**
- Consumes: `VisualAidWebPage`, `VisualAidWebSurface`, `VisualAidPageBudget` (Tasks 6-7), `ACPSession.visualAidForm(for:)`, `ACPSessionManager.answerVisualAid` (Task 4), `ACPVisualAidQuestionForm` (Task 2).
- Produces: `struct ACPVisualAidActions { var answer: (UUID, ACPVisualAid.Answer) async -> Bool; var popOut: (ACPVisualAid) -> Void; static var readOnly: Self }`; `struct ACPVisualAidCard: View` with `init(visual:form:actions:fillsHeight:)`. Task 9 supplies the real `popOut`.

- [ ] **Step 1: Write the failing presentation test**

Add to `ACPToolCallPresentationTests`:

```swift
    @Test("visual_show reads as a visual aid, not a generic MCP call", arguments: [
        ("mcp__alas__visual_show", "mcp__alas__visual_show"),
        ("alas.visual_show", nil),
    ] as [(String, String?)])
    func visualShowPresentation(title: String, name: String?) {
        let presentation = ACPToolCallPresentation.resolve(toolCall(title: title, name: name))
        #expect(presentation.label == "Visual aid")
        #expect(presentation.iconSystemName == "rectangle.on.rectangle")
        #expect(presentation.style == .mcp)
    }
```

- [ ] **Step 2: Run to verify failure**

Run the focused command with `-only-testing AlasTests/ACPToolCallPresentationTests`.
Expected: FAIL, label is `"MCP"`.

- [ ] **Step 3: Add the presentation rule**

In `ACPToolCallPresentation.resolve`, directly before the MCP rule (line 43):

```swift
        if name?.contains("visual_show") == true || lowerTitle.contains("visual_show") {
            return .init(label: "Visual aid", iconSystemName: "rectangle.on.rectangle", style: .mcp)
        }
```

Run the same command. Expected: PASS.

- [ ] **Step 4: Let `ACPUserInputPrompt` share a form state**

After the existing initializer in `ACPUserInputPrompt.swift`:

```swift
    /// Renders a form whose state the caller owns, so something other than
    /// these controls (a visual aid's page clicks) can edit the same selection.
    init(
        formState: ACPUserInputFormState,
        onRespond: @escaping (UUID, ACPUserInputAction) -> Void,
        onOpenURL: @escaping (UUID) async -> Bool,
        showsDismissActions: Bool = true
    ) {
        self.request = formState.request
        self.onRespond = onRespond
        self.onOpenURL = onOpenURL
        self.showsDismissActions = showsDismissActions
        _formState = State(initialValue: formState)
    }
```

- [ ] **Step 5: Implement the card**

Create `Alas/Sources/ACP/UI/ACPVisualAidCard.swift`:

```swift
import AppKit
import SwiftUI

/// What a visual aid card can ask its host to do.
struct ACPVisualAidActions {
    var answer: (UUID, ACPVisualAid.Answer) async -> Bool
    var popOut: (ACPVisualAid) -> Void

    /// For hosts that only display transcripts.
    static var readOnly: Self { .init(answer: { _, _ in false }, popOut: { _ in }) }
}

/// A visual aid in the transcript (or filling a pop-out tab): the sandboxed
/// page plus, when it asks one, the native question card.
struct ACPVisualAidCard: View {
    let visual: ACPVisualAid
    let form: ACPUserInputFormState?
    let actions: ACPVisualAidActions
    var fillsHeight = false

    @Environment(\.theme) private var theme
    @State private var slot = UUID()
    @State private var page: VisualAidWebPage?
    @State private var paused = false
    @State private var sending = false
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            surface
                .frame(height: fillsHeight ? nil : VisualAidWebPolicy.cardHeight(
                    forContentHeight: page?.contentHeight ?? VisualAidWebPolicy.minCardHeight))
                .frame(maxHeight: fillsHeight ? .infinity : nil)
            if let question = visual.question {
                Divider()
                questionArea(question)
            }
        }
        .background(theme.color("bg-1"))
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 1))
        .onAppear(perform: openPage)
        .onDisappear(perform: closePage)
        .onChange(of: theme.id) { page?.applyTheme(theme) }
        .onChange(of: page?.status) { syncSelection() }
        .onChange(of: form?.selectionValues[ACPVisualAidQuestionForm.choiceKey]) { syncSelection() }
        .onChange(of: visual.answer) {
            installChoiceHandler()
            syncSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(theme.color("accent"))
            Text(visual.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: copyHTML) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy HTML")
            if !fillsHeight {
                Button { actions.popOut(visual) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help("Open in a tab")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var surface: some View {
        if let page {
            switch page.status {
            case .sandboxFailed:
                placeholder("Couldn't set up the visual's sandbox")
            case .stopped(let canReload):
                placeholder("Visual stopped", button: canReload ? ("Reload", { page.reload() }) : nil)
            case .loading, .ready:
                VisualAidWebSurface(webView: page.webView)
            }
        } else {
            placeholder(paused ? "Visual paused to save memory" : "Visual not loaded", button: ("Show visual", openPage))
        }
    }

    private func placeholder(_ text: String, button: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            Text(text).foregroundStyle(theme.color("fg-muted"))
            if let button {
                Button(button.0, action: button.1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func questionArea(_ question: ACPVisualAid.Question) -> some View {
        switch visual.answer {
        case .answered(let ids, let note, _):
            let labels = Dictionary(uniqueKeysWithValues: question.options.map { ($0.id, $0.label) })
            VStack(alignment: .leading, spacing: 4) {
                Text("Answered: " + ids.map { "\($0), \(labels[$0] ?? $0)" }.joined(separator: "; "))
                if let note { Text("Note: \(note)").foregroundStyle(theme.color("fg-muted")) }
            }
            .font(.callout)
            .padding(12)
        case .dismissed:
            Text("Dismissed").font(.callout).foregroundStyle(theme.color("fg-muted")).padding(12)
        case nil:
            if let form {
                VStack(alignment: .leading, spacing: 6) {
                    ACPUserInputPrompt(
                        formState: form,
                        onRespond: { _, action in respond(action, question: question) },
                        onOpenURL: { _ in false }
                    )
                    .disabled(sending)
                    if let sendError {
                        Text(sendError).font(.callout).foregroundStyle(theme.color("del"))
                    }
                }
                .padding(8)
            }
        }
    }

    private func respond(_ action: ACPUserInputAction, question: ACPVisualAid.Question) {
        let answer: ACPVisualAid.Answer
        switch action {
        case .submit(let content):
            guard let answered = ACPVisualAidQuestionForm.answer(from: content, question: question, at: Date()) else { return }
            answer = answered
        case .decline, .cancel:
            answer = .dismissed(at: Date())
        }
        sending = true
        sendError = nil
        let visualID = visual.id
        Task {
            let ok = await actions.answer(visualID, answer)
            sending = false
            if !ok { sendError = "Couldn't send your answer. Try again." }
        }
    }

    private func openPage() {
        guard page == nil else { return }
        let page = VisualAidWebPage(visualID: visual.id, html: visual.html, theme: theme)
        self.page = page
        paused = false
        installChoiceHandler()
        let pageBinding = $page
        let pausedBinding = $paused
        VisualAidPageBudget.shared.admit(slot) {
            pageBinding.wrappedValue?.close()
            pageBinding.wrappedValue = nil
            pausedBinding.wrappedValue = true
        }
    }

    private func closePage() {
        page?.close()
        page = nil
        VisualAidPageBudget.shared.release(slot)
    }

    /// Page clicks edit the native form only while the question is open.
    private func installChoiceHandler() {
        guard let page else { return }
        guard visual.answer == nil, let form else {
            page.onChoice = { _ in }
            return
        }
        page.onChoice = { choice in
            guard let field = ACPVisualAidQuestionForm.choiceField(for: choice, in: form.request) else { return }
            form.toggle(choice, for: field)
        }
    }

    private func syncSelection() {
        guard let page else { return }
        if case .answered(let ids, _, _) = visual.answer {
            page.setSelected(ids)
        } else {
            page.setSelected(Array(form?.selectionValues[ACPVisualAidQuestionForm.choiceKey] ?? []))
        }
    }

    private func copyHTML() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visual.html, forType: .string)
    }
}
```

If `Theme` has no `id` property, change the theme `onChange` to observe whatever `Equatable` value `PluginWebTabView` uses to re-apply themes (`PluginWebView.swift:539-599`).

- [ ] **Step 6: Thread the actions to the row**

`ACPTranscriptRowContent`: add after `delegatedLabel` (line 75):

```swift
    var visualAidActions: ACPVisualAidActions = .readOnly
```

and replace the Task 3 placeholder branch in `body`:

```swift
        case .visualAid(let visual):
            ACPVisualAidCard(visual: visual, form: session.visualAidForm(for: visual), actions: visualAidActions)
```

`ACPTranscriptScroller`: add as its **last** stored property `var visualAidActions: ACPVisualAidActions = .readOnly`; in `messageRow` pass `visualAidActions: host.visualAidActions` as the last argument of `ACPTranscriptRowContent(…)`. After the `parksWhenReleased = false` block at line 567:

```swift
                // A parked graph would keep the visual's web page and its process alive.
                if case .message(let row) = renderRow,
                   transcript.messages.indices.contains(row.index),
                   case .visualAid = transcript.messages[row.index] {
                    specs[specs.count - 1].parksWhenReleased = false
                }
```

`ACPMessageList`: add `var visualAidActions: ACPVisualAidActions = .readOnly` after `upstreamReferences`, and pass `visualAidActions: visualAidActions` as the last argument of `ACPTranscriptScroller(…)`.

`ACPTabView.swift`, in the `messageList(...)` call that builds `ACPMessageList` (near the `onUserInputResponse:` closure), add as the last argument:

```swift
            visualAidActions: ACPVisualAidActions(
                answer: { visualId, answer in
                    await manager.answerVisualAid(id: visualId, answer: answer, in: sessionId)
                },
                popOut: { _ in }
            )
```

Task 9 replaces `popOut`.

- [ ] **Step 7: Build and run the suites**

Run the focused command with `-only-testing AlasTests/ACPToolCallPresentationTests -only-testing AlasTests/ACPTranscriptRowContentTests -only-testing AlasTests/ACPUserInputFormStateTests`.
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/ACP/UI AlasTests/ACP/UI/ACPToolCallPresentationTests.swift project.yml Alas.xcodeproj
git commit -m "feat(acp): render visual aids and their questions in the transcript"
```

---

### Task 9: Pop-out tab

**Files:**
- Create: `Alas/Sources/ACP/UI/VisualAidTabView.swift`
- Modify: `Alas/Sources/Center/Tab.swift` (case list line 30, `id` 32-59, `title` 61-88, `iconName` 90-117, `isRestorable` 119-123; new state struct near `WebPreviewTabState` line 187)
- Modify: `Alas/Sources/Center/TabsManager.swift` (new method near `openOrFocusRunReport`, line 1220)
- Modify: `Alas/Sources/Center/CenterPaneView.swift` (`isSharedSessionTab` 74-82; render switch near 694-705)
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift` (`popOut` from Task 8)

**Interfaces:**
- Consumes: `ACPVisualAidCard`, `ACPVisualAidActions` (Task 8); `AppState.session(for:)`, `AppState.acpManager(forSession:)` (Task 5); `ACPTranscript.visualAid(id:)` (Task 4).
- Produces: `struct VisualAidTabState: Codable, Equatable, Identifiable`, `Tab.visualAid(VisualAidTabState)`, `TabsManager.openOrFocusVisualAid(owner:state:)`.

No unit test: tab composition is view wiring; the smoke run covers it.

- [ ] **Step 1: Tab state and case**

In `Tab.swift`, near `WebPreviewTabState`:

```swift
struct VisualAidTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let sessionId: String
    let visualId: UUID
    let title: String

    init(sessionId: String, visualId: UUID, title: String) {
        self.sessionId = sessionId
        self.visualId = visualId
        self.title = title
        self.id = "visual-aid:\(visualId.uuidString)"
    }
}
```

Add `case visualAid(VisualAidTabState)` after `case plugin(PluginTabState)`. In `id`: `case .visualAid(let s): return s.id`. In `title`: `case .visualAid(let s): return s.title`. In `iconName`: `case .visualAid: return "rectangle.on.rectangle"`. In `isRestorable`, before `return true`:

```swift
        // The visual lives in a session transcript that may not be live after relaunch.
        if case .visualAid = self { return false }
```

Fix any other exhaustive `Tab` switch the compiler reports by grouping `.visualAid` with `.webPreview`.

- [ ] **Step 2: Open or focus**

In `TabsManager.swift`, near `openOrFocusRunReport`:

```swift
    @discardableResult
    func openOrFocusVisualAid(owner: SessionOwnerID, state: VisualAidTabState) -> Tab {
        let key = owner.storageKey
        if let existing = tabs(forWorktree: key).first(where: { $0.id == state.id }) {
            activate(worktreeId: key, tabId: state.id)
            return existing
        }
        let tab = Tab.visualAid(state)
        append(tab, to: key)
        return tab
    }
```

- [ ] **Step 3: Tab view**

Create `Alas/Sources/ACP/UI/VisualAidTabView.swift`:

```swift
import SwiftUI

/// A visual aid popped out of the transcript into a center tab.
struct VisualAidTabView: View {
    let state: AppState
    let tab: VisualAidTabState

    var body: some View {
        if let session = state.session(for: tab.sessionId), let manager = state.acpManager(forSession: tab.sessionId) {
            VisualAidTabContent(
                transcript: session.transcript,
                session: session,
                tab: tab,
                actions: ACPVisualAidActions(
                    answer: { visualId, answer in
                        await manager.answerVisualAid(id: visualId, answer: answer, in: tab.sessionId)
                    },
                    popOut: { _ in }
                )
            )
        } else {
            VisualAidUnavailableView()
        }
    }
}

private struct VisualAidTabContent: View {
    @ObservedObject var transcript: ACPTranscript
    let session: ACPSession
    let tab: VisualAidTabState
    let actions: ACPVisualAidActions

    var body: some View {
        if let visual = transcript.visualAid(id: tab.visualId) {
            ACPVisualAidCard(visual: visual, form: session.visualAidForm(for: visual), actions: actions, fillsHeight: true)
                .padding(16)
        } else {
            VisualAidUnavailableView()
        }
    }
}

private struct VisualAidUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "Visual unavailable",
            systemImage: "rectangle.on.rectangle",
            description: Text("The session that showed this visual is closed or no longer has it.")
        )
    }
}
```

- [ ] **Step 4: Center pane**

In `CenterPaneView.swift`, add `.visualAid` to `isSharedSessionTab`:

```swift
        case .terminal, .acpSession, .webPreview, .visualAid:
            true
```

In the active-tab render switch, after `.webPreview`:

```swift
case .visualAid(let s):
    VisualAidTabView(state: state, tab: s)
        .id(s.id)
        .onAppear { completeStartupRecoveryIfActive(s.id) }
```

- [ ] **Step 5: Wire pop-out**

In `ACPTabView.swift`, replace the Task 8 `popOut: { _ in }` with:

```swift
                popOut: { visual in
                    state.tabs.openOrFocusVisualAid(
                        owner: owner ?? .worktree(worktree.id),
                        state: VisualAidTabState(sessionId: sessionId, visualId: visual.id, title: visual.title)
                    )
                }
```

- [ ] **Step 6: Build**

Run `xcodegen`, then the build-only command. Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources project.yml Alas.xcodeproj
git commit -m "feat(acp): pop visual aids out into a center tab"
```

---

### Task 10: Smoke run and wrap-up

**Files:**
- Modify: `docs/superpowers/specs/2026-10-07-acp-visual-aids-design.md` only if the smoke run forces a behavior change (record it there).

- [ ] **Step 1: Run every touched suite once**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing AlasTests/ACPVisualAidTests -only-testing AlasTests/VisualAidWebPolicyTests \
  -only-testing AlasTests/ACPMessageTests -only-testing AlasTests/ACPSessionForkPolicyTests \
  -only-testing AlasTests/ACPSessionTranscriptReaderTests -only-testing AlasTests/ACPToolCallPresentationTests \
  -only-testing AlasTests/AlasCLIRequestTests -only-testing AlasTests/AlasCLICommandRouterTests \
  -only-testing AlasTests/AppStateCLIRoutingTests -only-testing AlasTests/ACPSessionManagerTests test
cd AlasCLI && cargo test -p alas mcp::tests && cargo test -p alas-client
```

Expected: PASS; the `Test run with N tests in M suites` line names 10 suites.

- [ ] **Step 2: Smoke run in the app**

Build and launch the app from this worktree (built `alas` CLI must be the one Alas injects; check **Settings → Agents** shows the built-in MCP enabled). With a Claude agent, then a Codex agent:

1. Ask: "Use visual_show to show me two homepage layouts built with the Tailwind CDN." Expected: a card renders under the tool call, styled by Tailwind, height fits the content. In the DEBUG web inspector, `fetch('https://example.com')` rejects.
2. Ask for a visual with a question. Click a `data-choice` element: the native card selects that option and the element gets the `selected` style. Submit: the card shows "Answered: …", the answer appears as your message, and the agent replies to it.
3. Disconnect the agent (stop its process), answer another visual's question: the card shows "Couldn't send your answer. Try again." and the question is editable again.
4. Quit and relaunch Alas. The visuals and their answers come back; the pop-out tab does not.
5. Pop a visual out: a center tab shows it full height and answering there updates the inline card.
6. Show 5 visuals and scroll so all are mounted: the least recently loaded card shows "Visual paused to save memory"; "Show visual" brings it back and pauses another.
7. In `session_read` output from a parent session, the visual is one `tool` entry with title and answer and no HTML.

- [ ] **Step 3: Commit any fixes from the smoke run**

```bash
git add -A
git commit -m "fix(acp): <what the smoke run found>"
```

Skip this step when the smoke run found nothing.
