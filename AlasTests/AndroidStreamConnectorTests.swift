import Testing
@testable import Alas

struct AndroidStreamConnectorTests {
    struct Refused: Error {}

    @Test func itRetriesUntilTheServerAnswers() async throws {
        // adb refuses, then accepts and hangs up twice, then the server answers.
        var answers: [Result<Int?, Refused>] = [.failure(Refused()), .success(nil), .success(nil), .success(7)]
        let socket = try await AndroidStreamConnector.connect(pause: {}) { try answers.removeFirst().get() }
        #expect(socket == 7)
        #expect(answers.isEmpty)
    }

    @Test func itGivesUpWhenTheServerNeverAnswers() async {
        await #expect(throws: AndroidStreamError.serverDidNotStart) {
            try await AndroidStreamConnector.connect(attempts: 3, pause: {}) { nil as Int? }
        }
    }
}
