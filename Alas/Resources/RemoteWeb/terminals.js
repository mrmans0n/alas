// The Terminal tab: a worktree's consoles on the active host, and one of them in xterm.js. The
// protocol side lives in peer-console.js; xterm.js loads the first time a terminal opens.

const TERMINAL_CAPABILITY = "peerConsole.v1";
const OPEN_CAPABILITY = "peerConsoleOpen.v1";
const TERMINATE_CAPABILITY = "peerConsoleTerminate.v1";
const RESIZE_CAPABILITY = "peerConsoleResize.v1";
const XTERM_ASSETS = ["/xterm.min.js?v=1", "/xterm-addon-fit.min.js?v=1"];
const XTERM_CSS = "/xterm.css?v=1";

function loadXterm() {
  if (globalThis.Terminal && globalThis.FitAddon) return Promise.resolve();
  if (!document.querySelector(`link[href="${XTERM_CSS}"]`)) {
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = XTERM_CSS;
    document.head.appendChild(link);
  }
  return XTERM_ASSETS.reduce((chain, src) => chain.then(() => new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = src;
    script.onload = resolve;
    script.onerror = () => reject(new Error(`Couldn't load ${src}`));
    document.head.appendChild(script);
  })), Promise.resolve());
}

function newId() {
  return globalThis.crypto && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

// `send(message)` sends one wire message; `el` holds the tab's elements by role. `keepView()` says
// whether an open terminal stays while the list shows, as on a desktop where it has its own tab;
// `onView(title)` hears a terminal open (its title) or close (null).
function createTerminals({ send, el, keepView = () => false, onView = () => {} }) {
  let capabilities = [];
  let worktreeId = null;
  let shown = false;
  let consoles = null;
  let opening = null;
  const closing = new Set();   // consoles terminated here, hidden until a list no longer has them
  let error = "";
  let view = null;   // { attachment, term, fit, observer }
  let selection = 0;   // bumped by every navigation, so a load that finishes late knows it is stale

  const has = capability => capabilities.includes(capability);
  const sendConsole = request => send({ type: "console", console: request });
  const mine = () => (consoles || []).filter(c => c.worktreeId === worktreeId);

  function renderList() {
    el.openButton.classList.toggle("hidden", !has(OPEN_CAPABILITY));
    el.openButton.disabled = opening !== null || !worktreeId;
    el.error.textContent = error;
    el.error.classList.toggle("hidden", !error);
    el.list.innerHTML = "";
    if (consoles === null) {
      el.list.appendChild(note("Loading terminals…"));
      return;
    }
    const rows = mine();
    if (!rows.length) {
      el.list.appendChild(note("No terminals. Start one to run commands in this worktree on its machine."));
      return;
    }
    for (const summary of rows) {
      const row = document.createElement("div");
      row.className = "term-row";
      const open = document.createElement("button");
      open.type = "button";
      open.className = "term-open";
      const title = document.createElement("span");
      title.className = "term-title";
      title.textContent = summary.title;
      const grid = document.createElement("span");
      grid.className = "term-grid";
      grid.textContent = `${summary.columns}×${summary.rows}`;
      open.append(title, grid);
      open.addEventListener("click", () => showConsole(summary));
      row.appendChild(open);
      if (has(TERMINATE_CAPABILITY)) {
        const close = document.createElement("button");
        close.type = "button";
        close.className = "term-close";
        close.setAttribute("aria-label", `Close ${summary.title}`);
        close.textContent = "×";
        close.addEventListener("click", () => {
          sendConsole({ terminate: { consoleId: summary.consoleId } });
          // A headless host answers with a list that can still show it while its shell exits.
          closing.add(summary.consoleId);
          consoles = consoles.filter(c => c.consoleId !== summary.consoleId);
          renderList();
        });
        row.appendChild(close);
      }
      el.list.appendChild(row);
    }
  }

  function note(text) {
    const p = document.createElement("p");
    p.className = "term-note";
    p.textContent = text;
    return p;
  }

  function renderView() {
    if (!view) return;
    const a = view.attachment;
    el.title.textContent = view.title;
    el.control.classList.toggle("hidden", a.phase !== "live");
    el.control.textContent = a.isControlling ? "Release" : "Take control";
    const status = a.phase === "ended" ? a.endedMessage
      : a.phase === "attaching" ? "Connecting…"
      : a.isControlling ? ""
      : a.control.owner === "anotherPeer" ? "Another device is typing. Take control to type."
      : "Viewing. Take control to type.";
    el.status.textContent = status;
    el.status.classList.toggle("hidden", !status);
    fitView();
    if (a.isControlling) view.term.focus();
  }

  // A holder on a host that resizes lays the console out for this view; anyone else shows the
  // host's grid, scrolling where it doesn't fit.
  function fitView() {
    if (!view) return;
    const a = view.attachment;
    if (a.isControlling && a.canResize) {
      view.fit.fit();
    } else if (view.term.cols !== a.columns || view.term.rows !== a.rows) {
      view.term.resize(a.columns, a.rows);
    }
    a.viewResized(view.term.rows, view.term.cols);
  }

  async function showConsole(summary) {
    closeConsole();
    const current = selection;
    el.listLevel.classList.add("hidden");
    el.viewLevel.classList.remove("hidden");
    el.title.textContent = summary.title;
    el.status.textContent = "Connecting…";
    el.status.classList.remove("hidden");
    el.control.classList.add("hidden");
    try {
      await loadXterm();
    } catch (e) {
      if (current === selection) el.status.textContent = e.message;
      return;
    }
    if (current !== selection) return;   // navigated elsewhere while xterm loaded
    const term = new globalThis.Terminal({
      cols: summary.columns, rows: summary.rows, scrollback: 5000, cursorBlink: true, fontSize: 13,
      fontFamily: getComputedStyle(document.body).getPropertyValue("--font-mono") || "monospace",
      theme: { background: "#0b0d10" },
    });
    const fit = new globalThis.FitAddon.FitAddon();
    term.loadAddon(fit);
    el.screen.innerHTML = "";
    term.open(el.screen);
    const encoder = new TextEncoder();
    const attachment = globalThis.RemotePeerConsole.createAttachment({
      consoleId: summary.consoleId, attachmentId: newId(), rows: summary.rows, columns: summary.columns,
      canResize: has(RESIZE_CAPABILITY), send: sendConsole, write: bytes => term.write(bytes), onChange: renderView,
    });
    term.onData(data => attachment.viewWrote(encoder.encode(data)));
    term.onBinary(data => attachment.viewWrote(Uint8Array.from(data, c => c.charCodeAt(0) & 0xff)));
    const observer = new ResizeObserver(() => fitView());
    observer.observe(el.screen);
    view = { attachment, term, fit, observer, title: summary.title };
    attachment.attach();
    renderView();
    onView(summary.title);
  }

  function closeConsole() {
    selection += 1;
    if (!view) return;
    view.attachment.detach();
    view.observer.disconnect();
    view.term.dispose();
    view = null;
    el.screen.innerHTML = "";
    onView(null);
  }

  function showList(closeView = !keepView()) {
    if (closeView) {
      closeConsole();
      el.viewLevel.classList.add("hidden");
    }
    el.listLevel.classList.remove("hidden");
    renderList();
    sendConsole({ list: {} });
  }

  el.back.addEventListener("click", () => showList(true));
  el.control.addEventListener("click", () => {
    if (!view) return;
    if (view.attachment.isControlling) view.attachment.releaseControl(); else view.attachment.takeControl();
  });
  el.openButton.addEventListener("click", () => {
    if (!worktreeId) return;
    opening = newId();
    error = "";
    renderList();
    // An unapproved session-open hook is skipped, not asked about: approving one belongs on the host.
    sendConsole({ open: { requestId: opening, worktreeId, repoHook: { skip: {} } } });
  });

  return {
    // Whether the active host serves this browser terminals.
    get available() { return has(TERMINAL_CAPABILITY); },
    setCapabilities(next) { capabilities = Array.isArray(next) ? next : []; },
    setWorktree(id) {
      if (id === worktreeId) return;
      worktreeId = id || null;
      opening = null;
      error = "";
      // Another worktree: close the open terminal and drop one still loading, even unseen.
      closeConsole();
      el.viewLevel.classList.add("hidden");
      if (shown) showList(true);
    },
    show() {
      shown = true;
      if (!view) return showList();
      // A terminal kept open by a wide window that has since narrowed: show it, not the list.
      el.listLevel.classList.add("hidden");
      renderList();
      sendConsole({ list: {} });
    },
    hide() {
      shown = false;
      if (!keepView()) closeConsole();
    },
    // Closes the open terminal, as its tab's close button does.
    closeView() {
      showList(true);
    },
    handle(event) {
      if (view && view.attachment.handle(event)) return;
      const [kind] = Object.keys(event || {});
      const body = (event || {})[kind] || {};
      if (kind === "list") {
        const listed = body.consoles || [];
        for (const id of closing) if (!listed.some(c => c.consoleId === id)) closing.delete(id);
        consoles = listed.filter(c => !closing.has(c.consoleId));
        if (shown) renderList();
      } else if (kind === "opened" && body.requestId === opening) {
        opening = null;
        // The host lists the new console before it answers.
        const summary = (consoles || []).find(c => c.consoleId === body.consoleId);
        if (summary && shown) showConsole(summary); else renderList();
      } else if ((kind === "openFailed" || kind === "openNeedsRepoHookApproval") && body.requestId === opening) {
        opening = null;
        error = body.message || "This worktree's session-open hook needs approval on its machine.";
        renderList();
      }
    },
    // A new link knows nothing of the old one's attachments or pending open.
    reconnected() {
      opening = null;
      if (view) view.attachment.reconnected();
      if (shown) sendConsole({ list: {} });   // a desktop shows the list beside the open terminal
    },
    disconnected() {
      if (view) view.attachment.disconnected();
    },
  };
}

globalThis.RemoteTerminals = { createTerminals, TERMINAL_CAPABILITY };
