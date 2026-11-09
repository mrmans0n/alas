import Foundation
import AlasPlatform

/// Finds platform packages npm skipped while installing an adapter.
///
/// The Claude and Codex adapters run a native binary shipped as an optional
/// dependency per platform (`@openai/codex-darwin-arm64`, about 300 MB). npm
/// only warns when an optional dependency fails to download and still exits
/// 0, so an install over a bad connection looks complete but cannot start.
///
/// The rule lives in one Node script so the local setup check, the SSH probes,
/// and the SSH staged install apply it the same way: every package in the
/// adapter's tree that declares an optional dependency for this OS and CPU
/// (name ending in `-<platform>-<arch>`, or followed by a libc variant such
/// as `-musl`) must have one of them installed where Node would resolve it.
public enum ACPAdapterPayloadCheck {
    /// Exit status of `script` when packages are missing. Any other non-zero
    /// status means the check itself could not run, which is not evidence of
    /// a broken install.
    public static let incompleteExitCode: Int32 = 3

    /// `node -e script <package directory>` prints the missing packages,
    /// comma-separated on one line, and exits `incompleteExitCode`.
    public static let script = #"""
    const fs = require('fs'), path = require('path');
    const suffix = '-' + process.platform + '-' + process.arch;
    const seen = new Set(), missing = new Set();
    const isPlatformPackage = (name) => name.endsWith(suffix) || name.includes(suffix + '-');
    function readManifest(dir) {
      try { return JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')); } catch (_) { return null; }
    }
    function resolvable(from, name) {
      for (let dir = from; ; dir = path.dirname(dir)) {
        if (fs.existsSync(path.join(dir, 'node_modules', name, 'package.json'))) return true;
        if (path.dirname(dir) === dir) return false;
      }
    }
    function children(dir) {
      try { return fs.readdirSync(dir).filter((name) => !name.startsWith('.')); } catch (_) { return []; }
    }
    function visit(dir) {
      let real;
      try { real = fs.realpathSync(dir); } catch (_) { return; }
      if (seen.has(real)) return;
      seen.add(real);
      const manifest = readManifest(dir);
      const candidates = Object.keys((manifest && manifest.optionalDependencies) || {}).filter(isPlatformPackage);
      if (candidates.length > 0 && !candidates.some((name) => resolvable(dir, name))) missing.add(candidates[0]);
      const modules = path.join(dir, 'node_modules');
      for (const entry of children(modules)) {
        if (entry.startsWith('@')) {
          for (const name of children(path.join(modules, entry))) visit(path.join(modules, entry, name));
        } else {
          visit(path.join(modules, entry));
        }
      }
    }
    visit(process.argv[1]);
    if (missing.size > 0) {
      process.stdout.write([...missing].sort().join(',') + '\n');
      process.exit(3);
    }
    """#

    /// Packages npm skipped under `packageDirectory`, or empty when the tree is
    /// complete or the check could not run.
    public static func missingPackages(
        packageDirectory: String,
        node: String,
        env: [String: String]
    ) async -> [String] {
        guard let result = try? await Process.run(node, args: ["-e", script, packageDirectory], env: env) else {
            return []
        }
        return missingPackages(exitCode: result.exitCode, stdout: result.stdout)
    }

    public static func missingPackages(exitCode: Int32, stdout: String) -> [String] {
        guard exitCode == incompleteExitCode else { return [] }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .map(String.init)
    }

    public static func incompleteReason(packageName: String, missing: [String], host: String? = nil) -> String {
        let location = host.map { " on \($0)" } ?? ""
        let packages = missing.map { "`\($0)`" }.joined(separator: ", ")
        return "`\(packageName)`\(location) is incomplete: npm did not install \(packages), "
            + "usually after an interrupted download. Reinstall the adapter to repair it."
    }
}
