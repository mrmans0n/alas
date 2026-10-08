// Pure logic for visual aids in the phone client: the sandboxed document an agent's HTML runs in, the answer
// state machine, and the live-frame budget. app.js owns every DOM and socket effect.
(function () {
  const CSP =
    "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; " +
    "img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; " +
    "worker-src 'none'; form-action 'none'; base-uri 'none'";
  // Never add allow-same-origin: the page keeps its bearer token in localStorage and /ws is same-origin.
  const SANDBOX = "allow-scripts";
  const HEIGHT_MIN = 120, HEIGHT_MAX = 720, NOTE_MAX = 2000, MAX_LIVE_FRAMES = 3;
  const FAILED_TEXT = "Couldn't send your answer. Try again.";
  const UUID = /^[0-9a-fA-F-]{36}$/;

  // Mirrors Alas/Resources/VisualAid/frame.html; RemoteWebAssetTests checks every class selector is present.
  const FRAME_CSS = `
  :root { color-scheme: dark; font: 14px -apple-system, system-ui, sans-serif;
    --alas-text: oklch(0.94 0.012 220); --alas-dim: oklch(0.64 0.014 220); --alas-accent: oklch(0.74 0.11 195);
    --alas-background: oklch(0.215 0.013 245); --alas-line: oklch(1 0 0 / 0.14);
    --alas-tone-success: oklch(0.78 0.14 155); --alas-tone-danger: oklch(0.72 0.16 25); }
  html, body { margin: 0; }
  body { padding: 14px; color: var(--alas-text); background: var(--alas-background); line-height: 1.45; }
  h2 { font-size: 17px; margin: 0 0 4px; }
  h3 { font-size: 14px; margin: 0 0 4px; }
  .subtitle { color: var(--alas-dim); margin: 0 0 14px; }
  .section { margin-bottom: 16px; }
  .label { font-size: 10.5px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--alas-dim); }
  .options, .cards { display: grid; gap: 10px; }
  .options { grid-template-columns: 1fr; }
  .cards { grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); }
  .option, .card { border: 1px solid var(--alas-line); border-radius: 8px; }
  .option { display: flex; gap: 12px; align-items: flex-start; padding: 12px; }
  .option .letter { flex: none; width: 24px; height: 24px; border-radius: 6px; display: grid; place-items: center; font-weight: 700; background: var(--alas-line); }
  .option.selected, .card.selected { border-color: var(--alas-accent); box-shadow: 0 0 0 1px var(--alas-accent); }
  .option.selected .letter { background: var(--alas-accent); color: var(--alas-background); }
  .card-image { min-height: 120px; padding: 12px; border-bottom: 1px solid var(--alas-line); }
  .card-body { padding: 10px 12px; }
  .mockup { border: 1px solid var(--alas-line); border-radius: 8px; overflow: hidden; }
  .mockup-header { padding: 6px 10px; font-size: 11px; color: var(--alas-dim); border-bottom: 1px solid var(--alas-line); }
  .mockup-body { padding: 12px; }
  .split { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .pros-cons { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .pros h4 { color: var(--alas-tone-success); }
  .cons h4 { color: var(--alas-tone-danger); }
  .mock-nav { padding: 8px 12px; border: 1px solid var(--alas-line); border-radius: 6px; margin-bottom: 8px; }
  .mock-sidebar { width: 160px; padding: 10px; border: 1px dashed var(--alas-line); border-radius: 6px; margin-right: 8px; }
  .mock-content { flex: 1; padding: 10px; border: 1px dashed var(--alas-line); border-radius: 6px; }
  .mock-button { font: inherit; padding: 6px 12px; border-radius: 6px; border: 1px solid var(--alas-accent); background: var(--alas-accent); color: var(--alas-background); }
  .mock-input { font: inherit; padding: 6px 8px; border-radius: 6px; border: 1px solid var(--alas-line); background: transparent; color: inherit; }
  .placeholder { display: grid; place-items: center; min-height: 80px; border: 1px dashed var(--alas-line); border-radius: 6px; color: var(--alas-dim); }`;

  // CSP does not cover WebRTC. Best effort in a browser: a no-src child frame is a clean realm.
  const LOCKDOWN_SCRIPT =
    "(() => { for (const name of Object.getOwnPropertyNames(window)) {" +
    " if (/^(webkit)?RTC/.test(name)) { try { delete window[name]; } catch (e) {} } } })();";

  function bridgeScript(id) {
    return `(() => {
      const id = ${JSON.stringify(id)};
      const post = () => parent.postMessage({ alasVisual: true, id, height: Math.ceil(document.documentElement.getBoundingClientRect().height) }, "*");
      const observer = new ResizeObserver(post);
      observer.observe(document.documentElement);
      addEventListener("DOMContentLoaded", () => { if (document.body) observer.observe(document.body); post(); });
      addEventListener("load", post);
      // Links do nothing in a phone visual; same-document anchors keep scrolling.
      document.addEventListener("click", (event) => {
        const link = event.target instanceof Element && event.target.closest("a[href]");
        if (link && !(link.getAttribute("href") || "").startsWith("#")) event.preventDefault();
      }, true);
    })();`;
  }

  // Swift Character.isWhitespace (Unicode White_Space). JS \s differs: it includes U+FEFF and excludes U+0085.
  const WS = "[\\t\\n\\u000B\\u000C\\r \\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]";
  const LEADING_WS = new RegExp("^" + WS + "+");
  const IS_WS = new RegExp("^" + WS + "$");

  // The desktop rule: after whitespace and comments, a doctype or <html followed by whitespace, ">" or "/".
  function isFullDocument(html) {
    let rest = String(html);
    for (;;) {
      rest = rest.replace(LEADING_WS, "");
      if (!rest.startsWith("<!--")) break;
      const end = rest.indexOf("-->");
      if (end < 0) return false;
      rest = rest.slice(end + 3);
    }
    const opening = rest.slice(0, 10).toLowerCase();
    return ["<!doctype", "<html"].some((token) => {
      if (!opening.startsWith(token)) return false;
      const next = opening.charAt(token.length);
      return next === "" || IS_WS.test(next) || next === ">" || next === "/";
    });
  }

  // Keep public and system ids: dropping them would switch a quirks-mode document to standards mode.
  function serializeDoctype(dt) {
    const quote = (v) => `"${String(v).replace(/"/g, "&quot;")}"`;
    let out = `<!DOCTYPE ${dt.name}`;
    if (dt.publicId) out += ` PUBLIC ${quote(dt.publicId)}` + (dt.systemId ? ` ${quote(dt.systemId)}` : "");
    else if (dt.systemId) out += ` SYSTEM ${quote(dt.systemId)}`;
    return out + ">";
  }

  function buildDocument(html, id, parse) {
    if (!UUID.test(id)) throw new Error("invalid visual id");
    const source = isFullDocument(html)
      ? html
      : `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${FRAME_CSS}</style></head><body>${html}</body></html>`;
    const doc = parse(source);
    let head = doc.head;
    if (!head) {
      head = doc.createElement("head");
      doc.documentElement.insertBefore(head, doc.documentElement.firstChild);
    }
    const csp = doc.createElement("meta");
    csp.httpEquiv = "Content-Security-Policy";
    csp.content = CSP;
    const lockdown = doc.createElement("script");
    lockdown.textContent = LOCKDOWN_SCRIPT;
    const bridge = doc.createElement("script");
    bridge.textContent = bridgeScript(id);
    // First in <head>, so they run before anything the agent wrote.
    head.prepend(csp, lockdown, bridge);
    const doctype = doc.doctype ? serializeDoctype(doc.doctype) : "";
    return doctype + doc.documentElement.outerHTML;
  }

  const isString = (x) => typeof x === "string";
  function validQuestion(q) {
    return !!q && typeof q === "object" && isString(q.prompt) && typeof q.allowMultiple === "boolean" &&
      Array.isArray(q.options) && q.options.length > 0 &&
      q.options.every((o) => o && isString(o.id) && isString(o.label));
  }
  function validAnswer(a) {
    if (!a || typeof a !== "object") return false;
    if (a.kind === "dismissed") return true;
    return a.kind === "answered" && Array.isArray(a.selectedOptionIds) && a.selectedOptionIds.every(isString) &&
      (a.note == null || isString(a.note));
  }

  function parseVisual(json) {
    let v;
    try { v = JSON.parse(json); } catch (_) { return null; }
    if (!v || !isString(v.id) || !UUID.test(v.id) || !isString(v.title) || !isString(v.html)) return null;
    if (v.question != null && !validQuestion(v.question)) return null;
    if (v.answer != null && !validAnswer(v.answer)) return null;
    return v;
  }

  function clampHeight(value) {
    if (typeof value !== "number" || !Number.isFinite(value)) return null;
    return Math.min(Math.max(Math.ceil(value), HEIGHT_MIN), HEIGHT_MAX);
  }

  // Only the card's own window may size it, and only for its own id.
  function heightFromMessage(data, expectedId, source, expectedSource) {
    if (!data || data.alasVisual !== true || data.id !== expectedId || source !== expectedSource) return null;
    return clampHeight(data.height);
  }

  function toggleSelection(question, selected, optionId) {
    if (!question.options.some((o) => o.id === optionId)) return selected.slice();
    if (!question.allowMultiple) return [optionId];
    return selected.includes(optionId) ? selected.filter((id) => id !== optionId) : selected.concat(optionId);
  }

  // The Mac counts extended grapheme clusters (Swift String.count); UTF-16 length would disagree.
  const segmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
  function noteLength(text) {
    const t = String(text || "").trim();
    if (segmenter) { let n = 0; for (const _ of segmenter.segment(t)) n++; return n; }
    return Array.from(t).length;
  }

  function canSubmit(question, selected, note) {
    if (selected.length === 0 || (!question.allowMultiple && selected.length !== 1)) return false;
    return noteLength(note) <= NOTE_MAX;
  }

  function buildResponse(sessionId, visual, action, selected, note) {
    const q = visual.question;
    if (!q) return null;
    const base = { type: "visualAidResponse", sessionId, visualId: visual.id, action };
    if (action === "dismiss") return { ...base, selectedOptionIds: [] };
    if (!canSubmit(q, selected, note)) return null;
    const ordered = q.options.map((o) => o.id).filter((id) => selected.includes(id));
    const trimmed = String(note || "").trim();
    return trimmed ? { ...base, selectedOptionIds: ordered, note: trimmed } : { ...base, selectedOptionIds: ordered };
  }

  function answerView(visual, state) {
    const q = visual.question;
    if (!q) return { kind: "none" };
    if (visual.answer) {
      if (visual.answer.kind === "dismissed") return { kind: "dismissed" };
      const ids = visual.answer.selectedOptionIds || [];
      const labels = q.options.filter((o) => ids.includes(o.id)).map((o) => o.label);
      return { kind: "answered", labels, note: visual.answer.note || "" };
    }
    const s = state || {};
    const selected = s.selected || [];
    const editable = s.canDrive === true && s.pending !== true;
    return {
      kind: "open",
      prompt: q.prompt,
      multiple: q.allowMultiple === true,
      options: q.options.map((o) => ({ id: o.id, label: o.label, checked: selected.includes(o.id) })),
      note: s.note || "",
      noteMax: NOTE_MAX,
      editable,
      canSubmit: editable && canSubmit(q, selected, s.note),
      hint: s.canDrive === true ? "" : "Take over to answer",
      error: s.error || "",
      pending: s.pending === true,
    };
  }

  function rejectionText(reason) {
    switch (reason) {
      case "notWriter": return "Take over this session to answer.";
      case "notFound": return "This visual is no longer available.";
      case "alreadyAnswered": return "This question was already answered.";
      case "invalid": return "That answer wasn't accepted. Check your choice and try again.";
      default: return FAILED_TEXT;
    }
  }

  // Least recently shown first. Admitting past the limit evicts from the front.
  function admitFrame(order, id, limit) {
    const next = order.filter((x) => x !== id).concat(id);
    const overflow = Math.max(0, next.length - limit);
    return { order: next.slice(overflow), evicted: next.slice(0, overflow) };
  }
  function touchFrame(order, id) { return order.includes(id) ? order.filter((x) => x !== id).concat(id) : order.slice(); }
  function releaseFrame(order, id) { return order.filter((x) => x !== id); }

  globalThis.RemoteVisualAid = {
    CSP, SANDBOX, HEIGHT_MIN, HEIGHT_MAX, NOTE_MAX, MAX_LIVE_FRAMES, FAILED_TEXT, FRAME_CSS,
    isFullDocument, buildDocument, parseVisual, clampHeight, heightFromMessage, toggleSelection, noteLength, canSubmit,
    buildResponse, answerView, rejectionText, admitFrame, touchFrame, releaseFrame,
  };
})();
