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

    private func formRequest(_ json: String) throws -> ACPUserInputRequest {
        let params = try JSONDecoder().decode(
            ACPElicitationRequestParams.self,
            from: Data(json.utf8)
        )
        return try #require(ACPUserInputRequest.elicitation(.init(id: .number(1), params: params)))
    }
}
