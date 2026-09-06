// Pure state for the lazy file tree in the Files tab. The server sends one
// directory's children at a time; this module remembers what has arrived, what
// is expanded, and flattens it into display rows. DOM wiring lives in app.js.

function nodeOrder(a, b) {
  if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1;
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

function createTree() {
  const childrenByPath = new Map();   // key: "" for root, else directory path
  const expanded = new Set();

  function key(path) {
    return path === null || path === undefined ? "" : path;
  }

  function applyNodes(path, nodes) {
    childrenByPath.set(key(path), (nodes || []).slice().sort(nodeOrder));
  }

  function isExpanded(path) {
    return expanded.has(key(path));
  }

  function needsChildren(path) {
    return !childrenByPath.has(key(path));
  }

  function toggle(path) {
    const id = key(path);
    if (expanded.has(id)) {
      expanded.delete(id);
      return false;
    }
    expanded.add(id);
    return needsChildren(path);
  }

  function collect(path, depth, rows) {
    const nodes = childrenByPath.get(key(path)) || [];
    for (const node of nodes) {
      const open = node.kind === "dir" && expanded.has(node.path);
      rows.push({ node, depth, expanded: open });
      if (open) collect(node.path, depth + 1, rows);
    }
  }

  function visibleRows() {
    const rows = [];
    collect(null, 0, rows);
    return rows;
  }

  function reset() {
    childrenByPath.clear();
    expanded.clear();
  }

  return { applyNodes, isExpanded, needsChildren, toggle, visibleRows, reset };
}

globalThis.RemoteFileBrowser = { createTree };
