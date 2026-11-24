// The web client reads the messages the Mac sends and sends ones it decodes. Both sides test
// against one fixture; AlasCore's RemoteWireCompatibilityTests round-trips it through Swift.
const assert = require("node:assert/strict");
const fixture = require("../../../Packages/AlasCore/Tests/AlasCoreTests/Fixtures/remote-web-wire.json");
const web = "../../../Alas/Resources/RemoteWeb/";
for (const file of ["session-ordering", "changes-view", "file-browser", "peer-console"]) require(web + file + ".js");
const { server, client } = fixture;

{
  const [section] = RemoteSessionOrdering.groupSessions(server.sessionList.sessions);
  assert.equal(section.title, "alas");
  assert.equal(section.worktrees[0].title, "proud-walrus");
  assert.deepEqual(section.worktrees[0].activeSessions.map(s => s.id), ["s1"]);
  assert.deepEqual(section.worktrees[0].closedSessions.map(s => s.id), ["s2"]);
  console.log("✔ sessionList groups by project and worktree");
}

{
  const msg = server.changeList;   // as app.js stores it
  const state = { files: msg.files, staged: msg.staged, unstaged: msg.unstaged, commits: msg.commits };
  assert.deepEqual(RemoteChangesView.changeSections(state).map(s => s.title),
    ["Branch changes", "Working tree", "Staged", "Unstaged", "Commits"]);
  const rows = RemoteChangesView.fileRows(msg.files);
  assert.deepEqual(rows.map(r => r.path || r.dir), ["README.md", "src", "src/app.js"]);
  const rows2 = RemoteChangesView.diffRows(server.fileDiffResult.hunks);
  assert.deepEqual(rows2.map(r => [r.type, r.kind, r.oldNumber, r.newNumber, r.noTrailingNewline]), [
    ["hunk", null, null, null, false],
    ["line", "context", 1, 1, false],
    ["line", "delete", 2, null, false],
    ["line", "add", null, 2, true],
  ]);
  console.log("✔ changeList and fileDiffResult read as the Changes view expects");
}

{
  const tree = RemoteFileBrowser.createTree();
  tree.applyNodes(server.fileTree.path ?? null, server.fileTree.nodes);
  assert.deepEqual(tree.visibleRows().map(r => r.node.path), ["src", "README.md"]);
  console.log("✔ fileTree lists directories first");
}

{
  const sent = [];
  const written = [];
  const consoleOf = message => message.console;
  const a = RemotePeerConsole.createAttachment({
    consoleId: "c1", attachmentId: "a1", canResize: true,
    send: request => sent.push({ type: "console", console: request }),
    write: bytes => written.push(Buffer.from(bytes).toString()), schedule: () => {},
  });
  a.attach();
  assert.deepEqual(sent.pop(), client.consoleAttach);
  a.handle(consoleOf(server.consoleAttached));
  assert.ok(a.isControlling);
  assert.equal(a.control.generation, 3);
  a.handle(consoleOf(server.consoleSnapshot));
  a.handle(consoleOf(server.consoleOutput));
  assert.match(written.join(""), /\$ hi\r\n$/);
  a.viewWrote(new TextEncoder().encode("ls\r"));
  assert.deepEqual(sent.pop(), client.consoleInput);
  a.viewResized(30, 100);
  assert.deepEqual(sent.pop(), client.consoleResize);
  a.releaseControl();
  assert.deepEqual(sent.pop(), client.consoleReleaseControl);
  a.detach();
  assert.deepEqual(sent.pop(), client.consoleDetach);
  a.attach();
  a.handle(consoleOf(server.consoleDetached));
  assert.equal(a.phase, "ended");
  assert.equal(a.endedMessage, "The terminal ended.");
  console.log("✔ a console attachment speaks the Mac's console frames");
}

{
  // Just enough DOM for terminals.js, whose xterm never loads here.
  const element = () => {
    const classes = new Set(), handlers = {};
    return {
      children: [], textContent: "", disabled: false,
      classList: { add: c => classes.add(c), remove: c => classes.delete(c), toggle: (c, on) => (on ?? !classes.has(c)) ? classes.add(c) : classes.delete(c) },
      addEventListener(type, fn) { handlers[type] = fn; }, click() { handlers.click(); },
      appendChild(child) { this.children.push(child); }, append(...nodes) { this.children.push(...nodes); },
      set innerHTML(_) { this.children = []; }, setAttribute() {},
    };
  };
  globalThis.document = { createElement: element, querySelector: () => ({}), head: { appendChild() {} } };
  crypto.randomUUID = () => "r1";
  require(web + "terminals.js");
  const sent = [];
  const el = Object.fromEntries(["listLevel", "viewLevel", "list", "title", "status", "control", "back", "openButton", "error", "screen"]
    .map(role => [role, element()]));
  const terminals = RemoteTerminals.createTerminals({ send: message => sent.push(message), el });
  terminals.setCapabilities([RemoteTerminals.TERMINAL_CAPABILITY, "peerConsoleOpen.v1"]);
  terminals.setWorktree("w1");
  terminals.show();
  assert.deepEqual(sent.pop(), client.consoleList);
  terminals.handle(server.consoleList.console);
  assert.equal(el.list.children[0].children[0].children[0].textContent, "zsh");
  el.openButton.click();
  assert.deepEqual(sent.pop(), client.consoleOpen);
  terminals.handle(server.consoleOpened.console);
  assert.equal(el.title.textContent, "zsh");
  console.log("✔ the terminal list reads the Mac's console list and opens the one it starts");
}
