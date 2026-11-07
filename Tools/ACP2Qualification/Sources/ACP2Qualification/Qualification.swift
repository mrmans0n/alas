import AlasCore
import Foundation

enum QualificationMode: String, Sendable {
    case allowOnce = "allow-once"
    case cancel
}

enum QualificationDecisionPolicy {
    enum Refusal: String { case classification, subject, input, command, cwd, locations, options }
    struct Assessment {
        let optionID: String?
        let refusal: Refusal?
        static func refuse(_ reason: Refusal) -> Self { .init(optionID: nil, refusal: reason) }
    }

    static func selectOption(in request: ACPV2InteractiveRequest, expectedCommand: String,
        directory: URL, mode: QualificationMode) -> String? {
        guard mode == .allowOnce else { return nil }
        return assess(in: request, expectedCommand: expectedCommand, directory: directory).optionID
    }

    static func assess(in request: ACPV2InteractiveRequest, expectedCommand: String, directory: URL) -> Assessment {
        guard case .permission(let permission) = request.classification else { return .refuse(.classification) }
        guard let subject = permission.subject, case .toolCall = subject.kind,
              case .object(let fields) = subject.rawValue,
              case .object(let tool)? = fields["toolCall"], tool["kind"] == .string("execute") else { return .refuse(.subject) }
        guard case .object(let input)? = tool["rawInput"],
              Set(input.keys).isSubset(of: ["command", "cwd", "description"]) else { return .refuse(.input) }
        guard case .string(let command)? = input["command"],
              command.utf8.elementsEqual(expectedCommand.utf8) else { return .refuse(.command) }
        if let cwd = input["cwd"] {
            guard case .string(let path) = cwd, path.hasPrefix("/") else { return .refuse(.cwd) }
            let requested = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            let expected = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard requested.utf8.elementsEqual(expected.utf8) else { return .refuse(.cwd) }
        }
        if let locations = tool["locations"] {
            guard case .array(let values) = locations else { return .refuse(.locations) }
            let target = directory.appendingPathComponent("permission-probe.txt").standardizedFileURL
            for value in values {
                guard case .object(let location) = value, case .string(let path)? = location["path"],
                      path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL == target else { return .refuse(.locations) }
            }
        }
        let offered = permission.options.filter { $0.kind == "allow_once" }
        guard offered.count == 1 else { return .refuse(.options) }
        return .init(optionID: offered[0].optionID, refusal: nil)
    }
}

enum QualificationIdentity {
    static func packageDigest(at directory: URL) throws -> String {
        try ACPLaunchContentIdentity.packageDigest(at: directory)
    }
    static func fileDigest(_ file: URL) throws -> String {
        try ACPLaunchContentIdentity.fileDigest(file)
    }
}
