import assert from "node:assert/strict";
import * as esbuild from "esbuild";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { bundleOptions } from "./bundle-options.mjs";
import * as unused from "./unused.js";

// Excluded backends must link successfully but never silently do work.
for (const name of ["codeToTokens", "registerLanguages", "createOnigurumaEngine"]) {
  assert.equal(typeof unused[name], "function", `${name} must be exported by the backend shim`);
  assert.throws(() => unused[name](), /Not bundled in the Alas web client/);
}
assert.throws(() => new unused.LiveTokenizer(), /Not bundled in the Alas web client/);

const here = path.dirname(fileURLToPath(import.meta.url));
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "alas-backends-"));
try {
  await esbuild.build({
    ...bundleOptions({ outdir: out }),
    entryPoints: undefined,
    stdin: {
      contents: 'export { createHighlighter, getSharedHighlighter, disposeHighlighter } from "@pierre/diffs";',
      resolveDir: here,
    },
    outExtension: { ".js": ".mjs" },
  });
  const { createHighlighter, getSharedHighlighter, disposeHighlighter } = await import(
    pathToFileURL(path.join(out, "stdin.mjs"))
  );
  try {
    const highlighter = await getSharedHighlighter({ langs: ["javascript"], themes: ["pierre-dark"] });
    assert.equal(highlighter.name, "shiki-js");
    const code = "const answer = 42;";
    const { tokens } = highlighter.codeToTokens(code, { lang: "javascript", theme: "pierre-dark" });
    assert.equal(tokens.flat().map(token => token.content).join(""), code);
    assert.ok(new Set(tokens.flat().map(token => token.color)).size > 1, "JavaScript must receive syntax highlighting");
  } finally {
    await disposeHighlighter();
  }
  await assert.rejects(createHighlighter("shiki-wasm"), /Not bundled in the Alas web client/);
} finally {
  fs.rmSync(out, { recursive: true, force: true });
}
console.log("remote web highlighter backends: ok");
