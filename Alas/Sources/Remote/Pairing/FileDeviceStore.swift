import Foundation

/// Production `RemoteDeviceStore`: persists paired devices as JSON under
/// Application Support (`remote-devices.json`), mirroring how `AppConfig` and
/// the other app-level state files are read/written via `PersistenceStore`.
/// `load()` returns `[]` when the file is missing or unreadable; `save()`
/// writes atomically (and silently no-ops on failure — pairing state is
/// recoverable by re-pairing, so a write hiccup must not crash the app).
final class FileDeviceStore: RemoteDeviceStore {
    private let store: any PersistenceStoreProtocol
    private let url: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), url: URL = Paths.remoteDevicesFile) {
        self.store = store
        self.url = url
    }

    func load() -> [RemoteDevice] {
        (try? store.readIfExists([RemoteDevice].self, from: url)) ?? []
    }

    func save(_ devices: [RemoteDevice]) {
        try? store.write(devices, to: url)
    }
}
