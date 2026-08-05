import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/messaging/sylphy_messaging_bridge.dart';
import 'package:sylphy/core/native/native_core.dart';

void main() {
  test('reads the empty native inbox without creating sample contacts', () {
    final bridge = SylphyMessagingBridge(core: _FakeNativeCore());

    expect(bridge.listConversations(), isEmpty);
    expect(bridge.listMessages('contact-1'), isEmpty);
  });

  test('sends plaintext only through the native secure core', () async {
    final core = _FakeNativeCore();
    final bridge = SylphyMessagingBridge(core: core);

    await bridge.sendText(conversationId: 'contact-1', plaintext: 'secret');
    expect(core.sentConversationId, 'contact-1');
    expect(core.sentPlaintext, 'secret');
  });

  test('imports contacts only through the native core', () async {
    final core = _FakeNativeCore();
    final bridge = SylphyMessagingBridge(core: core);

    final contactId = await bridge.addContact(
      displayName: 'Ada',
      invitationCode: 'signed-invitation',
    );

    expect(contactId, 'contact-verified');
    expect(core.importedName, 'Ada');
    expect(core.importedInvitation, 'signed-invitation');
  });

  test('sends attachment bytes only through the native secure core', () async {
    final core = _FakeNativeCore();
    final bridge = SylphyMessagingBridge(core: core);

    await bridge.sendAttachment(
      conversationId: 'contact-1',
      fileName: 'documento.txt',
      bytes: utf8.encode('contenuto'),
    );

    expect(core.sentAttachmentName, 'documento.txt');
    expect(base64Decode(core.sentAttachmentBase64!), utf8.encode('contenuto'));
  });
}

class _FakeNativeCore implements NativeCoreApi {
  @override
  NativeCoreResponse sendAttachment({
    required String conversationId,
    required String fileName,
    required String bytesBase64,
  }) {
    sentConversationId = conversationId;
    sentAttachmentName = fileName;
    sentAttachmentBase64 = bytesBase64;
    return const NativeCoreResponse(ok: true, code: 'ok', data: {});
  }

  String? importedName;
  String? importedInvitation;
  String? sentConversationId;
  String? sentPlaintext;
  String? sentAttachmentName;
  String? sentAttachmentBase64;

  @override
  NativeCoreResponse ensureIdentity({
    required String storageDirectory,
    required String vaultPassword,
    String? displayName,
    String? avatarBase64,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse addContact({
    required String displayName,
    required String invitationCode,
  }) {
    importedName = displayName;
    importedInvitation = invitationCode;
    return const NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {'contact_id': 'contact-verified'},
    );
  }

  @override
  NativeCoreResponse sendText({
    required String conversationId,
    required String plaintext,
  }) {
    sentConversationId = conversationId;
    sentPlaintext = plaintext;
    return const NativeCoreResponse(ok: true, code: 'ok', data: {});
  }

  @override
  NativeCoreResponse markConversationRead(String conversationId) =>
      const NativeCoreResponse(ok: true, code: 'ok', data: {});

  @override
  NativeCoreResponse deleteConversation(String conversationId) =>
      const NativeCoreResponse(ok: true, code: 'ok', data: {});

  @override
  NativeCoreResponse setContactVerified({
    required String conversationId,
    required bool verified,
  }) => const NativeCoreResponse(ok: true, code: 'ok', data: {});

  @override
  NativeCoreResponse listConversations() => const NativeCoreResponse(
    ok: true,
    code: 'ok',
    data: {
      'state': 'vault_locked',
      'can_send': false,
      'conversations': <Object>[],
    },
  );

  @override
  NativeCoreResponse listMessages(String conversationId) => NativeCoreResponse(
    ok: true,
    code: 'ok',
    data: {'conversation_id': conversationId, 'messages': const <Object>[]},
  );

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
