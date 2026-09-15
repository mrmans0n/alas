import Dispatch
import Foundation
import GhosttyKit
import Testing
@testable import Alas

private final class GhosttyRuntimeConfigBox: @unchecked Sendable {
    let value: ghostty_runtime_config_s

    init(_ value: ghostty_runtime_config_s) {
        self.value = value
    }
}

@Suite
struct AlasGhosttyRuntimeCallbackTests {
    @Test func mainThreadBridgeRunsOnMainFromBackground() async {
        let ranOnMain = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: alasGhosttyOnMain {
                    Thread.isMainThread
                })
            }
        }

        #expect(ranOnMain)
    }

    @Test func runtimeCallbacksCanRunOffMainActor() async {
        let config = GhosttyRuntimeConfigBox(makeAlasGhosttyRuntimeConfig(userdata: nil))

        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                config.value.wakeup_cb(nil)

                var target = ghostty_target_s()
                target.tag = GHOSTTY_TARGET_APP
                var action = ghostty_action_s()
                action.tag = GHOSTTY_ACTION_CELL_SIZE
                let handled = config.value.action_cb(nil, target, action)

                let readStarted = config.value.read_clipboard_cb(
                    nil,
                    GHOSTTY_CLIPBOARD_SELECTION,
                    nil
                )
                config.value.confirm_read_clipboard_cb(nil, nil, nil, GHOSTTY_CLIPBOARD_REQUEST_PASTE)
                config.value.write_clipboard_cb(nil, GHOSTTY_CLIPBOARD_SELECTION, nil, 0, false)
                config.value.close_surface_cb(nil, false)

                continuation.resume(returning: (handled, readStarted))
            }
        }

        #expect(result.0)
        #expect(!result.1)
    }
}
