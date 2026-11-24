import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const local = file => () => ({ path: path.join(here, file) });

export function bundleOptions({ outdir, write = true }) {
  return {
    absWorkingDir: here,
    entryPoints: { diffs: "entry.js" },
    bundle: true,
    format: "esm",
    splitting: true,
    minify: true,
    target: "es2022",
    legalComments: "none",
    metafile: true,
    logLevel: "warning",
    outdir,
    write,
    plugins: [{
      name: "trim",
      setup(build) {
        build.onResolve({ filter: /^shiki\/langs$/ }, local("langs.js"));
        build.onResolve({ filter: /^@pierre\/theming\/themes$/ }, local("themes.js"));
        build.onResolve(
          { filter: /^(@pierre\/highlights(\/.*)?|shiki\/wasm|shiki\/engine\/oniguruma)$/ },
          local("unused.js"),
        );
      },
    }],
  };
}
