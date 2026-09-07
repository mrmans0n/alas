const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/file-browser.js");

const browser = globalThis.RemoteFileBrowser;

function dir(name, path) {
  return { name, path, kind: "dir", badge: null, childrenState: "notLoaded", isSubmodule: false };
}

function file(name, path, badge) {
  return { name, path, kind: "file", badge: badge || null, childrenState: "loaded", isSubmodule: false };
}

{
  const tree = browser.createTree();
  tree.applyNodes(null, [file("z.txt", "z.txt"), dir("src", "src")]);
  const rows = tree.visibleRows();
  assert.deepEqual(rows.map((r) => r.node.path), ["src", "z.txt"]);
  assert.deepEqual(rows.map((r) => r.depth), [0, 0]);
  assert.equal(rows[0].expanded, false);
}

{
  const tree = browser.createTree();
  tree.applyNodes(null, [dir("src", "src")]);
  assert.equal(tree.needsChildren("src"), true);
  assert.equal(tree.toggle("src"), true);
  assert.equal(tree.isExpanded("src"), true);

  tree.applyNodes("src", [file("main.swift", "src/main.swift", "M")]);
  assert.equal(tree.needsChildren("src"), false);

  const rows = tree.visibleRows();
  assert.deepEqual(rows.map((r) => r.node.path), ["src", "src/main.swift"]);
  assert.deepEqual(rows.map((r) => r.depth), [0, 1]);
  assert.equal(rows[1].node.badge, "M");

  assert.equal(tree.toggle("src"), false);
  assert.equal(tree.isExpanded("src"), false);
  assert.deepEqual(tree.visibleRows().map((r) => r.node.path), ["src"]);
}

{
  const tree = browser.createTree();
  tree.applyNodes(null, [dir("a", "a")]);
  tree.toggle("a");
  tree.applyNodes("a", [file("x.txt", "a/x.txt")]);
  tree.reset();
  assert.deepEqual(tree.visibleRows(), []);
  assert.equal(tree.isExpanded("a"), false);
}

{
  // expandedPaths() must survive a collapsed ancestor: expand a, then a/b,
  // then collapse a. `a/b` is no longer visible (its parent is collapsed)
  // but is still in the expanded set, so a refresh that walks
  // expandedPaths() (not visibleRows()) must still request it — otherwise
  // re-expanding "a" later would render "a/b" from stale cached children.
  const tree = browser.createTree();
  tree.applyNodes(null, [dir("a", "a")]);
  tree.toggle("a");
  tree.applyNodes("a", [dir("b", "a/b")]);
  tree.toggle("a/b");
  tree.applyNodes("a/b", [file("x.txt", "a/b/x.txt")]);
  assert.deepEqual(tree.expandedPaths().sort(), ["a", "a/b"]);

  tree.toggle("a");   // collapse a; a/b's OWN expanded state is untouched
  assert.deepEqual(tree.visibleRows().map((r) => r.node.path), ["a"]);
  assert.deepEqual(tree.expandedPaths().sort(), ["a/b"]);

  tree.toggle("a");   // re-expand a; a/b reappears, still expanded
  assert.deepEqual(
    tree.visibleRows().map((r) => r.node.path),
    ["a", "a/b", "a/b/x.txt"]
  );
}

{
  // Regression: an expanded directory deleted or renamed by the agent must
  // be forgotten (not just left in `expanded` forever) once a fresh
  // listing of its PARENT reveals it's gone — otherwise a refresh keeps
  // re-requesting a path that no longer exists, failing every time.
  const tree = browser.createTree();
  tree.applyNodes(null, [dir("a", "a"), dir("b", "b")]);
  tree.toggle("a");
  tree.applyNodes("a", [file("x.txt", "a/x.txt")]);
  tree.toggle("b");
  tree.applyNodes("b", [dir("c", "b/c")]);
  tree.toggle("b/c");
  tree.applyNodes("b/c", [file("y.txt", "b/c/y.txt")]);
  assert.deepEqual(tree.expandedPaths().sort(), ["a", "b", "b/c"]);

  // Root refresh: "a" is gone (deleted/renamed), "b" remains.
  tree.applyNodes(null, [dir("b", "b")]);
  assert.deepEqual(tree.expandedPaths().sort(), ["b", "b/c"]);
  assert.equal(tree.isExpanded("a"), false);
  assert.equal(tree.needsChildren("a"), true);   // forgotten, not just collapsed

  // "b" refresh: "b/c" is gone too — forgetting it recurses into anything
  // cached under it as well.
  tree.applyNodes("b", []);
  assert.deepEqual(tree.expandedPaths(), ["b"]);
  assert.equal(tree.needsChildren("b/c"), true);
}

console.log("remote-web-file-browser: ok");
