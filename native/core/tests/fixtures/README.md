# libsignal upgrade fixture

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

To reproduce, temporarily pin **both** the libsignal dependency and the provider
string to the original v0.102.1 commit, resolve its lockfile, then run:

```sh
cargo test --manifest-path native/core/Cargo.toml --features signal-ratchet \
  --test libsignal_compat generate_previous_version_fixture -- --ignored --exact
```

Restore the current dependency, provider and lockfile afterwards. Never refresh
this fixture with a newer library: doing so would lose the migration coverage.
