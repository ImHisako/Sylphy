import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/core/messaging/sylphy_messaging_bridge.dart';

const _empty = NativeCoreResponse(
  ok: true,
  code: 'ok',
  data: {'conversations': []},
);
const _old = NativeCoreResponse(
  ok: true,
  code: 'ok',
  data: {
    'conversations': [
      {
        'id': 'chat',
        'name': 'Deleted chat',
        'initials': 'DC',
        'accent_value': 0xFFA5E5D3,
        'last_message': 'old preview',
        'last_activity_ms': 1,
        'unread_count': 0,
        'safety': 'verified',
        'fingerprint': 'REVIEW',
      },
    ],
  },
);

void main() {
  for (final olderFinishesFirst in [true, false]) {
    test(
      'deletion supersedes pending conversation reads (old first: $olderFinishesFirst)',
      () async {
        final core = _ControlledCore();
        final bridge = SylphyMessagingBridge(core: core);
        final earlier = bridge.refreshConversations();
        await bridge.deleteConversation('chat');
        final current = bridge.refreshConversations();
        expect(identical(earlier, current), isFalse);
        expect(core.reads.length, 2);
        if (olderFinishesFirst) {
          core.reads[0].complete(_old);
          await Future<void>.delayed(Duration.zero);
          // The old completion cannot clear the newer in-flight request.
          expect(identical(bridge.refreshConversations(), current), isTrue);
          core.reads[1].complete(_empty);
        } else {
          core.reads[1].complete(_empty);
          expect(await current, isEmpty);
          core.reads[0].complete(_old);
        }
        expect(await earlier, isEmpty);
        expect(await current, isEmpty);
        expect(bridge.cachedConversations, isEmpty);
        expect(core.reads.length, 2);
      },
    );
  }

  test(
    'a superseded read starts a fresh request when nobody else has',
    () async {
      final core = _ControlledCore();
      final bridge = SylphyMessagingBridge(core: core);
      final earlier = bridge.refreshConversations();
      await bridge.deleteConversation('chat');
      core.reads[0].complete(_old);
      await Future<void>.delayed(Duration.zero);
      expect(core.reads.length, 2);
      core.reads[1].complete(_empty);
      expect(await earlier, isEmpty);
      expect(bridge.cachedConversations, isEmpty);
    },
  );

  test(
    'account changes discard a read instead of joining the new account',
    () async {
      final core = _ControlledCore();
      final bridge = SylphyMessagingBridge(core: core);
      final old = bridge.refreshConversations();
      bridge.clearCachesAfterAccountImport();
      final current = bridge.refreshConversations();
      core.reads[0].complete(_old);
      expect(await old, isEmpty);
      expect(identical(bridge.refreshConversations(), current), isTrue);
      core.reads[1].complete(_empty);
      expect(await current, isEmpty);
    },
  );
}

class _ControlledCore extends Fake implements NativeCoreClient {
  final reads = <Completer<NativeCoreResponse>>[];
  @override
  Future<NativeCoreResponse> listConversationsInBackground() {
    final read = Completer<NativeCoreResponse>();
    reads.add(read);
    return read.future;
  }

  @override
  Future<NativeCoreResponse> deleteConversationInBackground(String id) async =>
      const NativeCoreResponse(ok: true, code: 'ok', data: {});
}
