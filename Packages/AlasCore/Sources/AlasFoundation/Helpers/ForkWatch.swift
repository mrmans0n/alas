import Foundation

/// Calls back when a process forks (and, with `watchExit`, when it exits,
/// passing `true`), so process-tree trackers notice new
/// children before their next poll. Linux has no fork event source, so
/// there `start` returns nil and the trackers rely on polling alone.
public final class ForkWatch: @unchecked Sendable {
    #if canImport(Darwin)
    private let source: DispatchSourceProcess

    private init(source: DispatchSourceProcess) {
        self.source = source
    }
    #endif

    public static func start(
        pid: pid_t,
        watchExit: Bool = false,
        queue: DispatchQueue,
        handler: @escaping @Sendable (_ exited: Bool) -> Void
    ) -> ForkWatch? {
        #if canImport(Darwin)
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: watchExit ? [.fork, .exit] : .fork,
            queue: queue
        )
        source.setEventHandler { [unowned source] in handler(source.data.contains(.exit)) }
        return ForkWatch(source: source)
        #else
        return nil
        #endif
    }

    public func resume() {
        #if canImport(Darwin)
        source.resume()
        #endif
    }

    public func cancel() {
        #if canImport(Darwin)
        source.cancel()
        #endif
    }
}
