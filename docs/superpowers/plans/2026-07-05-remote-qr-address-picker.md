# Remote QR Address Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Remote settings pane clearly show and control which advertised URL is encoded into the pairing QR.

**Architecture:** Keep the existing `RemoteServerPane` as the owner of the UI behavior and persisted `remote.preferredAdvertisedHost` state. Replace per-address "Use for QR" controls with one segmented selector row whose binding writes the selected address host through the existing `chooseAddress(_:)` path. Keep QR generation routed through `pairingURL(port:)` so generated and auto-refreshed QR codes inherit the selected address.

**Tech Stack:** Swift 5.9+, SwiftUI for macOS settings UI, existing `RemoteAdvertisedAddress` and `AppConfig.Remote` persistence, Swift Testing only if a practical pure test seam is already present.

---

## File Structure

- Modify `Alas/Sources/Remote/Settings/RemoteServerPane.swift`
  - Add a dedicated `Pairing QR address` settings row.
  - Add a segmented `Picker` bound to the selected advertised address id.
  - Remove `Use for QR` buttons and selected checkmark from individual address rows.
  - Keep `Copy`, fallback localhost behavior, and QR generation behavior intact.

No new production file is needed because the change is tightly scoped to one settings pane. Do not alter unrelated settings infrastructure.

## Task 1: Add the Segmented QR Address Selector

**Files:**
- Modify: `Alas/Sources/Remote/Settings/RemoteServerPane.swift`

- [x] **Step 1: Inspect the current pane and address helpers**

Run:

```bash
rtk sed -n '1,260p' Alas/Sources/Remote/Settings/RemoteServerPane.swift
```

Expected: the file contains `ForEach(state.remoteAdvertisedAddresses)`, `chooseAddress(_:)`, `pairingURL(port:)`, and `selectedAddress()`.

- [x] **Step 2: Add the selector row after the advertised address rows**

In `RemoteServerPane.body`, inside `if state.config.remote.enabled, let port = state.remotePort`, after the `ForEach(state.remoteAdvertisedAddresses)` block and before `SettingsRow(name: "PWA install", ...)`, add:

```swift
if let selected = selectedAddress(), !state.remoteAdvertisedAddresses.isEmpty {
    SettingsRow(
        name: "Pairing QR address",
        desc: "QR will use \(addressLabel(selected)): \(selected.url)"
    ) {
        Picker("", selection: selectedAddressBinding()) {
            ForEach(state.remoteAdvertisedAddresses) { address in
                Text(addressLabel(address)).tag(address.id)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
```

This row must be shown only when advertised addresses exist. The fallback localhost-only state must not show a selector.

- [x] **Step 3: Replace per-row selection controls with Copy only**

In the `ForEach(state.remoteAdvertisedAddresses)` row control, replace the existing `HStack` containing the checkmark, `Copy`, and `Use for QR` button with this single `Copy` button:

```swift
Button {
    copyAddress(address.url)
} label: {
    Text("Copy")
        .font(.system(size: 12, weight: .medium))
}
.buttonStyle(.plain)
```

Also update the localhost fallback row's copy action to use the same helper:

```swift
copyAddress(fallbackURL)
```

- [x] **Step 4: Add the binding and copy helpers**

Near the existing private helper methods in `RemoteServerPane`, add:

```swift
private func selectedAddressBinding() -> Binding<String> {
    Binding(
        get: { selectedAddress()?.id ?? "" },
        set: { id in
            guard let address = state.remoteAdvertisedAddresses.first(where: { $0.id == id }) else { return }
            chooseAddress(address)
        }
    )
}

private func copyAddress(_ url: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(url, forType: .string)
}
```

Keep `chooseAddress(_:)`, `pairingURL(port:)`, and `selectedAddress()` as the source of persisted selection and QR URL behavior.

- [x] **Step 5: Build the app**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits 0.

- [x] **Step 6: Self-review the UI logic**

Check:

```bash
rtk git diff -- Alas/Sources/Remote/Settings/RemoteServerPane.swift
```

Expected:

- `Use for QR` no longer appears.
- `Pairing QR address` appears exactly once.
- The segmented picker writes through `chooseAddress(_:)`.
- `pairingURL(port:)` still derives from `selectedAddress()`.
- No fallback localhost selector is shown when `remoteAdvertisedAddresses` is empty.

- [x] **Step 7: Commit**

Run:

```bash
rtk git add Alas/Sources/Remote/Settings/RemoteServerPane.swift
rtk git commit -m "feat: clarify remote qr address selection"
```

Expected: commit succeeds with only the Remote settings pane change.

## Task 2: Verify Focused Behavior and Plan Compliance

**Files:**
- Inspect: `docs/superpowers/specs/2026-07-05-remote-qr-address-picker-design.md`
- Inspect: `Alas/Sources/Remote/Settings/RemoteServerPane.swift`

- [x] **Step 1: Compare implementation to the design spec**

Run:

```bash
rtk sed -n '1,180p' docs/superpowers/specs/2026-07-05-remote-qr-address-picker-design.md
rtk sed -n '1,260p' Alas/Sources/Remote/Settings/RemoteServerPane.swift
```

Expected:

- Multiple advertised addresses show one segmented selector row.
- Address rows remain visible for inspection and copying.
- Selection persists through `remote.preferredAdvertisedHost`.
- QR URL continues through `pairingURL(port:)`.
- No extra remote behavior is introduced.

- [x] **Step 2: Run a focused build verification**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits 0.

- [x] **Step 3: Check the final diff**

Run:

```bash
rtk git diff HEAD~1..HEAD -- Alas/Sources/Remote/Settings/RemoteServerPane.swift
```

Expected: the final implementation commit contains only the selector row, simplified copy rows, and small helper methods.
