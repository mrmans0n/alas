import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP user input form state")
struct ACPUserInputFormStateTests {
    @Test("defaults are submitted and untouched optional fields are omitted")
    func defaultsAndOptionalOmission() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Configure",
          "requestedSchema":{"properties":{
            "name":{"type":"string","default":"Alas"},
            "note":{"type":"string"},
            "enabled":{"type":"boolean","default":true}
          },"required":["name"]}
        }
        """#)
        let state = ACPUserInputFormState(request: request)

        #expect(state.submittedContent() == [
            "name": .string("Alas"),
            "enabled": .boolean(true)
        ])
    }

    @Test("string and numeric constraints block invalid submission")
    func validatesConstraints() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Configure",
          "requestedSchema":{"properties":{
            "name":{"type":"string","minLength":3,"pattern":"^[A-Z].*"},
            "port":{"type":"integer","minimum":1024,"maximum":65535}
          },"required":["name","port"]}
        }
        """#)
        let state = ACPUserInputFormState(request: request)
        state.textValues["name"] = "ab"
        state.textValues["port"] = "3.5"
        #expect(state.submittedContent() == nil)

        state.textValues["name"] = "Alas"
        state.textValues["port"] = "3000.0"
        #expect(state.submittedContent() == [
            "name": .string("Alas"),
            "port": .integer(3000)
        ])
    }

    @Test("multi-select preserves schema option order")
    func multiSelectOrder() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Pick",
          "requestedSchema":{"properties":{
            "colors":{"type":"array","minItems":1,"items":{"type":"string","enum":["red","green","blue"]}}
          },"required":["colors"]}
        }
        """#)
        let state = ACPUserInputFormState(request: request)
        let field = try #require(request.fields.first)
        state.toggle("blue", for: field)
        state.toggle("red", for: field)
        #expect(state.submittedContent() == ["colors": .strings(["red", "blue"])])
    }

    @Test("blank optional constrained strings are omitted")
    func blankOptionalConstrainedStrings() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Configure",
          "requestedSchema":{"properties":{
            "name":{"type":"string","minLength":3,"pattern":"^[A-Z].*"},
            "email":{"type":"string","format":"email"}
          }}
        }
        """#)
        let state = ACPUserInputFormState(request: request)
        state.markTouched("name")
        state.markTouched("email")

        #expect(state.submittedContent() == [:])
    }

    @Test("unknown required fields cannot be submitted")
    func unknownRequiredField() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Pick",
          "requestedSchema":{"properties":{"nested":{"type":"object"}},"required":["nested"]}
        }
        """#)
        let state = ACPUserInputFormState(request: request)
        #expect(state.submittedContent() == nil)
        #expect(state.validationError(for: try #require(request.fields.first)) != nil)
    }

    @Test("required dates need an explicit or default value")
    func requiredDateNeedsValue() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Schedule",
          "requestedSchema":{"properties":{"due":{"type":"string","format":"date"}},"required":["due"]}
        }
        """#)
        let state = ACPUserInputFormState(request: request)

        #expect(state.dateValues["due"] == nil)
        #expect(state.submittedContent() == nil)

        state.dateValues["due"] = Date(timeIntervalSince1970: 0)
        state.markTouched("due")
        #expect(state.submittedContent() == ["due": .string("1970-01-01")])
    }

    @Test("date-only values preserve their calendar day west of UTC")
    func dateOnlyTimeZoneStability() throws {
        let timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(ACPUserInputFormState.parseDateOnly("2026-07-10", timeZone: timeZone))
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone

        #expect(calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(
            year: 2026,
            month: 7,
            day: 10
        ))
        #expect(ACPUserInputFormState.formatDateOnly(date, timeZone: timeZone) == "2026-07-10")
    }

    @Test("fractional date-time defaults are preserved")
    func fractionalDateTimeDefault() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Schedule",
          "requestedSchema":{"properties":{
            "startsAt":{"type":"string","format":"date-time","default":"2026-07-10T14:30:00.000Z"}
          },"required":["startsAt"]}
        }
        """#)
        let state = ACPUserInputFormState(request: request)

        #expect(state.dateValues["startsAt"] != nil)
        #expect(state.submittedContent() == ["startsAt": .string("2026-07-10T14:30:00Z")])
    }

    @Test("single-field form hides a message that repeats the field label")
    func matchingSingleFieldMessageIsHidden() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Choose an authoring model",
          "requestedSchema":{"properties":{
            "authoringModel":{"type":"string","title":"  Choose an authoring model  "}
          }}
        }
        """#)

        #expect(!ACPUserInputPrompt.shouldShowMessage(for: request))
    }

    @Test("single-field form keeps a distinct message")
    func distinctSingleFieldMessageIsShown() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Configure this project",
          "requestedSchema":{"properties":{
            "authoringModel":{"type":"string","title":"Authoring model"}
          }}
        }
        """#)

        #expect(ACPUserInputPrompt.shouldShowMessage(for: request))
    }

    @Test("multi-field form hides a message that repeats the first field label")
    func matchingFirstFieldMessageIsHiddenInMultiFieldForm() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Pick a design?",
          "requestedSchema":{"properties":{
            "choice":{"type":"string","title":"Pick a design?"},
            "other":{"type":"string","title":"Other (type your own)"}
          }}
        }
        """#)

        #expect(!ACPUserInputPrompt.shouldShowMessage(for: request))
    }

    @Test("multi-field form keeps its message when only a later field label matches")
    func laterFieldMatchKeepsMessage() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Authoring model",
          "requestedSchema":{"properties":{
            "a":{"type":"boolean","title":"Enabled"},
            "b":{"type":"string","title":"Authoring model"}
          }}
        }
        """#)

        #expect(ACPUserInputPrompt.shouldShowMessage(for: request))
    }

    @Test("form keeps a matching message when its only field is not rendered")
    func unsupportedOptionalFieldKeepsMessage() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Advanced configuration",
          "requestedSchema":{"properties":{
            "advanced":{"type":"object","title":"Advanced configuration"}
          }}
        }
        """#)

        #expect(ACPUserInputPrompt.shouldShowMessage(for: request))
    }

    @Test("required arrays without minItems submit an empty selection, even with no options to pick")
    func requiredArrayWithoutMinItemsSubmitsEmptySelection() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Pick",
          "requestedSchema":{"properties":{
            "scopes":{"type":"array","items":{"type":"string","enum":["read","write"]}},
            "tags":{"type":"array"},
            "targets":{"type":"array","minItems":1,"items":{"type":"string","enum":["mac"]}}
          },"required":["scopes","tags","targets"]}
        }
        """#)
        let state = ACPUserInputFormState(request: request)
        let scopes = try #require(request.fields.first { $0.key == "scopes" })
        let tags = try #require(request.fields.first { $0.key == "tags" })
        let targets = try #require(request.fields.first { $0.key == "targets" })

        #expect(state.validationError(for: scopes) == nil)
        #expect(state.validationError(for: tags) == nil)
        #expect(state.validationError(for: targets) != nil)

        state.toggle("mac", for: targets)
        #expect(state.submittedContent() == [
            "scopes": .strings([]), "tags": .strings([]), "targets": .strings(["mac"]),
        ])
    }

    @Test("enumerated strings still honor pattern and length constraints")
    func enumeratedStringsHonorConstraints() throws {
        let request = try formRequest(#"""
        {
          "requestId":1,"mode":"form","message":"Deploy",
          "requestedSchema":{"properties":{
            "target":{"type":"string","enum":["dev","prod"],"pattern":"^prod$"}
          },"required":["target"]}
        }
        """#)
        let state = ACPUserInputFormState(request: request)
        let target = try #require(request.fields.first)

        state.toggle("dev", for: target)
        #expect(state.validationError(for: target) != nil)
        #expect(state.submittedContent() == nil)

        state.toggle("prod", for: target)
        #expect(state.submittedContent() == ["target": .string("prod")])
    }

    @Test("plan approval checklist lists top-level todos and every phase")
    func planApprovalChecklistIncludesPhases() {
        let plan = ACPCursorCreatePlanParams(
            toolCallId: "tool-1", name: "Ship it", overview: "", plan: "",
            todos: [.init(id: "t1", content: "Update the sidebar", status: "pending")],
            isProject: true,
            phases: [
                .init(name: "Verification", todos: [.init(id: "t2", content: "Run tests", status: "pending")]),
                .init(name: "Empty", todos: []),
            ]
        )

        #expect(ACPPlanApprovalPrompt.checklistSections(for: plan) == [
            .init(title: nil, items: [.init(content: "Update the sidebar", status: "pending")]),
            .init(title: "Verification", items: [.init(content: "Run tests", status: "pending")]),
        ])
    }

    private func formRequest(_ json: String) throws -> ACPUserInputRequest {
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(json.utf8)
        )
        return try #require(ACPUserInputRequest.elicitation(.init(id: .number(1), params: params)))
    }
}
