import AlasRemoteKit
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

    init(hub: HostHub, prefilledOrigins: [String] = []) {
        self.hub = hub
        self.prefilledOrigins = prefilledOrigins
        _address = State(initialValue: prefilledOrigins.first ?? "")
        _method = State(initialValue: !prefilledOrigins.isEmpty ? .address : Self.canScan ? .scan : .link)
    }

    private static var canScan: Bool {
        DataScannerViewController.isSupported
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $method) {
                        if Self.canScan { Text("Scan").tag(Method.scan) }
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
                        if pairing != nil {
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
            QRScannerView { scanned in
                guard pairing == nil else { return }
                pair(link: scanned)
            }
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
            Text("\(help) Then copy the pairing link.")
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
        guard pairing == nil, canSubmit else { return }
        switch method {
        case .scan: break
        case .link: pair(link: link)
        case .address:
            guard let origin = addressOrigin else { return }
            pair(origins: [origin] + prefilledOrigins.filter { $0 != origin },
                 code: code.trimmingCharacters(in: .whitespaces))
        }
    }

    private func pair(link: String) {
        guard let parts = RemotePairingLink.parse(link) else {
            error = "That isn't an Alas pairing link."
            return
        }
        pair(origins: parts.origins, code: parts.code)
    }

    private func pair(origins: [String], code: String) {
        error = nil
        pairing = Task {
            defer { pairing = nil }
            do throws(RemotePairingError) {
                try await hub.pair(origins: origins, code: code)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
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
