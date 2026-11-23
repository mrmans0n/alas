const assert = require("node:assert/strict");

// Just enough DOM for terminals.js. xterm's scripts finish loading only when the test says so.
function element() {
  const classes = new Set();
  const handlers = {};
  return {
    children: [],
    classList: {
      add: c => classes.add(c), remove: c => classes.delete(c), contains: c => classes.has(c),
      toggle: (c, on) => (on ?? !classes.has(c)) ? classes.add(c) : classes.delete(c),
    },
    addEventListener(type, fn) { handlers[type] = fn; },
    click() { handlers.click(); },
    appendChild(child) { this.children.push(child); },
    append(...nodes) { this.children.push(...nodes); },
    set innerHTML(_) { this.children = []; },
    setAttribute() {}, focus() {},
    textContent: "",
  };
}
const pendingScripts = [];
globalThis.document = {
  createElement: element,
  querySelector: () => null,
  head: { appendChild: node => { if (node.src) pendingScripts.push(node); } },
  body: {},
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "" });
globalThis.ResizeObserver = class { observe() {} disconnect() {} };

require("../../../Alas/Resources/RemoteWeb/peer-console.js");
require("../../../Alas/Resources/RemoteWeb/terminals.js");

async function finishLoadingXterm() {
  globalThis.Terminal = class {
    constructor({ cols, rows }) { this.cols = cols; this.rows = rows; }
    loadAddon() {} open() {} onData() {} onBinary() {} write() {} resize() {} focus() {} dispose() {}
  };
  globalThis.FitAddon = { FitAddon: class { fit() {} } };
  for (let i = 0; i < 20; i += 1) {
    pendingScripts.splice(0).forEach(script => script.onload());
    await new Promise(resolve => setTimeout(resolve));
  }
}

(async () => {
  const sent = [];
  const el = Object.fromEntries(["listLevel", "viewLevel", "list", "title", "status", "control", "back", "openButton", "error", "screen"]
    .map(role => [role, element()]));
  const terminals = globalThis.RemoteTerminals.createTerminals({ send: m => sent.push(m.console), el });
  terminals.setCapabilities([globalThis.RemoteTerminals.TERMINAL_CAPABILITY]);
  terminals.setWorktree("w");
  terminals.show();
  const summary = id => ({ consoleId: id, worktreeId: "w", title: id, rows: 24, columns: 80 });
  terminals.handle({ list: { consoles: [summary("A"), summary("B")] } });
  const open = index => el.list.children[index].children[0].click();

  // Open A, go back while xterm is still loading, then open B.
  open(0);
  el.back.click();
  open(1);
  await finishLoadingXterm();

  const attached = sent.filter(m => m.attach).map(m => m.attach.consoleId);
  assert.deepEqual(attached, ["B"]);
  console.log("✔ a terminal left while xterm loads is never attached");
})().catch(error => { console.error("✘", error); process.exit(1); });
