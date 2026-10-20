import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public protocol NextPromptGenerating: Sendable {
    func generate(_ request: NextPromptRequest) async throws -> String?
    func cancel() async
    func cancelAndUnload() async
    func retryAfterFailure() async
}

extension NextPromptGenerating {
    public func cancel() async { await cancelAndUnload() }
}

public protocol NextPromptRuntime: NextPromptGenerating {
    var state: NextPromptInferenceState { get async }
    func states() async -> AsyncStream<NextPromptInferenceState>
}

public enum NextPromptInferenceState: Equatable, Sendable {
    case ready, running, unloading, unavailable, failed, retryRequired
}
