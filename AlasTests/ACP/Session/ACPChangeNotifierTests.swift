import Testing
import Foundation
@testable import Alas

@Suite struct ACPChangeNotifierTests {
    @Test("channel name is stable and notify-safe for a worktree id")
    func channelNameStable() {
        let a = DarwinChangeNotifier.channelName(worktreeId: "feature/long name with spaces")
        let b = DarwinChangeNotifier.channelName(worktreeId: "feature/long name with spaces")
        #expect(a == b)
        #expect(a.hasPrefix("io.alas.acp."))
        #expect(!a.contains(" "))
    }

    @Test("a posted ping invokes the registered observer")
    func postInvokesObserver() async throws {
        let notifier = DarwinChangeNotifier(worktreeId: "wt-\(UUID().uuidString)")
        var fired = 0
        let token = notifier.subscribe { fired += 1 }
        notifier.post()
        // Darwin notifications dispatch async on the registered queue.
        try await Task.sleep(nanoseconds: 300_000_000)
        notifier.unsubscribe(token)
        #expect(fired >= 1)
    }
}
