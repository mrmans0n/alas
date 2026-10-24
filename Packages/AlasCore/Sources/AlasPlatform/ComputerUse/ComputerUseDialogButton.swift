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
}
