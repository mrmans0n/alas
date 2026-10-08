const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/visual-aid.js");
const V = globalThis.RemoteVisualAid;

const ID = "6f0c2d4e-8b1a-4c3d-9e5f-1a2b3c4d5e6f";
const question = (allowMultiple = false) => ({
  prompt: "Which?",
  options: [{ id: "a", label: "One" }, { id: "b", label: "Two" }, { id: "c", label: "Three" }],
  allowMultiple,
});
const visual = (extra = {}) => ({ id: ID, title: "Layouts", html: "<p>x</p>", question: question(), ...extra });

// Constants that are part of the security contract.
assert.equal(V.SANDBOX, "allow-scripts");
assert.ok(!/allow-same-origin/.test(V.SANDBOX));
assert.equal(
  V.CSP,
  "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; " +
    "img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; " +
    "worker-src 'none'; form-action 'none'; base-uri 'none'");

// isFullDocument matches the desktop rule (VisualAidWebPolicyTests.fullDocumentDetection).
for (const [html, expected] of [
  ["<!DOCTYPE html><html></html>", true],
  ["  \n<!doctype html>", true],
  ["<!-- note --> <HTML lang=\"en\">", true],
  ["<!-- unterminated <html>", false],
  ["<div>hi</div>", false],
  ["<h2>html</h2>", false],
  ["<html-preview>x</html-preview>", false],
  ["<!doctype-widget>", false],
  ["<html>", true],
  ["<html/>", true],
  ["<!DOCTYPE\nhtml>", true],
  // Swift Character.isWhitespace, not JS \s (VisualAidWebPolicyTests.fullDocumentDetection).
  ["\uFEFF<html>", false],
  ["\u0085<html>", true],
  ["<html\u0085>", true],
  ["<html\uFEFF>", false],
]) {
  assert.equal(V.isFullDocument(html), expected, JSON.stringify(html));
}

// Height handling.
assert.equal(V.clampHeight(10), 120);
assert.equal(V.clampHeight(300.4), 301);
assert.equal(V.clampHeight(99999), 720);
assert.equal(V.clampHeight("nope"), null);
assert.equal(V.clampHeight(NaN), null);
const win = {};
const other = {};
assert.equal(V.heightFromMessage({ alasVisual: true, id: ID, height: 300 }, ID, win, win), 300);
assert.equal(V.heightFromMessage({ alasVisual: true, id: ID, height: 300 }, ID, other, win), null, "wrong source");
assert.equal(V.heightFromMessage({ alasVisual: true, id: "other", height: 300 }, ID, win, win), null, "wrong id");
assert.equal(V.heightFromMessage({ id: ID, height: 300 }, ID, win, win), null, "missing marker");
assert.equal(V.heightFromMessage(null, ID, win, win), null);

// Selection and submit rules.
assert.deepEqual(V.toggleSelection(question(false), ["a"], "b"), ["b"]);
assert.deepEqual(V.toggleSelection(question(false), ["a"], "a"), ["a"]);
assert.deepEqual(V.toggleSelection(question(true), ["a"], "b"), ["a", "b"]);
assert.deepEqual(V.toggleSelection(question(true), ["a", "b"], "a"), ["b"]);
assert.deepEqual(V.toggleSelection(question(true), ["a"], "zzz"), ["a"], "unknown id ignored");
assert.equal(V.canSubmit(question(false), [], ""), false);
assert.equal(V.canSubmit(question(false), ["a"], ""), true);
assert.equal(V.canSubmit(question(false), ["a", "b"], ""), false);
assert.equal(V.canSubmit(question(true), ["a", "b"], ""), true);
assert.equal(V.canSubmit(question(false), ["a"], "x".repeat(2000)), true);
assert.equal(V.canSubmit(question(false), ["a"], "x".repeat(2001)), false);

// Response builder: question order, trimmed note, dismissal carries nothing.
assert.deepEqual(V.buildResponse("s1", visual({ question: question(true) }), "answer", ["c", "a"], "  hi  "), {
  type: "visualAidResponse", sessionId: "s1", visualId: ID, action: "answer", selectedOptionIds: ["a", "c"], note: "hi",
});
assert.deepEqual(V.buildResponse("s1", visual(), "answer", ["a"], "   "), {
  type: "visualAidResponse", sessionId: "s1", visualId: ID, action: "answer", selectedOptionIds: ["a"],
});
assert.deepEqual(V.buildResponse("s1", visual(), "dismiss", ["a"], "ignored"), {
  type: "visualAidResponse", sessionId: "s1", visualId: ID, action: "dismiss", selectedOptionIds: [],
});
assert.equal(V.buildResponse("s1", visual(), "answer", [], ""), null, "an invalid answer builds nothing");
assert.equal(V.buildResponse("s1", visual({ question: null }), "dismiss", [], ""), null, "no question");

// Answer view states.
const open = (state) => V.answerView(visual(), { canDrive: true, pending: false, error: "", selected: [], note: "", ...state });
assert.equal(V.answerView(visual({ question: null }), {}).kind, "none");
assert.equal(open({}).kind, "open");
assert.equal(open({}).editable, true);
assert.equal(open({}).canSubmit, false);
assert.equal(open({ selected: ["a"] }).canSubmit, true);
assert.equal(open({ canDrive: false }).editable, false);
assert.equal(open({ canDrive: false }).hint, "Take over to answer");
assert.equal(open({ pending: true, selected: ["a"] }).editable, false);
assert.equal(open({ error: "boom" }).error, "boom");
assert.deepEqual(open({ selected: ["b"] }).options.map((o) => o.checked), [false, true, false]);
assert.equal(open({}).multiple, false);
const answered = V.answerView(visual({ answer: { kind: "answered", selectedOptionIds: ["b", "a"], note: "ok" } }), {});
assert.equal(answered.kind, "answered");
assert.deepEqual(answered.labels, ["One", "Two"], "labels follow question order");
assert.equal(answered.note, "ok");
assert.equal(V.answerView(visual({ answer: { kind: "dismissed" } }), {}).kind, "dismissed");

// Visual parsing.
assert.equal(V.parseVisual("not json"), null);
assert.equal(V.parseVisual(JSON.stringify({ id: ID, title: "t" })), null, "html is required");
assert.equal(V.parseVisual(JSON.stringify({ id: "bad id", title: "t", html: "x" })), null, "id must be a UUID");
assert.equal(V.parseVisual(JSON.stringify({ id: ID, title: "t", html: "x", question: { prompt: "p", options: [{ id: 1 }] } })), null);
assert.equal(V.parseVisual(JSON.stringify(visual())).id, ID);
assert.equal(V.parseVisual(JSON.stringify({ id: ID, title: "t", html: "x" })).question, undefined);

for (const bad of [
  { question: { ...question(), allowMultiple: "false" } },
  { answer: { kind: "answered", selectedOptionIds: [1] } },
  { answer: { kind: "mystery" } },
  { answer: { kind: "answered", selectedOptionIds: ["a"], note: 5 } },
]) assert.equal(V.parseVisual(JSON.stringify(visual(bad))), null, JSON.stringify(bad));
assert.ok(V.parseVisual(JSON.stringify(visual({ answer: { kind: "answered", selectedOptionIds: ["a"] } }))));
assert.ok(V.parseVisual(JSON.stringify(visual({ answer: { kind: "dismissed" }, question: null }))));

// Note length counts grapheme clusters like Swift String.count.
assert.equal(V.canSubmit(question(false), ["a"], "😀".repeat(2000)), true);
assert.equal(V.canSubmit(question(false), ["a"], "😀".repeat(2001)), false);
assert.equal(V.noteLength("👨‍👩‍👧‍👦"), 1);
assert.equal(V.noteLength("  hi  "), 2);

// Rejections.
assert.equal(V.rejectionText("failed"), "Couldn't send your answer. Try again.");
assert.equal(V.rejectionText("notWriter"), "Take over this session to answer.");
assert.equal(V.rejectionText("whatever"), "Couldn't send your answer. Try again.");

// Live frame budget: least recently shown goes first, re-admit refreshes.
let r = V.admitFrame([], "a", 3);
assert.deepEqual(r, { order: ["a"], evicted: [] });
r = V.admitFrame(r.order, "b", 3); r = V.admitFrame(r.order, "c", 3);
assert.deepEqual(V.touchFrame(r.order, "a"), ["b", "c", "a"]);
r = V.admitFrame(V.touchFrame(r.order, "a"), "d", 3);
assert.deepEqual(r, { order: ["c", "a", "d"], evicted: ["b"] });
assert.deepEqual(V.releaseFrame(r.order, "a"), ["c", "d"]);

// Card send state: only a card that submitted treats an unanswered row as a failed send.
const answeredRow = { answer: { kind: "answered" } }, unansweredRow = {};
assert.deepEqual(V.nextCardState({ pending: true, submitted: true }, unansweredRow),
  { pending: false, submitted: false, error: V.FAILED_TEXT }, "coalesced rollback while submitted");
let sendState = V.nextCardState({ pending: true, submitted: true }, answeredRow);
assert.deepEqual(sendState, { pending: false, submitted: true, error: "" }, "an answer keeps submitted");
assert.deepEqual(V.nextCardState({ pending: false, submitted: sendState.submitted }, unansweredRow),
  { pending: false, submitted: false, error: V.FAILED_TEXT }, "answered then rolled back while submitted");
assert.deepEqual(V.nextCardState({ pending: false, submitted: false, error: "" }, unansweredRow),
  { pending: false, submitted: false, error: "" }, "an observer shows no error");
assert.deepEqual(V.nextCardState({ pending: false, submitted: false }, answeredRow),
  { pending: false, submitted: false, error: "" }, "answeredRow by another client");
// A rejection clears submitted in app.js; the next unanswered row then shows no failure.
assert.equal(V.nextCardState({ pending: false, submitted: false, error: "x" }, unansweredRow).error, "x");

// Mount decision: evicted (paused) cards never remount by themselves.
assert.equal(V.shouldMount({ frame: null, paused: false }, true), true);
assert.equal(V.shouldMount({ frame: null, paused: true }, true), false);
assert.equal(V.shouldMount({ frame: {}, paused: false }, true), false);
assert.equal(V.shouldMount({ frame: null, paused: false }, false), false);

// buildDocument: a stub parser records what the module inserts. The real DOMParser behavior is
// covered in RemoteWebAssetTests with WebKit.
const inserted = [];
const stubDoc = (hasHead) => {
  const head = { prepend(...nodes) { inserted.push(...nodes); } };
  const node = (tag) => ({ tag, textContent: "", httpEquiv: "", content: "" });
  return {
    doctype: { name: "html" },
    head: hasHead ? head : null,
    documentElement: {
      outerHTML: "<html>…</html>",
      firstChild: null,
      insertBefore(h) { this.createdHead = h; return head; },
    },
    createElement: (tag) => (tag === "head" ? head : node(tag)),
  };
};
const doctypeOut = (doctype) => {
  const d = stubDoc(true);
  d.doctype = doctype;
  return V.buildDocument("<p>x</p>", ID, () => d);
};
assert.ok(doctypeOut(null).startsWith("<html>"), "no doctype stays none");
assert.ok(doctypeOut({ name: "html", publicId: "", systemId: "" }).startsWith("<!DOCTYPE html><html>"));
assert.ok(doctypeOut({ name: "html", publicId: "-//W3C//DTD HTML 4.01//EN", systemId: "" })
  .startsWith('<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN"><html>'));
assert.ok(doctypeOut({ name: "html", publicId: "p", systemId: "http://x/d.dtd" })
  .startsWith('<!DOCTYPE html PUBLIC "p" "http://x/d.dtd"><html>'));
assert.ok(doctypeOut({ name: "html", publicId: "", systemId: "about:legacy" })
  .startsWith('<!DOCTYPE html SYSTEM "about:legacy"><html>'));
assert.ok(doctypeOut({ name: "html", publicId: 'a"b', systemId: "" }).includes('"a&quot;b"'));
const out = V.buildDocument("<p>x</p>", ID, () => stubDoc(true));
assert.ok(out.startsWith("<!DOCTYPE html>"));
assert.equal(inserted[0].httpEquiv, "Content-Security-Policy");
assert.equal(inserted[0].content, V.CSP);
assert.match(inserted[1].textContent, /RTC/, "the lockdown script comes second");
assert.ok(inserted[2].textContent.includes(JSON.stringify(ID)), "the bridge script carries the id");
assert.throws(() => V.buildDocument("<p>x</p>", "</script><script>", () => stubDoc(true)));

console.log("visual-aid tests passed");
