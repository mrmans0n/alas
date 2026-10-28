import Foundation
import Testing
import AlasCore

struct ACPBrokerRestorePolicyTests {
    @Test func legacyAbsenceKeepsUnboundAndPreselectedNamespacesDistinct() throws {
        #expect(try ACPBrokerRestorePolicy.resolve(row: row(), supportedVersions: [.v1]) == nil)
        var saved = row()
        saved.acpBrokerId = "legacy"
        let restored = try #require(try ACPBrokerRestorePolicy.resolve(row: saved, supportedVersions: [.v1]))
        #expect(restored.brokerId.rawValue == "legacy")
        #expect(restored.generation == nil)
        #expect(restored.acknowledgedCursor.rawValue == 0)
        #expect(restored.wireContext == .legacyV1)
    }

    @Test(arguments: [false, true])
    func preferenceCannotReinterpretSavedRawContext(enabled: Bool) throws {
        var saved = boundRow()
        saved.acpBrokerWireContextJSON = try ACPBrokerWireContext.rawV2.persistedJSON()
        let selection = ACPProtocolSelection(experimentalV2Enabled: enabled)
        #expect(throws: ACPBrokerRestoreError.unsupported(context: .rawV2, storedJSON: saved.acpBrokerWireContextJSON)) {
            try ACPBrokerRestorePolicy.resolve(row: saved, supportedVersions: selection.supportedVersions)
        }
        let restored = try #require(try ACPBrokerRestorePolicy.resolve(row: saved, supportedVersions: [.v1, .v2]))
        #expect(restored.wireContext == .rawV2)
        #expect(restored.generation?.rawValue == 7)
        #expect(restored.acknowledgedCursor.rawValue == 4)
    }

    @Test(arguments: ["{broken", #"{"acpVersion":3,"payloadFormat":"future"}"#, "null"])
    func opaqueContextCannotBecomeLegacy(json: String) {
        var saved = boundRow()
        saved.acpBrokerWireContextJSON = json
        #expect(throws: ACPBrokerRestoreError.malformedContext(json)) {
            try ACPBrokerRestorePolicy.resolve(row: saved, supportedVersions: [.v1, .v2])
        }
        #expect(saved.acpBrokerWireContextJSON == json)
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func invalidDescriptorsCannotBecomeFreshLaunches(variant: Int) throws {
        var saved = boundRow()
        saved.acpBrokerWireContextJSON = try ACPBrokerWireContext.rawV2.persistedJSON()
        switch variant {
        case 0: saved.acpBrokerId = nil
        case 1: saved.acpBrokerGeneration = nil
        case 2: saved.acpBrokerGeneration = 0
        case 3: saved.acpBrokerGeneration = -1
        case 4: saved.acpBrokerAcknowledgedCursor = -1
        default: saved.acpBrokerId = "bad/id"
        }
        #expect(throws: ACPBrokerRestoreError.invalidDescriptor(contextJSON: saved.acpBrokerWireContextJSON)) {
            try ACPBrokerRestorePolicy.resolve(row: saved, supportedVersions: [.v1, .v2])
        }
    }

    private func row() -> ACPSessionRow {
        .init(id: "s", agentId: "fixture", title: "Saved", currentModel: nil, currentMode: nil,
            autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false)
    }
    private func boundRow() -> ACPSessionRow {
        var saved = row()
        saved.acpBrokerId = "broker"
        saved.acpBrokerGeneration = 7
        saved.acpBrokerAcknowledgedCursor = 4
        return saved
    }
}
