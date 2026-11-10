import AppKit
import Testing
@testable import Alas

@Suite("ACP clipboard image watcher")
struct ACPClipboardImageWatcherTests {
    @Test(
        "offers bitmap data but not files, whose Finder icon also comes as TIFF",
        arguments: [
            ([NSPasteboard.PasteboardType.png], true),
            ([.tiff, .string], true),
            ([.fileURL, .tiff], false),
            ([.string], false),
        ]
    )
    func offersImage(types: [NSPasteboard.PasteboardType], expected: Bool) {
        #expect(ACPClipboardImageWatcher.offersImage(types: types) == expected)
    }
}
