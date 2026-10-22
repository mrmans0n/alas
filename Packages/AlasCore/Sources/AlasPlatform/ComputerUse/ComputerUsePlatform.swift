import Foundation

/// macOS permission checks behind computer use. `PlatformServices.install()`
/// sets the system implementation at launch; until then nothing is granted.
@MainActor
public struct ComputerUsePlatform: Sendable {
    public var isGranted: (ComputerUsePermission) -> Bool
    /// Shows the system prompt where macOS has one; never opens System Settings itself.
    public var request: (ComputerUsePermission) -> Void
    public var isAdHocSigned: () -> Bool

    public static var shared = ComputerUsePlatform(
        isGranted: { _ in false },
        request: { _ in },
        isAdHocSigned: { false }
    )

    public init(
        isGranted: @escaping (ComputerUsePermission) -> Bool,
        request: @escaping (ComputerUsePermission) -> Void,
        isAdHocSigned: @escaping () -> Bool
    ) {
        self.isGranted = isGranted
        self.request = request
        self.isAdHocSigned = isAdHocSigned
    }

    public func grantedPermissions() -> Set<ComputerUsePermission> {
        Set(ComputerUsePermission.allCases.filter(isGranted))
    }
}
