import Foundation
import AlasFoundation
import AlasModel

public struct ACPTerminalExitStatus: Codable, Equatable, Sendable {
    public let exitCode: Int?
    public let signal: String?

    public init(exitCode: Int?, signal: String?) {
        self.exitCode = exitCode
        self.signal = signal
    }
}
