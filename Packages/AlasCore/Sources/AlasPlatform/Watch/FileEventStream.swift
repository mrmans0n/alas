import Foundation
#if canImport(CoreServices)
import CoreServices
#endif
import AlasFoundation

/// Reports batches of paths that changed under some roots, on `queue`:
/// FSEvents on macOS, recursive inotify on Linux. The handler gets nil when a
/// batch arrived but its paths couldn't be read, which callers treat as
/// "something changed". `stop()` is synchronous: once it returns, the handler
/// is not called again.
public final class FileEventStream: @unchecked Sendable {
    public typealias Handler = @Sendable (_ paths: [String]?) -> Void

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var stopped = false
    #if canImport(CoreServices)
    private var stream: FSEventStreamRef?
    #else
    private var inotify: InotifyTree?
    #endif

    /// `fileEvents` asks for per-file paths rather than per-directory ones
    /// where the platform makes the difference (FSEvents). `latency` is how
    /// long events coalesce into one batch. `recursive: false` watches only
    /// the roots' own entries where the platform makes the difference
    /// (inotify; FSEvents always covers the tree). Nil when no watch could be
    /// set up.
    public init?(
        paths: [String],
        fileEvents: Bool,
        latency: TimeInterval = 0.5,
        recursive: Bool = true,
        queue: DispatchQueue,
        handler: @escaping Handler
    ) {
        self.queue = queue
        queue.setSpecific(key: queueKey, value: ())
        #if canImport(CoreServices)
        guard let stream = Self.makeStream(paths: paths, fileEvents: fileEvents, latency: latency, handler: handler)
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        #else
        guard let tree = InotifyTree(roots: paths, latency: latency, recursive: recursive, queue: queue, handler: handler)
        else { return nil }
        inotify = tree
        #endif
    }

    deinit { stop() }

    public func stop() {
        let shouldStop = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard shouldStop else { return }
        let release = { [self] in
            #if canImport(CoreServices)
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            #else
            inotify?.close()
            inotify = nil
            #endif
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            release()
        } else {
            queue.sync(execute: release)
        }
        queue.setSpecific(key: queueKey, value: nil)
    }

    #if canImport(CoreServices)
    private final class HandlerBox {
        let handler: Handler

        init(_ handler: @escaping Handler) {
            self.handler = handler
        }
    }

    private static func makeStream(
        paths: [String],
        fileEvents: Bool,
        latency: TimeInterval,
        handler: @escaping Handler
    ) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(HandlerBox(handler)).toOpaque(),
            retain: nil,
            release: { @Sendable info in
                guard let info else { return }
                Unmanaged<HandlerBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { @Sendable _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<HandlerBox>.fromOpaque(info).takeUnretainedValue()
            // With `kFSEventStreamCreateFlagUseCFTypes`, `eventPaths` is a CFArray of CFString.
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let paths = array as? [String], paths.count == numEvents else {
                box.handler(nil)
                return
            }
            box.handler(paths)
        }
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        if fileEvents {
            flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Unmanaged<HandlerBox>.fromOpaque(context.info!).release()
            return nil
        }
        return stream
    }
    #endif
}

#if !canImport(CoreServices)
/// inotify watches one directory, not a tree, so this adds a watch for every
/// directory under the roots and for each new one as it appears. Used only
/// on `queue`.
// ponytail: one watch per directory, so a tree larger than the user's
// fs.inotify.max_user_watches is only partly watched (logged once); exclude
// heavy directories like node_modules if that bites.
private final class InotifyTree: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.nlopez.alas", category: "file-event-stream")
    private static let mask = UInt32(
        IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE
            | IN_DELETE_SELF | IN_MOVE_SELF
    )

    private let fd: Int32
    /// Each root as given and as resolved: a root may be a symlink, which
    /// inotify doesn't follow, and callers expect paths under the root they gave.
    private let roots: [(given: String, resolved: String)]
    private let latency: TimeInterval
    private let recursive: Bool
    private let queue: DispatchQueue
    private let handler: FileEventStream.Handler
    private var source: DispatchSourceRead?
    private var directories: [Int32: String] = [:]
    private var pending: [String] = []
    /// Events were dropped since the last batch: the next one is nil, "anything may have changed".
    private var overflowed = false
    private var flushScheduled = false
    private var warnedAboutLimit = false

    init?(
        roots: [String], latency: TimeInterval, recursive: Bool, queue: DispatchQueue,
        handler: @escaping FileEventStream.Handler
    ) {
        fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return nil }
        self.latency = latency
        self.recursive = recursive
        self.queue = queue
        self.handler = handler
        self.roots = roots.map { ($0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
        for root in self.roots {
            addTree(root.resolved)
        }
        guard !directories.isEmpty else {
            Foundation.close(fd)
            return nil
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in drain() }
        source.resume()
        self.source = source
    }

    func close() {
        source?.cancel()
        source = nil
        Foundation.close(fd)
    }

    private func addTree(_ root: String) {
        guard addWatch(root), recursive else { return }
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if !addWatch(url.path) {
                enumerator?.skipDescendants()
            }
        }
    }

    private func removeTree(_ path: String) {
        for (wd, directory) in directories where directory == path || directory.hasPrefix(path + "/") {
            inotify_rm_watch(fd, wd)
            directories[wd] = nil
        }
    }

    private func addWatch(_ path: String) -> Bool {
        let wd = inotify_add_watch(fd, path, Self.mask | UInt32(IN_ONLYDIR) | UInt32(IN_DONT_FOLLOW))
        guard wd >= 0 else {
            if errno == ENOSPC, !warnedAboutLimit {
                warnedAboutLimit = true
                Self.logger.error("inotify watch limit reached; changes under \(path, privacy: .public) and others go unseen")
            }
            return false
        }
        directories[wd] = path
        return true
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            var offset = 0
            while offset + MemoryLayout<inotify_event>.size <= count {
                let event = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: inotify_event.self) }
                let nameStart = offset + MemoryLayout<inotify_event>.size
                let nameBytes = buffer[nameStart ..< nameStart + Int(event.len)].prefix { $0 != 0 }
                offset = nameStart + Int(event.len)
                handle(event, name: String(decoding: nameBytes, as: UTF8.self))
            }
        }
        scheduleFlush()
    }

    private func handle(_ event: inotify_event, name: String) {
        if event.mask & UInt32(IN_Q_OVERFLOW) != 0 {
            // Events were dropped, directories created meanwhile among them: watch
            // the trees again, and tell callers anything may have changed.
            for root in roots {
                addTree(root.resolved)
            }
            overflowed = true
            return
        }
        guard let directory = directories[event.wd] else { return }
        if event.mask & UInt32(IN_IGNORED) != 0 {
            directories[event.wd] = nil
            return
        }
        let path = name.isEmpty ? directory : directory + "/" + name
        pending.append(path)
        // A folder moved away keeps its watches, which would follow it out of the
        // tree; drop them. A move within the tree adds them back at the new path.
        if event.mask & UInt32(IN_ISDIR) != 0, event.mask & UInt32(IN_MOVED_FROM) != 0 {
            removeTree(path)
        }
        let createdDirectory = event.mask & UInt32(IN_ISDIR) != 0
            && event.mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0
        if createdDirectory, recursive {
            addTree(path)
        }
    }

    /// `path` under the root as the caller gave it.
    private func given(_ path: String) -> String {
        for root in roots where root.given != root.resolved {
            if path == root.resolved { return root.given }
            if path.hasPrefix(root.resolved + "/") { return root.given + path.dropFirst(root.resolved.count) }
        }
        return path
    }

    private func scheduleFlush() {
        guard !pending.isEmpty || overflowed, !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self, source != nil else { return }
            flushScheduled = false
            let paths = pending.map(given)
            pending.removeAll()
            defer { overflowed = false }
            handler(overflowed ? nil : paths)
        }
    }
}
#endif
