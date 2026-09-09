# Sylphy native core

`core` is a Rust library built as a `cdylib` for Windows, Linux and Android. It
exposes a small C ABI: `sylphy_core_abi_version`, `sylphy_core_call` and
`sylphy_core_free_string`.

The core implements and tests:

- Memory-hard Argon2id derivation and an XChaCha20-Poly1305 vault.
- Ed25519 bundle signatures, size validation and rejection of unsupported
  versions.
- HKDF-SHA-256 composition of X25519 and ML-KEM-768 shared secrets.
- Official Signal ratchet sessions with post-quantum prekeys, per-message keys,
  persistent state, replay rejection and out-of-order delivery.
- XChaCha20-Poly1305 envelopes with metadata bound as associated data.
- An encrypted persistent outbox, automatic delivery retries and encrypted
  contact mailboxes with acknowledgements after local persistence.
- An optional Veilid lifecycle, enabled with `--features veilid`, including
  startup, aggregate status, private routes, bounded `AppMessage` handling and
  deterministic shutdown.

The `signal-ratchet` feature uses official
[`signalapp/libsignal v0.102.1`](https://github.com/signalapp/libsignal/releases/tag/v0.102.1),
pinned to immutable commit `ea42ed0ed3e2ae119282d98253c35a28cce02414`.
The production path keeps identity, signed prekeys, Kyber prekeys and persistent
session stores inside the native boundary. Signal/PreKey ciphertexts travel
inside authenticated encrypted Sylphy packets, subject to the 32 KiB packet
limit. Account and individual session records are encrypted with the
device-bound key and replaced atomically. Failed decryptions restore the
previous ratchet state.

## Local build

Use Rust **1.93.1 or later**. Install `protoc` and make it available on `PATH`, or
set `PROTOC` to its executable path. Ubuntu provides the `protobuf-compiler`
package; on Windows, `protoc` can be installed through Chocolatey or WinGet.

From the repository root:

```powershell
cargo test --locked --manifest-path native/core/Cargo.toml --features signal-ratchet
cargo test --locked --manifest-path native/core/Cargo.toml --features veilid,signal-ratchet
cargo build --locked --manifest-path native/core/Cargo.toml --release --features veilid,signal-ratchet
```

The first test command exercises cryptography, persistent sessions and offline
packet handling without linking Veilid. The second enables the full native
integration. Running `cargo test` without features does not exercise libsignal.

Production builds must enable both `veilid` and `signal-ratchet`. Rebuild and
package the native libraries after any Rust dependency update; changing the
manifest does not update previously built `.dll` or `.so` files.

### Android

Install NDK `28.2.13676358`, Java 17, the required Rust targets and `cargo-ndk`,
then run `./native/build-android.ps1` from the repository root. Libraries are
written to `android/app/src/main/jniLibs/<abi>/`.

`MainActivity` loads the library and registers the Android `Context` required by
Veilid before `super.onCreate`, so the first Dart frame cannot precede JNI
setup. The context also adapts JNI names containing `/` to the dotted binary
names required by Android `ClassLoader`. The release manifest includes
`INTERNET`, `ACCESS_NETWORK_STATE` and `ACCESS_WIFI_STATE`. The native protected
store also requires `androidx.security:security-crypto 1.1.0` in the Android
bundle.

### Windows

Use Visual Studio 2022 Build Tools with the C++ workload and an MSVC Rust
toolchain for the Flutter `3.35.5` build. Run `./native/build-windows.ps1` from
the repository root. It produces `sylphy_core.dll` in `native/core/target/release`;
CMake includes it in the Flutter bundle when present.

### Linux

Run `bash ./native/build-linux.sh release` from the repository root. It produces
`libsylphy_core.so` in `native/core/target/release`, which the CMake runner
installs in `bundle/lib`.

## Native API and persistence

ABI v10 includes `ensure_identity`, `start_veilid`, `veilid_status`,
`stop_veilid`, `list_conversations`, `list_messages`, `sync_inbound`,
`add_contact`, `create_group` and `ratchet_self_test`.

`ensure_identity` keeps keys and seeds in an encrypted native record and
returns only the public ID and invitation. `add_contact` decodes and validates
the signed bundle in Rust, rejects expired or duplicate invitations and records
the contact as pending. `create_group` resolves and verifies each invitation,
saves members in `groups-v1.vault` and sends encrypted invitations using the
requested group-chat or professional-channel mode.

Offline contact mailboxes are separate from the account journal used to sync
linked devices. They retain up to 32 unacknowledged packets per device pair and
direction for up to 7 days, subject to DHT availability. The receiver acknowledges
only after saving the message and committing the Signal session. See
[`../specs/offline-delivery.md`](../specs/offline-delivery.md) for the protocol
and verification procedure.

Errors distinguish missing features, Android bootstrap, protected/local
storage, configuration, startup and attachment to the network without returning
potentially sensitive internal messages. Unvalidated plaintext, private keys,
NodeIds, private route internals and sensitive configuration stay in the core.
