import AlasRemoteKit
import Foundation
import Testing

@Suite("RemoteElicitationForm")
struct RemoteElicitationFormTests {
    private func field(
        _ key: String,
        _ type: String,
        title: String? = nil,
        required: Bool = false,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        minItems: Int? = nil,
        format: String? = nil,
        pattern: String? = nil,
        options: [String] = []
    ) -> RemoteElicitationField {
        RemoteElicitationField(
            key: key, type: type, title: title ?? key.capitalized, description: nil, required: required,
            minLength: minLength, maxLength: maxLength, minimum: minimum, maximum: maximum,
            minItems: minItems, maxItems: nil, format: format, pattern: pattern,
            options: options.map { RemoteElicitationOption(value: $0, title: nil, description: nil) },
            defaultValue: nil
        )
    }

    private struct Rejection: CustomTestStringConvertible, Sendable {
        let field: RemoteElicitationField
        let input: RemoteElicitationInput?
        let message: String
        var testDescription: String { message + " / " + field.key }
    }

    private var rejections: [Rejection] {
        [
            Rejection(field: field("age", "integer", required: true), input: nil, message: "Enter a value for Age."),
            Rejection(field: field("age", "integer", required: true), input: .text("4.5"), message: "Enter a whole number for Age."),
            Rejection(field: field("email", "string", format: "email"), input: .text("a@b"), message: "Check the value for Email."),
            Rejection(field: field("code", "string", pattern: "^[a-z]+$"), input: .text("A1"), message: "Check the value for Code."),
            Rejection(field: field("short", "string", maxLength: 3), input: .text("abcd"), message: "Check the value for Short."),
            Rejection(field: field("count", "integer", minimum: 1), input: .text("0"), message: "Check the value for Count."),
            Rejection(
                field: field("tags", "array", minItems: 2, options: ["a", "b", "c"]),
                input: .selection(["a"]), message: "Choose at least 2 values for Tags."
            ),
            Rejection(field: field("blob", "object", required: true), input: nil, message: "Cannot submit the unsupported field Blob."),
        ]
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func contentRejectsInvalidInputWithTheWebsMessage(index: Int) {
        let r = rejections[index]
        let inputs = r.input.map { [r.field.key: $0] } ?? [:]
        let result = RemoteElicitationForm.content([r.field], inputs: inputs)
        #expect(result == .failure(RemoteElicitationFormError(message: r.message)))
    }

    @Test func contentEncodesTypedValuesAndOmitsUntouchedOptionals() {
        let fields = [
            field("age", "integer", required: true),
            field("ratio", "number"),
            field("ok", "boolean"),
            field("tags", "array", options: ["a", "b"]),
            field("pick", "string", options: ["x", "y"]),
            field("when", "string", format: "date-time"),
            field("note", "string"),
        ]
        let inputs: [String: RemoteElicitationInput] = [
            "age": .text("4"), "ratio": .text("4.5"), "ok": .toggle(true),
            "tags": .selection(["a", "b"]), "pick": .selection(["x"]),
            "when": .date(Date(timeIntervalSince1970: 1_794_650_400)),
        ]
        let content = try? RemoteElicitationForm.content(fields, inputs: inputs).get()
        #expect(content == [
            "age": .integer(4), "ratio": .number(4.5), "ok": .boolean(true),
            "tags": .strings(["a", "b"]), "pick": .string("x"),
            "when": .string("2026-11-14T10:00:00Z"),
        ])
    }
}
