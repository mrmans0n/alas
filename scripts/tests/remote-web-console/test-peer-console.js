const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/peer-console.js");

const { createInputFilter, createMouseTracker, createAttachment, toBase64, fromBase64, MAX_INPUT_CHUNK } = globalThis.RemotePeerConsole;
const esc = "\u001b";
const bytes = s => Uint8Array.from(Buffer.from(s, "utf8"));
const text = b => Buffer.from(b).toString("utf8");

function test(name, fn) {
  try { fn(); } catch (error) { console.error(`✘ ${name}`); throw error; }
  console.log(`✔ ${name}`);
}

// Filter: the same cases as PeerConsoleInputFilterTests.

test("user input passes through", () => {
  for (const input of ["ls -la\r", `${esc}[A${esc}OB`, `${esc}x`, `${esc}[1;5C`, `${esc}[3~${esc}[15;2~`, `${esc}[97;5u`,
    `${esc}[200~pasted\ntext${esc}[201~`, "\u0003\u007f\t", "héllo ✓"]) {
    assert.equal(text(createInputFilter().filter(bytes(input))), input);
  }
});

test("terminal replies are dropped", () => {
  for (const reply of [`${esc}[?62;22c`, `${esc}[>1;10;0c`, `${esc}[24;80R`, `${esc}[0n`, `${esc}[?2004;1$y`, `${esc}[?1u`,
    `${esc}]11;rgb:0000/0000/0000\u0007`, `${esc}]10;rgb:ffff/ffff/ffff${esc}\\`, `${esc}P1+r544e=787465726d${esc}\\`,
    `${esc}[I${esc}[O`, `${esc}[8;40;120t`, `${esc}[<0;10;5M`, `${esc}[M !!`, `${esc}[32;10;5M`]) {
    assert.equal(createInputFilter().filter(bytes(reply)).length, 0, JSON.stringify(reply));
  }
});

test("SGR mouse reports go through only while the host uses SGR", () => {
  const filter = createInputFilter();
  const press = `${esc}[<0;10;5M${esc}[<0;10;5m${esc}[<64;10;5M`;
  assert.equal(filter.filter(bytes(press)).length, 0);
  filter.forwardedMouseEvents = "any";
  assert.equal(text(filter.filter(bytes(press))), press);
  assert.equal(filter.filter(bytes(`${esc}[<0;1`)).length, 0);
  assert.equal(text(filter.filter(bytes("0;5M"))), `${esc}[<0;10;5M`);
  assert.equal(text(filter.filter(bytes(`${esc}[M !!k`))), "k");
});

test("replies split across reads are dropped and keys around them kept", () => {
  const filter = createInputFilter();
  const kept = [filter.filter(bytes(`a${esc}]11;rgb:00`)), filter.filter(bytes("00/0000/0000\u0007b" + `${esc}[?6`)),
    filter.filter(bytes(`2c${esc}`))].map(text).join("");
  assert.equal(kept, "ab");
  assert.equal(filter.filter(bytes("[?62c")).length, 0);
  assert.equal(filter.filter(bytes(esc)).length, 0);
  assert.equal(text(filter.flushAmbiguousPrefix()), esc);
  assert.equal(filter.flushAmbiguousPrefix().length, 0);
});

test("Alt keys that look like introducers are released on timeout", () => {
  for (const key of ["]", "P", "[", "O", "_"]) {
    const filter = createInputFilter();
    assert.equal(filter.filter(bytes(esc + key)).length, 0);
    assert.equal(text(filter.flushAmbiguousPrefix()), esc + key);
    assert.equal(text(filter.filter(bytes("x"))), "x");
  }
  const filter = createInputFilter();
  assert.equal(filter.filter(bytes(`${esc}]`)).length, 0);
  assert.equal(filter.filter(bytes("ab")).length, 0);
  assert.equal(text(filter.flushAmbiguousPrefix()), `${esc}]ab`);
  assert.equal(text(filter.filter(bytes(`${esc}]11;rgb:0/0/0\u0007c`))), "c");
});

test("oversized reply strings are discarded until their terminator", () => {
  const filter = createInputFilter();
  const body = "A".repeat(200 * 1024);
  let kept = text(filter.filter(bytes(`k${esc}]52;c;` + body.slice(0, 100 * 1024))));
  kept += text(filter.filter(bytes(body.slice(100 * 1024) + esc)));
  assert.equal(filter.flushAmbiguousPrefix().length, 0);
  kept += text(filter.filter(bytes("\\x")));
  assert.equal(kept, "kx");
});

// Mouse tracker: the same cases as PeerConsoleMouseModeTrackerTests.

test("SGR is forced right after each format change inside a chunk", () => {
  const tracker = createMouseTracker();
  const sgr = `${esc}[?1006h`;
  assert.equal(text(tracker.forcingSGR(bytes(`a${esc}[?1005hbig tail${esc}cb${esc}[?25lc`))),
    `a${esc}[?1005h${sgr}big tail${esc}c${sgr}b${esc}[?25lc`);
  assert.equal(tracker.hostFormat, "x10");
  const unchanged = bytes(`plain${esc}[?2004h`);
  assert.equal(tracker.forcingSGR(unchanged), unchanged);
});

test("a snapshot with several modes of a group set leaves them unknown until live output settles them", () => {
  const tracker = createMouseTracker();
  tracker.forcingSGR(bytes(`${esc}c${esc}[?1000h${esc}[?1005h${esc}[?1006h`), true);
  assert.equal(tracker.hostWantsSGRMouse, false);
  tracker.forcingSGR(bytes(`${esc}[?1006h`));
  assert.equal(tracker.hostWantsSGRMouse, true);
  tracker.forcingSGR(bytes(`${esc}c${esc}[?1000h${esc}[?1006h`), true);
  assert.equal(tracker.hostWantsSGRMouse, true);
});

test("follows the host's mouse format across splits, saves and malformed sequences", () => {
  const tracker = createMouseTracker();
  const changed = s => tracker.forcingSGR(bytes(s)).length !== bytes(s).length;
  assert.equal(changed(`${esc}[?1000;10`), false);
  assert.equal(changed("06h text"), true);
  assert.equal(tracker.hostFormat, "sgr");
  assert.equal(changed(`${esc}[?2004h${esc}[?10060l${esc}[1006l`), false);
  assert.equal(tracker.hostFormat, "sgr");
  assert.equal(changed(`${esc}[?1006h${esc}[?1006s${esc}[?1006l`), true);
  assert.equal(tracker.hostFormat, "x10");
  assert.equal(changed(`${esc}[?1006r`), true);
  assert.equal(tracker.hostFormat, "sgr");
  assert.equal(changed(`${esc}[?1005:0h`), false);
  assert.equal(changed(`${esc}[?10\u007f06h`), true);
  assert.equal(changed(`${esc}[?1005\u0018h`), false);
  assert.equal(tracker.hostFormat, "sgr");
  assert.equal(changed(`${esc}[?1002h`), true);
  assert.equal(tracker.hostEvents, "button");
});

// Attachment: what TerminalConsole does on the phone.

function attachment(options = {}) {
  const sent = [];
  const written = [];
  const timers = [];
  const a = createAttachment({
    consoleId: "c", attachmentId: "a", send: r => sent.push(r), write: b => written.push(text(b)),
    schedule: fn => timers.push(fn), ...options,
  });
  return { a, sent, written, timers };
}
const live = (a, owner = "host", generation = 0) =>
  a.handle({ attached: { attachmentId: "a", rows: 24, columns: 80, control: { owner, generation, change: "current" } } });
const snapshot = (a, sequence, data) => a.handle({ snapshot: { attachmentId: "a", sequence, reason: "initial", data: toBase64(bytes(data)) } });
const output = (a, sequence, data) => a.handle({ output: { attachmentId: "a", sequence, data: toBase64(bytes(data)) } });

test("output is written in order after a snapshot, and a gap waits for the next snapshot", () => {
  const { a, sent, written } = attachment();
  a.attach();
  assert.deepEqual(sent[0], { attach: { consoleId: "c", attachmentId: "a", scrollbackRows: 1000 } });
  live(a);
  output(a, 1, "early");
  snapshot(a, 4, "screen");
  output(a, 5, "x");
  output(a, 7, "lost");
  output(a, 8, "after");
  snapshot(a, 9, "again");
  output(a, 10, "y");
  // RIS clears the screen and the mouse format, so SGR is forced again after it.
  const ris = `${esc}c${esc}[?1006h`;
  assert.deepEqual(written, [`${ris}screen`, "x", `${ris}again`, "y"]);
  assert.deepEqual(sent.slice(1), [{ resync: { attachmentId: "a" } }]);
  assert.equal(a.handle({ output: { attachmentId: "other", sequence: 11, data: "" } }), false);
});

test("only the lease holder sends filtered, generation-stamped input in chunks", () => {
  const { a, sent } = attachment();
  a.attach();
  live(a);
  a.viewWrote(bytes("viewing"));
  assert.equal(sent.length, 1);
  a.handle({ control: { attachmentId: "a", control: { owner: "you", generation: 3, change: "granted" } } });
  a.viewWrote(bytes(`ls${esc}[?62;22c\r`));
  assert.deepEqual(sent[1], { input: { attachmentId: "a", generation: 3, sequence: 1, data: toBase64(bytes("ls\r")) } });
  const paste = "p".repeat(MAX_INPUT_CHUNK + 10);
  a.viewWrote(bytes(paste));
  assert.deepEqual(sent.slice(2).map(r => [r.input.sequence, fromBase64(r.input.data).length]), [[2, MAX_INPUT_CHUNK], [3, 10]]);
});

test("a sequence begun under one lease is not finished under another", () => {
  const { a, sent } = attachment();
  a.attach();
  live(a);
  a.viewWrote(bytes(`${esc}[`));
  a.handle({ control: { attachmentId: "a", control: { owner: "you", generation: 5, change: "granted" } } });
  a.viewWrote(bytes("?62c"));
  assert.equal(sent.length, 1);
});

test("a lone Escape goes out once nothing follows it", () => {
  const { a, sent, timers } = attachment();
  a.attach();
  live(a, "you", 1);
  a.viewWrote(bytes(esc));
  assert.equal(sent.length, 1);
  timers.forEach(fn => fn());
  assert.equal(text(fromBase64(sent[1].input.data)), esc);
});

test("mouse reports go out only while the host program asked for them in SGR", () => {
  const { a, sent } = attachment();
  a.attach();
  live(a, "you", 1);
  snapshot(a, 0, "");
  a.viewWrote(bytes(`${esc}[<0;3;4M`));
  assert.equal(sent.length, 1);
  output(a, 1, `${esc}[?1000h${esc}[?1006h`);
  a.viewWrote(bytes(`${esc}[<0;3;4M`));
  assert.equal(text(fromBase64(sent[1].input.data)), `${esc}[<0;3;4M`);
});

test("reconnecting attaches again as a viewer, and detached ends with a message", () => {
  const { a, sent } = attachment();
  a.attach();
  live(a, "you", 2);
  a.reconnected();
  assert.equal(a.phase, "attaching");
  assert.equal(a.isControlling, false);
  assert.deepEqual(sent[1], sent[0]);
  a.handle({ detached: { attachmentId: "a", reason: "unauthorized" } });
  assert.equal(a.phase, "ended");
  assert.match(a.endedMessage, /browsers terminals/);
  a.detach();
  assert.equal(sent.length, 2);
});

test("only a holder on a host that resizes asks for the view's grid", () => {
  const { a, sent } = attachment({ canResize: true });
  a.attach();
  live(a);
  a.viewResized(30, 100);
  assert.equal(sent.length, 1);
  a.handle({ control: { attachmentId: "a", control: { owner: "you", generation: 1, change: "granted" } } });
  a.viewResized(30, 100);
  assert.deepEqual(sent[1], { resize: { attachmentId: "a", rows: 30, columns: 100 } });
  // The host's new grid arrives; once the view fits it, a fresh snapshot is asked for.
  a.handle({ geometry: { attachmentId: "a", rows: 31, columns: 100 } });
  a.viewResized(31, 100);
  assert.deepEqual(sent[2], { resync: { attachmentId: "a" } });
});
