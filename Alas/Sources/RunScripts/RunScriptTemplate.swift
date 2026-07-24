import Foundation

enum RunScriptTemplate {
    /// "Dev Server" → "dev-server.sh". Non-alphanumerics collapse to single
    /// dashes so the display name lives in metadata, not the filename.
    static func fileName(for name: String) -> String {
        var slug = ""
        var lastWasDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                slug.append(ch)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        if slug.hasSuffix("-") { slug.removeLast() }
        return (slug.isEmpty ? "script" : slug) + ".sh"
    }

    static func contents(
        name: String,
        onExit: RunScriptOnExit = .keep
    ) -> String {
        """
        #!/bin/zsh
        # alas-name: \(name)
        # alas-on-exit: \(onExit.rawValue)

        """
    }
}
