import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public struct RunScriptCapturePaths: Equatable, Sendable {
    public let transcript: String
    public let completion: String

    public init(transcript: String, completion: String) {
        self.transcript = transcript
        self.completion = completion
    }
}
