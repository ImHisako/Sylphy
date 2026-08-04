import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/core/veilid/veilid_service.dart';

void main() {
  test('maps an attached native response without exposing routing data', () {
    const response = NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {
        'compiled': true,
        'running': true,
        'attachment_state': 'attached_good',
        'public_internet_ready': true,
        'live_peer_count': '7',
      },
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.attached);
    expect(snapshot.livePeerCount, 7);
    expect(response.data, isNot(contains('node_id')));
    expect(response.data, isNot(contains('route_blob')));
  });

  test('reports a missing native library truthfully', () {
    final service = VeilidService(nativeCore: null);
    addTearDown(service.dispose);

    expect(service.snapshot.phase, VeilidPhase.unavailable);
    expect(service.snapshot.title, 'Core Veilid non incluso');
  });

  test('starts the node in persistent application support storage', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'sylphy-veilid-test-',
    );
    addTearDown(() => supportDirectory.delete(recursive: true));
    final core = _FakeNativeCore();
    final service = VeilidService(
      nativeCore: core,
      applicationSupportDirectory: () async => supportDirectory,
    );
    addTearDown(service.dispose);

    await service.start();

    expect(service.snapshot.phase, VeilidPhase.attached);
    expect(core.storageDirectory, endsWith('${Platform.pathSeparator}veilid'));
    expect(Directory(core.storageDirectory!).existsSync(), isTrue);
  });

  test('keeps the native startup error code without sensitive details', () {
    const response = NativeCoreResponse(
      ok: false,
      code: 'feature_unavailable',
      data: {},
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.error);
    expect(snapshot.diagnosticCode, 'feature_unavailable');
    expect(snapshot.detail, contains('retry non può risolvere'));
  });

  test('distinguishes a retryable network startup failure', () {
    const response = NativeCoreResponse(
      ok: false,
      code: 'network_startup_failed',
      data: {},
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.error);
    expect(snapshot.diagnosticCode, 'network_startup_failed');
    expect(snapshot.detail, contains('nuovo tentativo automatico'));
  });

  test('identifies an Android protected-store startup failure', () {
    const response = NativeCoreResponse(
      ok: false,
      code: 'veilid_protected_store_failed',
      data: {},
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.error);
    expect(snapshot.detail, contains('Archivio sicuro Android'));
  });
}

class _FakeNativeCore implements NativeCoreApi {
  String? storageDirectory;

  @override
  NativeCoreResponse ensureIdentity({
    required String storageDirectory,
    required String vaultPassword,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse addContact({
    required String displayName,
    required String invitationCode,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse startVeilid(String storageDirectory) {
    this.storageDirectory = storageDirectory;
    return _attachedResponse;
  }

  @override
  NativeCoreResponse veilidStatus() => _attachedResponse;

  @override
  NativeCoreResponse stopVeilid() => const NativeCoreResponse(
    ok: true,
    code: 'ok',
    data: {
      'compiled': true,
      'running': false,
      'attachment_state': 'detached',
      'public_internet_ready': false,
      'live_peer_count': '0',
    },
  );

  @override
  NativeCoreResponse listConversations() => throw UnimplementedError();

  @override
  NativeCoreResponse listMessages(String conversationId) =>
      throw UnimplementedError();

  @override
  NativeCoreResponse status() => throw UnimplementedError();

  @override
  NativeCoreResponse verifyDoubleRatchet() => throw UnimplementedError();

  @override
  NativeCoreResponse verifyHybridPrimitives() => throw UnimplementedError();
}

const _attachedResponse = NativeCoreResponse(
  ok: true,
  code: 'ok',
  data: {
    'compiled': true,
    'running': true,
    'attachment_state': 'attached_good',
    'public_internet_ready': true,
    'live_peer_count': '4',
  },
);
