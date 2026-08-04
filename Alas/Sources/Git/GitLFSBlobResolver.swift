import AppKit
import Foundation

enum GitLFSBlobResolver {
    static func image(fromGitBlobData data: Data, worktreePath: URL) async -> NSImage? {
        if let image = NSImage(data: data) {
            return image
        }
        guard let objectData = await lfsObjectData(forPointerData: data, worktreePath: worktreePath) else {
            return nil
        }
        return NSImage(data: objectData)
    }

    /// Resolves an LFS pointer's bytes to the real object data from the local
    /// LFS store, or nil when `data` is not a valid pointer, or when the
    /// object is not present locally (LFS files can be un-fetched).
    static func lfsObjectData(forPointerData data: Data, worktreePath: URL) async -> Data? {
        guard let pointer = parsePointer(data) else { return nil }
        guard let commonDir = await gitCommonDirectory(worktreePath: worktreePath) else { return nil }
        guard let storageDir = await lfsStorageDirectory(
            worktreePath: worktreePath,
            commonDir: commonDir
        ) else { return nil }

        let oid = pointer.oid
        let objectURL = storageDir
            .appendingPathComponent("objects")
            .appendingPathComponent(String(oid.prefix(2)))
            .appendingPathComponent(String(oid.dropFirst(2).prefix(2)))
            .appendingPathComponent(oid)
        guard let objectData = try? Data(contentsOf: objectURL) else { return nil }
        if let size = pointer.size, objectData.count != size {
            return nil
        }
        return objectData
    }

    private static func gitCommonDirectory(worktreePath: URL) async -> URL? {
        let result = try? await Process.git(
            ["rev-parse", "--git-common-dir"],
            cwd: worktreePath
        )
        guard let result, result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return worktreePath.appendingPathComponent(path)
    }

    private static func lfsStorageDirectory(worktreePath: URL, commonDir: URL) async -> URL? {
        let result = try? await Process.git(
            ["config", "--path", "--get", "lfs.storage"],
            cwd: worktreePath
        )
        guard let result, result.exitCode == 0 else {
            return commonDir.appendingPathComponent("lfs")
        }

        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return commonDir.appendingPathComponent("lfs") }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return commonDir.appendingPathComponent(path)
    }

    private static func parsePointer(_ data: Data) -> LFSPointer? {
        guard data.count <= 1024,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "version https://git-lfs.github.com/spec/v1" else {
            return nil
        }

        var oid: String?
        var size: Int?
        for line in lines.dropFirst() {
            if line.hasPrefix("oid sha256:") {
                oid = String(line.dropFirst("oid sha256:".count))
            } else if line.hasPrefix("size ") {
                size = Int(line.dropFirst("size ".count))
            }
        }

        guard let oid, oid.count == 64, oid.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return LFSPointer(oid: oid, size: size)
    }

    private struct LFSPointer {
        let oid: String
        let size: Int?
    }
}
