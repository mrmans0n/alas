// Demo plugin for design captures: demo data only, no network.
function send(message) {
  alas.send(JSON.stringify({ jsonrpc: "2.0", ...message }));
}

const people = [
  { name: "Ana", yesterday: "Finished CSV export", today: "Stream large exports", blocked: false, done: 7, total: 8 },
  { name: "Ravi", yesterday: "Reviewed invite flow", today: "Webhook signing", blocked: false, done: 3, total: 6 },
  { name: "Mei", yesterday: "Chased timezone bug", today: "Waiting on staging database", blocked: true, done: 1, total: 5 },
];

function person(p) {
  return {
    id: `person-${p.name}`, kind: "card", children: [{
      id: `body-${p.name}`, kind: "vstack", spacing: 6, children: [
        { id: `head-${p.name}`, kind: "hstack", align: "center", spacing: 8, children: [
          { id: `name-${p.name}`, kind: "text", text: p.name, style: "title" },
          { id: `state-${p.name}`, kind: "badge", text: p.blocked ? "blocked" : "on track", tone: p.blocked ? "danger" : "success" },
        ] },
        { id: `yesterday-${p.name}`, kind: "text", text: `Yesterday: ${p.yesterday}`, style: "caption", tone: "dim" },
        { id: `today-${p.name}`, kind: "text", text: `Today: ${p.today}`, style: "body" },
        { id: `bar-${p.name}`, kind: "progressBar", done: p.done, total: p.total, text: `${p.done}/${p.total}`, tone: p.blocked ? "warn" : "success" },
      ],
    }],
  };
}

function board() {
  return {
    id: "root", kind: "scroll", axis: "vertical", child: {
      id: "col", kind: "vstack", spacing: 10, children: [
        { id: "title", kind: "text", text: "Standup, Thursday", style: "title" },
        { id: "summary", kind: "text", text: "3 people, 1 blocked", style: "caption", tone: "dim" },
        ...people.map(person),
        { id: "div", kind: "divider" },
        { id: "refresh", kind: "button", label: "Copy summary", icon: "doc.on.doc", style: "normal" },
      ],
    },
  };
}

function render() {
  send({ method: "view/render", params: { tab: 0, root: board() } });
  send({ method: "view/render", params: { panel: "today", root: board() } });
}

let decorated = false;

globalThis.handle = (json) => {
  const message = JSON.parse(json);
  if (message.method === "alas/activate") {
    send({ id: message.id, result: {} });
    render();
    send({ method: "panel/badge", params: { panel: "today", dot: true, tone: "danger" } });
    send({ method: "decorations/set", params: { slot: "repo.row", target: message.params.project.id, items: [{ text: "1 blocked", tone: "danger", tooltip: "Mei is blocked on staging" }] } });
  } else if (message.method === "workspace/changed" && !decorated) {
    decorated = true;
    const worktree = message.params.snapshot.worktrees.find((w) => w.branch === "fix/timezone-rollover");
    if (worktree) {
      send({ method: "decorations/set", params: { slot: "worktree.row", target: worktree.id, items: [{ text: "Mei", tone: "warn", tooltip: "Mei is working here, blocked" }] } });
    }
  } else if (message.method === "tab/visible" || message.method === "panel/visible") {
    if (message.params.visible) render();
  }
};
