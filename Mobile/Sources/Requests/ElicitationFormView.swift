import AlasRemoteKit
import SwiftUI

/// Form-mode elicitation: one control per field, validated by `RemoteElicitationForm`.
struct ElicitationFormView: View {
    let session: TranscriptSession
    let payload: RemoteElicitationPayload
    @State private var inputs: [String: RemoteElicitationInput]
    @State private var error: String?

    init(session: TranscriptSession, payload: RemoteElicitationPayload) {
        self.session = session
        self.payload = payload
        var initial = RemoteElicitationForm.initialInputs(payload.fields)
        // A date picker always shows a value, so a required one must count as chosen.
        for field in payload.fields where field.required && initial[field.key] == nil && Self.isDate(field) {
            initial[field.key] = .date(Date())
        }
        _inputs = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(payload.fields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        if field.type != "boolean" {
                            Text(field.required ? field.title : "\(field.title) (optional)").font(.subheadline.weight(.semibold))
                        }
                        control(field)
                        if let description = field.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
        .scrollBounceBehavior(.basedOnSize)
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
        }
        CardButton(title: "Submit", primary: true, action: submit)
        HStack(spacing: 8) {
            CardButton(title: "Decline") { session.answerElicitation(action: "decline", content: nil) }
            CardButton(title: "Cancel") { session.answerElicitation(action: "cancel", content: nil) }
        }
    }

    private func submit() {
        switch RemoteElicitationForm.content(payload.fields, inputs: inputs) {
        case .success(let content): session.answerElicitation(action: "accept", content: content)
        case .failure(let failure): error = failure.message
        }
    }

    private static func isDate(_ field: RemoteElicitationField) -> Bool {
        field.type == "string" && field.options.isEmpty && (field.format == "date" || field.format == "date-time")
    }

    @ViewBuilder
    private func control(_ field: RemoteElicitationField) -> some View {
        switch field.type {
        case "boolean":
            Toggle(field.required ? field.title : "\(field.title) (optional)", isOn: Binding(
                get: { if case .toggle(let on) = inputs[field.key] { on } else { false } },
                set: { inputs[field.key] = .toggle($0) }))
        case "array":
            VStack(spacing: 6) {
                ForEach(field.options, id: \.value) { option in
                    let on = selection(field).contains(option.value)
                    Button {
                        var items = selection(field)
                        if on { items.removeAll { $0 == option.value } } else { items.append(option.value) }
                        inputs[field.key] = .selection(items)
                    } label: {
                        HStack {
                            Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
                            Text(option.title ?? option.value).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        case "string" where !field.options.isEmpty:
            Picker(field.title, selection: Binding(
                get: { selection(field).first ?? "" },
                set: { inputs[field.key] = $0.isEmpty ? nil : .selection([$0]) })) {
                Text("Choose…").tag("")
                ForEach(field.options, id: \.value) { Text($0.title ?? $0.value).tag($0.value) }
            }
            .pickerStyle(.menu).labelsHidden()
        case "string" where Self.isDate(field):
            DatePicker(field.title, selection: Binding(
                get: { if case .date(let d) = inputs[field.key] { d } else { Date() } },
                set: { inputs[field.key] = .date($0) }),
                displayedComponents: field.format == "date" ? .date : [.date, .hourAndMinute])
                .labelsHidden()
        case "string", "number", "integer":
            let binding = Binding(
                get: { if case .text(let s) = inputs[field.key] { s } else { "" } },
                set: { inputs[field.key] = .text($0) })
            Group {
                if field.isSecret {
                    SecureField(field.title, text: binding)
                } else {
                    TextField(field.title, text: binding)
                        .keyboardType(field.type == "integer" || field.type == "number" ? .numbersAndPunctuation : keyboard(field))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(field.format == "email" || field.format == "uri")
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        default:
            Text("This field type isn\u{2019}t supported on the phone.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func keyboard(_ field: RemoteElicitationField) -> UIKeyboardType {
        switch field.format {
        case "email": .emailAddress
        case "uri": .URL
        default: .default
        }
    }

    private func selection(_ field: RemoteElicitationField) -> [String] {
        if case .selection(let items) = inputs[field.key] { items } else { [] }
    }
}
