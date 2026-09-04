import Foundation

#if canImport(FffC)
import FffC
#endif

/// Result shape returned by an optional indexed file-search backend.
/// SearchModel owns decoration with worktree/project ids and git status.
struct FileSearchBackendResult: Equatable, Sendable {
    let relativePath: String
    let score: Double
    let matchIndices: [Int]
}

/// Optional bridge to fff's Rust-backed C API.
///
/// The actor compiles without the vendored `FffC` module and returns `nil`,
/// which tells `SearchModel` to keep using the existing Swift file scorer.
/// Adding the bundled Rust library should only need to provide a `FffC`
/// module map plus the linked dynamic/static library; production wiring can
/// stay pointed at this actor.
actor FffFileSearchBackend {
#if canImport(FffC)
    private struct InstanceHandle: @unchecked Sendable {
        let raw: UnsafeMutableRawPointer
    }

    private var handles: [String: InstanceHandle] = [:]
#endif

    deinit {
#if canImport(FffC)
        for handle in handles.values {
            fff_destroy(handle.raw)
        }
#endif
    }

    func search(query: String, worktree: SearchWorktree, limit: Int) async throws -> [FileSearchBackendResult]? {
        // fff mmaps and watches the local filesystem, neither of which is
        // meaningful for an ssh-backed worktree. Returning nil selects the
        // existing host-aware git-ls-files fallback in SearchModel.
        if worktree.remoteHost != nil { return nil }
#if canImport(FffC)
        guard canSearchWithFff(query: query) else {
            return nil
        }
        let handle = try instance(for: worktree)
        guard isInitialScanReady(handle) else {
            return nil
        }
        guard let envelope = fff_search(handle, query, nil, 0, 0, UInt32(limit), 0, 0) else {
            return nil
        }
        defer { fff_free_result(envelope) }
        guard envelope.pointee.success, let rawSearchResult = envelope.pointee.handle else {
            return nil
        }

        let searchResult = rawSearchResult.assumingMemoryBound(to: FffSearchResult.self)
        defer { fff_free_search_result(searchResult) }

        let count = Int(searchResult.pointee.count)
        var results: [FileSearchBackendResult] = []
        results.reserveCapacity(count)

        for index in 0..<count {
            guard
                let item = fff_search_result_get_item(searchResult, UInt32(index)),
                let pathCString = fff_file_item_get_relative_path(item)
            else { continue }
            let relativePath = String(cString: pathCString)
            let scorePointer = fff_search_result_get_score(searchResult, UInt32(index))
            let score = scorePointer.map { Double($0.pointee.total) } ?? 0
            let matchIndices = FuzzyMatch.score(query: query, target: relativePath)?.indices ?? []
            results.append(FileSearchBackendResult(
                relativePath: relativePath,
                score: score,
                matchIndices: matchIndices
            ))
        }
        return results
#else
        _ = query
        _ = worktree
        _ = limit
        return nil
#endif
    }

#if canImport(FffC)
    private func instance(for worktree: SearchWorktree) throws -> UnsafeMutableRawPointer {
        let key = worktree.cacheKey
        if let handle = handles[key] {
            return handle.raw
        }

        let handle = try worktree.absolutePath.path.withCString { basePath in
            var options = FffCreateOptions(
                version: UInt32(FFF_CREATE_OPTIONS_VERSION),
                base_path: basePath,
                frecency_db_path: nil,
                history_db_path: nil,
                enable_mmap_cache: false,
                enable_content_indexing: false,
                watch: true,
                ai_mode: false,
                log_file_path: nil,
                log_level: nil,
                cache_budget_max_files: 0,
                cache_budget_max_bytes: 0,
                cache_budget_max_file_size: 0,
                enable_fs_root_scanning: false,
                enable_home_dir_scanning: false
            )
            guard let envelope = fff_create_instance_with(&options) else {
                throw FffFileSearchBackendError.createFailed(nil)
            }
            defer { fff_free_result(envelope) }
            guard envelope.pointee.success, let handle = envelope.pointee.handle else {
                let message = envelope.pointee.error.map { String(cString: $0) }
                throw FffFileSearchBackendError.createFailed(message)
            }
            return handle
        }
        handles[key] = InstanceHandle(raw: handle)
        return handle
    }

    private func isInitialScanReady(_ handle: UnsafeMutableRawPointer) -> Bool {
        guard let envelope = fff_wait_for_scan(handle, 0) else {
            return false
        }
        defer { fff_free_result(envelope) }
        return envelope.pointee.success && envelope.pointee.int_value != 0
    }

    private func canSearchWithFff(query: String) -> Bool {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .contains { $0.count >= 2 }
    }
#endif
}

enum FffFileSearchBackendError: Error, Equatable {
    case createFailed(String?)
}
