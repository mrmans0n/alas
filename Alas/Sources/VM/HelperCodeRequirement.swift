import Foundation
import Security

/// The compiled designated requirement of a code bundle: the `csreq` blob a
/// TCC row needs so the grant matches that exact build of the helper.
enum HelperCodeRequirement {
    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "\(step) failed: \(message)"
        }
    }

    static func designatedRequirementData(of bundle: URL) throws -> Data {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Failure(step: "SecStaticCodeCreateWithPath", status: status) }

        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw Failure(step: "SecCodeCopyDesignatedRequirement", status: status)
        }

        var data: CFData?
        status = SecRequirementCopyData(requirement, [], &data)
        guard status == errSecSuccess, let data else { throw Failure(step: "SecRequirementCopyData", status: status) }
        return data as Data
    }
}
