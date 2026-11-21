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
  // The Mac lets an embedded visual grow to 2000pt; the phone keeps its own limit when that is lower.
  const EMBEDDED_HEIGHT_MAX = Math.min(HEIGHT_MAX, 2000);
  const FAILED_TEXT = "Couldn't send your answer. Try again.";
  const BLOCKED_TEXT = "Visual blocked: it tried to leave the page.";
  const UUID = /^[0-9a-fA-F-]{36}$/;

  // Mirrors Alas/Resources/VisualAid/frame.html; RemoteWebAssetTests checks every class selector is present.
  // The variables are the Mac's dark theme (cool-slate) and its layout variables, fixed: the phone gets no
  // theme push. test-visual-aid.js checks every variable the Mac defines is here.
  const FRAME_CSS = `
  :root { color-scheme: dark; font: 14px -apple-system, system-ui, sans-serif;
    --alas-text: oklch(0.94 0.012 220); --alas-dim: oklch(0.64 0.014 220); --alas-accent: oklch(0.74 0.11 195);
    --alas-background: oklch(0.215 0.013 245); --alas-line: oklch(1 0 0 / 0.14);
    --alas-tone-success: oklch(0.78 0.14 155); --alas-tone-danger: oklch(0.72 0.16 25);
    --alas-tone-warning: oklch(0.80 0.13 65); --alas-tone-info: oklch(0.76 0.11 230);
    --alas-card: oklch(0.275 0.020 220); --alas-border: oklch(0.32 0.020 220 / 0.35); --alas-muted: oklch(0.50 0.014 220);
    --alas-accent-soft: oklch(0.74 0.11 195 / 0.18);
    --alas-chart-1: oklch(0.74 0.11 195); --alas-chart-2: oklch(0.76 0.11 230); --alas-chart-3: oklch(0.78 0.14 155);
    --alas-chart-4: oklch(0.80 0.13 65); --alas-chart-5: oklch(0.72 0.16 25); --alas-chart-6: oklch(0.74 0.11 295);
    --alas-radius: 6px; --alas-font-sans: -apple-system, system-ui, sans-serif;
    --alas-font-mono: ui-monospace, SFMono-Regular, Menlo, monospace; --alas-font-size: 14px; }
  html, body { margin: 0; }
  body { color: var(--alas-text); line-height: 1.45; }
  .alas-card body { padding: 14px; background: var(--alas-background); }
  .alas-embedded, .alas-embedded body { background: transparent; }
  .alas-embedded body { padding: 0; font: var(--alas-font-size) var(--alas-font-sans); line-height: 1.45; }
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
  .placeholder { display: grid; place-items: center; min-height: 80px; border: 1px dashed var(--alas-line); border-radius: 6px; color: var(--alas-dim); }
  alas-chart { display: block; margin: 4px 0 12px; }
  .alas-chart-legend { display: flex; flex-wrap: wrap; gap: 4px 14px; font-size: 11px; color: var(--alas-dim, GrayText); margin-bottom: 6px; }
  .alas-chart-swatch { display: inline-block; width: 8px; height: 8px; border-radius: 2px; margin-right: 5px; }
  .alas-chart-text { font-size: 11px; fill: var(--alas-dim, GrayText); font-variant-numeric: tabular-nums; }
  .alas-chart-grid { stroke: var(--alas-line, #8884); stroke-width: 1; }
  .alas-line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
  .alas-bar:hover, .alas-dot:hover { opacity: .8; }
  .alas-chart-error { color: var(--alas-tone-danger, red); font-size: 12px; }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin-bottom: 12px; }
  .stat { background: var(--alas-card, #8881); border-radius: var(--alas-radius, 6px); padding: 12px; }
  .stat .value { display: block; font-size: 22px; font-weight: 600; font-variant-numeric: tabular-nums; }
  .stat .delta { font-size: 12px; color: var(--alas-dim, GrayText); }
  .delta.up { color: var(--alas-tone-success, green); }
  .delta.down { color: var(--alas-tone-danger, red); }
  .timeline { list-style: none; margin: 0 0 12px 4px; padding: 0 0 0 14px; border-left: 2px solid var(--alas-line, #8884); }
  .timeline li { position: relative; padding: 0 0 12px 8px; }
  .timeline li::before { content: ""; position: absolute; left: -20px; top: 5px; width: 8px; height: 8px; border-radius: 50%; background: var(--alas-accent, AccentColor); }
  .timeline .when { display: block; font-size: 11.5px; color: var(--alas-dim, GrayText); }
  .flow { display: flex; flex-wrap: wrap; gap: 10px 24px; margin-bottom: 12px; }
  .flow > * { position: relative; box-sizing: border-box; flex: 1 1 100px; background: var(--alas-card, #8881); border-radius: var(--alas-radius, 6px); padding: 10px 12px; }
  .flow > * + *::before { content: "→"; position: absolute; left: -12px; top: 50%; transform: translate(-50%, -50%); color: var(--alas-dim, GrayText); }
  .callout { border-left: 3px solid var(--alas-tone-info, AccentColor); background: var(--alas-card, #8881); border-radius: var(--alas-radius, 6px); padding: 10px 12px; margin-bottom: 12px; }
  .callout.success { border-left-color: var(--alas-tone-success, green); }
  .callout.warn { border-left-color: var(--alas-tone-warning, orange); }
  .callout.danger { border-left-color: var(--alas-tone-danger, red); }
  table { border-collapse: collapse; width: 100%; margin-bottom: 12px; font-variant-numeric: tabular-nums; }
  th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--alas-line, #8884); }
  th { font-size: 11px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--alas-dim, GrayText); }
  th.num, td.num { text-align: right; }`;

  // A copy of the components script in Alas/Resources/VisualAid/frame.html, identical between the markers;
  // RemoteWebAssetTests compares them. Fragments get it, as on the Mac; full documents stay as written.
  const COMPONENTS_SCRIPT = String.raw`
/* alas-components:begin */
(() => {
  // No template literals here: RemoteWeb/visual-aid.js holds a copy inside one.
  // <alas-chart type="bar|hbar|line" height="200" unit="ms" data='{"labels":[...],"series":[{"name":"...","values":[...]}]}'>
  const NS = "http://www.w3.org/2000/svg";
  const TYPES = ["bar", "hbar", "line"];
  const svg = (tag, attrs, parent) => {
    const node = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    if (parent) parent.appendChild(node);
    return node;
  };
  const tip = (node, text) => { svg("title", {}, node).textContent = text; };
  const color = (i) => "var(--alas-chart-" + ((i % 6) + 1) + ", currentColor)";
  const fmt = (n) => {
    const a = Math.abs(n);
    if (a >= 1e9) return +(n / 1e9).toFixed(1) + "B";
    if (a >= 1e6) return +(n / 1e6).toFixed(1) + "M";
    if (a >= 1e4) return +(n / 1e3).toFixed(1) + "k";
    if (a >= 100) return String(Math.round(n));
    // Three significant digits, so 0.001 and 0.002 stay apart.
    return String(+n.toPrecision(3));
  };
  const textWidth = (s) => String(s).length * 6.2;
  function niceScale(min, max) {
    if (min === max) { max = min === 0 ? 1 : min + Math.abs(min); }
    const raw = (max - min) / 4;
    const mag = Math.pow(10, Math.floor(Math.log10(raw)));
    const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw);
    const lo = Math.floor(min / step) * step, hi = Math.ceil(max / step) * step;
    const ticks = [];
    for (let t = lo; t <= hi + step / 2; t += step) ticks.push(+t.toFixed(10));
    return { lo, hi, ticks };
  }
  function parse(el) {
    let data;
    try { data = JSON.parse(el.getAttribute("data") || ""); } catch (_) { throw new Error("data is not valid JSON"); }
    if (!data || typeof data !== "object") throw new Error("data must be an object");
    let series = data.series;
    if (!series && Array.isArray(data.values)) series = [{ name: data.name || "", values: data.values }];
    if (!Array.isArray(series) || !series.length) throw new Error("data needs a series array");
    const labels = Array.isArray(data.labels) ? data.labels.map(String) : series[0].values.map((_, i) => String(i + 1));
    series = series.map((s, i) => {
      if (!s || !Array.isArray(s.values)) throw new Error("series " + (i + 1) + " needs a values array");
      if (s.values.length !== labels.length) throw new Error("series " + (i + 1) + " has " + s.values.length + " values for " + labels.length + " labels");
      if (!s.values.every((v) => typeof v === "number" && isFinite(v))) throw new Error("series " + (i + 1) + " has a non-numeric value");
      return { name: s.name == null ? "" : String(s.name), values: s.values };
    });
    return { labels, series };
  }
  class AlasChart extends HTMLElement {
    connectedCallback() {
      this.render();
      if (!this.observer && window.ResizeObserver) {
        this.observer = new ResizeObserver(() => { if (this.clientWidth !== this.drawnWidth) this.render(); });
        this.observer.observe(this);
      }
    }
    disconnectedCallback() { if (this.observer) { this.observer.disconnect(); this.observer = null; } }
    render() {
      const type = TYPES.includes(this.getAttribute("type")) ? this.getAttribute("type") : "bar";
      const unit = this.getAttribute("unit") || "";
      this.textContent = "";
      this.drawnWidth = this.clientWidth;
      let data;
      try { data = parse(this); } catch (e) {
        const note = document.createElement("div");
        note.className = "alas-chart-error";
        note.textContent = "Chart data is invalid: " + e.message;
        this.appendChild(note);
        return;
      }
      const { labels, series } = data;
      if (series.length > 1 || series[0].name) {
        const legend = document.createElement("div");
        legend.className = "alas-chart-legend";
        series.forEach((s, i) => {
          const item = document.createElement("span");
          const swatch = document.createElement("span");
          swatch.className = "alas-chart-swatch";
          swatch.style.background = color(i);
          item.append(swatch, s.name || "Series " + (i + 1));
          legend.appendChild(item);
        });
        this.appendChild(legend);
      }
      const width = Math.max(160, this.clientWidth || 480);
      const values = series.flatMap((s) => s.values);
      const scale = niceScale(Math.min(0, ...values), Math.max(0, ...values));
      const tickLabel = (t) => fmt(t) + unit;
      const rowHeight = Math.max(14, series.length * 12 + 8);
      const height = Math.min(800, Math.max(80, Number(this.getAttribute("height")) ||
        (type === "hbar" ? labels.length * rowHeight + 28 : 200)));
      const root = svg("svg", {
        width: "100%", height, viewBox: "0 0 " + width + " " + height, role: "img",
        "aria-label": this.getAttribute("label") || (type === "line" ? "Line" : "Bar") + " chart of " + (series.map((s) => s.name).filter(Boolean).join(", ") || "values"),
      }, this);
      const text = (x, y, content, anchor, parent) => {
        const t = svg("text", { x, y, "text-anchor": anchor, class: "alas-chart-text" }, parent || root);
        t.textContent = content;
        return t;
      };
      const label = (l, s, v) => l + (s.name ? " · " + s.name : "") + ": " + fmt(v) + unit;
      if (type === "hbar") {
        const left = Math.min(width * 0.4, Math.max(...labels.map(textWidth)) + 10);
        const right = Math.max(12, textWidth(tickLabel(scale.hi)) / 2 + 4);
        const plot = { x: left, y: 4, w: width - left - right, h: height - 24 };
        const x = (v) => plot.x + (v - scale.lo) / (scale.hi - scale.lo) * plot.w;
        for (const t of scale.ticks) {
          svg("line", { x1: x(t), x2: x(t), y1: plot.y, y2: plot.y + plot.h, class: "alas-chart-grid" }, root);
          text(x(t), height - 6, tickLabel(t), "middle");
        }
        const band = plot.h / labels.length, bar = band * 0.75 / series.length;
        labels.forEach((l, i) => {
          text(left - 6, plot.y + band * i + band / 2 + 4, l, "end");
          series.forEach((s, j) => {
            const v = s.values[i], y = plot.y + band * i + band * 0.125 + bar * j;
            const r = svg("rect", { x: Math.min(x(0), x(v)), y, width: Math.abs(x(v) - x(0)), height: Math.max(1, bar - 1),
              rx: 2, class: "alas-bar", style: "fill: " + color(j) }, root);
            tip(r, label(l, s, v));
          });
        });
        return;
      }
      const left = Math.max(...scale.ticks.map((t) => textWidth(tickLabel(t)))) + 10;
      const plot = { x: left, y: 8, w: width - left - 8, h: height - 30 };
      const y = (v) => plot.y + plot.h - (v - scale.lo) / (scale.hi - scale.lo) * plot.h;
      for (const t of scale.ticks) {
        svg("line", { x1: plot.x, x2: plot.x + plot.w, y1: y(t), y2: y(t), class: "alas-chart-grid" }, root);
        text(left - 6, y(t) + 4, tickLabel(t), "end");
      }
      const band = plot.w / labels.length;
      const every = Math.max(1, Math.ceil(Math.max(...labels.map(textWidth)) / Math.max(1, band - 6)));
      labels.forEach((l, i) => { if (i % every === 0) text(plot.x + band * i + band / 2, height - 8, l, "middle"); });
      if (type === "line") {
        const px = (i) => plot.x + band * i + band / 2;
        series.forEach((s, j) => {
          svg("path", { d: s.values.map((v, i) => (i ? "L" : "M") + px(i) + "," + y(v)).join(""),
            class: "alas-line", style: "stroke: " + color(j) }, root);
          s.values.forEach((v, i) => tip(svg("circle", { cx: px(i), cy: y(v), r: 3, class: "alas-dot", style: "fill: " + color(j) }, root), label(labels[i], s, v)));
        });
        return;
      }
      const bar = band * 0.75 / series.length;
      labels.forEach((l, i) => series.forEach((s, j) => {
        const v = s.values[i], x = plot.x + band * i + band * 0.125 + bar * j;
        const r = svg("rect", { x, y: Math.min(y(0), y(v)), width: Math.max(1, bar - 1), height: Math.abs(y(v) - y(0)),
          rx: 2, class: "alas-bar", style: "fill: " + color(j) }, root);
        tip(r, label(l, s, v));
      }));
    }
  }
  if (!customElements.get("alas-chart")) customElements.define("alas-chart", AlasChart);
})();
/* alas-components:end */
`;

  // CSP does not cover WebRTC. Best effort in a browser: a no-src child frame is a clean realm.
  const LOCKDOWN_SCRIPT =
    "(() => { for (const name of Object.getOwnPropertyNames(window)) {" +
    " if (/^(webkit)?RTC/.test(name)) { try { delete window[name]; } catch (e) {} } } })();";

  function bridgeScript(id) {
    return `(() => {
      const id = ${JSON.stringify(id)};
      // The first listener the page gets. pagehide fires when a navigation commits, before the new document
      // runs anything, and does not depend on the load event (a page can hold a subresource open forever).
      // Not beforeunload: that also fires for navigations that end as a 204 or a download and stay on this page.
      addEventListener("pagehide", () => parent.postMessage({ alasVisual: true, id, navigating: true }, "*"), true);
      const post = () => parent.postMessage({ alasVisual: true, id, height: Math.ceil(document.documentElement.getBoundingClientRect().height) }, "*");
      const observer = new ResizeObserver(post);
      observer.observe(document.documentElement);
      addEventListener("DOMContentLoaded", () => { if (document.body) observer.observe(document.body); post(); });
      addEventListener("load", post);
      // Links do nothing in a phone visual, same-document anchors included (see shouldSwallowLinkClick).
      document.addEventListener("click", (event) => {
        const link = event.target instanceof Element && event.target.closest("a[href], area[href]");
        if (link && link.getAttribute("href") !== null) event.preventDefault();
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

  // A visual from a Mac that predates presentations, or with anything unexpected, is a card. So is one with a
  // question: its answer controls belong to a card.
  function presentationOf(visual) {
    return !!visual && visual.presentation === "embedded" && visual.question == null ? "embedded" : "card";
  }

  // Fragments are wrapped like frame.html, with the presentation as the root class. Full documents are the
  // agent's own and stay as written, as on the Mac.
  function buildDocument(html, id, parse, presentation) {
    if (!UUID.test(id)) throw new Error("invalid visual id");
    const rootClass = presentation === "embedded" ? "alas-embedded" : "alas-card";
    const source = isFullDocument(html)
      ? html
      : `<!DOCTYPE html><html class="${rootClass}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${FRAME_CSS}</style><script>${COMPONENTS_SCRIPT}</script></head><body>${html}</body></html>`;
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

  function clampHeight(value, presentation) {
    if (typeof value !== "number" || !Number.isFinite(value)) return null;
    const max = presentation === "embedded" ? EMBEDDED_HEIGHT_MAX : HEIGHT_MAX;
    return Math.min(Math.max(Math.ceil(value), HEIGHT_MIN), max);
  }

  // Only the card's own window may size it, and only for its own id.
  function heightFromMessage(data, expectedId, source, expectedSource, presentation) {
    if (!data || data.alasVisual !== true || data.id !== expectedId || source !== expectedSource) return null;
    return clampHeight(data.height, presentation);
  }

  // The source document is unloading because it navigated itself. Same trust rule as heightFromMessage.
  function navigationFromMessage(data, expectedId, source, expectedSource) {
    return !!data && data.alasVisual === true && data.id === expectedId && data.navigating === true &&
      !!expectedSource && source === expectedSource;
  }

  function toggleSelection(question, selected, optionId) {
    if (!question.options.some((o) => o.id === optionId)) return selected.slice();
    if (!question.allowMultiple) return [optionId];
    return selected.includes(optionId) ? selected.filter((id) => id !== optionId) : selected.concat(optionId);
  }

  // The Mac counts extended grapheme clusters (Swift String.count); UTF-16 length would disagree.
  const segmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
  // The gateway and the desktop card trim notes with Foundation's CharacterSet.whitespacesAndNewlines, by
  // scalar at both edges. JS trim() is a different set (it strips U+FEFF; it keeps U+0085 and U+200B), so
  // this class lists the Foundation set exactly. Enumerated over U+0000...U+10FFFF with swiftc on
  // macOS 26.7 (build 25G229): 0009-000D 0020 0085 00A0 1680 2000-200B 2028-2029 202F 205F 3000.
  const NOTE_EDGE = /^[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200B\u2028\u2029\u202F\u205F\u3000]+|[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200B\u2028\u2029\u202F\u205F\u3000]+$/g;
  function trimNote(text) { return String(text || "").replace(NOTE_EDGE, ""); }

  function noteLength(text) {
    const t = trimNote(text);
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
    const trimmed = trimNote(note);
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

  // How a card's send state moves when a row for it arrives. `submitted` means THIS phone sent an answer or
  // dismissal that has not been reported as failed. An answer clears the pending state but keeps `submitted`,
  // because the gateway can still roll the answer back; an unanswered row after that (or one that coalesced
  // the whole answer-and-rollback into a single delta) is a failed send. A phone that never submitted and
  // merely observed another client's answer and rollback shows no error.
  function nextCardState(card, incoming) {
    if (incoming.answer) return { pending: false, submitted: card.submitted === true, error: "" };
    if (card.submitted === true) return { pending: false, submitted: false, error: FAILED_TEXT };
    return { pending: card.pending === true, submitted: false, error: card.error || "" };
  }

  // Every link click is swallowed: any element with an href, whatever the scheme or fragment. The in-frame
  // script in bridgeScript applies the same rule inline.
  function shouldSwallowLinkClick(link) {
    return !!link && typeof link.getAttribute === "function" && link.getAttribute("href") !== null;
  }

  // A rejection is session-scoped, so every phone on a federated session receives it. Only the card that is
  // waiting on a reply (pending) belongs to this phone's request; anything else ignores it (null). The server
  // echoes the request's `requestId`: when the message carries one it must match the card's, so a rejection
  // meant for another phone's simultaneous answer never clears this phone's accepted send. A message without
  // an id (an older Mac) applies to the pending card, as before.
  function applyRejection(card, reason, requestId) {
    if (card.pending !== true) return null;
    if (typeof requestId === "string" && requestId !== card.requestId) return null;
    return { pending: false, submitted: false, error: rejectionText(reason) };
  }

  function newRequestId() {
    if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID();
    return Math.random().toString(36).slice(2) + Date.now().toString(36);
  }

  // Drafts survive a transcript resync: a snapshot rebuilds every card from the server row, which would drop
  // what the user picked or typed. The stash holds only unanswered cards with something to keep, tagged with the
  // question's shape so a draft never applies to a different question.
  function questionShape(q) {
    return JSON.stringify([q.prompt, q.allowMultiple === true, q.options.map((o) => o.id)]);
  }
  function stashDraft(card) {
    const q = card.visual && card.visual.question;
    if (!q || card.visual.answer) return null;
    const selected = card.selected || [];
    const note = card.note || "";
    if (selected.length === 0 && note === "") return null;
    return { selected: selected.slice(), note, shape: questionShape(q) };
  }
  // Returns {selected, note} filtered against the question, or null when the draft no longer applies.
  function restoreDraft(visual, draft) {
    const q = visual && visual.question;
    if (!q || visual.answer || !draft || draft.shape !== questionShape(q)) return null;
    const known = new Set(q.options.map((o) => o.id));
    let selected = [...new Set((draft.selected || []).filter((id) => known.has(id)))];
    if (!q.allowMultiple) selected = selected.slice(0, 1);
    const note = typeof draft.note === "string" ? draft.note : "";
    return selected.length === 0 && note === "" ? null : { selected, note };
  }

  // `submitted` (this phone sent an answer that may still be rolled back) survives a snapshot rebuild only
  // when the rebuilt row is answered: a later rollback must still report the failed send. An unanswered
  // row means the snapshot already shows the outcome, so the card starts idle and re-answerable.
  function restoreSubmitted(visual, stashedSubmitted) {
    return stashedSubmitted === true && !!visual && !!visual.answer;
  }

  // A srcdoc iframe fires `load` once for its own document, so any further load means the page navigated the
  // frame itself (scripted navigation cannot be stopped by cancelling click defaults). Calls onNavigated once.
  function guardFrameNavigation(frame, onNavigated) {
    let loads = 0;
    const listener = () => {
      loads += 1;
      if (loads < 2) return;
      frame.removeEventListener("load", listener);
      onNavigated();
    };
    frame.addEventListener("load", listener);
  }

  // A frame the budget evicted ("paused") comes back only through an explicit tap; otherwise it would
  // evict a sibling that the observer remounts in turn.
  function shouldMount(card, isIntersecting) {
    return isIntersecting === true && !card.frame && card.paused !== true && card.blocked !== true;
  }

  globalThis.RemoteVisualAid = {
    CSP, SANDBOX, HEIGHT_MIN, HEIGHT_MAX, EMBEDDED_HEIGHT_MAX, NOTE_MAX, MAX_LIVE_FRAMES, FAILED_TEXT, BLOCKED_TEXT, FRAME_CSS,
    isFullDocument, presentationOf, buildDocument, parseVisual, clampHeight, heightFromMessage, toggleSelection, noteLength, canSubmit,
    buildResponse, answerView, rejectionText, admitFrame, touchFrame, releaseFrame, nextCardState, shouldMount, trimNote, guardFrameNavigation, stashDraft, restoreDraft, restoreSubmitted,
    shouldSwallowLinkClick, applyRejection, newRequestId, navigationFromMessage,
  };
})();
