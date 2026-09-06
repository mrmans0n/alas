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

console.log("remote-web-file-browser: ok");
