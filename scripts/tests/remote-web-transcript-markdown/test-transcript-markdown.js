const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/transcript-markdown.js");

const tm = globalThis.RemoteTranscriptMarkdown;

// --- alerts -------------------------------------------------------------------

assert.deepEqual(tm.alertMarker("[!NOTE]"), { kind: "note", title: "Note", rest: "" });
assert.deepEqual(tm.alertMarker("[!warning] Mind the gap"), { kind: "warning", title: "Warning", rest: "Mind the gap" });
assert.equal(tm.alertMarker("[!TODO] later"), null);
assert.equal(tm.alertMarker("Some text [!NOTE]"), null);

// --- fences -------------------------------------------------------------------

const types = (text) => tm.splitVisualFences(text).map((s) => s.type);

// Prose around a visual keeps its order; the title is the rest of the info string.
assert.deepEqual(tm.splitVisualFences("Before\n```visual Auth flow\n<svg/>\n```\nAfter"), [
  { type: "markdown", text: "Before" },
  { type: "visual", title: "Auth flow", html: "<svg/>" },
  { type: "markdown", text: "After" },
]);

// A streaming fence draws a label, never its raw body.
assert.deepEqual(tm.splitVisualFences("Intro\n```visual\n<div>"), [
  { type: "markdown", text: "Intro" },
  { type: "drawing", title: null },
]);

// Empty visuals, other languages, and fences inside other code blocks stay markdown.
assert.deepEqual(types("```visual\n\n```"), ["markdown"]);
assert.deepEqual(types("```html\n<svg/>\n```"), ["markdown"]);
assert.deepEqual(types("````md\n```visual\n<svg/>\n```\n````"), ["markdown"]);
// So does a visual inside a <details> section, which a split would tear open; after it closes, they draw again.
assert.deepEqual(types("<details>\n<summary>Log</summary>\n\n```visual\n<svg/>\n```\n\n</details>"), ["markdown"]);
assert.deepEqual(types("<details><summary>a</summary>b</details>\n```visual\n<svg/>\n```"), ["markdown", "visual"]);
assert.deepEqual(types("<details>\n\n</details>\n```visual\n<svg/>\n```"), ["markdown", "visual"]);

// A chart becomes an escaped <alas-chart>, titled by its label.
const [chart] = tm.splitVisualFences('```chart line unit=ms label="Build & test"\n{"labels":["a"],"values":[1]}\n```');
assert.equal(chart.type, "visual");
assert.equal(chart.title, "Build & test");
assert.equal(chart.html, '<alas-chart type="line" unit="ms" label="Build &amp; test" data="{&quot;labels&quot;:[&quot;a&quot;],&quot;values&quot;:[1]}"></alas-chart>');
assert.equal(tm.splitVisualFences('```chart\n{"values":[1]}\n```')[0].title, "Chart");

// Chart data the component would reject stays code.
for (const body of ['not json', '{"labels":["a"],"values":[1,2]}', '{"values":[1,true]}', '{"series":[]}', '[1,2]']) {
  assert.deepEqual(types("```chart\n" + body + "\n```"), ["markdown"], body);
}

// Reference definitions reach every prose segment around a visual; without a visual the text is untouched.
const linked = tm.splitVisualFences("See [the report][r].\n```visual\n<svg/>\n```\n[r]: https://example.com/report");
assert.equal(linked[0].text, "See [the report][r].\n\n[r]: https://example.com/report");
assert.equal(linked[2].text, "[r]: https://example.com/report\n\n[r]: https://example.com/report");
assert.deepEqual(tm.splitVisualFences("[a][r]\n\n[r]: https://x.y"), [{ type: "markdown", text: "[a][r]\n\n[r]: https://x.y" }]);
// A definition-looking line inside a code block is code, not a definition.
assert.equal(tm.splitVisualFences("```\n[r]: https://x.y\n```\n```visual\n<svg/>\n```")[0].text, "```\n[r]: https://x.y\n```");

// --- ids ----------------------------------------------------------------------

const id = tm.stableVisualId("row:0:<svg/>");
assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
assert.equal(tm.stableVisualId("row:0:<svg/>"), id);
assert.notEqual(tm.stableVisualId("row:1:<svg/>"), id);

console.log("transcript-markdown tests passed");
