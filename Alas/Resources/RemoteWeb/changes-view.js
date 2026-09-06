// Pure logic for the Changes tab: ordering, labels, and the diff row model.
// DOM wiring lives in app.js; everything here is unit-tested under
// scripts/tests/remote-web-changes.

function sortFiles(files) {
  return (files || []).slice().sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function splitPath(path) {
  const value = path || "";
  const index = value.lastIndexOf("/");
  if (index < 0) return { dir: "", name: value };
  return { dir: value.slice(0, index + 1), name: value.slice(index + 1) };
}

function formatFileCounts(file) {
  const add = file && file.add ? file.add : 0;
  const del = file && file.del ? file.del : 0;
  return "+" + add + " −" + del;
}

function formatSummary(state) {
  const files = (state && state.files) || [];
  let add = 0;
  let del = 0;
  for (const file of files) {
    add += file.add || 0;
    del += file.del || 0;
  }
  const count = files.length + (files.length === 1 ? " file" : " files");
  const totals = count + " · +" + add + " −" + del;
  const ref = state && state.comparisonRef;
  return ref ? "vs " + ref + " · " + totals : totals;
}

function diffRows(hunks) {
  const rows = [];
  for (const hunk of hunks || []) {
    rows.push({ type: "hunk", text: hunk.header, kind: null, oldNumber: null, newNumber: null });
    for (const line of hunk.lines || []) {
      rows.push({
        type: "line",
        text: line.text,
        kind: line.kind,
        oldNumber: typeof line.oldNumber === "number" ? line.oldNumber : null,
        newNumber: typeof line.newNumber === "number" ? line.newNumber : null
      });
    }
  }
  return rows;
}

function truncationNotice(truncated, kind) {
  if (!truncated) return "";
  if (kind === "files") return "File list truncated — too many changed files to show.";
  return "Diff truncated — open this file on the desktop to see the rest.";
}

globalThis.RemoteChangesView = {
  sortFiles,
  splitPath,
  formatSummary,
  formatFileCounts,
  diffRows,
  truncationNotice
};
