import ApplicationServices
import CoreGraphics
import Security

/// The macOS implementation of `ComputerUsePlatform`.
enum ComputerUseSystemPermissions {
    @MainActor
    static func make() -> ComputerUsePlatform {
        ComputerUsePlatform(
            isGranted: { permission in
                switch permission {
                case .screenRecording: CGPreflightScreenCaptureAccess()
                case .accessibility: AXIsProcessTrusted()
                }
            },
            request: { permission in
                switch permission {
                case .screenRecording:
                    _ = CGRequestScreenCaptureAccess()
                case .accessibility:
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary // value of kAXTrustedCheckOptionPrompt, a non-Sendable global var
                    _ = AXIsProcessTrustedWithOptions(options)
                }
            },
            isAdHocSigned: { isCurrentProcessAdHocSigned() }
        )
    }

    /// An ad-hoc signature changes with every build, so macOS drops the grants.
    /// Unknown counts as unstable.
    private static func isCurrentProcessAdHocSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let flags = dict[kSecCodeInfoFlags as String] as? UInt32
        else { return true }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
}
