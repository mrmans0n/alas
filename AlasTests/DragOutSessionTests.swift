import AppKit
import Foundation
import Testing
@testable import Alas

struct DragOutSessionTests {
    @Test func dragsOutsideTheAppAreCopyOnly() {
        #expect(DragOutSession.operationMask(for: .outsideApplication) == .copy)
    }

    @Test func dragsInsideTheAppAreRefused() {
        #expect(DragOutSession.operationMask(for: .withinApplication) == [])
    }

    @Test func pasteboardItemCarriesTheFileURL() {
        let url = URL(fileURLWithPath: "/tmp/alas drag/a b.txt")
        let item = DragOutSession.pasteboardItem(for: url)
        #expect(item.string(forType: .fileURL) == url.absoluteString)
    }

    @Test func pasteboardItemCarriesThePOSIXPathAsText() {
        let url = URL(fileURLWithPath: "/tmp/alas drag/a b.txt")
        let item = DragOutSession.pasteboardItem(for: url)
        #expect(item.string(forType: .string) == "/tmp/alas drag/a b.txt")
    }
}
