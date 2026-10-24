import Foundation

/// Finding a dialog's buttons by title, for panels whose cancel and default button attributes
/// can't be read (a Save sheet hosted out of process lists them but returns no value).
public enum ComputerUseDialogButton {
    /// "Cancel" in the languages macOS ships; Spanish and Portuguese share "Cancelar".
    public static let cancelTitles = [
        "Cancel", "Cancelar", "Annuler", "Abbrechen", "Annulla", "キャンセル", "取消", "취소", "Отменить",
        "Anuluj", "Annuleren", "Avbryt", "Peruuta", "İptal", "Zrušit", "Mégse", "Ακύρωση", "ביטול", "إلغاء",
        "Hủy", "Batal", "ยกเลิก",
    ]

    private static let normalizedCancelTitles = Set(cancelTitles.map(normalized))

    /// Whether a button titled `title` is a dialog's cancel button: the whole title, trimmed and
    /// compared case-insensitively, is one of `cancelTitles`. "Cancel Download" is not.
    public static func isCancelTitle(_ title: String) -> Bool {
        normalizedCancelTitles.contains(normalized(title))
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// "OK" in the languages macOS ships, for a default button found by its label.
    public static let defaultTitles = ["OK", "Aceptar", "Accepter", "Akzeptieren", "Accetta", "확인", "好", "ОК", "Tamam"]
    private static let normalizedDefaultTitles = Set(defaultTitles.map(normalized))

    /// Identifiers AppKit and SwiftUI give a dialog's buttons, whatever the language.
    static let cancelIdentifiers: Set<String> = ["AX_CANCEL", "_NS:cancel"]
    static let defaultIdentifiers: Set<String> = ["AX_OK", "_NS:ok"]

    public enum Role: Sendable { case cancel, `default` }

    /// A button as read: a sheet's own cancel or default button, or one found in it.
    public struct Candidate: Sendable, Equatable {
        public var title: String?
        public var description: String?
        public var identifier: String?
        public var isEnabled: Bool

        public init(title: String? = nil, description: String? = nil, identifier: String? = nil, isEnabled: Bool = true) {
            self.title = title
            self.description = description
            self.identifier = identifier
            self.isEnabled = isEnabled
        }

        /// What the result's `button` says: the label the button shows.
        public func label(for role: Role) -> String {
            title ?? description ?? (role == .cancel ? "Cancel" : "OK")
        }
    }

    public enum Resolution: Sendable, Equatable {
        /// The sheet's own `AXCancelButton` / `AXDefaultButton`.
        case attribute(label: String)
        /// `candidates[index]`, by its identifier, then its title or description.
        case candidate(index: Int, label: String)
        case none
    }

    /// Which button Escape (`.cancel`) or Return (`.default`) presses on a sheet: its own attribute's
    /// button when it has one that is enabled; else the first enabled candidate whose identifier
    /// names the role, else whose title or description is one of the role's localized titles (System
    /// Settings' buttons carry their label only in the description).
    public static func resolve(_ role: Role, attributeButton: Candidate?, candidates: [Candidate]) -> Resolution {
        if let attributeButton, attributeButton.isEnabled { return .attribute(label: attributeButton.label(for: role)) }
        let identifiers = role == .cancel ? cancelIdentifiers : defaultIdentifiers
        let titles = role == .cancel ? normalizedCancelTitles : normalizedDefaultTitles
        let enabled = candidates.indices.filter { candidates[$0].isEnabled }
        if let index = enabled.first(where: { candidates[$0].identifier.map(identifiers.contains) == true }) {
            return .candidate(index: index, label: candidates[index].label(for: role))
        }
        if let index = enabled.first(where: { index in
            [candidates[index].title, candidates[index].description].contains { $0.map { titles.contains(normalized($0)) } == true }
        }) {
            return .candidate(index: index, label: candidates[index].label(for: role))
        }
        return .none
    }
}
