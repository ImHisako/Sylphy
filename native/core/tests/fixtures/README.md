# libsignal upgrade fixture

`libsignal-v0.105.0.json` was generated on 2026-10-16 with official libsignal
v0.105.0, commit `4beb029d8a941f81e7d9c6d8af1ed25a677569a8`, **before**
upgrading the dependency to v0.105.1. Its SHA-256 is
`647d41402ff0e68fca8c743148758ea194c78f56ff7bd2dcd6258e0f27974924`.
It contains the same disposable test scenarios as the older fixture. Both are
consumed by the current compatibility tests; neither may be regenerated with
the new dependency.

`libsignal-v0.102.1.json` was generated with official libsignal v0.102.1,
commit `ea42ed0ed3e2ae119282d98253c35a28cce02414`, before updating Sylphy's
dependency to v0.105.0. Every identity, private key and message is disposable
test material. These keys must never be used outside tests.

The fixture contains serialized identities, EC/signed/Kyber prekeys, a pending
prekey message and both sides of an established session. Bob has already
received a later message, leaving a skipped key for a delayed ciphertext. Alice
also has another ciphertext in transit. The tests consume the original bytes
without reserializing them with the new dependency first.

For the v0.105.0 upgrade, a separate local harness also linked both pinned
libsignal revisions in one process. It restored Alice with v0.102.1 and Bob with
v0.105.0, consumed the pending messages, then verified a new message and reply in
both directions. This supplements the fixture tests; it is not a device test.

To reproduce the v0.102.1 fixture, temporarily pin **both** the libsignal
dependency and the provider string to its original commit, resolve the lockfile,
then run:

```sh
cargo test --manifest-path native/core/Cargo.toml --features signal-ratchet \
  --test libsignal_compat generate_previous_version_fixture -- --ignored --exact
```

Restore the current dependency, provider and lockfile afterwards. Never refresh
this fixture with a newer library: doing so would lose the migration coverage.

To reproduce v0.105.0 instead, pin its original commit and provider, set
`SYLPHY_GENERATE_FIXTURE_VERSION=v0.105.0`, and run the same ignored generator.
The generator checks the runtime provider before writing the version-specific
file. Its default remains v0.102.1 for the older reproduction command.
