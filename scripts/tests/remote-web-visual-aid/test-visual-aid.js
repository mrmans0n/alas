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

// Navigation message: the source document unloaded because it navigated itself.
const nav = (extra = {}) => ({ alasVisual: true, id: ID, navigating: true, ...extra });
assert.equal(V.navigationFromMessage(nav(), ID, win, win), true);
assert.equal(V.navigationFromMessage(nav(), ID, other, win), false, "wrong source");
assert.equal(V.navigationFromMessage(nav({ id: "other" }), ID, win, win), false, "wrong id");
assert.equal(V.navigationFromMessage(nav({ alasVisual: undefined }), ID, win, win), false, "missing marker");
assert.equal(V.navigationFromMessage(nav({ navigating: undefined }), ID, win, win), false, "not a navigation");
assert.equal(V.navigationFromMessage({ alasVisual: true, id: ID, height: 300 }, ID, win, win), false, "a height message");
assert.equal(V.navigationFromMessage(nav(), ID, undefined, undefined), false, "no frame window");
assert.equal(V.navigationFromMessage(null, ID, win, win), false);

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
const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
assert.equal(V.canSubmit(question(false), ["a"], family.repeat(2000)), true, "multi-scalar graphemes count once");
assert.equal(V.canSubmit(question(false), ["a"], family.repeat(2001)), false);
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

// Links: every element with an href is swallowed, fragments included.
const link = (href) => ({ getAttribute: (n) => (n === "href" ? href : null) });
for (const href of ["#frag", "https://example.com/", "javascript:alert(1)", "mailto:a@b.c", ""]) {
  assert.equal(V.shouldSwallowLinkClick(link(href)), true, href);
}
assert.equal(V.shouldSwallowLinkClick(link(null)), false, "an anchor without href");
assert.equal(V.shouldSwallowLinkClick(null), false);

// Rejections apply only to the card waiting on a reply.
assert.deepEqual(V.applyRejection({ pending: true, submitted: true }, "notWriter"),
  { pending: false, submitted: false, error: V.rejectionText("notWriter") });
assert.equal(V.applyRejection({ pending: false, submitted: false }, "notWriter"), null, "an idle card ignores it");
assert.equal(V.applyRejection({ pending: false, submitted: true }, "notWriter"), null, "submitted but no longer pending");

// A rejection echoes the request's id: only the card that sent that request takes it.
assert.deepEqual(V.applyRejection({ pending: true, submitted: true, requestId: "r1" }, "notWriter", "r1"),
  { pending: false, submitted: false, error: V.rejectionText("notWriter") }, "a matching id applies");
assert.equal(V.applyRejection({ pending: true, submitted: true, requestId: "r1" }, "notWriter", "r2"), null,
  "another phone's simultaneous response is ignored");
assert.deepEqual(V.applyRejection({ pending: true, submitted: true, requestId: "r1" }, "notWriter", undefined),
  { pending: false, submitted: false, error: V.rejectionText("notWriter") }, "no id (older Mac) applies when pending");
assert.equal(V.applyRejection({ pending: false, submitted: false, requestId: null }, "notWriter", "r1"), null, "an idle card ignores an id");
assert.equal(V.applyRejection({ pending: false, submitted: false }, "notWriter", undefined), null, "an idle card ignores an id-less rejection");
assert.notEqual(V.newRequestId(), V.newRequestId(), "ids differ per request");
assert.ok(V.newRequestId().length > 0 && V.newRequestId().length <= 64);

// Frame navigation guard: the first load is the srcdoc itself, any later load is a navigation.
{
  const listeners = [];
  const frame = {
    addEventListener(type, fn) { assert.equal(type, "load"); listeners.push(fn); },
    removeEventListener(type, fn) { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); },
    fire() { [...listeners].forEach((fn) => fn()); },
  };
  let calls = 0;
  V.guardFrameNavigation(frame, () => { calls += 1; });
  assert.equal(listeners.length, 1);
  frame.fire();
  assert.equal(calls, 0, "one load is the document itself");
  frame.fire();
  assert.equal(calls, 1);
  assert.equal(listeners.length, 0, "the listener is removed");
  frame.fire(); frame.fire();
  assert.equal(calls, 1, "later loads are ignored");
}
assert.equal(V.shouldMount({ frame: null, paused: false, blocked: true }, true), false, "a blocked card never remounts");

// Note trimming equals Foundation's whitespacesAndNewlines (the same vectors run through the gateway in Swift).
for (const [scalar, trimmed] of [[0x85, true], [0x200B, true], [0xA0, true], [0x2028, true], [0x3000, true], [0x1680, true],
                                 [0x202F, true], [0xFEFF, false]]) {
  const v = String.fromCodePoint(scalar);
  const note = v + "x".repeat(2000);
  assert.equal(V.trimNote(note), trimmed ? "x".repeat(2000) : note, scalar.toString(16));
  assert.equal(V.trimNote(note + v), trimmed ? "x".repeat(2000) : note + v, scalar.toString(16) + " both edges");
  assert.equal(V.noteLength(note), trimmed ? 2000 : 2001, scalar.toString(16));
  assert.equal(V.canSubmit({ allowMultiple: false }, ["a"], note), trimmed, scalar.toString(16));
  assert.equal(V.trimNote(v), trimmed ? "" : v);
}
assert.equal(V.trimNote(" \t\n\r x y \n\t"), "x y", "a tab and newline mix");
assert.equal(V.trimNote("a\u200Bb"), "a\u200Bb", "only the edges are trimmed");

// Drafts across a resync.
{
  const q = { prompt: "Pick", allowMultiple: true, options: [{ id: "a", label: "A" }, { id: "b", label: "B" }] };
  const visual = { question: q };
  const card = (extra) => ({ visual, selected: [], note: "", ...extra });
  const draft = V.stashDraft(card({ selected: ["a", "b"], note: "why" }));
  assert.deepEqual(V.restoreDraft(visual, draft), { selected: ["a", "b"], note: "why" }, "survives a reset");
  assert.deepEqual(V.restoreDraft(visual, V.stashDraft(card({ note: "only a note" }))), { selected: [], note: "only a note" });
  assert.equal(V.stashDraft(card({})), null, "nothing to keep");
  assert.equal(V.stashDraft(card({ selected: ["a"], visual: { question: q, answer: { kind: "dismissed" } } })), null, "answered cards keep nothing");
  assert.deepEqual(V.restoreDraft(visual, { ...draft, selected: ["a", "gone"] }), { selected: ["a"], note: "why" }, "invalid id dropped");
  assert.equal(V.restoreDraft(visual, { ...draft, selected: ["gone"], note: "" }), null, "nothing valid left");
  const changed = { question: { ...q, prompt: "Different" } };
  assert.equal(V.restoreDraft(changed, draft), null, "a changed question drops the draft");
  assert.equal(V.restoreDraft({ question: { ...q, options: [q.options[0]] } }, draft), null, "changed options drop it");
  assert.equal(V.restoreDraft({ question: q, answer: { kind: "answered", selectedOptionIds: ["a"] } }, draft), null, "an answered row drops it");
  const single = { question: { ...q, allowMultiple: false } };
  const singleDraft = V.stashDraft({ visual: single, selected: ["b"], note: "" });
  assert.deepEqual(V.restoreDraft(single, { ...singleDraft, selected: ["a", "b"] }), { selected: ["a"], note: "" }, "single choice keeps one");
}

// Submit provenance across a snapshot rebuild.
{
  assert.equal(V.restoreSubmitted(answeredRow, true), true, "answered row keeps provenance");
  assert.equal(V.restoreSubmitted({ answer: { kind: "dismissed" } }, true), true, "dismissed row keeps provenance");
  assert.equal(V.restoreSubmitted(unansweredRow, true), false, "unanswered row already shows the outcome");
  assert.equal(V.restoreSubmitted(answeredRow, false), false, "never submitted stays false");
  assert.equal(V.restoreSubmitted(answeredRow, undefined), false, "no stash entry");
  assert.equal(V.restoreSubmitted(unansweredRow, false), false);

  // This phone answers, a snapshot rebuilds the card, then the prompt fails and the row rolls back.
  let card = { pending: true, submitted: true, error: "" };
  card = { ...card, ...V.nextCardState(card, answeredRow) };                       // accepted answer delta
  assert.equal(card.submitted, true);
  const stashed = card.submitted === true;                                           // resetVisualCards(true)
  card = { pending: false, error: "", submitted: V.restoreSubmitted(answeredRow, stashed) };   // rebuilt from the answered snapshot row
  assert.equal(card.submitted, true, "provenance survives the rebuild");
  const failed = V.nextCardState(card, unansweredRow);                               // rollback delta
  assert.deepEqual(failed, { pending: false, submitted: false, error: V.FAILED_TEXT }, "this phone's send is reported failed");

  // An observer never submitted: another client's answer, a snapshot, then its rollback shows no error.
  let observer = { pending: false, submitted: false, error: "" };
  observer = { ...observer, ...V.nextCardState(observer, answeredRow) };
  observer = { pending: false, error: "", submitted: V.restoreSubmitted(answeredRow, observer.submitted === true) };
  assert.equal(observer.submitted, false);
  assert.deepEqual(V.nextCardState(observer, unansweredRow), { pending: false, submitted: false, error: "" }, "the observer reports nothing");

  // A snapshot that already shows the rollback drops the provenance: the card is idle and re-answerable.
  const rolledBack = { pending: false, error: "", submitted: V.restoreSubmitted(unansweredRow, true) };
  assert.deepEqual(V.nextCardState(rolledBack, unansweredRow), { pending: false, submitted: false, error: "" });
}

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
{
  const bridge = inserted[2].textContent;
  assert.ok(bridge.includes('addEventListener("pagehide"'), "the bridge reports its document unloading");
  assert.ok(bridge.includes("navigating: true") && bridge.includes(", true);"), "capture phase");
  assert.ok(!bridge.includes('addEventListener("beforeunload"'), "beforeunload also fires for 204 and download navigations");
  assert.ok(bridge.indexOf("pagehide") < bridge.indexOf("ResizeObserver"), "registered before anything else in the bridge");
  assert.ok(inserted.indexOf(inserted[2]) < inserted.length, "the bridge is prepended ahead of agent content");
}
assert.throws(() => V.buildDocument("<p>x</p>", "</script><script>", () => stubDoc(true)));

console.log("visual-aid tests passed");
