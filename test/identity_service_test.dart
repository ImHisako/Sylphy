import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/identity/identity_service.dart';
import 'package:sylphy/core/native/native_core.dart';

void main() {
  test(
    'loads the public identity through the native encrypted vault',
    () async {
      final supportDirectory = await Directory.systemTemp.createTemp(
        'sylphy-identity-service-test-',
      );
      addTearDown(() => supportDirectory.delete(recursive: true));
      final core = _IdentityNativeCore();
      final service = IdentityService(
        nativeCore: core,
        deviceSecretStore: _TestDeviceSecretStore(),
        applicationSupportDirectory: () async => supportDirectory,
      );
      addTearDown(service.dispose);

      await service.initialize();

      expect(service.snapshot.phase, IdentityPhase.ready);
      expect(service.snapshot.identityId, 'AAAA BBBB CCCC DDDD');
      expect(service.snapshot.invitationCode, startsWith('sylphy:'));
      expect(core.receivedVaultPassword, 'device-bound-test-secret');
      expect(core.receivedStorageDirectory, endsWith('native'));
    },
  );

  test(
    'does not retry a long inline invitation on a periodic timer',
    () async {
      final supportDirectory = await Directory.systemTemp.createTemp(
        'sylphy-identity-inline-test-',
      );
      addTearDown(() => supportDirectory.delete(recursive: true));
      final core = _IdentityNativeCore(invitationCode: 'sylphy:${'a' * 512}');
      final service = IdentityService(
        nativeCore: core,
        deviceSecretStore: _TestDeviceSecretStore(),
        applicationSupportDirectory: () async => supportDirectory,
      );
      addTearDown(service.dispose);

      await service.initialize();
      await Future<void>.delayed(const Duration(seconds: 11));

      expect(core.ensureIdentityCalls, 1);
      expect(service.snapshot.phase, IdentityPhase.ready);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

class _TestDeviceSecretStore implements DeviceSecretStore {
  @override
  Future<String> getOrCreate() async => 'device-bound-test-secret';
}

class _IdentityNativeCore implements NativeCoreApi {
  _IdentityNativeCore({this.invitationCode = 'sylphy:signed-public-bundle'});

  final String invitationCode;
  int ensureIdentityCalls = 0;

  @override
  NativeCoreResponse sendAttachment({
    required String conversationId,
    required String fileName,
    required String bytesBase64,
  }) => throw UnimplementedError();
  String? receivedStorageDirectory;
  String? receivedVaultPassword;

  @override
  NativeCoreResponse ensureIdentity({
    required String storageDirectory,
    required String vaultPassword,
    String? displayName,
    String? avatarBase64,
  }) {
    ensureIdentityCalls += 1;
    receivedStorageDirectory = storageDirectory;
    receivedVaultPassword = vaultPassword;
    return NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {
        'identity_id': 'AAAA BBBB CCCC DDDD',
        'invitation_code': invitationCode,
        'expires_at_ms': 1800000000000,
      },
    );
  }

  @override
  NativeCoreResponse addContact({
    required String displayName,
    required String invitationCode,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse sendText({
    required String conversationId,
    required String plaintext,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse markConversationRead(String conversationId) =>
      throw UnimplementedError();

  @override
  NativeCoreResponse deleteConversation(String conversationId) =>
      throw UnimplementedError();

  @override
  NativeCoreResponse setContactVerified({
    required String conversationId,
    required bool verified,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse listConversations() => throw UnimplementedError();

  @override
  NativeCoreResponse listMessages(String conversationId) =>
      throw UnimplementedError();

  @override
  NativeCoreResponse startVeilid(String storageDirectory) =>
      throw UnimplementedError();

  @override
  NativeCoreResponse status() => throw UnimplementedError();

  @override
  NativeCoreResponse stopVeilid() => throw UnimplementedError();

  @override
  NativeCoreResponse veilidStatus() => throw UnimplementedError();

  @override
  NativeCoreResponse verifyDoubleRatchet() => throw UnimplementedError();

  @override
  NativeCoreResponse verifyHybridPrimitives() => throw UnimplementedError();
}
