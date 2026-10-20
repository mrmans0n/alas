import Foundation

extension LanguageServerConfig {
    public static func prefilled(from package: MasonPackage) -> LanguageServerConfig {
        let language = package.languageId.isEmpty ? package.masonId.lowercased() : package.languageId
        return LanguageServerConfig(
            language: language,
            extensions: package.extensions,
            command: package.command,
            args: package.args,
            env: [:],
            rootMarkers: [".git"],
            enabled: true
        )
    }
}
