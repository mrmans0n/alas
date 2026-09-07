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
    const id = key(path);
    const sorted = (nodes || []).slice().sort(nodeOrder);
    const previous = childrenByPath.get(id);
    childrenByPath.set(id, sorted);
    // A directory the agent deleted or renamed since the last listing no
    // longer appears here — forget it (and anything cached under it)
    // rather than leaving it in `expanded`/`childrenByPath` forever: a
    // refresh (`expandedPaths()`) would otherwise keep re-requesting a
    // path that no longer exists, failing every single time.
    if (previous) {
      const stillPresent = new Set(sorted.map(node => node.path));
      for (const child of previous) {
        if (child.kind === "dir" && !stillPresent.has(child.path)) {
          forgetSubtree(child.path);
        }
      }
    }
  }

  function forgetSubtree(path) {
    const id = key(path);
    expanded.delete(id);
    const children = childrenByPath.get(id);
    childrenByPath.delete(id);
    if (children) {
      for (const child of children) {
        if (child.kind === "dir") forgetSubtree(child.path);
      }
    }
  }

  function isExpanded(path) {
    return expanded.has(key(path));
  }

  function needsChildren(path) {
    return !childrenByPath.has(key(path));
  }

  /// Every expanded directory's path, root excluded (the caller re-requests
  /// root separately). Unlike `visibleRows()`, this includes a directory
  /// expanded behind a since-collapsed ancestor — collapsing a parent
  /// doesn't clear its descendants' own expanded state, so re-expanding the
  /// parent later reveals them again straight from cache with no request in
  /// between. A refresh that only walked `visibleRows()` would miss exactly
  /// that hidden-but-still-expanded subtree.
  function expandedPaths() {
    return Array.from(expanded).filter(path => path !== "");
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

  return { applyNodes, isExpanded, needsChildren, toggle, visibleRows, reset, expandedPaths };
}

globalThis.RemoteFileBrowser = { createTree };
