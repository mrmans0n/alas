import fs from "node:fs";
import path from "node:path";

export function packageDirFromInput(input, baseDir) {
  const segments = input.split("/");
  const nodeModules = segments.lastIndexOf("node_modules");
  if (nodeModules < 0 || !segments[nodeModules + 1]) return null;
  const packageEnd = segments[nodeModules + 1].startsWith("@")
    ? nodeModules + 3
    : nodeModules + 2;
  if (packageEnd > segments.length) return null;
  return path.resolve(baseDir, segments.slice(0, packageEnd).join("/"));
}

export function isNoticeFileName(name) {
  return /^(?:notices?|third[-_ ]party[-_ ]notices?)(?:[._-].*)?$/i.test(name);
}

export function licenseFileName(dir) {
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter(entry => entry.isFile() && /^licen[cs]e/i.test(entry.name))
    .map(entry => entry.name)
    .sort()[0];
}

export function noticeFileNames(dir) {
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter(entry => entry.isFile() && isNoticeFileName(entry.name))
    .map(entry => entry.name)
    .sort();
}
