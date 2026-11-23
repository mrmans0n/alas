// Bundles @pierre/diffs into Alas/Resources/RemoteWeb/diffs: diffs.js plus chunks it imports on
// demand (grammars, themes). The output is committed; CI rebuilds it and fails on any difference.
import * as esbuild from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, "../../Alas/Resources/RemoteWeb/diffs");
const local = file => () => ({ path: path.join(here, file) });

fs.rmSync(out, { recursive: true, force: true });
const result = await esbuild.build({
  absWorkingDir: here,
  entryPoints: { diffs: "entry.js" },
  bundle: true, format: "esm", splitting: true, minify: true, target: "es2022",
  legalComments: "none", metafile: true, logLevel: "warning", outdir: out,
  plugins: [{
    name: "trim",
    setup(build) {
      build.onResolve({ filter: /^shiki\/langs$/ }, local("langs.js"));
      build.onResolve({ filter: /^@pierre\/theming\/themes$/ }, local("themes.js"));
      build.onResolve({ filter: /^(@pierre\/highlights(\/.*)?|shiki\/wasm|shiki\/engine\/oniguruma)$/ }, local("unused.js"));
    },
  }],
});

// One notices file for every package that ended up in the bundle.
const packages = new Set();
for (const output of Object.values(result.metafile.outputs)) {
  for (const input of Object.keys(output.inputs)) {
    const match = input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)\//);
    if (match) packages.add(match[1]);
  }
}
const notices = [...packages].sort().map(name => {
  const dir = path.join(here, "node_modules", name);
  const { version, license } = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  const file = fs.readdirSync(dir).find(f => /^licen[cs]e/i.test(f));
  const text = file ? fs.readFileSync(path.join(dir, file), "utf8").trim() : `License: ${license}`;
  return `${name} ${version}\n\n${text}`;
});
fs.writeFileSync(path.join(out, "LICENSES.txt"), notices.join("\n\n" + "-".repeat(72) + "\n\n") + "\n");
