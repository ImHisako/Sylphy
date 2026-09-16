import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/messaging/models.dart';
import 'package:sylphy/core/messaging/secure_messaging_bridge.dart';
import 'package:sylphy/core/messaging/sylphy_messaging_bridge.dart';
import 'package:sylphy/core/native/native_core.dart';

void main() {
  test(
    'download state changes invalidate placeholders without exposing keys',
    () async {
      final core = _FakeNativeCore();
      final bridge = SylphyMessagingBridge(core: core);
      core.messages.add({
        ..._record('file', 1),
        'attachment_name': 'file.bin',
        'attachment_size': 1024,
        'attachment_state': 'pending',
      });
      final pending = bridge.listMessages('chat').single;
      expect(pending.canDownloadAttachment, isTrue);
      expect(pending.attachmentSize, 1024);
      core.messages.single['attachment_state'] = 'downloading';
      final active = (await bridge.refreshMessages('chat')).single;
      expect(active.attachmentDownloading, isTrue);
      expect(identical(pending, active), isFalse);
      core.messages.single['attachment_state'] = 'failed';
      expect(
        (await bridge.refreshMessages('chat')).single.canDownloadAttachment,
        isTrue,
      );
      core.messages.single['attachment_state'] = 'ready';
      core.messages.single['attachment_base64'] = base64Encode([1, 2, 3]);
      expect((await bridge.refreshMessages('chat')).single.attachmentBytes, [
        1,
        2,
        3,
      ]);
    },
  );
  test(
    'history merges and paginates by local order while preserving sender time',
    () async {
      final core = _PagedCore()
        ..latest = [
          {
            ..._record('incoming', 1),
            'order_at_ms': 2000,
            'is_outgoing': false,
          },
          {..._record('outgoing', 3000), 'order_at_ms': 3000},
        ];
      final bridge = SylphyMessagingBridge(core: core);
      await bridge.refreshMessages('chat');
      final pending = bridge.loadOlderMessages('chat');
      expect(core.lastBeforeMs, 2000);
      core.older.complete(_page([_record('older', 1000)], false));
      final messages = await pending;
      expect(messages.map((m) => m.id), ['older', 'incoming', 'outgoing']);
      expect(messages[1].sentAt.millisecondsSinceEpoch, 1);
      expect(messages[1].orderAt.millisecondsSinceEpoch, 2000);
      expect(
        messages[1].copyWith(deliveryState: DeliveryState.read).orderAt,
        messages[1].orderAt,
      );
    },
  );
  test(
    'sender names survive parsing, receipt updates and cache refreshes',
    () async {
      final core = _FakeNativeCore();
      core.messages.add({..._record('named', 1), 'author_name': 'Alice'});
      final bridge = SylphyMessagingBridge(core: core);
      final message = bridge.listMessages('chat').single;
      expect(message.authorName, 'Alice');
      expect(
        message.copyWith(deliveryState: DeliveryState.read).authorName,
        'Alice',
      );
      core.messages.single['author_name'] = 'Alice Rossi';
      expect(
        (await bridge.refreshMessages('chat')).single.authorName,
        'Alice Rossi',
      );
    },
  );
  test(
    'a newer group page cannot merge deleted messages from an older cache',
    () async {
      final core = _PagedCore()..groupRevision = 1;
      final bridge = SylphyMessagingBridge(core: core);
      await bridge.refreshMessages('chat');
      final pending = bridge.loadOlderMessages('chat');
      core.groupRevision = 2;
      core.latest = [_record('retained', 3)];
      core.older.complete(_page([_record('old', 1)], false, groupRevision: 2));
      expect((await pending).map((message) => message.id), ['retained']);
      expect(bridge.cachedMessages('chat')!.map((message) => message.id), [
        'retained',
      ]);
      bridge.clearCachesAfterAccountImport();
      core.groupRevision = 0;
      core.latest = [_record('new-account', 4)];
      expect((await bridge.refreshMessages('chat')).single.id, 'new-account');
    },
  );
  test(
    'older pages merge with concurrent refresh and survive later refreshes',
    () async {
      final core = _PagedCore();
      final bridge = SylphyMessagingBridge(core: core);
      await bridge.refreshMessages('chat');
      final pending = bridge.loadOlderMessages('chat');
      final duplicate = bridge.loadOlderMessages('chat');
      expect(core.olderCalls, 1);
      core.latest = [_record('new', 3)];
      await bridge.refreshMessages('chat');
      core.older.complete(_page([_record('old', 1)], false));
      expect((await pending).map((m) => m.id), ['old', 'middle', 'new']);
      await duplicate;
      expect((await bridge.refreshMessages('chat')).map((m) => m.id), [
        'old',
        'middle',
        'new',
      ]);
      expect(bridge.hasOlderMessages('chat'), isFalse);
    },
  );

  test(
    'late pages from a previous account cannot repopulate its cache',
    () async {
      final core = _PagedCore();
      final bridge = SylphyMessagingBridge(core: core);
      await bridge.refreshMessages('chat');
      final pending = bridge.loadOlderMessages('chat');
      bridge.clearCachesAfterAccountImport();
      core.older.complete(_page([_record('private-old', 1)], false));
      expect(await pending, isEmpty);
      expect(bridge.cachedMessages('chat'), isNull);
    },
  );

  test(
    'attachment completion invalidates an earlier cached placeholder',
    () async {
      final core = _FakeNativeCore();
      core.messages.add({..._record('file', 1), 'attachment_name': 'file.bin'});
      final bridge = SylphyMessagingBridge(core: core);
      expect(bridge.listMessages('chat').single.attachmentBytes, isNull);
      core.messages.single['attachment_base64'] = base64Encode([1, 2, 3]);
      expect((await bridge.refreshMessages('chat')).single.attachmentBytes, [
        1,
        2,
        3,
      ]);
    },
  );

  test('a slow native commit remains pending until its real result', () async {
    final commit = Completer<int>();
    var warned = false;
    var completed = false;
    final pending =
        awaitNativeOperation(
          commit.future,
          warningAfter: Duration.zero,
          onSlow: () => warned = true,
        ).then((result) {
          completed = true;
          return result;
        });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(warned, isTrue);
    expect(completed, isFalse);
    commit.complete(42);
    expect(await pending, 42);
  });

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

  test(
    'sends a 2 MiB attachment and rejects oversized or empty files',
    () async {
      final core = _FakeNativeCore();
      final bridge = SylphyMessagingBridge(core: core);
      final bytes = List<int>.filled(2 * 1024 * 1024, 42);
      await bridge.sendAttachment(
        conversationId: 'contact-1',
        fileName: 'large.bin',
        bytes: bytes,
      );
      expect(base64Decode(core.sentAttachmentBase64!), bytes);
      for (final invalid in [
        <int>[],
        [...bytes, 0],
      ]) {
        await expectLater(
          bridge.sendAttachment(
            conversationId: 'contact-1',
            fileName: 'invalid.bin',
            bytes: invalid,
          ),
          throwsA(isA<SecureMessagingException>()),
        );
        await expectLater(
          bridge.sendChannelAttachment(
            'group-1',
            'channel-1',
            'invalid.bin',
            invalid,
          ),
          throwsA(isA<SecureMessagingException>()),
        );
      }
      expect(core.sentAttachmentName, 'large.bin');
    },
  );

  test('reuses bounded UI caches and refreshes them explicitly', () async {
    final core = _FakeNativeCore();
    final bridge = SylphyMessagingBridge(core: core);

    bridge.listConversations();
    bridge.listConversations();
    bridge.listMessages('contact-1');
    bridge.listMessages('contact-1');

    expect(core.listConversationCalls, 1);
    expect(core.listMessageCalls, 1);

    await bridge.refreshConversations();
    await bridge.refreshMessages('contact-1');

    expect(core.listConversationCalls, 2);
    expect(core.listMessageCalls, 2);
    expect(bridge.cachedConversations, isNotNull);
    expect(bridge.cachedMessages('contact-1'), isNotNull);
  });

  test(
    'refreshes an offline queued message when the native deposit succeeds',
    () async {
      final core = _FakeNativeCore();
      core.messages.add({
        'id': 'offline-message',
        'author_id': 'me',
        'body': 'Ci sentiamo quando torni online',
        'sent_at_ms': 1800000000000,
        'is_outgoing': true,
        'delivery_state': 'queued',
      });
      final bridge = SylphyMessagingBridge(core: core);
      final queued = bridge.listMessages('contact-1').single;
      expect(queued.deliveryState, DeliveryState.queued);
      core.messages.single['delivery_state'] = 'sent';
      final refreshed = (await bridge.refreshMessages('contact-1')).single;
      expect(refreshed.deliveryState, DeliveryState.sent);
      expect(refreshed.id, queued.id);
      expect(refreshed.body, queued.body);
      expect(queued.deliveryState, DeliveryState.queued);
    },
  );
}

Map<String, Object> _record(String id, int time) => {
  'id': id,
  'author_id': 'me',
  'body': id,
  'sent_at_ms': time,
  'is_outgoing': true,
  'delivery_state': 'sent',
};

NativeCoreResponse _page(
  List<Map<String, Object>> messages,
  bool hasMore, {
  int? groupRevision,
}) => NativeCoreResponse(
  ok: true,
  code: 'ok',
  data: {
    'messages': messages,
    'has_more': hasMore,
    if (groupRevision != null) 'group_revision': groupRevision,
  },
);

class _PagedCore extends _FakeNativeCore implements NativeCoreMessagePageApi {
  final older = Completer<NativeCoreResponse>();
  int olderCalls = 0;
  int? lastBeforeMs;
  int? groupRevision;
  List<Map<String, Object>> latest = [_record('middle', 2)];

  @override
  Future<NativeCoreResponse> listMessagesInBackground(
    String conversationId, {
    bool priority = false,
    int? beforeMs,
    String? beforeId,
  }) {
    if (beforeMs != null) {
      lastBeforeMs = beforeMs;
      olderCalls++;
      return older.future;
    }
    return Future.value(_page(latest, true, groupRevision: groupRevision));
  }
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
  int listConversationCalls = 0;
  int listMessageCalls = 0;
  final messages = <Map<String, Object>>[];

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
  NativeCoreResponse listConversations() {
    listConversationCalls += 1;
    return const NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {
        'state': 'vault_locked',
        'can_send': false,
        'conversations': <Object>[],
      },
    );
  }

  @override
  NativeCoreResponse listMessages(String conversationId) {
    listMessageCalls += 1;
    return NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {'conversation_id': conversationId, 'messages': messages},
    );
  }

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
