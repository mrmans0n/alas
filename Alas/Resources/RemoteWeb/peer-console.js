// Host consoles over the peer console protocol (`PeerConsoleProtocol.swift`): what the phone app's
// `TerminalConsole` does, for xterm.js. No DOM access. `createInputFilter` and `createMouseTracker`
// are ports of `PeerConsoleInputFilter` and `PeerConsoleMouseModeTracker` in AlasRemoteKit.

const ESC = 0x1b;
const MAX_PENDING = 64 * 1024;
const MAX_DISCARD = 16 * 1024 * 1024;
// The largest `input` message, as the Mac and the phone split a paste; the host caps one at 1 MiB.
const MAX_INPUT_CHUNK = 64 * 1024;
// A lone ESC waits this long for the rest of a sequence, then goes out as the Escape key.
const ESCAPE_WAIT_MS = 30;

const ch = s => s.charCodeAt(0);
const isStringIntroducer = b => b === ch("]") || b === ch("P") || b === ch("_") || b === ch("^") || b === ch("X");

function concat(a, b) {
  if (!a.length) return b;
  if (!b.length) return a;
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

// Index just past the BEL or ST that ends a string sequence, scanning from `start`; -1 when it has
// not arrived.
function stringEnd(bytes, start) {
  for (let j = start; j < bytes.length; j++) {
    if (bytes[j] === 0x07) return j + 1;
    if (bytes[j] === ESC && j + 1 < bytes.length && bytes[j + 1] === ch("\\")) return j + 2;
  }
  return -1;
}

// Whether an SGR report (`b;x;y` after the `<`) is an event the host's tracking mode asked for.
function sgrMouseReport(params, release, events) {
  let digits = "";
  for (const b of params) { if (b === ch(";")) break; digits += String.fromCharCode(b); }
  if (!/^\d+$/.test(digits)) return false;
  const button = Number(digits);
  const motion = (button & 32) !== 0;
  const noButtonHeld = (button & 3) === 3 && (button & (64 | 128)) === 0;
  switch (events) {
    case "x10": return !motion && !release;
    case "normal": return !motion;
    case "button": return !motion || !noButtonHeld;
    case "any": return true;
    default: return false;
  }
}

// { keep: n } | { drop: n } | null (incomplete)
function controlSequence(bytes, start, mouseEvents, legacyUTF8) {
  let j = start + 2;
  const paramsStart = j;
  while (j < bytes.length && bytes[j] >= 0x30 && bytes[j] <= 0x3f) j++;
  const params = bytes.subarray(paramsStart, j);
  const intermediatesStart = j;
  while (j < bytes.length && bytes[j] >= 0x20 && bytes[j] <= 0x2f) j++;
  const intermediates = bytes.subarray(intermediatesStart, j);
  if (j >= bytes.length) return null;
  if (bytes[j] < 0x40 || bytes[j] > 0x7e) return { drop: j - start };
  const final = bytes[j];
  const length = j - start + 1;

  // SGR mouse reports, the only user input with a private marker.
  if (params[0] === ch("<") && (final === ch("M") || final === ch("m"))) {
    return sgrMouseReport(params.subarray(1), final === ch("m"), mouseEvents) ? { keep: length } : { drop: length };
  }
  // Every other private marker is a reply: DA, DECRPM, kitty keyboard status.
  if (params.length && params[0] >= 0x3c && params[0] <= 0x3f) return { drop: length };
  switch (final) {
    case ch("M"): {
      // Legacy mouse reports, never forwarded.
      if (params.length) return { drop: length };
      let end = start + length;
      for (let k = 0; k < 3; k++) {
        if (end >= bytes.length) return null;
        end += legacyUTF8 && bytes[end] >= 0xc0 ? 2 : 1;
      }
      return end <= bytes.length ? { drop: end - start } : null;
    }
    case ch("I"): case ch("O"):
      // Focus in/out.
      return params.length ? { keep: length } : { drop: length };
    case ch("R"): case ch("n"): case ch("c"): case ch("t"):
      // Cursor position, status, attributes and window reports.
      return { drop: length };
    case ch("y"):
      return intermediates.includes(ch("$")) ? { drop: length } : { keep: length };
    default:
      return { keep: length };
  }
}

function sequence(bytes, start, mouseEvents, legacyUTF8) {
  if (start + 1 >= bytes.length) return null;
  const next = bytes[start + 1];
  if (next === ch("[")) return controlSequence(bytes, start, mouseEvents, legacyUTF8);
  if (isStringIntroducer(next)) {
    const end = stringEnd(bytes, start + 2);
    return end < 0 ? null : { drop: end - start };
  }
  if (next === ch("O")) return start + 2 < bytes.length ? { keep: 3 } : null;
  return { keep: 2 };   // Alt/Meta + key
}

// Keeps the keys, paste and wanted mouse reports a viewer's terminal wrote, and drops what it wrote
// on its own: replies to queries and focus reports, which the host's terminal already answers.
function createInputFilter() {
  let pending = new Uint8Array(0);
  let pendingLegacyUTF8 = false;
  let discarding = null;

  const f = {
    forwardedMouseEvents: "none",
    legacyMouseUTF8: false,
    get hasPending() { return pending.length > 0 || discarding !== null; },
    get hasAmbiguousPrefix() {
      if (discarding !== null || pending[0] !== ESC) return false;
      return pending.length <= 2 || isStringIntroducer(pending[1]);
    },
    filter(chunk) {
      const bytes = concat(pending, chunk);
      const resumesPending = pending.length > 0;
      pending = new Uint8Array(0);
      const kept = [];
      let i = 0;
      if (discarding !== null) {
        const end = stringEnd(bytes, 0);
        if (end < 0) { continueDiscarding(bytes, discarding); return Uint8Array.from(kept); }
        discarding = null;
        i = end;
      }
      while (i < bytes.length) {
        if (bytes[i] !== ESC) { kept.push(bytes[i]); i++; continue; }
        const legacyUTF8 = resumesPending && i === 0 ? pendingLegacyUTF8 : f.legacyMouseUTF8;
        const seq = sequence(bytes, i, f.forwardedMouseEvents, legacyUTF8);
        if (seq === null) {
          if (bytes.length - i <= MAX_PENDING) {
            pending = bytes.slice(i);
            pendingLegacyUTF8 = legacyUTF8;
          } else if (isStringIntroducer(bytes[i + 1])) {
            continueDiscarding(bytes.subarray(i), 0);
          }
          return Uint8Array.from(kept);
        }
        if (seq.keep) { for (let k = 0; k < seq.keep; k++) kept.push(bytes[i + k]); i += seq.keep; } else i += seq.drop;
      }
      return Uint8Array.from(kept);
    },
    // An ambiguous prefix nothing completed in time was Escape or an Alt+key.
    flushAmbiguousPrefix() {
      if (!f.hasAmbiguousPrefix) return new Uint8Array(0);
      const held = pending;
      pending = new Uint8Array(0);
      if (held.length <= 2) return held;
      return concat(held.slice(0, 2), f.filter(held.slice(2)));
    },
  };

  function continueDiscarding(bytes, already) {
    const total = already + bytes.length;
    if (total > MAX_DISCARD) { discarding = null; return; }
    discarding = total;
    if (bytes[bytes.length - 1] === ESC) pending = Uint8Array.of(ESC);
  }

  return f;
}

const FORMATS = { 1005: "utf8", 1006: "sgr", 1015: "urxvt", 1016: "sgrPixels" };
const EVENTS = { 9: "x10", 1000: "normal", 1002: "button", 1003: "any" };
const SGR_OVERRIDE = Uint8Array.from([ESC, ...Array.from("[?1006h", ch)]);
const PARAMETER_LIMIT = 100000;
const MAX_PARAMETERS = 24;

// The host program's mouse modes, followed in its output, as Ghostty follows them.
function createMouseTracker() {
  let state = "ground";
  let parameter = 0;
  let named = [];
  let ignored = false;
  let separators = 0;
  let modesSet = new Set();
  let savedSet = new Set();

  const t = {
    hostFormat: "x10",
    hostEvents: "none",
    formatKnown: true,
    eventsKnown: true,
    get hostWantsSGRMouse() {
      return t.formatKnown && t.eventsKnown && t.hostEvents !== "none" && t.hostFormat === "sgr";
    },
    // Returns `data` with the SGR override after every mouse mode change, so the viewer's terminal
    // only ever reports the mouse in SGR. `snapshot`: its mode list can't say which of several set
    // modes in a group was selected last, so that case leaves the group unknown.
    forcingSGR(data, snapshot = false) {
      const out = [];
      let start = 0;
      for (let i = 0; i < data.length; i++) {
        if (!step(data[i])) continue;
        for (let k = start; k <= i; k++) out.push(data[k]);
        out.push(...SGR_OVERRIDE);
        start = i + 1;
      }
      if (snapshot) {
        if ([...modesSet].filter(m => FORMATS[m]).length > 1) t.formatKnown = false;
        if ([...modesSet].filter(m => EVENTS[m]).length > 1) t.eventsKnown = false;
      }
      if (start === 0) return data;
      for (let k = start; k < data.length; k++) out.push(data[k]);
      return Uint8Array.from(out);
    },
  };

  function step(byte) {
    if (byte === ESC) { state = "escape"; return false; }
    if (byte === 0x18 || byte === 0x1a) { state = "ground"; return false; }
    if (byte < 0x20 || byte === 0x7f) return false;
    switch (state) {
      case "ground":
        return false;
      case "escape":
        state = byte === ch("[") ? "csi" : "ground";
        if (byte !== ch("c")) return false;
        t.hostFormat = "x10"; t.hostEvents = "none"; t.formatKnown = true; t.eventsKnown = true;
        modesSet = new Set(); savedSet = new Set();
        return true;
      case "csi":
        state = byte === ch("?") ? "private" : "ground";
        parameter = 0; named = []; ignored = false; separators = 0;
        return false;
      default:
        if (byte >= ch("0") && byte <= ch("9")) {
          parameter = Math.min(parameter * 10 + (byte - ch("0")), PARAMETER_LIMIT);
          return false;
        }
        if (byte === ch(";")) {
          separators++;
          if (separators >= MAX_PARAMETERS) ignored = true;
          nameCurrent();
          return false;
        }
        if (byte === ch(":")) { ignored = true; return false; }
        if (byte === ch("h") || byte === ch("l") || byte === ch("s") || byte === ch("r")) {
          nameCurrent();
          state = "ground";
          if (ignored) return false;
          for (const mode of named) apply(byte, mode);
          return named.length > 0;
        }
        state = "ground";
        return false;
    }
  }

  function nameCurrent() {
    const mode = parameter;
    parameter = 0;
    if (!FORMATS[mode] && !EVENTS[mode]) return;
    named = named.filter(m => m !== mode);
    named.push(mode);
  }

  function apply(action, mode) {
    if (action === ch("s")) { if (modesSet.has(mode)) savedSet.add(mode); else savedSet.delete(mode); }
    else if (action === ch("r")) set(mode, savedSet.has(mode));
    else set(mode, action === ch("h"));
  }

  function set(mode, enabled) {
    if (enabled) modesSet.add(mode); else modesSet.delete(mode);
    if (FORMATS[mode]) { t.hostFormat = enabled ? FORMATS[mode] : "x10"; t.formatKnown = true; }
    else if (EVENTS[mode]) { t.hostEvents = enabled ? EVENTS[mode] : "none"; t.eventsKnown = true; }
  }

  return t;
}

function toBase64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function fromBase64(text) {
  const s = atob(text || "");
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

const RIS = Uint8Array.of(ESC, ch("c"));

function detachMessage(reason) {
  switch (reason) {
    case "detached": return "Detached.";
    case "unavailable": return "This terminal is no longer available.";
    case "targetExited": case "terminated": return "The terminal ended.";
    case "restartRequired": return "Restart this terminal on its machine to view it.";
    case "unauthorized": return "This machine doesn't share terminals with this browser. Allow it on that machine: alas-host browsers terminals, or this browser's row in Settings > Remote.";
    case "limitReached": return "Too many terminals are open. Close one and try again.";
    default: return "The connection to this terminal was lost.";
  }
}

// One attachment to a host console. Starts as a viewer; typing needs `takeControl`.
//   send(consoleRequest)        sends `{ type: "console", console: consoleRequest }`
//   write(bytes)                feeds the terminal; a snapshot arrives with RIS before it
//   onChange()                  phase, control or grid changed
//   schedule(fn, ms)            setTimeout, injectable for tests
function createAttachment({ consoleId, attachmentId, rows = 24, columns = 80, canResize = false, send, write, onChange = () => {}, schedule = setTimeout }) {
  let expected = null;
  let filter = createInputFilter();
  let mouse = createMouseTracker();
  let inputSequence = 0;
  let escapeToken = 0;
  let pendingLease = null;
  let viewGrid = null;
  let resyncWhenFitted = false;
  let attached = false;

  const a = {
    consoleId,
    attachmentId,
    canResize,
    phase: "attaching",
    endedMessage: "",
    control: { owner: "host", generation: 0, change: "current" },
    rows,
    columns,
    get isControlling() { return a.phase === "live" && a.control.owner === "you"; },
    attach() {
      attached = true;
      send({ attach: { consoleId, attachmentId, scrollbackRows: 1000 } });
    },
    // A dropped socket takes its attachments with it on the host, which says nothing about them:
    // once the link is back, attach again and start over from a fresh snapshot, as a viewer.
    reconnected() {
      if (!attached) return;
      expected = null;
      filter = createInputFilter();
      mouse = createMouseTracker();
      pendingLease = null;
      a.control = { owner: "host", generation: 0, change: "current" };
      a.phase = "attaching";
      onChange();
      a.attach();
    },
    disconnected() {
      if (a.phase === "live") { a.phase = "attaching"; onChange(); }
    },
    detach() {
      if (!attached) return;
      attached = false;
      send({ detach: { attachmentId } });
    },
    takeControl() { send({ takeControl: { attachmentId } }); },
    releaseControl() { send({ releaseControl: { attachmentId } }); },
    viewResized(viewRows, viewColumns) {
      viewGrid = { rows: viewRows, columns: viewColumns };
      if (resyncWhenFitted && viewRows === a.rows && viewColumns === a.columns && a.phase === "live") {
        // Bytes fed into the old grid lost what it couldn't hold; only a new snapshot restores it.
        resyncWhenFitted = false;
        expected = null;
        send({ resync: { attachmentId } });
      }
      if (!canResize || !a.isControlling || viewRows < 2 || viewColumns < 2) return;
      if (viewRows === a.rows && viewColumns === a.columns) return;
      send({ resize: { attachmentId, rows: viewRows, columns: viewColumns } });
    },
    // Bytes the terminal wrote: keys, paste, and its own replies, which the filter drops. A sequence
    // begun under one lease (or while viewing) is dropped rather than finished under another.
    viewWrote(bytes) {
      const heldUnder = filter.hasPending ? pendingLease : null;
      const keys = filter.filter(bytes);
      const crossesLease = heldUnder ? !sameLease(heldUnder, a.control) : false;
      pendingLease = filter.hasPending ? (heldUnder || a.control) : null;
      if (!crossesLease) forward(keys);
      if (!filter.hasAmbiguousPrefix) return;
      const token = ++escapeToken;
      schedule(() => {
        if (token !== escapeToken) return;
        const lease = pendingLease;
        const flushed = filter.flushAmbiguousPrefix();
        pendingLease = filter.hasPending ? lease : null;
        if (lease && sameLease(lease, a.control)) forward(flushed);
      }, ESCAPE_WAIT_MS);
    },
    handle(event) {
      const [kind] = Object.keys(event);
      const body = event[kind] || {};
      if (body.attachmentId !== attachmentId) return false;
      switch (kind) {
        case "attached":
          gridChanged(body.rows, body.columns);
          a.control = body.control;
          a.phase = "live";
          break;
        case "snapshot": {
          expected = body.sequence + 1;
          mouse = createMouseTracker();
          write(mouse.forcingSGR(concat(RIS, fromBase64(body.data)), true));
          syncMouse();
          break;
        }
        case "output": {
          if (expected === null) return true;
          if (body.sequence !== expected) {
            // Bytes went missing: drop output until a fresh snapshot replaces the screen.
            expected = null;
            mouse = createMouseTracker();
            syncMouse();
            send({ resync: { attachmentId } });
            return true;
          }
          expected += 1;
          write(mouse.forcingSGR(fromBase64(body.data)));
          syncMouse();
          return true;
        }
        case "control":
          a.control = body.control;
          break;
        case "geometry":
          gridChanged(body.rows, body.columns);
          break;
        case "detached":
          attached = false;
          a.phase = "ended";
          a.endedMessage = detachMessage(body.reason);
          break;
        default:
          return true;
      }
      onChange();
      return true;
    },
  };

  function syncMouse() {
    filter.forwardedMouseEvents = mouse.hostWantsSGRMouse ? mouse.hostEvents : "none";
    filter.legacyMouseUTF8 = mouse.hostFormat === "utf8";
  }

  function gridChanged(newRows, newColumns) {
    a.rows = newRows;
    a.columns = newColumns;
    if (!viewGrid || viewGrid.rows !== newRows || viewGrid.columns !== newColumns) resyncWhenFitted = true;
  }

  function forward(keys) {
    if (!keys.length || !a.isControlling) return;
    for (let offset = 0; offset < keys.length; offset += MAX_INPUT_CHUNK) {
      inputSequence += 1;
      send({ input: { attachmentId, generation: a.control.generation, sequence: inputSequence,
                             data: toBase64(keys.subarray(offset, offset + MAX_INPUT_CHUNK)) } });
    }
  }

  return a;
}

function sameLease(x, y) {
  return x.owner === y.owner && x.generation === y.generation;
}

globalThis.RemotePeerConsole = {
  createInputFilter, createMouseTracker, createAttachment, detachMessage, toBase64, fromBase64,
  ESCAPE_WAIT_MS, MAX_INPUT_CHUNK,
};
