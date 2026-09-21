import Foundation
import Testing
@testable import Alas

@Suite("SQLiteError")
struct SQLiteErrorTests {
    @Test("step failure description omits the raw SQL text")
    func stepFailureDescriptionOmitsSQL() throws {
        let error = SQLiteError.stepFailed(
            code: 10,
            message: "disk I/O error",
            sql: "INSERT OR IGNORE INTO run_history (run_id, script_key) VALUES (?, ?)"
        )
        let description = try #require(error.errorDescription)
        #expect(description.contains("disk I/O error"))
        #expect(!description.contains("INSERT"))
        #expect(!description.contains("run_history"))
    }

    @Test("prepare failure description omits the raw SQL text")
    func prepareFailureDescriptionOmitsSQL() throws {
        let error = SQLiteError.prepareFailed(
            code: 1,
            message: "syntax error",
            sql: "SELECT * FROM run_history WHERE bogus"
        )
        let description = try #require(error.errorDescription)
        #expect(description.contains("syntax error"))
        #expect(!description.contains("SELECT"))
    }

    @Test("the full SQL remains available via reflection for diagnostic logging")
    func fullDetailStillAvailableForLogs() {
        let error = SQLiteError.stepFailed(
            code: 10,
            message: "disk I/O error",
            sql: "INSERT OR IGNORE INTO run_history (run_id) VALUES (?)"
        )
        #expect(String(describing: error).contains("run_history"))
    }
}
