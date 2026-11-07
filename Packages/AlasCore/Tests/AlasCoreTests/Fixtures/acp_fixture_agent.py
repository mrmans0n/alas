#!/usr/bin/env python3
"""A minimal ACP agent over stdio for the alas-host end-to-end tests.

It answers `initialize` and `session/new`, and answers every prompt with one
agent message, "fixture reply", then ends the turn. Other requests get an
empty result; notifications are ignored.

With ALAS_E2E_LOG set, as the peer delegation tests set it, it also:

- appends each session, prompt and permission answer to that file as JSON lines;
- gives each session its own id and offers `session/load`, as real agents do;
- with ALAS_E2E_OBEY set, follows directives in a prompt:
  - `E2E-TOKEN=<word>` ends its reply with that word;
  - `E2E-HOLD=<path>` keeps the turn open until the file exists or the turn is
    cancelled;
  - `E2E-PERMISSION` asks for a permission and waits for the answer.
"""
import json
import os
import re
import select
import sys
import uuid

LOG = os.environ.get("ALAS_E2E_LOG")
OBEY = bool(os.environ.get("ALAS_E2E_OBEY"))
_pending = b""
_queue = []


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def log(event, **fields):
    if not LOG:
        return
    fields["event"] = event
    fields["pid"] = os.getpid()
    with open(LOG, "a") as file:
        file.write(json.dumps(fields) + "\n")


def next_message(timeout=None):
    """The next JSON message, None on timeout; exits at end of input."""
    global _pending
    while True:
        newline = _pending.find(b"\n")
        if newline >= 0:
            line, _pending = _pending[:newline].strip(), _pending[newline + 1:]
            if line:
                return json.loads(line)
            continue
        ready, _, _ = select.select([0], [], [], timeout)
        if not ready:
            return None
        chunk = os.read(0, 65536)
        if not chunk:
            log("exit")
            sys.exit(0)
        _pending += chunk


def answer_other(message):
    """A request or notification arriving while a turn runs."""
    if message.get("method") == "session/prompt":
        _queue.append(message)
    elif message.get("id") is not None and message.get("method") is not None:
        send({"jsonrpc": "2.0", "id": message["id"], "result": {}})


def message_chunk(session_id, text):
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": session_id,
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text},
            },
        },
    })


def run_prompt(message):
    session_id = message["params"]["sessionId"]
    text = "\n".join(
        block.get("text", "") for block in message["params"].get("prompt", []) if isinstance(block, dict)
    )
    log("prompt", session=session_id, text=text)
    token = re.search(r"E2E-TOKEN=([\w-]+)", text) if OBEY else None
    reply = "fixture reply " + token.group(1) if token else "fixture reply"
    stop_reason = "end_turn"
    if OBEY and "E2E-PERMISSION" in text:
        stop_reason = ask_permission(session_id)
    hold = re.search(r"E2E-HOLD=(\S+)", text) if OBEY else None
    if hold and stop_reason == "end_turn":
        message_chunk(session_id, "fixture working")
        log("holding", session=session_id, path=hold.group(1))
        while not os.path.exists(hold.group(1)):
            other = next_message(0.1)
            if other is None:
                continue
            if other.get("method") == "session/cancel":
                stop_reason = "cancelled"
                log("cancelled", session=session_id)
                break
            answer_other(other)
    if stop_reason == "end_turn":
        message_chunk(session_id, reply)
    log("turn_end", session=session_id, stop_reason=stop_reason)
    send({"jsonrpc": "2.0", "id": message["id"], "result": {"stopReason": stop_reason}})


def ask_permission(session_id):
    request_id = "permission-" + uuid.uuid4().hex
    send({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "session/request_permission",
        "params": {
            "sessionId": session_id,
            "toolCall": {"toolCallId": request_id, "title": "fixture tool", "kind": "execute", "status": "pending"},
            "options": [
                {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                {"optionId": "deny", "name": "Deny", "kind": "reject_once"},
            ],
        },
    })
    log("permission_asked", session=session_id)
    while True:
        other = next_message()
        if other.get("id") == request_id and other.get("method") is None:
            log("permission_answered", session=session_id, outcome=other.get("result"))
            return "end_turn"
        if other.get("method") == "session/cancel":
            log("cancelled", session=session_id)
            return "cancelled"
        answer_other(other)


while True:
    message = _queue.pop(0) if _queue else next_message()
    request_id = message.get("id")
    method = message.get("method")
    if request_id is None or method is None:
        continue
    if method == "initialize":
        result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": True} if LOG else {}, "authMethods": []}
    elif method == "session/new":
        result = {"sessionId": "fixture-" + uuid.uuid4().hex if LOG else "fixture-session"}
        log("session_new", session=result["sessionId"], parent=os.environ.get("ALAS_PARENT_SESSION_ID"))
    elif method == "session/prompt":
        run_prompt(message)
        continue
    else:
        if method == "session/load":
            log("session_load", session=message["params"].get("sessionId"))
        result = {}
    send({"jsonrpc": "2.0", "id": request_id, "result": result})
