# serve-sim native code

Swift and Objective-C from serve-sim, the iOS Simulator streamer in
[expo/expo-device-hub](https://github.com/expo/expo-device-hub/tree/main/packages/serve-sim),
under the Apache License 2.0 (`LICENSE`, `NOTICE`). The commit is in
`UPSTREAM_COMMIT`.

Alas's `AlasSimService` uses it to capture a booted simulator's framebuffer
and send it touches and keys. It loads Apple's private CoreSimulator and
SimulatorKit frameworks at runtime, so expect breakage with new Xcode
releases.

- `Sources/StreamingPolicy`, `Sources/CoreDeviceShim`: upstream modules, whole.
- `Sources/ServeSimCore`: the upstream `SimNative` files in
  `vendored-files.txt`, without the Node bindings, encoders, WebRTC and
  recording. `AlasSimulatorSession.swift` is Alas's and is the only public API.

Never edit the upstream files here. To update, run `./sync.sh <commit>`,
then build: `swift build --package-path ThirdParty/serve-sim-native`. If the
build needs another upstream file, add its name to `vendored-files.txt` and
sync again.
