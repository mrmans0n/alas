import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

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
