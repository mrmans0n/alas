import CoreText
import Foundation

enum BundledFontRegistrar {
    static func registerFonts() {
        registerFont(named: "JetBrainsMonoNerdFont-Regular", extension: "ttf")
    }

    private static func registerFont(named name: String, extension ext: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            return
        }

        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }
}
