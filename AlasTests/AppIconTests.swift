import Foundation
import Testing

struct AppIconTests {
    @Test func bundleMetadataUsesAlasAppIcon() {
        let info = Bundle.main.infoDictionary

        #expect(info?["CFBundleIconFile"] as? String == "AppIcon")
        #expect(info?["CFBundleIconName"] as? String == "AppIcon")
    }
}
