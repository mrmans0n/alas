import Foundation

/// One forwarded transcript row, decoded into the value types the local ACP
/// transcript renders so the peer pane can reuse its cards instead of showing
/// flattened text.
public enum RemoteTranscriptRow: Equatable, Sendable {
    /// `images` replace their `🖼` labels in the text; a viewer shows each
    /// label again until its bytes load.
    case user(String, checkpointID: UUID?, images: [RemoteWireMessage.Image] = [])
    case agent(String)
    case thought(String)
    case toolCall(ACPToolCall)
    case fileEdit(ACPFileEdit)
    case plan([ACPPlanItem])
    case planDocument(ACPPlanDocument)
    case visualAid(ACPVisualAid)
    case systemNotice(String)

    public init(message: RemoteWireMessage) {
        let text = message.text ?? ""
        switch message.kind {
        case "user":
            let images = message.images ?? []
            self = .user(
                images.isEmpty ? text : RemoteWireMessage.userRowText(text, removingImageNames: images.map(\.name)),
                checkpointID: message.checkpointId.flatMap(UUID.init(uuidString:)),
                images: images
            )
        case "agent":
            self = .agent(text)
        case "thought":
            self = .thought(text)
        case "systemNotice":
            self = .systemNotice(text)
        case "toolCall":
            if let call: ACPToolCall = Self.decode(message.json) {
                self = .toolCall(call)
            } else {
                self = .systemNotice("Tool call details are unavailable.")
            }
        case "fileEdit":
            if let edit: ACPFileEdit = Self.decode(message.json) {
                self = .fileEdit(edit)
            } else {
                self = .systemNotice("File edit details are unavailable.")
            }
        case "plan":
            if let items: [ACPPlanItem] = Self.decode(message.json) {
                self = .plan(items)
            } else {
                self = .systemNotice("Plan details are unavailable.")
            }
        case "visualAid":
            if let visual = Self.visual(message.json) {
                self = .visualAid(visual)
            } else {
                self = .systemNotice("Visual details are unavailable.")
            }
        case "planDocument":
            if let document: ACPPlanDocument = Self.decode(message.json) {
                self = .planDocument(document)
            } else {
                self = .systemNotice(message.text ?? "Plan details are unavailable.")
            }
        default:
            self = .systemNotice(text)
        }
    }

    private static func visual(_ json: String?) -> ACPVisualAid? {
        guard let dto: RemoteVisualAid = decode(json), let id = UUID(uuidString: dto.id) else { return nil }
        let question = dto.question.map {
            ACPVisualAid.Question(prompt: $0.prompt, options: $0.options.map { .init(id: $0.id, label: $0.label) },
                                  allowMultiple: $0.allowMultiple)
        }
        guard ACPVisualAid.validationFailure(title: dto.title, html: dto.html, question: question) == nil else { return nil }
        let answer: ACPVisualAid.Answer?
        switch dto.answer?.kind {
        case "answered":
            answer = .answered(selectedOptionIds: dto.answer?.selectedOptionIds ?? [], note: dto.answer?.note, at: .distantPast)
        case "dismissed": answer = .dismissed(at: .distantPast)
        case nil: answer = nil
        default: return nil
        }
        return ACPVisualAid(id: id, title: dto.title, html: dto.html, question: question,
                            presentation: question == nil ? (ACPVisualAid.Presentation(rawValue: dto.presentation) ?? .card) : .card,
                            answer: answer, createdAt: .distantPast)
    }

    private static func decode<T: Decodable>(_ json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
