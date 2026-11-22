// Pure helpers for agent markdown in the transcript: GitHub alerts, and the ```visual and ```chart
// fences the Mac and the phone draw inline. No DOM access, no mutable state — mirrors the shape of
// repo-filter.js. The rules follow MarkdownAlert, VisualFence and ChartSpec in AlasHighlight.

const ALERT_TITLES = { note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution" };

// The alert a blockquote opens with: { kind, title, rest } for a known "[!KIND]" marker at the start
// of its first line, else null. `rest` is the text after the marker on that line, which is kept.
function alertMarker(firstLine) {
  const line = String(firstLine || "");
  const match = /^\s*\[!([A-Za-z]+)\]/.exec(line);
  if (!match) return null;
  const kind = match[1].toLowerCase();
  if (!Object.prototype.hasOwnProperty.call(ALERT_TITLES, kind)) return null;
  return { kind, title: ALERT_TITLES[kind], rest: line.slice(match[0].length).trim() };
}

const VISUAL_TAG = "visual";
const CHART_TAG = "chart";
const CHART_TYPES = ["bar", "hbar", "line"];

function firstWord(info) {
  return String(info || "").trim().split(/\s+/)[0].toLowerCase();
}

function afterFirstWord(info) {
  return String(info || "").trim().replace(/^\S+\s*/, "");
}

// A bare chart type, and key=value or key="quoted value" pairs. Anything else is ignored.
function chartOptions(text) {
  const options = { type: null, attributes: {} };
  const pattern = /([^\s=]+)(?:=(?:"([^"]*)"?|(\S*)))?/g;
  let match;
  while ((match = pattern.exec(String(text || "")))) {
    const key = match[1].toLowerCase();
    if (match[2] === undefined && match[3] === undefined) {
      if (CHART_TYPES.includes(key)) options.type = key;
    } else {
      options.attributes[key] = match[2] !== undefined ? match[2] : match[3];
    }
  }
  return options;
}

// Whether `<alas-chart>` in frame.html draws this data rather than an error.
function chartDataIsValid(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) return false;
  let series = data.series;
  if (!series && Array.isArray(data.values)) series = [{ values: data.values }];
  if (!Array.isArray(series) || !series.length || !series[0] || !Array.isArray(series[0].values)) return false;
  const count = Array.isArray(data.labels) ? data.labels.length : series[0].values.length;
  return series.every((s) => s && Array.isArray(s.values) && s.values.length === count &&
    s.values.every((v) => typeof v === "number" && Number.isFinite(v)));
}

function escapeAttribute(value) {
  return String(value).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// A chart fence as the `<alas-chart>` its visual draws, or null when the component would reject the
// data, so the fence stays code.
function chartHTML(info, body) {
  let data;
  try { data = JSON.parse(body); } catch (_) { return null; }
  if (!chartDataIsValid(data)) return null;
  const options = chartOptions(afterFirstWord(info));
  const attributes = [["type", options.type || "bar"]];
  for (const key of ["unit", "height", "label"]) {
    if (options.attributes[key] !== undefined) attributes.push([key, options.attributes[key]]);
  }
  attributes.push(["data", String(body).trim()]);
  return "<alas-chart " + attributes.map(([k, v]) => k + '="' + escapeAttribute(v) + '"').join(" ") + "></alas-chart>";
}

const FENCE_OPEN = /^( {0,3})(`{3,}|~{3,})(.*)$/;
const REFERENCE_DEFINITION = /^ {0,3}\[[^\]]+\]:\s*\S/;

// Splits agent markdown at its top-level ```visual and ```chart fences. Returns segments in order:
//   { type: "markdown", text }  prose and every other fence, for the markdown renderer
//   { type: "visual", title, html }  a closed fence drawn as an embedded visual
//   { type: "drawing", title }  a visual or chart fence still streaming
// A fence whose body draws nothing (an empty visual, chart data the component rejects) stays markdown.
// Each markdown segment renders on its own, so when the text has a visual, every one of them also gets
// the text's link reference definitions: a [link][ref] before a visual keeps its definition after it.
function splitVisualFences(text) {
  const lines = String(text || "").split("\n");
  const segments = [];
  let prose = [];
  const flush = () => {
    if (prose.length) segments.push({ type: "markdown", text: prose.join("\n") });
    prose = [];
  };
  const definitions = [];
  let i = 0;
  while (i < lines.length) {
    const open = FENCE_OPEN.exec(lines[i]);
    // A backtick fence's info string cannot hold a backtick.
    if (!open || (open[2][0] === "`" && open[3].includes("`"))) {
      if (REFERENCE_DEFINITION.test(lines[i])) definitions.push(lines[i].trim());
      prose.push(lines[i]);
      i++;
      continue;
    }
    const marker = open[2];
    const close = new RegExp("^ {0,3}" + (marker[0] === "`" ? "`" : "~") + "{" + marker.length + ",}\\s*$");
    let end = i + 1;
    while (end < lines.length && !close.test(lines[end])) end++;
    const closed = end < lines.length;
    const tag = firstWord(open[3]);
    if (tag !== VISUAL_TAG && tag !== CHART_TAG) {
      prose.push(...lines.slice(i, closed ? end + 1 : lines.length));
      i = closed ? end + 1 : lines.length;
      continue;
    }
    const title = tag === CHART_TAG ? (chartOptions(afterFirstWord(open[3])).attributes.label || "Chart")
      : (afterFirstWord(open[3]) || null);
    if (!closed) {
      flush();
      segments.push({ type: "drawing", title });
      break;
    }
    const body = lines.slice(i + 1, end).join("\n");
    const html = tag === CHART_TAG ? chartHTML(open[3], body) : (body.trim() ? body : null);
    if (html) {
      flush();
      segments.push({ type: "visual", title, html });
    } else {
      prose.push(...lines.slice(i, end + 1));
    }
    i = end + 1;
  }
  flush();
  if (definitions.length && segments.some((segment) => segment.type !== "markdown")) {
    for (const segment of segments) {
      if (segment.type === "markdown") segment.text += "\n\n" + definitions.join("\n");
    }
  }
  return segments;
}

// A UUID-shaped id that stays the same for the same input, so re-rendering a message keeps its
// visual's frame. Four 32-bit FNV-1a hashes with different seeds.
function stableVisualId(key) {
  const source = String(key);
  const parts = [0x811c9dc5, 0x050c5d1f, 0x1b873593, 0x7feb352d].map((seed) => {
    let hash = seed >>> 0;
    for (let i = 0; i < source.length; i++) {
      hash ^= source.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    return hash.toString(16).padStart(8, "0");
  }).join("");
  return [parts.slice(0, 8), parts.slice(8, 12), parts.slice(12, 16), parts.slice(16, 20), parts.slice(20, 32)].join("-");
}

globalThis.RemoteTranscriptMarkdown = {
  alertMarker,
  chartOptions,
  chartDataIsValid,
  chartHTML,
  splitVisualFences,
  stableVisualId,
};
