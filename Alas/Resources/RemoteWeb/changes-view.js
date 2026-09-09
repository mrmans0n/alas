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

function changeSections(state) {
  const sections = [];
  const staged = sortFiles(state && state.staged);
  const unstaged = sortFiles(state && state.unstaged);
  const commits = (state && state.commits) || [];
  if (staged.length || unstaged.length) sections.push({ title: "Working Tree" });
  if (staged.length) sections.push({ title: "Staged", files: staged });
  if (unstaged.length) sections.push({ title: "Unstaged", files: unstaged });
  if (commits.length) sections.push({ title: "Commits", commits });
  return sections;
}

function formatSummary(state) {
  const staged = (state && state.staged) || [];
  const unstaged = (state && state.unstaged) || [];
  const files = staged.length || unstaged.length ? staged.concat(unstaged) : (state && state.files) || [];
  let add = 0;
  let del = 0;
  for (const file of files) {
    add += file.add || 0;
    del += file.del || 0;
  }
  const count = files.length + (files.length === 1 ? " file" : " files");
  const totals = count + " · +" + add + " −" + del;
  const ref = state && state.comparisonRef;
  const commitCount = ((state && state.commits) || []).length;
  const commits = commitCount ? " · " + commitCount + (commitCount === 1 ? " commit" : " commits") : "";
  return (ref ? "vs " + ref + " · " : "") + totals + commits;
}

function diffRows(hunks) {
  const rows = [];
  for (const hunk of hunks || []) {
    rows.push({ type: "hunk", text: hunk.header, kind: null, oldNumber: null, newNumber: null, noTrailingNewline: false });
    for (const line of hunk.lines || []) {
      rows.push({
        type: "line",
        text: line.text,
        kind: line.kind,
        oldNumber: typeof line.oldNumber === "number" ? line.oldNumber : null,
        newNumber: typeof line.newNumber === "number" ? line.newNumber : null,
        noTrailingNewline: !!line.noTrailingNewline
      });
    }
  }
  return rows;
}

function truncationNotice(truncated, kind) {
  if (!truncated) return "";
  if (kind === "files") return "File list truncated — too many changed files to show.";
  if (kind === "lines") return "File truncated — too many lines to show.";
  if (kind === "directory") return "Directory truncated — too many entries to show.";
  return "Diff truncated — open this file on the desktop to see the rest.";
}

// A pure rename/copy or executable-bit-only change has no `@@` hunks to
// render — an empty diff would look indistinguishable from "nothing
// changed", so the server sends `metadataNote` describing what actually
// happened (see `ParsedDiff.metadataSummary`). Only surfaced when there
// really are no hunks: a rename/mode change alongside real content edits
// already has hunks to show, and the note would just be noise there.
function metadataOnlyNotice(hunks, metadataNote) {
  if ((hunks || []).length > 0) return "";
  return metadataNote || "";
}

globalThis.RemoteChangesView = {
  sortFiles,
  splitPath,
  changeSections,
  formatSummary,
  formatFileCounts,
  diffRows,
  truncationNotice,
  metadataOnlyNotice
};
