import CoreGraphics
import Testing

@testable import Alas

@Suite("ACP transcript logical scroll model")
struct ACPTranscriptLogicalScrollModelTests {
    @Test("empty and viewport-sized histories are not scrollable")
    func nonScrollableHistories() {
        let empty = ACPTranscriptLogicalScrollModel.metrics(
            totalCount: 0,
            viewportHeight: 960,
            topGlobalIndex: 0,
            isAtTail: false
        )
        #expect(empty.value == 0)
        #expect(empty.knobProportion == 1)
        #expect(empty.logicalViewportMessages == 10)

        let short = ACPTranscriptLogicalScrollModel.metrics(
            totalCount: 5,
            viewportHeight: 960,
            topGlobalIndex: 3,
            isAtTail: false
        )
        #expect(short.value == 0)
        #expect(short.knobProportion == 1)
        #expect(ACPTranscriptLogicalScrollModel.targetGlobalIndex(
            value: 0.75,
            totalCount: 5,
            viewportHeight: 960
        ) == 0)
    }

    @Test("thumb metrics represent message-index progress")
    func messageIndexProgress() {
        let top = ACPTranscriptLogicalScrollModel.metrics(
            totalCount: 200,
            viewportHeight: 960,
            topGlobalIndex: 0,
            isAtTail: false
        )
        #expect(top.value == 0)
        #expect(top.knobProportion == 0.05)
        #expect(top.logicalViewportMessages == 10)

        let middle = ACPTranscriptLogicalScrollModel.metrics(
            totalCount: 200,
            viewportHeight: 960,
            topGlobalIndex: 95,
            isAtTail: false
        )
        #expect(middle.value == 0.5)
        #expect(middle.knobProportion == top.knobProportion)

        let tail = ACPTranscriptLogicalScrollModel.metrics(
            totalCount: 200,
            viewportHeight: 960,
            topGlobalIndex: 120,
            isAtTail: true
        )
        #expect(tail.value == 1)
        #expect(tail.knobProportion == top.knobProportion)
    }

    @Test("release values map to clamped global top indices")
    func releaseMapping() {
        #expect(ACPTranscriptLogicalScrollModel.targetGlobalIndex(
            value: -1,
            totalCount: 200,
            viewportHeight: 960
        ) == 0)
        #expect(ACPTranscriptLogicalScrollModel.targetGlobalIndex(
            value: 0.5,
            totalCount: 200,
            viewportHeight: 960
        ) == 95)
        #expect(ACPTranscriptLogicalScrollModel.targetGlobalIndex(
            value: 2,
            totalCount: 200,
            viewportHeight: 960
        ) == 190)
    }

    @Test("viewport resize and genuine count growth update only logical range")
    func rangeChanges() {
        let taller = ACPTranscriptLogicalScrollModel.metrics(
            totalCount: 200,
            viewportHeight: 1920,
            topGlobalIndex: 90,
            isAtTail: false
        )
        #expect(taller.logicalViewportMessages == 20)
        #expect(taller.knobProportion == 0.1)
        #expect(taller.value == 0.5)

        let grown = ACPTranscriptLogicalScrollModel.metrics(
            totalCount: 400,
            viewportHeight: 960,
            topGlobalIndex: 95,
            isAtTail: false
        )
        #expect(grown.logicalViewportMessages == 10)
        #expect(grown.knobProportion == 0.025)
        #expect(abs(grown.value - (95.0 / 390.0)) < 0.000_001)
    }
}
