import AlasRemoteKit
import AVFoundation
import SwiftUI
import VisionKit

/// Pairs a Mac by scanning its QR code, pasting its pairing link, or typing
/// an address and the code. `prefilledOrigins` comes from "Pair again".
struct PairHostView: View {
    private enum Method: Hashable {
        case scan, link, address
    }

    let hub: HostHub
    let prefilledOrigins: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var method: Method
    @State private var link = ""
    @State private var address: String
    @State private var code = ""
    @State private var error: String?
    @State private var pairing: Task<Void, Never>?
    /// Set once a code is redeemed: codes are single-use, so nothing may submit again while the
    /// sheet animates away.
    @State private var paired = false
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    /// The last scanned QR whose code the Mac rejected. VisionKit reports a code again each time
    /// it re-acquires it, and every redeem of a dead code spends the Mac's failed-attempt budget,
    /// which is shared by every client.
    @State private var rejectedScan: String?

    init(hub: HostHub, prefilledOrigins: [String] = []) {
        self.hub = hub
        self.prefilledOrigins = prefilledOrigins
        _address = State(initialValue: prefilledOrigins.first ?? "")
        let scannable = Self.canScan(AVCaptureDevice.authorizationStatus(for: .video))
        _method = State(initialValue: !prefilledOrigins.isEmpty ? .address : scannable ? .scan : .link)
    }

    /// Hidden when the camera is denied or restricted, where the scanner would
    /// be blank. Shown while undecided: picking Scan asks for access.
    private static func canScan(_ camera: AVAuthorizationStatus) -> Bool {
        DataScannerViewController.isSupported && (camera == .notDetermined || camera == .authorized)
    }

    /// Camera access was refused on this device, so Scan is gone.
    private var cameraRefused: Bool {
        DataScannerViewController.isSupported && (camera == .denied || camera == .restricted)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $method) {
                        if Self.canScan(camera) { Text("Scan").tag(Method.scan) }
                        Text("Link").tag(Method.link)
                        Text("Address").tag(Method.address)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch method {
                case .scan: scanSection
                case .link: linkSection
                case .address: addressSection
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                if method != .scan {
                    ToolbarItem(placement: .confirmationAction) {
                        if pairing != nil || paired {
                            ProgressView()
                        } else {
                            Button("Pair", action: submit).disabled(!canSubmit)
                        }
                    }
                }
            }
            .onChange(of: method) { error = nil }
            .onDisappear { pairing?.cancel() }
        }
    }

    private var scanSection: some View {
        Section {
            Group {
                if camera == .authorized {
                    QRScannerView { scanned in
                        guard scanned != rejectedScan else { return }
                        pair(link: scanned) { rejectedScan = scanned }
                    }
                } else {
                    ProgressView().task { await requestCamera() }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .overlay {
                if pairing != nil { ProgressView().controlSize(.large) }
            }
            .listRowInsets(EdgeInsets())
        } footer: {
            Text(help)
        }
    }

    private var linkSection: some View {
        Section {
            TextField("Pairing link", text: $link, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.callout.monospaced())
                .onSubmit(submit)
            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else { return }
                link = pasted
                submit()
            }
            .labelStyle(.titleAndIcon)
        } footer: {
            Text(cameraRefused
                ? "Camera access is off, so use the pairing link. \(help)"
                : "\(help) Then copy the pairing link.")
        }
    }

    private var addressSection: some View {
        Section {
            TextField("Address", text: $address, prompt: Text("192.168.1.20:8765"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
            TextField("Code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .onSubmit(submit)
        } footer: {
            Text("\(help) The code is shown under the QR.")
        }
    }

    private func requestCamera() async {
        guard camera == .notDetermined else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        camera = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
        if !granted { method = .link }
    }

    private var help: String {
        "On your Mac, open Alas Settings › Remote and click Show pairing QR."
    }

    private var canSubmit: Bool {
        switch method {
        case .scan: false
        case .link: !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .address: addressOrigin != nil && !code.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The typed address as an origin; `http://` is assumed when no scheme is given.
    private var addressOrigin: String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        return RemotePairingLink.normalizeOrigin(trimmed.contains("://") ? trimmed : "http://" + trimmed)
    }

    private func submit() {
        guard canSubmit else { return }
        switch method {
        case .scan: break
        case .link: pair(link: link)
        case .address:
            guard let origin = addressOrigin else { return }
            pair(origins: [origin] + prefilledOrigins.filter { $0 != origin },
                 code: code.trimmingCharacters(in: .whitespaces))
        }
    }

    private func pair(link: String, onRejected: @escaping () -> Void = {}) {
        guard pairing == nil, !paired else { return }
        guard let parts = RemotePairingLink.parse(link) else {
            error = "That isn't an Alas pairing link."
            return
        }
        pair(origins: parts.origins, code: parts.code, onRejected: onRejected)
    }

    /// Single-flight: every path (Pair, Return, Paste, a scan) funnels through here.
    private func pair(origins: [String], code: String, onRejected: @escaping () -> Void = {}) {
        guard pairing == nil, !paired else { return }
        error = nil
        pairing = Task {
            defer { pairing = nil }
            do throws(RemotePairingError) {
                try await hub.pair(origins: origins, code: code)
                paired = true
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                if error == .codeRejected { onRejected() }
                self.error = switch error {
                case .codeRejected: "That code was wrong or has expired. Make a new one on your Mac."
                case .originNotAllowed: "This Mac doesn't accept connections from this address."
                case .unreachable: "Couldn't reach your Mac. Check that you're on the same network or tailnet."
                }
            }
        }
    }
}

/// VisionKit's live QR scanner. Reports each new code's text.
private struct QRScannerView: UIViewControllerRepresentable {
    let onScan: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: @MainActor (String) -> Void

        init(onScan: @escaping @MainActor (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if let text = barcode.payloadStringValue { onScan(text) }
            }
        }
    }
}
