import Foundation
import CoreServices

final class WorktreeWatcher {
    var onChange: (() -> Void)?
    private let path: URL
    private var stream: FSEventStreamRef?
    private let debouncer = DebounceTimer(interval: 0.5)

    init(path: URL) {
        self.path = path
        self.debouncer.onFire = { [weak self] in
            self?.onChange?()
        }
    }

    func start() {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, ctx, _, _, _, _ in
            guard let ctx else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(ctx).takeUnretainedValue()
            watcher.debouncer.poke()
        }
        let paths = [path.path] as CFArray
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debouncer.cancel()
    }

    deinit { stop() }
}
