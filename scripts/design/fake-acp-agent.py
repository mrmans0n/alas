#!/usr/bin/env python3
"""Scripted stdio ACP server for design captures. Makes no model calls.

Alas restores the demo session with session/load, which replays the canned
transcript with no prompt or click. A session/new or session/prompt replays it
too, so the agent also works from a session started by hand.

Usage: fake-acp-agent.py [--done-marker <path>]
The marker file is created once the whole transcript has been sent.
"""

import json
import pathlib
import sys
import time

SESSION_ID = "demo-session"
PERMISSION_REQUEST_ID = "demo-permission"

QUESTION = "Why do long branch names make the invoice export screen stutter while scrolling?"

ANALYSIS = """\
The stutter comes from measuring every row on the main thread. `RowHeightCache` is keyed by \
the row's identity, so a rename invalidates the whole table.

```swift
func height(for row: InvoiceRow, width: CGFloat) -> CGFloat {
    let key = CacheKey(id: row.id, width: width.rounded())
    if let cached = heights[key] { return cached }
    let measured = layout.measure(row, width: width)
    heights[key] = measured
    return measured
}
```

| Scenario | Rows measured | p95 frame |
|---|---:|---:|
| Before the fix | 1,240 | 31.4 ms |
| With width bucketing | 96 | 9.8 ms |
| With identity keys | 14 | 7.1 ms |

Keying on identity and width keeps almost every row out of layout."""

FINAL_REPLY = """\
The cache now keys on identity and bucketed width, so scrolling stays under 10 ms per frame. \
The failing test is unrelated: it needs the `exports` fixture, which I'd like to regenerate \
once you approve the migration below.

```swift
let row = InvoiceRow(id: invoice.id, title: invoice.title, branch: branch.name, isPinned: invoice.isPinned)
let key = CacheKey(id: row.id, width: width.rounded(.down), scale: window.backingScaleFactor, density: density)
heights[key] = layout.measure(row, width: width, options: [.usesFontLeading, .usesLineFragmentOrigin])
```

| Migration step | Rows | Time | Worst frame | What it changes |
|---|---:|---:|---:|---|
| Rename fixtures | 1,240 | 2.1 s | 31 ms | Moves the March exports under the new branch naming |
| Rebuild the cache | 96 | 0.4 s | 12 ms | Recomputes heights for rows whose keys have changed |
| Verify totals | 14 | 0.1 s | 7 ms | Checks each invoice total against the source ledger |"""


def text(value):
    return {"type": "text", "text": value}


def tool_output(value):
    return [{"type": "content", "content": text(value)}]


def tool_call(call_id, title, kind, status, output=None, path=None):
    update = {
        "sessionUpdate": "tool_call",
        "toolCallId": call_id,
        "title": title,
        "kind": kind,
        "status": status,
    }
    if output is not None:
        update["content"] = tool_output(output)
    if path is not None:
        update["locations"] = [{"path": path}]
    return update


TRANSCRIPT_BEFORE_PERMISSION = [
    {"sessionUpdate": "user_message_chunk", "content": text(QUESTION)},
    {"sessionUpdate": "agent_message_chunk", "content": text("I'll trace how the rows get measured.\n\n")},
    tool_call("read-1", "Read Sources/Invoices/RowHeightCache.swift", "read", "completed",
              "148 lines", "Sources/Invoices/RowHeightCache.swift"),
    tool_call("search-1", "Search for layout.measure", "search", "completed", "6 matches in 3 files"),
    tool_call("edit-1", "Edit Sources/Invoices/RowHeightCache.swift", "edit", "completed",
              "Keyed the cache on identity and bucketed width", "Sources/Invoices/RowHeightCache.swift"),
    {"sessionUpdate": "agent_message_chunk", "content": text(ANALYSIS)},
    tool_call("test-1", "Run swift test --filter InvoiceExportTests", "execute", "failed",
              "error: fixture exports/march.csv not found\n1 test failed, 41 passed"),
]

PERMISSION_TOOL_CALL = tool_call(
    "migrate-1", "Run scripts/regenerate-fixtures.sh --migrate", "execute", "pending"
)

TRANSCRIPT_AFTER_PERMISSION = [
    {"sessionUpdate": "agent_message_chunk", "content": text(FINAL_REPLY)},
]

# What a real agent advertises, so the composer toolbar has its usual chips.
SESSION_OPTIONS = {
    "modes": {
        "currentModeId": "default",
        "availableModes": [
            {"id": "default", "name": "Default"},
            {"id": "plan", "name": "Plan"},
        ],
    },
    "models": {
        "currentModelId": "demo-large",
        "availableModels": [
            {"modelId": "demo-large", "name": "Demo Large"},
            {"modelId": "demo-small", "name": "Demo Small"},
        ],
    },
    "configOptions": [
        {
            "id": "thinking",
            "name": "Thinking",
            "type": "select",
            "category": "thought_level",
            "currentValue": "high",
            "options": [
                {"value": "low", "name": "Low"},
                {"value": "high", "name": "High"},
            ],
        },
        {"id": "fast_mode", "name": "Fast mode", "type": "boolean", "currentValue": False},
    ],
}


class Agent:
    def __init__(self, done_marker):
        self.done_marker = done_marker
        self.replayed = False

    def send(self, message):
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", **message}) + "\n")
        sys.stdout.flush()

    def respond(self, request_id, result):
        self.send({"id": request_id, "result": result})

    def update(self, session_id, update):
        self.send({"method": "session/update", "params": {"sessionId": session_id, "update": update}})

    def replay(self, session_id):
        """Sends the transcript once per process, so a reattach cannot duplicate it."""
        if self.replayed:
            return
        self.replayed = True
        for update in TRANSCRIPT_BEFORE_PERMISSION:
            self.update(session_id, update)
        self.update(session_id, PERMISSION_TOOL_CALL)
        self.send({
            "id": PERMISSION_REQUEST_ID,
            "method": "session/request_permission",
            "params": {
                "sessionId": session_id,
                "toolCall": PERMISSION_TOOL_CALL,
                "options": [
                    {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
                ],
            },
        })
        for update in TRANSCRIPT_AFTER_PERMISSION:
            self.update(session_id, update)
        if self.done_marker:
            pathlib.Path(self.done_marker).touch()

    def handle(self, message):
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params") or {}
        if method == "initialize":
            self.respond(request_id, {
                "protocolVersion": params.get("protocolVersion", 1),
                "agentCapabilities": {"loadSession": True},
                "authMethods": [],
                "agentInfo": {"name": "demo-agent", "version": "1.0.0"},
            })
        elif method == "session/new":
            self.respond(request_id, {"sessionId": SESSION_ID, **SESSION_OPTIONS})
            self.replay(SESSION_ID)
        elif method == "session/load":
            session_id = params.get("sessionId", SESSION_ID)
            self.respond(request_id, SESSION_OPTIONS)
            # Replayed after the response, so the permission request arrives
            # once the session is attached and has somewhere to show it.
            time.sleep(0.2)
            self.replay(session_id)
        elif method == "session/prompt":
            self.replay(params.get("sessionId", SESSION_ID))
            self.respond(request_id, {"stopReason": "end_turn"})
        elif request_id is not None and method is not None:
            self.send({"id": request_id, "error": {"code": -32601, "message": f"Unsupported: {method}"}})


def main():
    args = sys.argv[1:]
    done_marker = args[args.index("--done-marker") + 1] if "--done-marker" in args else None
    agent = Agent(done_marker)
    for line in sys.stdin:
        line = line.strip()
        if line:
            agent.handle(json.loads(line))


if __name__ == "__main__":
    main()
