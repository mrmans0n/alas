# Remote Helper Toolchain

## Decision

The Alas remote helper is implemented in stable Rust and built with Cargo.
The build uses Rust's distributed targets directly. Linux artifacts link with
the `rust-lld` shipped in the pinned Rust toolchain; no additional compiler or
cross-linker toolchain is required.

The release matrix is:

- `x86_64-unknown-linux-musl`
- `aarch64-unknown-linux-musl`
- `x86_64-apple-darwin`
- `aarch64-apple-darwin`

Linux artifacts are statically linked against musl. macOS artifacts are
self-contained apart from Apple system libraries and frameworks. All four
artifacts are built on the macOS host that builds Alas and are bundled as
separate resources so the app can select one from the remote host's `uname`
result.

## Rationale

Rust provides mature JSON, native filesystem event, and child-process APIs for
the helper's planned responsibilities. In particular, the `notify` ecosystem
offers inotify on Linux and FSEvents on macOS without making Alas own those
bindings. Rust also produces small standalone binaries without introducing a
runtime on the remote host.

Go makes the basic cross-build matrix simpler, but its common filesystem
watcher uses kqueue rather than FSEvents on macOS and requires explicit watches
for every directory. Zig matches existing build infrastructure, but choosing
it for the helper would make Alas own more platform binding, event
normalization, JSON, and process-supervision code.

## Compatibility

The helper emits a JSON handshake containing `name`, `protocolVersion`, and
`binaryVersion`. The bundled manifest contains the same values. Alas only uses
a helper whose complete handshake matches the manifest; a host with previously
granted consent is upgraded automatically when either version changes.

Installation and upgrade remain optional accelerators. Declined, unsupported,
unreachable, or failed hosts continue through the existing remote-exec and
polling paths.

## Build Policy

`scripts/build-alas-helper.sh` owns the four-target matrix. The Rust toolchain,
target list, Cargo lockfile, helper sources, manifest, and build script are all
fingerprint inputs. Xcode builds reuse matching artifacts from `.build`.

The helper intentionally starts with only the handshake. RPC methods, file
watching, search, and helper-owned ACP processes belong to their follow-up
issues.
