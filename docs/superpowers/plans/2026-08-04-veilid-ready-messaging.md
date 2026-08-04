# Veilid-Ready Messaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a Windows, Linux, and Android Sylphy client in which two people exchange a verified private invitation and send ratcheted, end-to-end encrypted messages over Veilid private routes with DHT mailbox fallback.

**Architecture:** Flutter owns interaction, Veilid lifecycle, DHT calls, and network status through the official `veilid` Flutter package. A native Rust `SecureCore` owns the vault, identities, invitation protocol, session state, message envelope validation, mailbox credentials, and Double Ratchet adapter. The Dart coordinator only exchanges typed commands and opaque envelopes with these boundaries.

**Tech Stack:** Flutter 3.44+, Dart 3.10+, `veilid` 0.5.7, Rust 1.89+, `veilid-core` 0.5.7, `libsignal` pinned source/release under AGPL-3.0, Argon2id, XChaCha20-Poly1305, Ed25519, X25519, ML-KEM-768, HKDF-SHA-256.

## Global Constraints

- Retain AGPL-3.0 compatibility for all distributed source and `libsignal` integration.
- Use `veilid` exactly at 0.5.7 and align the native `veilid-core` dependency to 0.5.7.
- Support Windows, Linux, and Android; do not claim a platform release until it builds and two-node integration tests run there.
- Use only private-route targets and safe routing contexts for `AppMessage`; never target a NodeId.
- Flutter persists no vault, ratchet, identity, ML-KEM, or DHT writer key material.
- Never log plaintext, envelope ciphertext, route blobs, private keys, passwords, or DHT writer capabilities.
- Do not add a global user directory, username search, groups, large attachments, push notifications, read receipts, backup, or multi-device sync.
- Do not implement a custom Double Ratchet. If the supported `libsignal` API cannot initialize from the hybrid root secret, stop before enabling real messaging.
- Keep the working tree uncommitted unless the user explicitly requests a commit.

---

## File Structure

- `lib/core/veilid/veilid_gateway.dart`: the only Flutter-facing wrapper around the official Veilid API.
- `lib/core/veilid/veilid_gateway_test.dart`: fake-backed lifecycle, route, DHT, and callback tests.
- `lib/core/messaging/messaging_models.dart`: application-level contact, invitation, delivery, and node-state DTOs.
- `lib/core/messaging/sylphy_messaging_bridge.dart`: production `SecureMessagingBridge` backed by `NativeCoreClient` and `VeilidGateway`.
- `lib/core/messaging/messaging_coordinator.dart`: route, mailbox, retry, deduplication, and UI-state orchestrator.
- `lib/features/onboarding/onboarding_flow.dart`: vault create/unlock and node-start user flow.
- `lib/features/invites/invite_flow.dart`: create, import, inspect, verify, accept, and revoke invitation flows.
- `native/core/src/identity.rs`: vault-owned local identity, public bundle, and fingerprint operations.
- `native/core/src/invite.rs`: versioned invite serialization, signature checks, expiry, reuse, and acceptance logic.
- `native/core/src/mailbox.rs`: mailbox epoch descriptors, recipient/writer credentials, slot allocation, and idempotency indices.
- `native/core/src/session.rs`: protocol-facing session state, hybrid bootstrap transcript, and ratchet-provider interface.
- `native/core/src/libsignal_adapter.rs`: isolated `libsignal` bridge, compiled only after its hybrid-seed capability is proved.
- `native/core/src/ffi.rs`: versioned JSON ABI commands, command-specific DTOs, and sanitized errors.
- `native/core/tests/*.rs`: deterministic security-contract and two-core interoperability tests.
- `integration_test/`: device-level Flutter tests that exercise two nodes without the demo bridge.

## Task 1: Enable the supported platform and Veilid dependency baseline

**Files:**
- Modify: `pubspec.yaml`
- Modify: `native/core/Cargo.toml`
- Modify: `README.md`
- Create: `linux/CMakeLists.txt` and generated Linux runner files through Flutter tooling
- Test: `test/platform_support_test.dart`

**Interfaces:**
- Consumes: existing Flutter Android/Windows project and native core crate.
- Produces: a project with Android, Windows, and Linux runners and a locked `veilid: 0.5.7` dependency.

- [ ] **Step 1: Add a failing platform capability test**

```dart
test('advertises exactly the supported native targets', () {
  expect(SupportedPlatforms.current, containsAll(<String>['android', 'windows', 'linux']));
  expect(SupportedPlatforms.current, isNot(contains('web')));
});
```

- [ ] **Step 2: Run the test to verify the missing production platform declaration**

Run: `flutter test test/platform_support_test.dart`

Expected: FAIL because `SupportedPlatforms` does not exist.

- [ ] **Step 3: Add platform setup and dependency locks**

Run `flutter create --platforms=android,linux,windows .`, add `veilid: 0.5.7` through an exact git or path dependency locked to the upstream 0.5.7 tag, and create `lib/core/platform/supported_platforms.dart` with the exact three platform names. Preserve `veilid-core = "=0.5.7"` in `native/core/Cargo.toml`; remove the previous optional Rust Veilid lifecycle adapter only after Task 2 owns the lifecycle in Flutter.

- [ ] **Step 4: Pass the focused test and resolve dependencies**

Run: `flutter pub get; flutter test test/platform_support_test.dart; flutter analyze`

Expected: dependency resolution succeeds and the focused test passes.

- [ ] **Step 5: Record reproducible build prerequisites**

Document Flutter 3.44+, Dart 3.10+, Rust 1.89+, Android NDK required by Veilid 0.5.7, Visual Studio Desktop C++ for Windows, and a C++ toolchain for Linux in `README.md`.

## Task 2: Create a safe, disposable Veilid gateway

**Files:**
- Create: `lib/core/veilid/veilid_gateway.dart`
- Create: `lib/core/veilid/veilid_gateway_test.dart`
- Modify: `lib/main.dart`
- Modify: `lib/core/native/native_core.dart`

**Interfaces:**
- Consumes: `Veilid.instance`, `VeilidConfig`, `VeilidUpdate`, `VeilidRoutingContext`, `RouteBlob`, and `RouteId` from `package:veilid/veilid.dart`.
- Produces: `abstract interface class VeilidGateway` with `start`, `stop`, `networkStates`, `updates`, `allocatePrivateRoute`, `importPrivateRoute`, `releasePrivateRoute`, `sendAppMessage`, `openRecord`, `readSubkey`, `writeSubkey`, `watchRecord`, and `closeRecord`.

- [ ] **Step 1: Write gateway lifecycle and disposal tests**

```dart
test('starts once, attaches once, and closes route resources', () async {
  final api = FakeVeilidApi();
  final gateway = VeilidFlutterGateway(api: api);
  await gateway.start();
  await gateway.start();
  final route = await gateway.allocatePrivateRoute();
  await gateway.releasePrivateRoute(route.routeId);
  await gateway.stop();
  expect(api.calls, <String>['initialize', 'startup', 'attach', 'newRoute', 'releaseRoute', 'detach', 'shutdown']);
});
```

- [ ] **Step 2: Run the gateway test to verify the adapter is absent**

Run: `flutter test lib/core/veilid/veilid_gateway_test.dart`

Expected: FAIL because `VeilidFlutterGateway` and `FakeVeilidApi` do not exist.

- [ ] **Step 3: Implement the wrapper and update mapping**

Initialize Veilid only in `start`, call `startupVeilidCore`, subscribe to its update stream before `attach`, and map `VeilidUpdateAttachment`, `VeilidUpdateAppMessage`, `VeilidUpdateRouteChange`, and `VeilidUpdateValueChange` into sealed Sylphy events. Every routing context must be obtained with `safeRoutingContext`, closed in `finally`, and send only `Target.routeId`. Allocate/import/release private routes and open/close DHT records in matching pairs.

- [ ] **Step 4: Reject unsafe send and preserve DHT write semantics**

Add tests that `sendAppMessage` rejects node-id targets before reaching the Veilid API, that every route and DHT record is released, and that `writeSubkey` returns a deferred state when Veilid accepts an offline write.

- [ ] **Step 5: Run the gateway suite**

Run: `flutter test lib/core/veilid/veilid_gateway_test.dart; flutter analyze`

Expected: all gateway tests pass and analysis has no issues.

## Task 3: Define application protocol DTOs and delivery state

**Files:**
- Create: `lib/core/messaging/messaging_models.dart`
- Modify: `lib/core/messaging/models.dart`
- Create: `test/messaging_models_test.dart`
- Modify: `lib/features/messenger/messenger_home.dart`

**Interfaces:**
- Consumes: current `Conversation`, `ChatMessage`, and delivery UI.
- Produces: `NodeState`, `InviteState`, `VerificationState`, `MailboxState`, `DeliveryState.queued`, `DeliveryState.synchronized`, `ContactRecordRef`, `MailboxEpochRef`, and `InvitePreview`.

- [ ] **Step 1: Write model validation tests**

```dart
test('does not enable a composer before session verification', () {
  final status = ContactRuntimeState(
    node: NodeState.attached,
    invite: InviteState.accepted,
    verification: VerificationState.pending,
    session: SessionState.none,
  );
  expect(status.canSend, isFalse);
});
```

- [ ] **Step 2: Run the model test to establish the missing state machine**

Run: `flutter test test/messaging_models_test.dart`

Expected: FAIL because `ContactRuntimeState` does not exist.

- [ ] **Step 3: Implement immutable state and presentation mapping**

Add the DTOs with constructors that reject empty IDs, unsupported protocol versions, and invalid enum combinations. Extend `ChatMessage.copyWith` and the chat UI to render only `queued`, `synchronized`, and `secure failure` delivery status; remove the demo-only `read` claim from production state.

- [ ] **Step 4: Verify state transitions and UI labels**

Run: `flutter test test/messaging_models_test.dart test/widget_test.dart`

Expected: transitions are deterministic and existing shell rendering remains intact.

## Task 4: Add identity, invite, and mailbox contracts to the Rust core

**Files:**
- Create: `native/core/src/identity.rs`
- Create: `native/core/src/invite.rs`
- Create: `native/core/src/mailbox.rs`
- Modify: `native/core/src/lib.rs`
- Modify: `native/core/src/error.rs`
- Modify: `native/core/src/ffi.rs`
- Create: `native/core/tests/invite_contract.rs`
- Create: `native/core/tests/mailbox_contract.rs`

**Interfaces:**
- Consumes: `vault`, `bundle`, `hybrid`, `envelope`, `CoreError`, and current C JSON ABI.
- Produces: `create_identity`, `unlock_vault`, `create_invite`, `inspect_invite`, `confirm_invite`, `create_mailbox_epoch`, `next_mailbox_slot`, `accept_envelope`, and `list_safe_state` ABI commands.

- [ ] **Step 1: Write deterministic invitation security tests**

```rust
#[test]
fn invite_rejects_expiry_tampering_and_second_use() {
    let fixture = InviteFixture::new();
    let invite = fixture.create_invite(1_000).expect("invite");
    assert!(fixture.inspect(&invite, 1_001).is_err());
    assert!(fixture.consume(&invite, 999).is_ok());
    assert!(fixture.consume(&invite, 999).is_err());
}
```

- [ ] **Step 2: Write mailbox schema and idempotency tests**

```rust
#[test]
fn mailbox_reuses_the_same_slot_for_a_message_retry() {
    let mut mailbox = MailboxEpoch::for_test();
    let first = mailbox.reserve_slot([7; 16]).expect("first reservation");
    let retry = mailbox.reserve_slot([7; 16]).expect("retry reservation");
    assert_eq!(first, retry);
}
```

- [ ] **Step 3: Run the core tests to verify the missing protocol**

Run: `rustup run stable-x86_64-pc-windows-gnu cargo test --manifest-path native/core/Cargo.toml --no-default-features`

Expected: FAIL because invitation and mailbox modules are absent.

- [ ] **Step 4: Implement versioned, bounded native DTOs**

Use canonical CBOR for `InviteV1`, include `protocol_version`, 16-byte `invite_id`, expiration, public bundle, contact record key, reply writer capability, fingerprint commitment, and Ed25519 signature. Reject all malformed lengths before cryptographic work. Make `MailboxEpoch` allocate fixed message, receipt, and rotation ranges; emit only opaque `MailboxEpochRef` and single-use writer capabilities for the gateway call. Persist identity, invite-use marker, mailbox credentials, and indices only through the encrypted vault.

- [ ] **Step 5: Expose sanitized ABI responses**

Expand `CoreRequest` and response data so no success path returns passwords, private keys, root keys, chain keys, ciphertext, raw route blobs, or writer capabilities in `status` calls. Map all security failures to stable public error codes.

- [ ] **Step 6: Run native contract and formatting checks**

Run: `cargo fmt --manifest-path native/core/Cargo.toml -- --check; rustup run stable-x86_64-pc-windows-gnu cargo test --manifest-path native/core/Cargo.toml --no-default-features`

Expected: all existing and new contract tests pass.

## Task 5: Implement the libsignal feasibility gate before real session enablement

**Files:**
- Create: `native/core/src/session.rs`
- Create: `native/core/src/libsignal_adapter.rs`
- Modify: `native/core/Cargo.toml`
- Modify: `native/core/src/ffi.rs`
- Create: `native/core/tests/libsignal_interop.rs`
- Modify: `docs/superpowers/specs/2026-08-04-veilid-ready-messaging-design.md`

**Interfaces:**
- Consumes: the 32-byte hybrid root secret, local and remote ratchet public material, encrypted vault persistence, and a pinned `libsignal` source/release.
- Produces: `trait RatchetProvider`, `LibsignalRatchetProvider`, `create_session`, `seal_message`, `open_message`, `session_state`, and a binary capability report that is false until interoperability passes.

- [ ] **Step 1: Write the two-core interoperability test first**

```rust
#[test]
fn libsignal_session_round_trips_with_a_hybrid_seed() {
    let (mut alice, mut bob) = paired_test_sessions();
    let first = alice.seal(b"hello").expect("seal");
    assert_eq!(bob.open(&first).expect("open"), b"hello");
    let reply = bob.seal(b"world").expect("seal");
    assert_eq!(alice.open(&reply).expect("open"), b"world");
}
```

- [ ] **Step 2: Run the test to make the release blocker visible**

Run: `cargo test --manifest-path native/core/Cargo.toml --test libsignal_interop`

Expected: FAIL because `RatchetProvider` is absent.

- [ ] **Step 3: Pin and audit the upstream dependency**

Add the exact `libsignal` release or commit, record its license and source checksum in `native/THIRD_PARTY_NOTICES.md`, and compile the adapter for the host before wiring it to the message path. Do not use unpublished internals or copy Double Ratchet logic from the specification.

- [ ] **Step 4: Implement only the supported libsignal initialization path**

Implement `LibsignalRatchetProvider::from_hybrid_seed` only if the supported upstream API accepts the hybrid root secret and remote ratchet material. Store provider state encrypted through the vault and expose no provider handles to Dart. If the upstream public API cannot satisfy this constructor, retain `ratchet: "provider-required"`, make the interoperability test fail with an explicit capability error, and stop the real-messaging tasks pending a reviewed protocol decision.

- [ ] **Step 5: Prove forward and out-of-order behavior**

Add tests for unique message keys, replay rejection, a bounded skipped-key window, reordered delivery, corrupted header rejection, and vault restore of a valid session. Use two independent core instances and assert neither test API returns secret fields.

- [ ] **Step 6: Gate all later real send paths**

Run: `cargo test --manifest-path native/core/Cargo.toml --test libsignal_interop; cargo test --manifest-path native/core/Cargo.toml --no-default-features`

Expected: both commands pass before any production bridge replaces the demo bridge.

## Task 6: Connect invite records and DHT mailbox operations to VeilidGateway

**Files:**
- Create: `lib/core/messaging/mailbox_repository.dart`
- Create: `lib/core/messaging/mailbox_repository_test.dart`
- Modify: `lib/core/veilid/veilid_gateway.dart`
- Modify: `lib/core/native/native_core.dart`
- Modify: `native/core/src/ffi.rs`

**Interfaces:**
- Consumes: `VeilidGateway`, `ContactRecordRef`, `MailboxEpochRef`, bounded native commands, and Veilid `DHTSchemaSMPL` records.
- Produces: `Future<InvitePreview> importInvite(Uri invite)`, `Future<void> publishAcceptance(...)`, `Future<DeliveryAttempt> enqueueEnvelope(...)`, and `Stream<InboundEnvelope>`.

- [ ] **Step 1: Write the offline-write and watch behavior test**

```dart
test('writes an opaque envelope to the mailbox when the private route is unavailable', () async {
  final gateway = FakeVeilidGateway(routeAvailable: false);
  final repository = MailboxRepository(gateway: gateway, core: FakeNativeCore.ready());
  final result = await repository.deliver(opaqueEnvelope());
  expect(result, DeliveryAttempt.queued);
  expect(gateway.writtenValues.single, opaqueEnvelope().bytes);
});
```

- [ ] **Step 2: Run the test to demonstrate the missing fallback**

Run: `flutter test lib/core/messaging/mailbox_repository_test.dart`

Expected: FAIL because `MailboxRepository` does not exist.

- [ ] **Step 3: Implement contact-record and mailbox state machines**

Create and open `DHTSchemaSMPL` contact/mailbox records with the owner and member ranges provided by `SecureCore`. Watch contact and active mailbox subkeys. For every received `ValueChange`, fetch the specified value, validate it through the core, and mark it consumed only after core acceptance. On route failure, preserve the exact envelope and `message_id`, call `setDHTValue`, then wait with `flushDHTRecord` only when user-visible delivery confirmation needs it.

- [ ] **Step 4: Implement route rotation and resource cleanup**

On `VeilidUpdateRouteChange`, release stale route IDs, reload the signed contact record, import a non-empty new route blob, and emit a suspended state if reimport fails. Close DHT records and cancel watches when a contact is revoked or the app stops.

- [ ] **Step 5: Prove retry and duplicate handling**

Add tests for same-message retry, deferred offline DHT write, duplicate `ValueChange`, stale route, empty rotated blob, and `closeRecord` cleanup.

- [ ] **Step 6: Run the repository suite**

Run: `flutter test lib/core/messaging/mailbox_repository_test.dart lib/core/veilid/veilid_gateway_test.dart; flutter analyze`

Expected: fallback, retries, route rotation, and disposal tests pass.

## Task 7: Replace the demo bridge only when the ratchet capability is ready

**Files:**
- Create: `lib/core/messaging/sylphy_messaging_bridge.dart`
- Create: `lib/core/messaging/sylphy_messaging_bridge_test.dart`
- Modify: `lib/core/messaging/secure_messaging_bridge.dart`
- Modify: `lib/main.dart`
- Modify: `lib/features/messenger/messenger_home.dart`

**Interfaces:**
- Consumes: `NativeCoreClient`, `MailboxRepository`, `ContactRuntimeState`, and the `libsignal` capability report.
- Produces: `SylphyMessagingBridge implements SecureMessagingBridge`, `Stream<MessagingSnapshot> snapshots`, and `Future<DeliveryState> sendText(...)`.

- [ ] **Step 1: Write a send refusal test**

```dart
test('never forwards plaintext when verification or ratchet support is missing', () async {
  final bridge = SylphyMessagingBridge(core: FakeNativeCore.ratchetUnavailable(), mailbox: FakeMailbox());
  await expectLater(
    bridge.sendText(conversationId: 'contact', plaintext: 'secret'),
    throwsA(isA<SecureMessagingException>()),
  );
  expect(FakeMailbox.lastEnvelope, isNull);
});
```

- [ ] **Step 2: Run the bridge test before implementation**

Run: `flutter test lib/core/messaging/sylphy_messaging_bridge_test.dart`

Expected: FAIL because the production bridge is absent.

- [ ] **Step 3: Implement snapshot-driven production messaging**

Make `SylphyMessagingBridge` call native commands to seal/open messages and use `MailboxRepository` only with returned opaque bytes. Map verified plaintext to `ChatMessage` only after native acceptance. Retain `LocalDemoMessagingBridge` for explicit widget preview injection, but make `main.dart` select it only in debug preview mode; release initialization fails closed if native or ratchet capability is absent.

- [ ] **Step 4: Implement delivery and error mapping**

Map route dispatch to `synchronized`, mailbox fallback to `queued`, receipt acceptance to `synchronized`, and security/network failures to a generic non-sensitive UI state. Disable the composer whenever `ContactRuntimeState.canSend` is false.

- [ ] **Step 5: Run bridge and existing widget tests**

Run: `flutter test lib/core/messaging/sylphy_messaging_bridge_test.dart test/widget_test.dart; flutter analyze`

Expected: production bridge passes, preview bridge stays test-only, and UI remains analyzable.

## Task 8: Build onboarding, invitation verification, and contact-management UI

**Files:**
- Create: `lib/features/onboarding/onboarding_flow.dart`
- Create: `lib/features/invites/invite_flow.dart`
- Create: `lib/features/contacts/contact_security_sheet.dart`
- Create: `test/onboarding_flow_test.dart`
- Create: `test/invite_flow_test.dart`
- Modify: `lib/features/messenger/messenger_home.dart`

**Interfaces:**
- Consumes: `MessagingSnapshot`, `InvitePreview`, `ContactRuntimeState`, and bridge commands.
- Produces: create/unlock-vault flow, QR/link creation, clipboard import, fingerprint confirmation, and revoke controls.

- [ ] **Step 1: Write widget tests for secure gating**

```dart
testWidgets('keeps the acceptance action disabled until the safety code is confirmed', (tester) async {
  await tester.pumpWidget(InviteFlow(preview: verifiedPreview, bridge: FakeBridge()));
  expect(find.byKey(const ValueKey('accept-invite')), findsOneWidget);
  expect(tester.widget<FilledButton>(find.byKey(const ValueKey('accept-invite'))).onPressed, isNull);
  await tester.tap(find.byKey(const ValueKey('confirm-safety-code')));
  await tester.pump();
  expect(tester.widget<FilledButton>(find.byKey(const ValueKey('accept-invite'))).onPressed, isNotNull);
});
```

- [ ] **Step 2: Run the UI test before implementing the flow**

Run: `flutter test test/onboarding_flow_test.dart test/invite_flow_test.dart`

Expected: FAIL because the flows are absent.

- [ ] **Step 3: Implement the flows without secrets in widgets**

Render node attachment with neutral labels, create and display only an encoded invitation QR/link, import a URI through camera/clipboard adapters, display a short safety code, and require explicit confirmation. Show `queued`, `synchronized`, route-refresh, generic security failure, and revoked states in existing conversation UI. Never render NodeId, route blob, keys, or raw envelope data.

- [ ] **Step 4: Add revocation and offline queue coverage**

Test that revocation disables the composer and removes the contact from active routing, and that a queued message remains visible without exposing ciphertext.

- [ ] **Step 5: Run all UI tests and analysis**

Run: `flutter test test/onboarding_flow_test.dart test/invite_flow_test.dart test/widget_test.dart; flutter analyze`

Expected: invitation and state-gating flows pass without regressions.

## Task 9: Package native libraries and establish real two-node integration tests

**Files:**
- Modify: `native/build-android.ps1`
- Modify: `native/build-windows.ps1`
- Create: `native/build-linux.sh`
- Modify: `android/app/build.gradle.kts`
- Modify: `windows/CMakeLists.txt`
- Modify: `linux/CMakeLists.txt`
- Create: `integration_test/private_messaging_test.dart`
- Create: `scripts/run-two-node-integration.ps1`
- Create: `scripts/run-two-node-integration.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: built `veilid` code assets, `sylphy_core`, `libsignal` adapter, and production bridge.
- Produces: platform bundles that contain matching Veilid/core libraries and an integration runner able to launch two isolated Sylphy profiles.

- [ ] **Step 1: Write the end-to-end test scenario**

```dart
testWidgets('two verified profiles exchange one online and one offline message', (tester) async {
  final pair = await TwoNodeHarness.start();
  await pair.alice.createInvite();
  await pair.bob.importAndConfirm(pair.alice.invite);
  await pair.alice.confirm(pair.bob.safetyCode);
  await pair.alice.send('online');
  await pair.bob.stopNode();
  await pair.alice.send('offline');
  await pair.bob.startNode();
  await pair.untilSynchronized();
  expect(await pair.bob.messages(), containsAll(<String>['online', 'offline']));
});
```

- [ ] **Step 2: Run the integration test and capture the missing harness failure**

Run: `flutter test integration_test/private_messaging_test.dart`

Expected: FAIL because `TwoNodeHarness` and packaged native libraries are absent.

- [ ] **Step 3: Package all platform-native artifacts**

Build Android ABI libraries with the Veilid-required NDK, package Windows DLLs through CMake, and package Linux shared libraries through CMake. Each script verifies the expected `veilid` and `sylphy_core` versions before copying artifacts. Android Gradle must package the architecture-specific `libsignal` artifacts with incompatible Windows/macOS artifacts excluded.

- [ ] **Step 4: Implement isolated two-profile execution**

Make harness profiles use separate temporary storage/configuration directories, distinct vault passwords, and one attached Veilid node each. Keep logs at error level and assert captured logs contain neither plaintext nor capability strings.

- [ ] **Step 5: Run the platform matrix**

Run on available hosts or devices:

```text
Windows <-> Linux: private invite, online send, offline mailbox send, route rotation.
Windows <-> Android: private invite, online send, offline mailbox send, app restart.
Linux <-> Android: private invite, duplicate delivery, reorder, revocation.
```

Expected: all scenarios pass with no duplicate rendered message and both mailbox queues drain.

- [ ] **Step 6: Perform release verification**

Run: `flutter test; flutter analyze; cargo fmt --manifest-path native/core/Cargo.toml -- --check; cargo test --manifest-path native/core/Cargo.toml; flutter build windows; flutter build linux; flutter build apk --release`

Expected: all commands exit 0 only after all host toolchains and native artifacts are configured. Report any unavailable platform toolchain as a release blocker rather than an application success.

## Task 10: Align specifications, threat model, and operator guidance with implementation

**Files:**
- Modify: `README.md`
- Modify: `native/README.md`
- Modify: `specs/flutter-client.md`
- Modify: `specs/native-core.md`
- Create: `specs/private-invite.md`
- Create: `specs/mailbox-protocol.md`
- Create: `specs/threat-model.md`
- Create: `native/THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Consumes: implemented wire formats, ABI commands, platform build commands, and test evidence.
- Produces: source-of-truth protocol documents and build/operator instructions that match shipped behavior.

- [ ] **Step 1: Write documentation assertions before editing prose**

```text
Required protocol assertions:
1. A QR/link is private contact discovery, not a global username.
2. A contact is inactive until both people confirm the safety code.
3. Veilid receives only opaque application envelopes.
4. DHT writer capabilities are per-contact, per-epoch, and never logged.
5. A library/toolchain/platform failure blocks release claims.
```

- [ ] **Step 2: Update protocol and threat-model documents**

Specify every `InviteV1`, contact-record, mailbox-epoch, envelope, receipt, error, rotation, retry, and revocation field; document size limits, version rules, security properties, known metadata exposure, and the lack of push notifications/read receipts.

- [ ] **Step 3: Update installation and licensing guidance**

List exact Veilid/libsignal versions, AGPL notices, Android NDK/JDK requirements, Windows and Linux toolchains, artifact locations, test commands, and how to run two isolated local profiles.

- [ ] **Step 4: Verify documentation matches code**

Run: `rg -n "LocalDemoMessagingBridge|provider-required|NodeId|veilid-core" README.md native/README.md specs docs; git diff --check`

Expected: demo-only references are explicitly test-preview-only, production paths are documented correctly, and the diff has no whitespace errors.
