// Demo plugin for design captures: demo data only, no network.
function send(message) {
  alas.send(JSON.stringify({ jsonrpc: "2.0", ...message }));
}

const releases = [
  { version: "2.4.0", date: "Jan 12", tone: "success", items: ["CSV export for invoices", "Streamed exports for large accounts", "Team invite emails"] },
  { version: "2.3.2", date: "Jan 5", tone: "info", items: ["Retry backoff now uses jitter", "Fixes a timezone rollover on the 1st"] },
  { version: "2.3.1", date: "Dec 19", tone: "warning", items: ["Escapes quotes in CSV fields", "Avatar fallback when a user has no photo"] },
  { version: "2.3.0", date: "Dec 8", tone: "info", items: ["Usage charts", "Webhook signing", "Dark mode for emails"] },
];

let decorated = false;

globalThis.handle = (json) => {
  const message = JSON.parse(json);
  if (message.method === "alas/activate") {
    send({ id: message.id, result: {} });
    send({ method: "panel/badge", params: { panel: "changelog", count: 3, tone: "accent" } });
  } else if (message.method === "workspace/changed" && !decorated) {
    decorated = true;
    const byBranch = new Map(message.params.snapshot.worktrees.map((w) => [w.branch, w.id]));
    const tag = (branch, text, tone, tooltip) => {
      const id = byBranch.get(branch);
      if (id) send({ method: "decorations/set", params: { slot: "worktree.row", target: id, items: [{ text, tone, tooltip }] } });
    };
    tag("feat/invoice-export", "v2.4", "accent", "Ships in release 2.4.0");
    tag("fix/retry-backoff-jitter", "v2.3.2", "success", "Shipped in release 2.3.2");
  } else if (message.method === "web/message" && message.params.message.ready) {
    const target = message.params.panel !== undefined ? { panel: message.params.panel } : { tab: message.params.tab };
    send({ method: "web/post", params: { ...target, message: { releases } } });
  }
};
