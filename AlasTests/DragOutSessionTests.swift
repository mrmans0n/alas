import AppKit
import Foundation
import Testing
@testable import Alas

struct DragOutSessionTests {
    @Test func typedPayloadsCanBeCopiedInsideTheApp() {
        #expect(DragOutSession.operationMask(
            for: .withinApplication,
            hasInternalPayload: true,
            hasExternalRepresentation: false
        ) == .copy)
    }

    @Test func externalOnlyFileDragsRemainRefusedInsideTheApp() {
        #expect(DragOutSession.operationMask(
            for: .withinApplication,
            hasInternalPayload: false,
            hasExternalRepresentation: true
        ) == [])
    }

    @Test func itemsWithPublicRepresentationsCanBeCopiedOutsideTheApp() {
        #expect(DragOutSession.operationMask(
            for: .outsideApplication,
            hasInternalPayload: true,
            hasExternalRepresentation: true
        ) == .copy)
    }

    @Test func internalOnlyItemsAreRefusedOutsideTheApp() {
        #expect(DragOutSession.operationMask(
            for: .outsideApplication,
            hasInternalPayload: true,
            hasExternalRepresentation: false
        ) == [])
    }

    @Test func pasteboardItemCarriesTheFileURLAndTypedPayload() throws {
        let url = URL(fileURLWithPath: "/tmp/alas drag/a b.txt")
        let payload = AlasDropPayload.file(relativePath: "a b.txt", absolutePath: url.path)
        let item = DragOutSession.pasteboardItem(for: DragOutPreparedItem(
            dropPayload: payload,
            fileURL: url,
            publicText: url.path
        ))

        #expect(item.string(forType: .fileURL) == url.absoluteString)
        let encoded = try #require(item.data(forType: .alasDropPayload))
        #expect(AlasDropPayload.decode(encoded) == payload)
    }

    @Test func pasteboardItemCarriesThePOSIXPathAsText() {
        let url = URL(fileURLWithPath: "/tmp/alas drag/a b.txt")
        let item = DragOutSession.pasteboardItem(for: DragOutPreparedItem(
            dropPayload: nil,
            fileURL: url,
            publicText: url.path
        ))
        #expect(item.string(forType: .string) == "/tmp/alas drag/a b.txt")
    }
}
