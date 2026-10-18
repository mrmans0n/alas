#!/usr/bin/env python3
"""A minimal ACP agent over stdio for the alas-host end-to-end test.

It answers `initialize` and `session/new`, and answers every prompt with one
agent message, "fixture reply", then ends the turn. Other requests get an
empty result; notifications are ignored.
"""
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    request_id = message.get("id")
    method = message.get("method")
    if request_id is None or method is None:
        continue
    if method == "initialize":
        result = {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}
    elif method == "session/new":
        result = {"sessionId": "fixture-session"}
    elif method == "session/prompt":
        send({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": message["params"]["sessionId"],
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "fixture reply"},
                },
            },
        })
        result = {"stopReason": "end_turn"}
    else:
        result = {}
    send({"jsonrpc": "2.0", "id": request_id, "result": result})
