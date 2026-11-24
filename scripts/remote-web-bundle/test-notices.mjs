import assert from "node:assert/strict";
import * as esbuild from "esbuild";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { bundleOptions } from "./bundle-options.mjs";
import {
  isNoticeFileName,
  licenseFileName,
  noticeFileNames,
  packageDirFromInput,
} from "./legal-notices.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

assert.equal(
  packageDirFromInput("node_modules/plain-package/dist/index.js", here),
  path.join(here, "node_modules/plain-package"),
);
assert.equal(
  packageDirFromInput("node_modules/@scope/outer/node_modules/nested/lib/index.js", here),
  path.join(here, "node_modules/@scope/outer/node_modules/nested"),
);
assert.equal(packageDirFromInput("entry.js", here), null);

for (const file of [
  "NOTICE",
  "NOTICE.md",
  "NOTICE-third-party",
  "NOTICE_vendor.txt",
  "NOTICES",
  "NOTICES.txt",
  "THIRD-PARTY-NOTICE",
  "THIRD-PARTY-NOTICES.md",
  "THIRD_PARTY_NOTICE.txt",
]) {
  assert.equal(isNoticeFileName(file), true, `${file} must be treated as a legal notice`);
}
for (const file of ["noticeboard.md", "third-party.md", "LICENSE-NOTICE"]) {
  assert.equal(isNoticeFileName(file), false, `${file} must not be treated as a legal notice`);
}

const fixtureDir = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "alas-notices-"));
try {
  fs.mkdirSync(path.join(fixtureDir, "LICENSE"));
  fs.writeFileSync(path.join(fixtureDir, "LICENSE.txt"), "fixture license\n");
  fs.mkdirSync(path.join(fixtureDir, "NOTICE.md"));
  fs.writeFileSync(path.join(fixtureDir, "NOTICE.txt"), "fixture notice\n");
  assert.equal(licenseFileName(fixtureDir), "LICENSE.txt");
  assert.deepEqual(noticeFileNames(fixtureDir), ["NOTICE.txt"]);
} finally {
  fs.rmSync(fixtureDir, { recursive: true, force: true });
}

const licenses = fs.readFileSync(
  path.resolve(here, "../../Alas/Resources/RemoteWeb/diffs/LICENSES.txt"),
  "utf8",
);

const sections = licenses.split(`\n\n${"-".repeat(72)}\n\n`);
const audit = await esbuild.build(bundleOptions({
  outdir: path.join(here, ".notice-audit-output"),
  write: false,
}));
const expectedPackageVersions = new Set();
for (const output of Object.values(audit.metafile.outputs)) {
  for (const input of Object.keys(output.inputs)) {
    const dir = packageDirFromInput(input, here);
    if (!dir) continue;
    const packageJSON = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
    expectedPackageVersions.add(`${packageJSON.name} ${packageJSON.version}`);
  }
}
const actualPackageVersions = new Set(
  sections.map(section => section.slice(0, section.indexOf("\n"))),
);
assert.deepEqual(
  [...actualPackageVersions].sort(),
  [...expectedPackageVersions].sort(),
  "LICENSES.txt package versions must exactly match the esbuild input inventory",
);
const nestedPackageDir = path.join(
  here,
  "node_modules/@shikijs/core/node_modules/hast-util-to-html",
);
const nestedPackage = JSON.parse(
  fs.readFileSync(path.join(nestedPackageDir, "package.json"), "utf8"),
);
assert.ok(
  sections.some(section => section.startsWith(`${nestedPackage.name} ${nestedPackage.version}\n`)),
  `nested bundle package ${nestedPackage.name} ${nestedPackage.version} is missing from LICENSES.txt`,
);

const packageLock = JSON.parse(fs.readFileSync(path.join(here, "package-lock.json"), "utf8"));
const packageDirsByVersion = new Map();
for (const packagePath of Object.keys(packageLock.packages)) {
  if (!packagePath.includes("node_modules/")) continue;
  const dir = path.resolve(here, packagePath);
  const packageJSONPath = path.join(dir, "package.json");
  if (!fs.existsSync(packageJSONPath)) continue;
  const packageJSON = JSON.parse(fs.readFileSync(packageJSONPath, "utf8"));
  const key = `${packageJSON.name}\0${packageJSON.version}`;
  packageDirsByVersion.set(key, [...(packageDirsByVersion.get(key) ?? []), dir]);
}

let noticeCount = 0;
for (const section of sections) {
  const heading = section.slice(0, section.indexOf("\n"));
  const split = heading.lastIndexOf(" ");
  const name = heading.slice(0, split);
  const version = heading.slice(split + 1);
  const dirs = packageDirsByVersion.get(`${name}\0${version}`);
  assert.ok(dirs?.length, `${heading} is not an installed package version`);
  for (const dir of dirs) {
    for (const file of noticeFileNames(dir)) {
      noticeCount += 1;
      const notice = fs.readFileSync(path.join(dir, file), "utf8").trim();
      assert.ok(
        section.includes(`${file}\n\n${notice}`),
        `${file} from ${heading} is missing from LICENSES.txt`,
      );
    }
  }
}

assert.notEqual(noticeCount, 0, "the bundle must exercise at least one third-party notice");
console.log(`remote web third-party notices: ok (${noticeCount})`);
