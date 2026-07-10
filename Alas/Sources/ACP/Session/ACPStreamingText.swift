import Foundation
import Combine

/// Reference-typed text buffer shared between an `ACPMessage` value and
/// the SwiftUI row rendering it. Appending streaming chunks mutates one
/// String in place (amortized O(1)) instead of rebuilding the enclosing
/// enum case + reassigning the @Published transcript array on every
/// chunk (which over the lifetime of a message is O(n²) in chars).
///
/// Equality is by reference identity: two `.agent(id, buf)` values that
/// share the same buffer compare equal even as the text grows, so the
/// transcript-array diff doesn't fire on streaming. The inner row view
/// observes the buffer directly via @ObservedObject and re-renders
/// when `value` changes.
@MainActor
final class StreamingText: ObservableObject {
    @Published private(set) var value: String
    private(set) var utf8Length: Int
    private(set) var revision: UInt64 = 0
    private(set) var lastAppendedSuffix: String?

    init(_ initial: String = "") {
        self.value = initial
        self.utf8Length = initial.utf8.count
    }

    func append(_ s: String) {
        value.append(s)
        utf8Length += s.utf8.count
        revision &+= 1
        lastAppendedSuffix = s
    }
}

extension StreamingText: Equatable {
    nonisolated static func == (lhs: StreamingText, rhs: StreamingText) -> Bool { lhs === rhs }
}
