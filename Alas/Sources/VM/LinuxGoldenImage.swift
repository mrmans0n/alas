import Foundation

/// The Ubuntu cloud image Linux golden VMs are built from, pinned to one
/// release serial and its checksum so every build starts from the same bytes.
/// Bumping it means updating all three together from that serial's
/// `SHA256SUMS`.
enum LinuxGoldenImage {
    static let release = "26.04"
    static let serial = "20261016"
    static let fileName = "ubuntu-26.04-server-cloudimg-arm64.img"
    static let sha256 = "8eb876c2ccc4b6ff89e4a65d511815923b285e04503ba465809bf587f763da24"
    /// The serial's own directory, never the moving `release/` alias.
    static let url = URL(string: "https://cloud-images.ubuntu.com/releases/\(release)/release-\(serial)/\(fileName)")!
    /// The golden disk's logical size; the raw image is sparse.
    static let diskSize: UInt64 = 64 << 30
}
