import AppKit
import TreeSitterPack

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
        LanguageRegistry.grammarPack = TreeSitterGrammarPack(
            language: { id in id.withCString { alas_ts_language($0) } },
            highlightQuery: { id in
                // The pack returns static UTF-8 bytes that are not NUL-terminated,
                // so the length is read back through `out_len`.
                var length = 0
                guard let bytes = id.withCString({ alas_ts_query($0, &length) }), length > 0 else { return nil }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
            }
        )
        RunScheduler.wakeNotification = (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        ReviewShepherd.wakeNotification = (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        LocalTextEngine.make = { LocalTextInferenceEngine(store: $0, observeMemoryPressure: false) }
        ACPImageEncoding.encoder = { ACPImageEncoding.appKitInlineBase64(fileURL: $0, maxDimension: $1) }
        ComputerUsePlatform.shared = ComputerUseSystemPermissions.make()
        URLOpening.shared = URLOpening(
            launchHandler: { url in
                guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                    return false
                }
                return await withCheckedContinuation { continuation in
                    NSWorkspace.shared.openApplication(
                        at: applicationURL,
                        configuration: .init()
                    ) { application, error in
                        continuation.resume(returning: application != nil && error == nil)
                    }
                }
            },
            open: { _ = NSWorkspace.shared.open($0) }
        )
        NotificationPlatform.shared = NotificationPlatform(
            playAwaitingPing: {
                DispatchQueue.main.async {
                    if let sound = NSSound(named: NSSound.Name("Tink")) {
                        sound.play()
                    } else {
                        NSSound.beep()
                    }
                }
            },
            logoPNG: { assetName in
                guard let image = NSImage(named: NSImage.Name(assetName)),
                      let tiffData = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
                return bitmap.representation(using: .png, properties: [:])
            }
        )
    }
}
