# Remote QR Address Picker Design

## Context

The Remote settings pane can expose multiple advertised URLs for the same
remote server: LAN, localhost, tailnet, or custom hostnames. The current UI lets
each address row copy its URL and contains a separate "Use for QR" action. The
selected state is only shown as a small checkmark on the row, while the actual
"Pair a device" action lives lower in the section.

That makes the pairing QR target easy to miss. The user should be able to tell,
before generating or scanning a QR code, which advertised URL the QR will encode.

## Goal

Make the QR target explicit by adding a dedicated address selector near the
pairing action. The control should preserve the existing persisted
`remote.preferredAdvertisedHost` behavior and keep URL rows useful for copying.

## Design

When remote control is enabled and advertised addresses are available, the pane
shows a new settings row between the address list and the "PWA install" / "Pair a
device" rows:

- Row title: `Pairing QR address`
- Row description: `QR will use <label>: <url>`
- Row control: a segmented `Picker` containing each available advertised address
  label, such as `LAN`, `Localhost`, `Tailnet`, or `Custom`

Selecting a segment immediately saves that address as
`state.config.remote.preferredAdvertisedHost`, calls the same refresh path used
by the existing row action, and causes future pairing URLs to use the selected
address.

The individual advertised address rows remain visible, but they stop carrying
selection controls. Each row shows the address label, URL description, and a
`Copy` action only. This separates URL inspection/copying from QR target
selection.

If no advertised addresses are available, the existing fallback behavior remains
simple: the pairing URL uses `http://localhost:<port>`, and no segmented selector
is shown.

## QR Behavior

The QR URL continues to be derived through the existing `pairingURL(port:)`
flow. Because that function already reads `selectedAddress()`, changing the
preferred host updates newly generated QR codes and also affects the automatic
QR refresh while a code is visible.

## Testing

Add focused Swift Testing coverage for the pure selection behavior if a practical
test seam already exists around remote advertised addresses. Otherwise verify
with a focused macOS build and manual settings-pane inspection:

- Remote enabled with multiple advertised addresses shows the segmented selector.
- Changing the segment updates the persisted preferred host.
- Generated QR uses the selected address.
- URL rows still copy their exact URLs.
- Fallback localhost behavior still works when there are no advertised addresses.
