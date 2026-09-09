import Foundation
import Testing
@testable import Alas

@Suite("ACPConfigOption")
struct ACPConfigOptionTests {
    @Test("decodes a select config option")
    func decodeSelect() throws {
        let json = """
        {
          "id": "effort",
          "name": "Effort",
          "type": "select",
          "category": "ThoughtLevel",
          "currentValue": "medium",
          "options": [
            { "id": "low", "name": "Low" },
            { "id": "medium", "name": "Medium" },
            { "id": "high", "name": "High", "description": "Use more reasoning" }
          ]
        }
        """.data(using: .utf8)!
        let opt = try JSONDecoder().decode(ACPConfigOption.self, from: json)
        #expect(opt.id == "effort")
        #expect(opt.name == "Effort")
        #expect(opt.type == "select")
        #expect(opt.category == "ThoughtLevel")
        #expect(opt.currentValue == .string("medium"))
        #expect(opt.options.count == 3)
        #expect(opt.options[2].description == "Use more reasoning")
    }

    @Test("option items decode the `value` wire key")
    func decodeOptionValueKey() throws {
        let json = """
        {
          "id": "effort",
          "name": "Effort",
          "type": "select",
          "currentValue": "high",
          "options": [
            { "value": "low", "name": "Low" },
            { "value": "high", "name": "High" }
          ]
        }
        """.data(using: .utf8)!
        let opt = try JSONDecoder().decode(ACPConfigOption.self, from: json)
        #expect(opt.options.count == 2)
        #expect(opt.options[0].id == "low")
        #expect(opt.options[1].id == "high")
    }

    @Test("non-select type decodes with empty options")
    func decodeUnknownType() throws {
        let json = """
        { "id": "x", "name": "X", "type": "text", "currentValue": "" }
        """.data(using: .utf8)!
        let opt = try JSONDecoder().decode(ACPConfigOption.self, from: json)
        #expect(opt.type == "text")
        #expect(opt.options.isEmpty)
    }

    @Test("boolean config option decodes a boolean current value")
    func decodeBooleanCurrentValue() throws {
        let json = """
        {
          "id": "fast-mode",
          "name": "Fast mode",
          "type": "boolean",
          "category": "model_config",
          "currentValue": true
        }
        """.data(using: .utf8)!

        let opt = try JSONDecoder().decode(ACPConfigOption.self, from: json)

        #expect(opt.type == "boolean")
        #expect(opt.currentValue == .boolean(true))
        #expect(opt.currentStringValue == nil)
        #expect(opt.currentBoolValue == true)
    }

    @Test("encodes setConfigOption params")
    func encodeSetParams() throws {
        let params = ACPSessionSetConfigOptionParams(
            sessionId: "s", configId: "effort", value: .string("high"))
        let data = try JSONEncoder().encode(params)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["sessionId"] as? String == "s")
        #expect(json["configId"] as? String == "effort")
        #expect(json["type"] as? String == "id")
        #expect(json["value"] as? String == "high")
    }

    @Test("encodes boolean setConfigOption params")
    func encodeBooleanSetParams() throws {
        let params = ACPSessionSetConfigOptionParams(
            sessionId: "s", configId: "fast-mode", value: .boolean(false))
        let data = try JSONEncoder().encode(params)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["sessionId"] as? String == "s")
        #expect(json["configId"] as? String == "fast-mode")
        #expect(json["type"] as? String == "boolean")
        #expect(json["value"] as? Bool == false)
    }

    @Test("successful set response preserves the selected config value")
    func mergeSuccessfulSetResponsePreservesSelectedValue() throws {
        let staleFast = ACPConfigOption(
            id: "fast", name: "Fast", type: "select", currentValue: "false",
            options: [
                ACPConfigOptionItem(id: "false", name: "Off"),
                ACPConfigOptionItem(id: "true", name: "On"),
            ])
        let refreshedContext = ACPConfigOption(
            id: "context", name: "Context", type: "select", currentValue: "1m",
            options: [
                ACPConfigOptionItem(id: "272k", name: "272k"),
                ACPConfigOptionItem(id: "1m", name: "1m"),
            ])
        let currentFast = ACPConfigOption(
            id: "fast", name: "Fast", type: "select", currentValue: "true",
            options: staleFast.options)

        let merged = try #require(ACPConfigOption.mergingSuccessfulSetResponse(
            [staleFast, refreshedContext],
            configId: "fast",
            selectedValue: .string("true"),
            currentConfigOptions: [currentFast, refreshedContext]))

        #expect(merged.map(\.id) == ["fast", "context"])
        #expect(merged.first(where: { $0.id == "fast" })?.currentValue == .string("true"))
        #expect(merged.first(where: { $0.id == "context" })?.currentValue == .string("1m"))
    }

    @Test("stale set response is ignored after a newer local selection")
    func staleSetResponseIsIgnoredAfterNewerSelection() {
        let oldResponse = ACPConfigOption(
            id: "fast", name: "Fast", type: "select", currentValue: "true",
            options: [
                ACPConfigOptionItem(id: "false", name: "Off"),
                ACPConfigOptionItem(id: "true", name: "On"),
            ])
        let currentFast = ACPConfigOption(
            id: "fast", name: "Fast", type: "select", currentValue: "false",
            options: oldResponse.options)

        let merged = ACPConfigOption.mergingSuccessfulSetResponse(
            [oldResponse],
            configId: "fast",
            selectedValue: .string("true"),
            currentConfigOptions: [currentFast])

        #expect(merged == nil)
    }

    @Test("successful set response preserves concurrently changed dependent value")
    func mergeSuccessfulSetResponsePreservesConcurrentlyChangedDependentValue() throws {
        let baselineFast = ACPConfigOption(
            id: "fast", name: "Fast", type: "select", currentValue: "true",
            options: [
                ACPConfigOptionItem(id: "false", name: "Off"),
                ACPConfigOptionItem(id: "true", name: "On"),
            ])
        let baselineEffort = ACPConfigOption(
            id: "effort", name: "Effort", type: "select", currentValue: "low",
            options: [
                ACPConfigOptionItem(id: "low", name: "Low"),
                ACPConfigOptionItem(id: "high", name: "High"),
            ])
        let staleEffort = ACPConfigOption(
            id: "effort", name: "Effort", type: "select", currentValue: "low",
            options: baselineEffort.options)
        let currentEffort = ACPConfigOption(
            id: "effort", name: "Effort", type: "select", currentValue: "high",
            options: baselineEffort.options)

        let merged = try #require(ACPConfigOption.mergingSuccessfulSetResponse(
            [baselineFast, staleEffort],
            configId: "fast",
            selectedValue: .string("true"),
            currentConfigOptions: [baselineFast, currentEffort],
            baselineConfigOptions: [baselineFast, baselineEffort]))

        #expect(merged.first(where: { $0.id == "effort" })?.currentValue == .string("high"))
    }

    @Test("successful set response preserves concurrently changed dependent metadata")
    func mergeSuccessfulSetResponsePreservesConcurrentlyChangedDependentMetadata() throws {
        let baselineFast = ACPConfigOption(
            id: "fast", name: "Fast", type: "select", currentValue: "true",
            options: [
                ACPConfigOptionItem(id: "false", name: "Off"),
                ACPConfigOptionItem(id: "true", name: "On"),
            ])
        let baselineEffort = ACPConfigOption(
            id: "effort", name: "Effort", type: "select", currentValue: "low",
            options: [
                ACPConfigOptionItem(id: "low", name: "Low"),
                ACPConfigOptionItem(id: "high", name: "High"),
            ])
        let staleEffort = ACPConfigOption(
            id: "effort", name: "Effort", type: "select", currentValue: "low",
            options: baselineEffort.options)
        let currentEffort = ACPConfigOption(
            id: "effort", name: "Effort", type: "select", currentValue: "low",
            options: [
                ACPConfigOptionItem(id: "low", name: "Low"),
                ACPConfigOptionItem(id: "medium", name: "Medium"),
                ACPConfigOptionItem(id: "high", name: "High"),
            ])

        let merged = try #require(ACPConfigOption.mergingSuccessfulSetResponse(
            [baselineFast, staleEffort],
            configId: "fast",
            selectedValue: .string("true"),
            currentConfigOptions: [baselineFast, currentEffort],
            baselineConfigOptions: [baselineFast, baselineEffort]))

        let effort = try #require(merged.first(where: { $0.id == "effort" }))
        #expect(effort.options.map(\.id) == ["low", "medium", "high"])
    }

    @Test("successful set response preserves concurrent option membership changes")
    func mergeSuccessfulSetResponsePreservesConcurrentOptionMembershipChanges() throws {
        let fast = ACPConfigOption(
            id: "fast", name: "Fast", type: "select", currentValue: "true",
            options: [
                ACPConfigOptionItem(id: "false", name: "Off"),
                ACPConfigOptionItem(id: "true", name: "On"),
            ])
        let removed = ACPConfigOption(
            id: "removed", name: "Removed", type: "select", currentValue: "old")
        let added = ACPConfigOption(
            id: "added", name: "Added", type: "select", currentValue: "new")

        let merged = try #require(ACPConfigOption.mergingSuccessfulSetResponse(
            [fast, removed],
            configId: "fast",
            selectedValue: .string("true"),
            currentConfigOptions: [fast, added],
            baselineConfigOptions: [fast, removed]))

        #expect(merged.map(\.id) == ["fast", "added"])
    }

    @Test("successful boolean set response preserves the selected config value")
    func mergeSuccessfulBooleanSetResponsePreservesSelectedValue() throws {
        let staleFast = ACPConfigOption(
            id: "fast-mode", name: "Fast mode", type: "boolean", currentValue: .boolean(false))
        let currentFast = ACPConfigOption(
            id: "fast-mode", name: "Fast mode", type: "boolean", currentValue: .boolean(true))

        let merged = try #require(ACPConfigOption.mergingSuccessfulSetResponse(
            [staleFast],
            configId: "fast-mode",
            selectedValue: .boolean(true),
            currentConfigOptions: [currentFast]))

        #expect(merged.first?.currentValue == .boolean(true))
    }
}
