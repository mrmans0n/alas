import CryptoKit
import Darwin
import Foundation

actor NextPromptModelStore {
    private(set) var state: NextPromptModelState
    private let root: URL
    private let manifest: NextPromptModelManifest?
    private let transport: any NextPromptModelTransport
    private let capacity: @Sendable (Int32) throws -> Int64
    private var worker: Task<NextPromptModelState, Never>?
    private var installationID: UUID?
    private var observers: [UUID: AsyncStream<NextPromptModelState>.Continuation] = [:]

    init(root: URL = Paths.nextPromptModelsRoot, manifest: NextPromptModelManifest? = try? .bundled(),
         transport: any NextPromptModelTransport = NextPromptModelDownload(),
         capacity: @escaping @Sendable (Int32) throws -> Int64 = { try availableCapacity($0) }) {
        self.root = root
        self.manifest = manifest
        self.transport = transport
        self.capacity = capacity
        state = manifest == nil ? .unavailable : .notInstalled
    }

    func states() -> AsyncStream<NextPromptModelState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<NextPromptModelState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ value: NextPromptModelState) {
        state = value
        for continuation in observers.values { continuation.yield(value) }
    }
    private func progress(_ value: NextPromptModelState, id: UUID) {
        guard installationID == id else { return }
        if case .downloading(let received, _) = value {
            if case .verifying = state { return }
            if case .downloading(let previous, _) = state, received < previous { return }
        }
        publish(value)
    }

    func install() async {
        guard worker == nil else { return }
        guard let manifest else {
            publish(.unavailable)
            return
        }
        let id = UUID()
        installationID = id
        let task = Task.detached { [root, transport, capacity] in
            await Self.installRevision(root: root, manifest: manifest, transport: transport, capacity: capacity) { value in
                await self.progress(value, id: id)
            }
        }
        worker = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        finish(result, id: id)
    }

    func cancelDownload() async {
        guard let worker, let id = installationID else { return }
        worker.cancel()
        let result = await worker.value
        finish(result, id: id)
    }

    private func finish(_ result: NextPromptModelState, id: UUID) {
        guard installationID == id else { return }
        installationID = nil
        worker = nil
        publish(result)
    }

    func inspect() async {
        guard worker == nil else { return }
        publish(Self.inspectionState(root: root, manifest: manifest))
    }

    private static func inspectionState(root: URL, manifest: NextPromptModelManifest?) -> NextPromptModelState {
        do {
            let lease = try verifiedLease(root: root, manifest: manifest)
            lease.close()
            return .ready
        } catch let error as POSIXError where error.code == .ENOENT {
            return .notInstalled
        } catch {
            return manifest == nil ? .unavailable : .failed(.safe(error))
        }
    }

    func acquireVerifiedLease() async throws -> NextPromptModelLease {
        do { return try Self.verifiedLease(root: root, manifest: manifest) }
        catch let error as POSIXError where error.code == .ENOENT { throw NextPromptModelFailure.integrity }
        catch { throw NextPromptModelFailure.safe(error) }
    }

    private static func verifiedLease(root: URL, manifest: NextPromptModelManifest?) throws -> NextPromptModelLease {
        guard let manifest else { throw NextPromptModelFailure.invalidManifest }
        try manifest.validate()
        let directory = try NextPromptModelFiles.openRoot(root)
        defer { try? directory.close() }
        let lock = try NextPromptModelFiles.lock(root: directory.fileDescriptor, exclusive: false)
        do {
            let generation = try Self.verify(root: directory.fileDescriptor, name: manifest.revision, manifest: manifest)
            return NextPromptModelLease(directory: root.appendingPathComponent(manifest.revision), generation: generation, handle: lock)
        } catch {
            try? lock.close()
            if let error = error as? POSIXError, error.code == .ENOENT { throw error }
            throw NextPromptModelFailure.safe(error)
        }
    }

    func remove() async throws {
        guard worker == nil else { throw NextPromptModelFailure.busy }
        guard let manifest else { throw NextPromptModelFailure.invalidManifest }
        do {
            try manifest.validate()
            let directory = try NextPromptModelFiles.openRoot(root)
            defer { try? directory.close() }
            let lock = try NextPromptModelFiles.lock(root: directory.fileDescriptor, exclusive: true)
            defer { try? lock.close() }
            try NextPromptModelFiles.removeDirectory(parent: directory.fileDescriptor, name: manifest.revision)
            try Self.cleanStaging(root: directory.fileDescriptor, revision: manifest.revision)
            try NextPromptModelFiles.synchronize(directory.fileDescriptor)
            publish(.notInstalled)
        } catch { throw NextPromptModelFailure.safe(error) }
    }

    static func availableCapacity(_ descriptor: Int32) throws -> Int64 {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { throw NextPromptModelFiles.posix() }
        let capacity = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        return capacity.overflow ? Int64.max : Int64(clamping: capacity.partialValue)
    }

    private static func installRevision(root: URL, manifest: NextPromptModelManifest, transport: any NextPromptModelTransport,
                                        capacity: @Sendable (Int32) throws -> Int64,
                                        update: @escaping @Sendable (NextPromptModelState) async -> Void) async -> NextPromptModelState {
        do {
            try manifest.validate()
            try Task.checkCancellation()
            let directory = try NextPromptModelFiles.openRoot(root)
            defer { try? directory.close() }
            let fd = directory.fileDescriptor
            let lock = try NextPromptModelFiles.lock(root: fd, exclusive: true)
            defer { try? lock.close() }
            try cleanStaging(root: fd, revision: manifest.revision)
            do {
                _ = try verify(root: fd, name: manifest.revision, manifest: manifest)
                return .ready
            } catch let error as POSIXError where error.code == .ENOENT {
                // No published revision yet.
            } catch NextPromptModelFailure.integrity {
                // Keep the corrupt revision in place until its replacement is verified.
            }
            guard try capacity(fd) >= manifest.totalBytes + 64 * 1024 * 1024 else {
                throw NextPromptModelFailure.insufficientSpace
            }
            let stagingName = ".staging-\(manifest.revision)-\(UUID().uuidString)"
            guard mkdirat(fd, stagingName, 0o700) == 0 else { throw NextPromptModelFiles.posix() }
            defer { try? NextPromptModelFiles.removeDirectory(parent: fd, name: stagingName) }
            let staging = try NextPromptModelFiles.directory(parent: fd, name: stagingName)
            defer { try? staging.close() }
            var completed: Int64 = 0
            await update(.downloading(received: 0, expected: manifest.totalBytes))
            for asset in manifest.assets {
                try Task.checkCancellation()
                let file = try NextPromptModelFiles.regular(parent: staging.fileDescriptor, name: asset.path, create: true)
                defer { try? file.close() }
                let base = completed
                let sink = NextPromptModelSink(handle: file, asset: asset) { received in
                    Task { await update(.downloading(received: base + received, expected: manifest.totalBytes)) }
                }
                try await transport.download(manifest.url(for: asset), into: sink)
                try Task.checkCancellation()
                try sink.finish()
                completed += asset.bytes
            }
            await update(.verifying)
            _ = try verify(root: fd, name: stagingName, manifest: manifest)
            try Task.checkCancellation()
            try NextPromptModelFiles.synchronize(staging.fileDescriptor)
            var info = stat()
            let exists = fstatat(fd, manifest.revision, &info, AT_SYMLINK_NOFOLLOW) == 0
            if !exists, errno != ENOENT { throw NextPromptModelFiles.posix() }
            if exists {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw NextPromptModelFailure.invalidPath }
                guard renameatx_np(fd, stagingName, fd, manifest.revision, UInt32(RENAME_SWAP)) == 0 else {
                    throw NextPromptModelFiles.posix()
                }
            } else {
                guard renameatx_np(fd, stagingName, fd, manifest.revision, UInt32(RENAME_EXCL)) == 0 else {
                    throw NextPromptModelFiles.posix()
                }
            }
            try NextPromptModelFiles.synchronize(fd)
            return .ready
        } catch {
            guard error is CancellationError || Task.isCancelled else { return .failed(.safe(error)) }
            // Cleanup and transport drain have finished. Recheck retained files in a task
            // that cannot inherit the installation's cancellation and abort verification.
            return await Task.detached {
                inspectionState(root: root, manifest: manifest)
            }.value
        }
    }

    private static func cleanStaging(root: Int32, revision: String) throws {
        let prefix = ".staging-\(revision)-"
        for name in try NextPromptModelFiles.entries(root) where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            guard let id = UUID(uuidString: suffix), id.uuidString == suffix else { continue }
            try NextPromptModelFiles.removeDirectory(parent: root, name: name)
        }
    }

    private static func verify(root: Int32, name: String, manifest: NextPromptModelManifest) throws -> UInt64 {
        let directory = try NextPromptModelFiles.directory(parent: root, name: name)
        defer { try? directory.close() }
        guard Set(try NextPromptModelFiles.entries(directory.fileDescriptor)) == Set(manifest.assets.map(\.path)) else {
            throw NextPromptModelFailure.integrity
        }
        for asset in manifest.assets {
            try Task.checkCancellation()
            let file: FileHandle
            do { file = try NextPromptModelFiles.regular(parent: directory.fileDescriptor, name: asset.path) }
            catch let error as POSIXError where error.code == .ENOENT { throw NextPromptModelFailure.integrity }
            defer { try? file.close() }
            var info = stat()
            guard fstat(file.fileDescriptor, &info) == 0 else { throw NextPromptModelFiles.posix() }
            guard info.st_size == asset.bytes else { throw NextPromptModelFailure.integrity }
            var hash = SHA256()
            var received: Int64 = 0
            while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                guard Int64(chunk.count) <= asset.bytes - received else { throw NextPromptModelFailure.integrity }
                received += Int64(chunk.count)
                hash.update(data: chunk)
            }
            guard received == asset.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
                throw NextPromptModelFailure.integrity
            }
        }
        var info = stat()
        guard fstat(directory.fileDescriptor, &info) == 0 else { throw NextPromptModelFiles.posix() }
        return UInt64(info.st_ino)
    }
}
