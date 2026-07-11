#!/usr/bin/env python3
"""A dependency-free stdio MCP server for manually exercising ACP adapters.

Run from the repository root:

    python3 scripts/mcp-smoke-server.py

It uses the MCP stdio transport: one JSON-RPC 2.0 message per line on stdin
and stdout. The only tool, ``echo``, returns its required string ``message``
argument unchanged. Keep stdout protocol-only; diagnostics go to stderr.
"""

from __future__ import annotations

import json
import sys
from typing import Any


PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "alas-mcp-smoke", "version": "1.0.0"}


def write_message(message: dict[str, Any]) -> None:
    """Write one JSON-RPC message without contaminating stdout with logs."""
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(request_id: Any, result: dict[str, Any]) -> None:
    write_message({"jsonrpc": "2.0", "id": request_id, "result": result})


def respond_error(request_id: Any, code: int, message: str) -> None:
    write_message({
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    })


def handle_request(message: dict[str, Any]) -> None:
    method = message.get("method")
    request_id = message.get("id")
    is_request = "id" in message

    if not isinstance(method, str):
        if is_request:
            respond_error(request_id, -32600, "Invalid Request")
        return

    if method == "notifications/initialized":
        return

    if method == "initialize":
        if is_request:
            respond(request_id, {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
            })
        return

    if method == "ping":
        if is_request:
            respond(request_id, {})
        return

    if method == "tools/list":
        if is_request:
            respond(request_id, {
                "tools": [{
                    "name": "echo",
                    "description": "Returns the supplied message unchanged.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {"message": {"type": "string"}},
                        "required": ["message"],
                        "additionalProperties": False,
                    },
                }],
            })
        return

    if method == "tools/call":
        params = message.get("params")
        arguments = params.get("arguments") if isinstance(params, dict) else None
        value = arguments.get("message") if isinstance(arguments, dict) else None

        if not is_request:
            return
        if not isinstance(params, dict) or params.get("name") != "echo":
            respond(request_id, {
                "content": [{"type": "text", "text": "Unknown tool."}],
                "isError": True,
            })
        elif not isinstance(value, str):
            respond(request_id, {
                "content": [{"type": "text", "text": "echo requires a string message."}],
                "isError": True,
            })
        else:
            respond(request_id, {"content": [{"type": "text", "text": value}]})
        return

    if is_request:
        respond_error(request_id, -32601, "Method not found")


def main() -> int:
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            respond_error(None, -32700, "Parse error")
            continue
        if not isinstance(message, dict):
            respond_error(None, -32600, "Invalid Request")
            continue
        handle_request(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
