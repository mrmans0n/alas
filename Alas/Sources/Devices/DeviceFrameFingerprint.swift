import IOSurface

/// A coarse sample of a frame's pixels, to tell when a simulator's screen
/// stopped changing: 64×64 bytes on a grid over the first plane (luma for the
/// service's `420v` frames).
struct DeviceFrameFingerprint: Equatable {
    private let samples: [UInt8]

    init?(_ surface: IOSurface) {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let ref = surface as IOSurfaceRef
        let planar = IOSurfaceGetPlaneCount(ref) > 0
        let base = planar ? IOSurfaceGetBaseAddressOfPlane(ref, 0) : IOSurfaceGetBaseAddress(ref)
        let rowBytes = planar ? IOSurfaceGetBytesPerRowOfPlane(ref, 0) : IOSurfaceGetBytesPerRow(ref)
        let height = planar ? IOSurfaceGetHeightOfPlane(ref, 0) : IOSurfaceGetHeight(ref)
        guard rowBytes > 0, height > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var samples: [UInt8] = []
        samples.reserveCapacity(64 * 64)
        for row in 0..<64 {
            let y = min((row * height) / 64 + height / 128, height - 1)
            for column in 0..<64 {
                let x = min((column * rowBytes) / 64 + rowBytes / 128, rowBytes - 1)
                samples.append(bytes[y * rowBytes + x])
            }
        }
        self.samples = samples
    }

    /// Fewer than 0.5% of samples differ by more than 8: a blinking caret
    /// doesn't count as a change.
    func matches(_ other: Self) -> Bool {
        let differing = zip(samples, other.samples).count { abs(Int($0) - Int($1)) > 8 }
        return differing * 200 < samples.count
    }
}
