// Bundles @pierre/diffs into Alas/Resources/RemoteWeb/diffs: diffs.js plus chunks it imports on
// demand (grammars, themes). The output is committed; CI rebuilds it and fails on any difference.
import * as esbuild from "esbuild";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bundleOptions } from "./bundle-options.mjs";
import { licenseFileName, noticeFileNames, packageDirFromInput } from "./legal-notices.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, "../../Alas/Resources/RemoteWeb/diffs");

fs.rmSync(out, { recursive: true, force: true });
const result = await esbuild.build(bundleOptions({ outdir: out }));

// One notices section for every package version that ended up in the bundle.
const packageDirs = new Set();
for (const output of Object.values(result.metafile.outputs)) {
  for (const input of Object.keys(output.inputs)) {
    const dir = packageDirFromInput(input, here);
    if (dir) packageDirs.add(dir);
  }
}
const packagesByVersion = new Map();
for (const dir of packageDirs) {
  const packageJSON = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  packagesByVersion.set(`${packageJSON.name}\0${packageJSON.version}`, { dir, ...packageJSON });
}
const notices = [...packagesByVersion.values()]
  .sort((a, b) => `${a.name}\0${a.version}`.localeCompare(`${b.name}\0${b.version}`))
  .map(({ dir, name, version, license }) => {
    const licenseFile = licenseFileName(dir);
    const licenseText = licenseFile
      ? fs.readFileSync(path.join(dir, licenseFile), "utf8").trim()
      : `License: ${license}`;
    const noticeTexts = noticeFileNames(dir)
      .sort()
      .map(file => `${file}\n\n${fs.readFileSync(path.join(dir, file), "utf8").trim()}`);
    return [`${name} ${version}`, licenseText, ...noticeTexts].join("\n\n");
  });
fs.writeFileSync(path.join(out, "LICENSES.txt"), notices.join("\n\n" + "-".repeat(72) + "\n\n") + "\n");
