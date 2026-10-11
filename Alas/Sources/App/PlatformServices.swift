import AppKit

/// Installs the AppKit implementations behind the seams that core code calls
/// through. Runs first in `AlasApp.init`, before any state is created.
@MainActor
enum PlatformServices {
    static func install() {
        ImageDiffDecoding.shared = ImageDiffDecoding(
            cachedSide: { key, load in
                await ImageDiffDecodedCache.shared.side(
                    for: key,
                    cost: ImageDiffDecodedCache.decodedImageCost,
                    makeImageSide: GitService.imageSide(forDecodedImage:),
                    load: load
                )
            },
            decode: { data, worktreePath in
                await GitService.imageSide(fromRawData: data, worktreePath: worktreePath)
            }
        )
    }
}
