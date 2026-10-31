import Foundation
import AlasACP
import AlasPlatform

public protocol ACPV2SubmissionPersisting: Sendable {
    func registerV2Submission(id: UUID, sessionId: String, upstreamSessionId: String, localRowID: UUID,
        binding: ACPV2SubmissionBinding, fence: ACPSessionLeaseFence) async throws -> ACPV2SubmissionRegistration
    func retainV2SubmissionOutcome(_ delivery: ACPRawRPCDelivery, for registration: ACPV2SubmissionRegistration,
        fence: ACPSessionLeaseFence) async throws -> ACPV2SubmissionReceipt
    func loadV2Submission(id: UUID) async throws -> ACPV2SubmissionRecord?
    func loadV2SubmissionPage(sessionId: String, upstreamSessionId: String, source: ACPV2SubmissionSource,
        after: ACPV2SubmissionContinuation?, maxRecords: Int, maxBytes: Int) async throws -> ACPV2SubmissionPage
}

extension ACPSessionPersistence: ACPV2SubmissionPersisting {}
