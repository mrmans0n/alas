import AlasCore
import SwiftUI

struct RemoteDeviceSharingSettings: View {
    let state: AppState

    var body: some View {
        SettingsGroup(title: "Device sharing") {
            if let error = state.peerDeviceSharingError {
                SettingsRow(name: "Device sharing error", desc: error) { EmptyView() }
            }
            if !state.canServePeerDevices {
                SettingsRow(name: "Tailscale HTTPS required", desc: "Device sharing waits for a verified HTTPS address with Serve over HTTPS and Tailscale only enabled.") {
                    EmptyView()
                }
            }
            let clients = state.peerDeviceShareClients
            let devices = state.peerAndroidShares
            if clients.isEmpty {
                SettingsRow(name: "No paired clients", desc: "Pair a Mac or the Alas iPhone app to share an Android device.") { EmptyView() }
            } else if devices.isEmpty {
                SettingsRow(name: "No USB Android devices", desc: "Connect a device by USB and allow debugging on it.") { EmptyView() }
            } else {
                ForEach(devices) { device in
                    let shared = clients.contains { state.peerDeviceAccess(serial: device.id, pairingID: $0.id) != nil }
                    SettingsRow(name: device.name, desc: description(for: device)) {
                        if shared {
                            Button("Stop Sharing") { state.stopSharingPeerDevice(serial: device.id) }
                        }
                    }
                    ForEach(clients) { client in
                        let access = state.peerDeviceAccess(serial: device.id, pairingID: client.id)
                        if device.availability == .ready || access != nil {
                            SettingsRow(name: client.name, desc: "Access to \(device.name)") {
                                Picker("Access", selection: Binding(
                                    get: { state.peerDeviceAccess(serial: device.id, pairingID: client.id) },
                                    set: { state.setPeerDeviceAccess($0, share: device, pairingID: client.id) }
                                )) {
                                    Text("Off").tag(nil as PeerDeviceAccess?)
                                    Text("View").tag(PeerDeviceAccess.view as PeerDeviceAccess?)
                                    if device.availability == .ready || access == .control {
                                        Text("View and Control").tag(PeerDeviceAccess.control as PeerDeviceAccess?)
                                    }
                                }
                                .labelsHidden()
                                .accessibilityLabel("\(client.name) access to \(device.name)")
                            }
                        }
                    }
                }
            }
        }
        .onAppear { state.peerDeviceSettingsVisibilityChanged(true) }
        .onDisappear { state.peerDeviceSettingsVisibilityChanged(false) }
    }

    private func description(for device: AppState.AndroidShare) -> String {
        switch device.availability {
        case .ready:
            if let name = state.peerDeviceDriverNames[device.id] { "\(name) is driving" } else { "Connected by USB" }
        case .absent: "Not connected by USB"
        case .unauthorized: "USB debugging needs authorization on the device"
        case .offline: "ADB reports this device is offline"
        case .interrupted: "The device stream was interrupted"
        }
    }
}
