"""A scripted stand-in for `cua-driver mcp --direct`: newline-delimited MCP JSON-RPC over stdio.

Usage: fake_cua.py <script.json>. The script is

    {"tools": {"<tool>": [<tools/call result>, ...]},
     "crash_on_call": N,     # exit without answering the Nth tools/call, counted across processes
     "hang_on": "<tool>",    # never answer that tool
     "server_request_on": "<tool>"}  # send a request first and echo the client's answer

Each tool's results are used in turn; the last one repeats. A result whose structuredContent is
"$arguments" echoes the call's arguments. Calls are counted in <script.json>.calls so a respawned
fake carries on where the crashed one stopped. Like the real driver, it logs a non-JSON line to
stdout first.
"""

import json
import sys
import time

script_path = sys.argv[1]
with open(script_path) as f:
    script = json.load(f)
counter_path = script_path + ".calls"


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def count_call():
    try:
        with open(counter_path) as f:
            calls = int(f.read())
    except FileNotFoundError:
        calls = 0
    calls += 1
    with open(counter_path, "w") as f:
        f.write(str(calls))
    return calls


print("cua-driver fake: starting", flush=True)
served = {}
for line in sys.stdin:
    request = json.loads(line)
    method, request_id = request.get("method"), request.get("id")
    if request_id is None:
        continue
    if method == "initialize":
        result = {
            "protocolVersion": request["params"]["protocolVersion"],
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "cua-driver-fake", "version": "0"},
        }
    elif method == "tools/list":
        result = {"tools": [{"name": name} for name in script.get("tools", {})]}
    elif method == "tools/call":
        name, arguments = request["params"]["name"], request["params"].get("arguments")
        if count_call() == script.get("crash_on_call"):
            sys.exit(1)
        if name == script.get("hang_on"):
            time.sleep(3600)
        if name == script.get("server_request_on"):
            # Reuses the call's id, as a server may.
            send({"jsonrpc": "2.0", "id": request_id, "method": "roots/list"})
            answer = json.loads(sys.stdin.readline())
            send({"jsonrpc": "2.0", "id": request_id,
                  "result": {"content": [], "structuredContent": answer}})
            continue
        results = script["tools"][name]
        result = results[min(served.get(name, 0), len(results) - 1)]
        served[name] = served.get(name, 0) + 1
        if result.get("structuredContent") == "$arguments":
            result = dict(result, structuredContent=arguments)
    else:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": method}})
        continue
    send({"jsonrpc": "2.0", "id": request_id, "result": result})
