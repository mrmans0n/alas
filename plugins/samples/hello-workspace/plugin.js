// Minimal Alas plugin, written against the raw protocol with no SDK. Logs a summary of the
// project's worktrees and agent sessions, and deliberately calls `worktree/switch` without the
// capability to show the denial path.

let nextId = 1;
const pending = new Map();

function send(message) {
  alas.send(JSON.stringify({ jsonrpc: "2.0", ...message }));
}

function request(method, params, onReply) {
  const id = nextId++;
  pending.set(id, onReply);
  send({ id, method, params });
}

function log(level, message) {
  send({ method: "log", params: { level, message } });
}

function summary(snapshot) {
  const sessions = snapshot.worktrees.flatMap((w) => w.sessions);
  const running = sessions.filter((s) => s.state === "running").length;
  return `${snapshot.worktrees.length} worktrees, ${sessions.length} sessions (${running} running)`;
}

globalThis.handle = (json) => {
  const message = JSON.parse(json);
  if (message.method === "alas/activate") {
    // The activation reply must be sent during this first call.
    send({ id: message.id, result: {} });
    log("info", `activated for ${message.params.project.name}`);
    request("workspace/snapshot", {}, (reply) => log("info", `snapshot: ${summary(reply.result.snapshot)}`));
    request("worktree/switch", { id: "any" }, (reply) => {
      if (reply.error) log("warn", `worktree/switch replied ${reply.error.code} ${reply.error.message}`);
    });
  } else if (message.method === "workspace/changed") {
    log("info", `changed: ${summary(message.params.snapshot)}`);
  } else if (message.method === undefined && pending.has(message.id)) {
    const onReply = pending.get(message.id);
    pending.delete(message.id);
    onReply(message);
  }
};
