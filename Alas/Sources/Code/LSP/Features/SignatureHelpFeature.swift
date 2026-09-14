import AppKit

// MARK: - Protocol shapes

enum LSPSignatureDocumentation: Codable, Equatable, Hashable, Sendable {
    case plain(String)
    case markup(kind: String, value: String)

    var displayText: String {
        switch self {
        case .plain(let value), .markup(_, let value): value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .plain(value)
            return
        }
        let markup = try container.decode(Markup.self)
        self = .markup(kind: markup.kind, value: markup.value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let value):
            try container.encode(value)
        case .markup(let kind, let value):
            try container.encode(Markup(kind: kind, value: value))
        }
    }

    private struct Markup: Codable, Equatable, Hashable, Sendable {
        let kind: String
        let value: String
    }
}

enum LSPSignatureParameterLabel: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case offsets(start: Int, end: Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        let values = try container.decode([Int].self)
        guard values.count == 2 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "parameter label offsets require exactly two values")
        }
        self = .offsets(start: values[0], end: values[1])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .offsets(let start, let end):
            try container.encode([start, end])
        }
    }
}

struct LSPSignatureParameter: Codable, Equatable, Hashable, Sendable {
    let label: LSPSignatureParameterLabel
    let documentation: LSPSignatureDocumentation?
}

struct LSPSignatureInformation: Codable, Equatable, Hashable, Sendable {
    let label: String
    let documentation: LSPSignatureDocumentation?
    let parameters: [LSPSignatureParameter]?
    let activeParameter: Int?
}

struct LSPSignatureHelp: Codable, Equatable, Hashable, Sendable {
    let signatures: [LSPSignatureInformation]
    let activeSignature: Int?
    let activeParameter: Int?
}

enum LSPSignatureHelpTriggerKind: Int, Codable, Hashable, Sendable {
    case invoked = 1
    case triggerCharacter = 2
    case contentChange = 3
}

struct LSPSignatureHelpContext: Codable, Hashable, Sendable {
    let triggerKind: LSPSignatureHelpTriggerKind
    let triggerCharacter: String?
    let isRetrigger: Bool
    let activeSignatureHelp: LSPSignatureHelp?

    init(
        triggerKind: LSPSignatureHelpTriggerKind,
        triggerCharacter: String?,
        isRetrigger: Bool,
        activeSignatureHelp: LSPSignatureHelp?
    ) {
        self.triggerKind = triggerKind
        self.triggerCharacter = triggerCharacter
        self.isRetrigger = isRetrigger
        self.activeSignatureHelp = activeSignatureHelp
    }

    private enum CodingKeys: String, CodingKey {
        case triggerKind, triggerCharacter, isRetrigger, activeSignatureHelp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(triggerKind, forKey: .triggerKind)
        try container.encodeIfPresent(triggerCharacter, forKey: .triggerCharacter)
        try container.encode(isRetrigger, forKey: .isRetrigger)
        try container.encodeIfPresent(activeSignatureHelp, forKey: .activeSignatureHelp)
    }
}

struct LSPSignatureHelpParams: Codable, Hashable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
    let context: LSPSignatureHelpContext?
}

// MARK: - Editor behavior

@MainActor
final class SignatureHelpFeature {
    typealias SynchronizeRequest = (_ range: NSRange) async -> (LSPClient, EditorRequestContext)?

    private weak var textView: CodeTextView?
    private let getClient: () -> LSPClient?
    private let getURI: () -> String?
    private let isEnabled: () -> Bool
    private let prepareForSignatureHelpRequest: @MainActor () async -> Void
    private let synchronizeRequest: SynchronizeRequest?
    private let isContextCurrent: (EditorRequestContext) -> Bool
    private let windowController = SignatureHelpWindowController()

    private var requestTask: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?
    private var requestID: UInt64 = 0
    private var automaticGeneration: UInt64 = 0
    private var help: LSPSignatureHelp?
    private var selectedSignatureIndex: Int?
    private var shownCaret: Int?
    private var shownCallStart: Int?

    init(
        textView: CodeTextView,
        getClient: @escaping () -> LSPClient?,
        getURI: @escaping () -> String?,
        isEnabled: @escaping () -> Bool,
        prepareForSignatureHelpRequest: @escaping @MainActor () async -> Void = {},
        synchronizeRequest: SynchronizeRequest? = nil,
        isContextCurrent: @escaping (EditorRequestContext) -> Bool = { _ in true }
    ) {
        self.textView = textView
        self.getClient = getClient
        self.getURI = getURI
        self.isEnabled = isEnabled
        self.prepareForSignatureHelpRequest = prepareForSignatureHelpRequest
        self.synchronizeRequest = synchronizeRequest
        self.isContextCurrent = isContextCurrent

        textView.signatureHelpManualTriggerHandler = { [weak self] in
            self?.triggerManual()
        }
        textView.signatureHelpChangeHandler = { [weak self] in
            self?.scheduleAutomatic()
        }
        textView.signatureHelpSelectionChangeHandler = { [weak self] in
            self?.dismiss()
        }
    }

    static let manualRequestContext = LSPSignatureHelpContext(
        triggerKind: .invoked,
        triggerCharacter: nil,
        isRetrigger: false,
        activeSignatureHelp: nil
    )

    static func activeSignatureIndex(in help: LSPSignatureHelp) -> Int? {
        guard !help.signatures.isEmpty else { return nil }
        guard let active = help.activeSignature, help.signatures.indices.contains(active) else { return 0 }
        return active
    }

    static func activeParameter(in help: LSPSignatureHelp) -> Int? {
        guard let signatureIndex = activeSignatureIndex(in: help) else { return nil }
        let signature = help.signatures[signatureIndex]
        guard let parameters = signature.parameters, !parameters.isEmpty else { return nil }
        let active = signature.activeParameter ?? help.activeParameter ?? 0
        guard parameters.indices.contains(active) else { return 0 }
        return active
    }

    static func requestContext(
        text: String,
        caret: Int,
        triggerCharacters: [String],
        retriggerCharacters: [String],
        isVisible: Bool,
        activeSignatureHelp: LSPSignatureHelp? = nil
    ) -> LSPSignatureHelpContext? {
        guard caret >= 0, caret <= (text as NSString).length, callStart(text: text, caret: caret) != nil else { return nil }
        let prefix = (text as NSString).substring(to: caret)
        if let trigger = triggerCharacters.sorted(by: { $0.count > $1.count }).first(where: { prefix.hasSuffix($0) }) {
            return LSPSignatureHelpContext(
                triggerKind: .triggerCharacter,
                triggerCharacter: trigger,
                isRetrigger: isVisible,
                activeSignatureHelp: isVisible ? activeSignatureHelp : nil
            )
        }
        if isVisible,
           let retrigger = retriggerCharacters.sorted(by: { $0.count > $1.count }).first(where: { prefix.hasSuffix($0) }) {
            return LSPSignatureHelpContext(
                triggerKind: .triggerCharacter,
                triggerCharacter: retrigger,
                isRetrigger: true,
                activeSignatureHelp: activeSignatureHelp
            )
        }
        return nil
    }

    static func contentChangeContext(
        text: String,
        caret: Int,
        previousCallStart: Int?,
        isVisible: Bool,
        activeSignatureHelp: LSPSignatureHelp? = nil
    ) -> LSPSignatureHelpContext? {
        guard isVisible,
              let callStart = callStart(text: text, caret: caret),
              callStart != previousCallStart else { return nil }
        return LSPSignatureHelpContext(
            triggerKind: .contentChange,
            triggerCharacter: nil,
            isRetrigger: true,
            activeSignatureHelp: activeSignatureHelp
        )
    }

    static func callStart(text: String, caret: Int) -> Int? {
        let length = (text as NSString).length
        guard caret >= 0, caret <= length else { return nil }
        let prefix = (text as NSString).substring(to: caret)
        var openParens: [Int] = []
        var utf16Offset = 0
        for scalar in prefix.unicodeScalars {
            switch scalar {
            case "(":
                openParens.append(utf16Offset)
            case ")":
                _ = openParens.popLast()
            default:
                break
            }
            utf16Offset += scalar.utf16.count
        }
        return openParens.last
    }

    static func parameterRange(in signature: LSPSignatureInformation, index: Int) -> NSRange? {
        guard let parameters = signature.parameters, parameters.indices.contains(index) else { return nil }
        let label = signature.label as NSString
        switch parameters[index].label {
        case .offsets(let start, let end):
            guard start >= 0, end >= start, end <= label.length else { return nil }
            return NSRange(location: start, length: end - start)
        case .string:
            var searchStart = 0
            for (parameterIndex, parameter) in parameters.enumerated() {
                let range: NSRange
                switch parameter.label {
                case .offsets(let start, let end):
                    guard start >= 0, end >= start, end <= label.length else { return nil }
                    range = NSRange(location: start, length: end - start)
                case .string(let value):
                    let searchRange = NSRange(location: searchStart, length: label.length - searchStart)
                    range = label.range(of: value, options: [], range: searchRange)
                    guard range.location != NSNotFound else { return nil }
                }
                if parameterIndex == index { return range }
                searchStart = max(searchStart, NSMaxRange(range))
            }
            return nil
        }
    }

    static func isResponseCurrent(requestID: UInt64, currentRequestID: UInt64, contextIsCurrent: Bool) -> Bool {
        requestID == currentRequestID && contextIsCurrent
    }

    func notifyScrolled() {
        reposition()
    }

    func notifyWindowResized() {
        reposition()
    }

    func handleEscape() -> Bool {
        guard windowController.isVisible else { return false }
        cancelAndDismiss()
        return true
    }

    /// Cancels work and hides the overlay while retaining the text-view handlers.
    /// A coordinator rebind uses this so signature help remains installed.
    func cancelAndDismiss() {
        automaticTask?.cancel()
        automaticTask = nil
        automaticGeneration &+= 1
        dismiss()
    }

    func tearDown() {
        cancelAndDismiss()
        textView?.signatureHelpManualTriggerHandler = nil
        textView?.signatureHelpChangeHandler = nil
        textView?.signatureHelpSelectionChangeHandler = nil
    }

    func triggerManual() {
        request(context: Self.manualRequestContext)
    }

    private func scheduleAutomatic() {
        guard let textView, isEnabled(), textView.isEditable,
              textView.sourceSelectedRanges.count == 1, textView.sourceSelectedRange.length == 0 else {
            dismiss()
            return
        }
        let text = textView.sourceString
        let caret = textView.sourceSelectedRange.location
        guard let callStart = Self.callStart(text: text, caret: caret) else {
            cancelAndDismiss()
            return
        }
        let client = getClient()
        automaticTask?.cancel()
        automaticGeneration &+= 1
        let generation = automaticGeneration
        automaticTask = Task { [weak self] in
            guard let self, let client else { return }
            let triggers = await client.signatureHelpTriggerCharacters
            let retriggers = await client.signatureHelpRetriggerCharacters
            guard !Task.isCancelled,
                  generation == self.automaticGeneration,
                  self.textView?.sourceString == text,
                  self.textView?.sourceSelectedRange.location == caret,
                  self.textView?.sourceSelectedRange.length == 0 else { return }
            let visible = self.windowController.isVisible
            let activeSignatureHelp = visible ? self.signatureHelpForRetrigger() : nil
            let context = Self.requestContext(
                text: text,
                caret: caret,
                triggerCharacters: triggers,
                retriggerCharacters: retriggers,
                isVisible: visible,
                activeSignatureHelp: activeSignatureHelp
            )
            if let context {
                self.request(context: context)
            } else if let context = Self.contentChangeContext(
                text: text,
                caret: caret,
                previousCallStart: self.shownCallStart,
                isVisible: visible,
                activeSignatureHelp: activeSignatureHelp
            ) {
                self.request(context: context)
            } else {
                self.shownCaret = caret
                self.shownCallStart = callStart
                self.reposition()
            }
        }
    }

    private func request(context: LSPSignatureHelpContext) {
        guard let textView, isEnabled(), textView.isEditable,
              textView.sourceSelectedRanges.count == 1, textView.sourceSelectedRange.length == 0,
              let uri = getURI() else {
            dismiss()
            return
        }
        let caret = textView.sourceSelectedRange.location
        guard context.triggerKind == .invoked || Self.callStart(text: textView.sourceString, caret: caret) != nil else {
            cancelAndDismiss()
            return
        }
        requestTask?.cancel()
        requestID &+= 1
        let thisRequestID = requestID
        let fallbackClient = getClient()

        requestTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareForSignatureHelpRequest()
            guard !Task.isCancelled else { return }

            let bound = await self.synchronizeRequest?(NSRange(location: caret, length: 0))
            let requestContext = bound?.1
            let response: LSPSignatureHelp?
            if let bound {
                response = try? await bound.0.signatureHelp(
                    uri: bound.1.document.uri,
                    position: bound.1.range.start,
                    context: context
                )
            } else if self.synchronizeRequest == nil, let fallbackClient,
                      let position = TextEditCoordinates.lspPosition(utf16Offset: caret, in: textView.sourceString) {
                response = try? await fallbackClient.signatureHelp(uri: uri, position: position, context: context)
            } else {
                response = nil
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      Self.isResponseCurrent(
                        requestID: thisRequestID,
                        currentRequestID: self.requestID,
                        contextIsCurrent: requestContext.map(self.isContextCurrent) ?? true
                      ),
                      self.getURI() == uri,
                      self.textView?.sourceSelectedRange.location == caret,
                      self.textView?.sourceSelectedRange.length == 0
                else { return }
                self.applyCurrentResponse(response, caret: caret)
            }
        }
    }

    private func applyCurrentResponse(_ response: LSPSignatureHelp?, caret: Int) {
        guard let response, Self.activeSignatureIndex(in: response) != nil else {
            cancelAndDismiss()
            return
        }
        help = response
        selectedSignatureIndex = Self.activeSignatureIndex(in: response)
        shownCaret = caret
        shownCallStart = Self.callStart(text: textView?.sourceString ?? "", caret: caret)
        present()
    }

    private func present() {
        guard let textView, let help,
              let signatureIndex = selectedSignatureIndex,
              help.signatures.indices.contains(signatureIndex),
              let anchor = textView.completionAnchorRect() else {
            dismiss()
            return
        }
        let signature = help.signatures[signatureIndex]
        let activeParameter = activeParameter(for: signatureIndex, in: help)
        windowController.show(
            signature: signature,
            activeParameter: activeParameter,
            signatureIndex: signatureIndex,
            signatureCount: help.signatures.count,
            anchor: anchor,
            in: textView,
            onSelectSignature: { [weak self] index in
                self?.selectSignature(index)
            }
        )
    }

    private func reposition() {
        guard windowController.isVisible else { return }
        guard let textView, let caret = shownCaret,
              textView.sourceSelectedRange.location == caret,
              let anchor = textView.completionAnchorRect() else {
            dismiss()
            return
        }
        windowController.reposition(anchor: anchor, in: textView)
    }

    private func selectSignature(_ index: Int) {
        guard let help, help.signatures.indices.contains(index) else { return }
        selectedSignatureIndex = index
        self.help = LSPSignatureHelp(
            signatures: help.signatures,
            activeSignature: index,
            activeParameter: help.activeParameter
        )
        present()
        if windowController.isVisible {
            request(context: LSPSignatureHelpContext(
                triggerKind: .contentChange,
                triggerCharacter: nil,
                isRetrigger: true,
                activeSignatureHelp: signatureHelpForRetrigger()
            ))
        }
    }

    private func activeParameter(for signatureIndex: Int, in help: LSPSignatureHelp) -> Int? {
        guard help.signatures.indices.contains(signatureIndex) else { return nil }
        let signature = help.signatures[signatureIndex]
        guard let parameters = signature.parameters, !parameters.isEmpty else { return nil }
        let active = signature.activeParameter ?? (signatureIndex == Self.activeSignatureIndex(in: help) ? help.activeParameter : nil) ?? 0
        guard parameters.indices.contains(active) else { return 0 }
        return active
    }

    private func signatureHelpForRetrigger() -> LSPSignatureHelp? {
        guard let help else { return nil }
        guard let selectedSignatureIndex else { return help }
        return LSPSignatureHelp(
            signatures: help.signatures,
            activeSignature: selectedSignatureIndex,
            activeParameter: help.activeParameter
        )
    }

    private func dismiss() {
        requestTask?.cancel()
        requestTask = nil
        requestID &+= 1
        help = nil
        selectedSignatureIndex = nil
        shownCaret = nil
        shownCallStart = nil
        windowController.hide()
    }

    struct TestingSnapshot: Equatable {
        let help: LSPSignatureHelp?
        let selectedSignatureIndex: Int?
        let shownCallStart: Int?
    }

    var testingSnapshot: TestingSnapshot {
        TestingSnapshot(help: help, selectedSignatureIndex: selectedSignatureIndex, shownCallStart: shownCallStart)
    }

    func testingApplyCurrentResponse(_ response: LSPSignatureHelp?, caret: Int) {
        applyCurrentResponse(response, caret: caret)
    }
}

// MARK: - Non-key overlay presentation

@MainActor
private final class SignatureHelpWindowController {
    private let overlay = EditorOverlayPanel()
    private var contentController: SignatureHelpContentController?
    private var size: NSSize = .zero

    var isVisible: Bool { overlay.isVisible }

    func show(
        signature: LSPSignatureInformation,
        activeParameter: Int?,
        signatureIndex: Int,
        signatureCount: Int,
        anchor: NSRect,
        in textView: CodeTextView,
        onSelectSignature: @escaping (Int) -> Void
    ) {
        let controller = SignatureHelpContentController(
            signature: signature,
            activeParameter: activeParameter,
            signatureIndex: signatureIndex,
            signatureCount: signatureCount,
            onSelectSignature: onSelectSignature
        )
        contentController = controller
        size = controller.preferredSize
        overlay.show(contentViewController: controller, size: size, anchor: anchor, in: textView)
    }

    func reposition(anchor: NSRect, in textView: CodeTextView) {
        guard let contentController else { return }
        overlay.show(contentViewController: contentController, size: size, anchor: anchor, in: textView)
    }

    func hide() {
        overlay.hide()
        contentController = nil
    }
}

@MainActor
private final class SignatureHelpContentController: NSViewController {
    private let signature: LSPSignatureInformation
    private let activeParameter: Int?
    private let signatureIndex: Int
    private let signatureCount: Int
    private let onSelectSignature: (Int) -> Void

    init(
        signature: LSPSignatureInformation,
        activeParameter: Int?,
        signatureIndex: Int,
        signatureCount: Int,
        onSelectSignature: @escaping (Int) -> Void
    ) {
        self.signature = signature
        self.activeParameter = activeParameter
        self.signatureIndex = signatureIndex
        self.signatureCount = signatureCount
        self.onSelectSignature = onSelectSignature
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    var preferredSize: NSSize {
        NSSize(width: 440, height: documentationText == nil ? 58 : 112)
    }

    override func loadView() {
        let view = NSView(frame: NSRect(origin: .zero, size: preferredSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        view.layer?.cornerRadius = 7

        let signatureField = NSTextField(labelWithAttributedString: attributedSignature())
        signatureField.lineBreakMode = .byTruncatingTail
        signatureField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(signatureField)

        var trailingAnchor = view.trailingAnchor
        if signatureCount > 1 {
            let cycling = NSSegmentedControl(labels: ["‹", "›"], trackingMode: .momentary, target: self, action: #selector(cycleSignature(_:)))
            cycling.translatesAutoresizingMaskIntoConstraints = false
            cycling.setAccessibilityLabel("Cycle signatures")
            view.addSubview(cycling)
            NSLayoutConstraint.activate([
                cycling.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
                cycling.centerYAnchor.constraint(equalTo: signatureField.centerYAnchor),
                cycling.widthAnchor.constraint(equalToConstant: 48)
            ])
            trailingAnchor = cycling.leadingAnchor
        }

        NSLayoutConstraint.activate([
            signatureField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            signatureField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            signatureField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10)
        ])

        if let documentationText {
            let documentation = NSTextField(wrappingLabelWithString: documentationText)
            documentation.font = .systemFont(ofSize: 11)
            documentation.textColor = .secondaryLabelColor
            documentation.maximumNumberOfLines = 3
            documentation.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(documentation)
            NSLayoutConstraint.activate([
                documentation.leadingAnchor.constraint(equalTo: signatureField.leadingAnchor),
                documentation.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                documentation.topAnchor.constraint(equalTo: signatureField.bottomAnchor, constant: 7),
                documentation.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10)
            ])
        }
        self.view = view
    }

    @objc private func cycleSignature(_ sender: NSSegmentedControl) {
        let next: Int
        if sender.selectedSegment == 0 {
            next = (signatureIndex - 1 + signatureCount) % signatureCount
        } else {
            next = (signatureIndex + 1) % signatureCount
        }
        onSelectSignature(next)
    }

    private var documentationText: String? {
        if let activeParameter,
           let documentation = signature.parameters?[activeParameter].documentation?.displayText,
           !documentation.isEmpty {
            return documentation
        }
        let documentation = signature.documentation?.displayText
        return documentation?.isEmpty == false ? documentation : nil
    }

    private func attributedSignature() -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: signature.label,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        guard let activeParameter,
              let range = parameterRange(index: activeParameter),
              NSMaxRange(range) <= result.length else { return result }
        result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: range)
        result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
        return result
    }

    private func parameterRange(index: Int) -> NSRange? {
        SignatureHelpFeature.parameterRange(in: signature, index: index)
    }
}
