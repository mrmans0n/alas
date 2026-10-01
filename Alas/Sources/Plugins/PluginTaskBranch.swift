import Foundation

/// The branch a plugin task starts on: the plugin's own name when git accepts
/// it, otherwise `task/<slug>` from that name or the task title.
enum PluginTaskBranch {
    static let maxSlugLength = 48

    static func name(title: String, requested: String?) -> String {
        let requested = requested?.isEmpty == false ? requested : nil
        // `HEAD` passes the name check but names no branch.
        if let requested, requested.caseInsensitiveCompare("HEAD") != .orderedSame,
           GitNameValidator.validateBranchName(requested) == .valid {
            return requested
        }
        let folded = (requested ?? title)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
        var slug = ""
        for character in folded {
            let isAllowed = character.isASCII && (character.isLetter || character.isNumber)
            if isAllowed {
                slug.append(character)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        let dashes = CharacterSet(charactersIn: "-")
        slug = String(slug.trimmingCharacters(in: dashes).prefix(maxSlugLength)).trimmingCharacters(in: dashes)
        return "task/" + (slug.isEmpty ? "task" : slug)
    }
}
