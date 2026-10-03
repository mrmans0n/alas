import Darwin
import Foundation

/// `files.read` and `files.write`: plugin paths resolved inside one worktree.
enum PluginFiles {
    /// Half the 1 MiB message limit, like `PluginHTTP.maxBodyBytes`, so a file's content, JSON-escaped, still fits
    /// in the reply as a rule. A reply that still does not fit is refused like any other.
    static let maxFileBytes = 512 << 10
    static let maxListEntries = 2000
    /// A folder past this many names lists a sorted sample of the first ones read.
    static let maxListRead = 20000

    /// Where `path`, relative to `root`, really leads, or why it may not be used. Refuses absolute paths, `..`,
    /// anything that resolves outside `root`, through symlinks too, and anything with a component named `.git`,
    /// compared case-folded on the resolved path: in a linked worktree `.git` points git at the repository.
    /// Parts of the path that do not exist yet are kept as written. An empty path or `.` is `root` itself.
    /// ponytail: resolved once, then used; a symlink swapped in between is followed. Open with O_NOFOLLOW per
    /// component if plugins ever race the user.
    static func resolve(_ path: String, in root: URL) -> Result<URL, PluginFilesError> {
        guard !path.hasPrefix("/") else { return .failure(.refused("\(path) is not relative")) }
        let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !components.contains("..") else { return .failure(.refused("\(path) uses ..")) }
        guard let realRoot = realPath(root.path) else { return .failure(.notFound("the worktree")) }
        var current = realRoot
        for (index, component) in components.enumerated() {
            let candidate = current + "/" + component
            var info = stat()
            guard lstat(candidate, &info) == 0 else {
                // Not there yet: the rest is kept as written.
                current = ([candidate] + components[(index + 1)...]).joined(separator: "/")
                break
            }
            // A symlink that leads nowhere, or in circles, is refused: writing through it would land wherever it points.
            guard let real = realPath(candidate) else { return .failure(.refused("\(path) has a broken symlink")) }
            current = real
        }
        guard current == realRoot || current.hasPrefix(realRoot + "/") else {
            return .failure(.refused("\(path) leaves the worktree"))
        }
        let inside = current.dropFirst(realRoot.count).split(separator: "/")
        guard !inside.contains(where: { $0.lowercased() == ".git" }) else {
            return .failure(.refused("\(path) is inside .git"))
        }
        return .success(URL(fileURLWithPath: current))
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func read(_ path: String, in root: URL) -> Result<String, PluginFilesError> {
        resolve(path, in: root).flatMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { return .failure(.notFound(path)) }
            guard (values.fileSize ?? 0) <= maxFileBytes else { return .failure(.refused("\(path) is larger than 512 KiB")) }
            guard let data = try? Data(contentsOf: url) else { return .failure(.notFound(path)) }
            guard let text = String(data: data, encoding: .utf8) else { return .failure(.refused("\(path) is not UTF-8 text")) }
            return .success(text)
        }
    }

    static func list(_ dir: String, in root: URL, readLimit: Int = maxListRead) -> Result<PluginFileListResult, PluginFilesError> {
        resolve(dir, in: root).flatMap { url in
            guard let stream = opendir(url.path) else { return .failure(.notFound(dir.isEmpty ? "." : dir)) }
            defer { closedir(stream) }
            var names: [String] = []
            var unread = false
            while let entry = readdir(stream) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    FileManager.default.string(
                        withFileSystemRepresentation: bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                        length: Int(entry.pointee.d_namlen))
                }
                guard name != ".", name != "..", name.lowercased() != ".git" else { continue }
                guard names.count < readLimit else {
                    unread = true
                    break
                }
                names.append(name)
            }
            let visible = names.sorted()
            // Names that JSON-escape badly could still overflow the reply, so the list also stops at half the
            // message limit of encoded names.
            var budget = maxFileBytes
            let fitting = visible.prefix(maxListEntries).prefix { name in
                budget -= ((try? JSONEncoder().encode(name).count) ?? name.utf8.count * 6) + 32
                return budget >= 0
            }
            let entries = fitting.map { name in
                let type = (try? FileManager.default.attributesOfItem(atPath: url.appending(path: name).path))?[.type] as? FileAttributeType
                let kind = switch type {
                case .typeDirectory?: "directory"
                case .typeSymbolicLink?: "symlink"
                default: "file"
                }
                return PluginFileListResult.Entry(name: name, kind: kind)
            }
            return .success(PluginFileListResult(entries: Array(entries), truncated: unread || visible.count > entries.count))
        }
    }

    /// Creates missing folders on the way, all inside the worktree because the path resolved there.
    static func write(_ path: String, content: String, in root: URL) -> Result<Void, PluginFilesError> {
        guard content.utf8.count <= maxFileBytes else { return .failure(.refused("content is larger than 512 KiB")) }
        return resolve(path, in: root).flatMap { url in
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return .failure(.refused("\(path) is a folder"))
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: .atomic)
                return .success(())
            } catch {
                return .failure(.refused("could not write \(path): \(error.localizedDescription)"))
            }
        }
    }
}

enum PluginFilesError: Error, Equatable {
    case refused(String)
    case notFound(String)

    var message: String {
        switch self {
        case .refused(let reason): reason
        case .notFound(let what): "\(what) does not exist"
        }
    }
}

struct PluginFileParams: Decodable, Sendable {
    let worktree: String
    let path: String
}

struct PluginFileListParams: Decodable, Sendable {
    let worktree: String
    let dir: String?
}

struct PluginFileWriteParams: Decodable, Sendable {
    let worktree: String
    let path: String
    let content: String
}

struct PluginFileReadResult: Encodable, Equatable, Sendable {
    let content: String
}

struct PluginFileListResult: Encodable, Equatable, Sendable {
    struct Entry: Encodable, Equatable, Sendable {
        let name: String
        let kind: String
    }

    let entries: [Entry]
    let truncated: Bool
}
