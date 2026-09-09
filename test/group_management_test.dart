import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/messaging/secure_messaging_bridge.dart';
import 'package:sylphy/features/messenger/group_management_page.dart';

void main() {
  testWidgets(
    'group settings save write permissions and never offer stickers',
    (tester) async {
      final bridge = _Groups();
      await tester.pumpWidget(
        MaterialApp(
          home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tutti i membri possono scrivere'), findsOneWidget);
      await tester.tap(find.text('Permessi e antispam'));
      await tester.pumpAndSettle();
      expect(find.textContaining('sticker'), findsNothing);
      expect(find.textContaining('sondaggi'), findsNothing);
      await tester.tap(find.text('Inviare messaggi'));
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      expect(bridge.actions.single['kind'], 'policy');
      expect((bridge.actions.single['policy'] as Map)['send_messages'], false);
      expect(find.text('Scrivono solo gli amministratori'), findsOneWidget);
    },
  );

  testWidgets(
    'adding people sends each ID and delegated changes show pending state',
    (tester) async {
      final bridge = _Groups()..pending = true;
      await tester.pumpWidget(
        MaterialApp(
          home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Aggiungi persone'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'sylphy:VLDalice\nsylphy:VLDbob',
      );
      await tester.tap(find.text('Aggiungi'));
      await tester.pumpAndSettle();
      expect(bridge.actions.single['invitation_codes'], [
        'sylphy:VLDalice',
        'sylphy:VLDbob',
      ]);
      expect(
        find.textContaining('quando il proprietario sarà online'),
        findsOneWidget,
      );
    },
  );

  testWidgets('read-only members cannot change settings or delete the group', (
    tester,
  ) async {
    final bridge = _Groups()..owner = false;
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Permessi e antispam'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Elimina gruppo per tutti'), findsNothing);
    expect(find.byTooltip('Gestisci membro'), findsNothing);
    expect(bridge.actions, isEmpty);
  });

  testWidgets(
    'delete for everyone requires confirmation and cancelling does nothing',
    (tester) async {
      final bridge = _Groups();
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Elimina gruppo per tutti'));
      await tester.tap(find.text('Elimina gruppo per tutti'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();
      expect(bridge.actions, isEmpty);
    },
  );

  testWidgets(
    'search ignores stale responses and clears results when query is cleared',
    (tester) async {
      final bridge = _Groups();
      final old = Completer<Map<String, dynamic>>();
      bridge.searchOverride = (query) => query == 'vecchio'
          ? old.future
          : Future.value({
              'messages': [
                {
                  'id': 'new',
                  'author_id': 'alice',
                  'body': '#nuovo',
                  'sent_at_ms': 1,
                  'is_outgoing': false,
                },
              ],
              'total': 1,
              'has_more': false,
            });
      await tester.pumpWidget(
        MaterialApp(
          home: ChatSearchPage(bridge: bridge, conversationId: 'group'),
        ),
      );
      await tester.enterText(find.byType(TextField), 'vecchio');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(find.byType(TextField), '#nuovo');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      old.complete({'messages': [], 'total': 0, 'has_more': false});
      await tester.pumpAndSettle();
      expect(find.text('1 risultati'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '#nuovo'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '#nuovo'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SelectableText, '#nuovo'), findsOneWidget);
      expect(find.text('Rispondi'), findsOneWidget);
      await tester.tap(find.text('Chiudi'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pins outside loaded history can be opened and unpinned', (
    tester,
  ) async {
    final bridge = _Groups()..pinned = ['old-message'];
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Rimuovi dai fissati'));
    await tester.tap(find.byTooltip('Rimuovi dai fissati'));
    await tester.pumpAndSettle();
    expect(bridge.actions.single, {
      'kind': 'pin',
      'message_id': 'old-message',
      'pinned': false,
    });
    expect(tester.takeException(), isNull);
  });
}

class _Groups implements GroupManagementBridge {
  bool owner = true;
  bool pending = false;
  List<String> pinned = [];
  Map<String, dynamic> policy = {
    'send_messages': true,
    'send_media': true,
    'send_links': true,
    'slow_mode_seconds': 0,
    'aggressive_antispam': false,
  };
  final List<Map<String, dynamic>> actions = [];
  Future<Map<String, dynamic>> Function(String)? searchOverride;
  @override
  Future<Map<String, dynamic>> groupDetails(String conversationId) async => {
    'id': conversationId,
    'name': 'Team Sylphy',
    'description': 'Gruppo aziendale',
    'revision': 1,
    'policy': policy,
    'is_owner': owner,
    'closed': false,
    'can_send': true,
    'pinned': pinned,
    'permissions': {
      for (final key in [
        'change_info',
        'manage_permissions',
        'manage_members',
        'invite_members',
        'pin_messages',
        'delete_messages',
        'add_admins',
      ])
        key: owner,
    },
    'members': [
      {'id': 'owner', 'name': 'Proprietario', 'is_owner': true},
      {'id': 'alice', 'name': 'Alice', 'is_owner': false},
    ],
  };
  @override
  Future<String> groupAction(
    String conversationId,
    Map<String, dynamic> action,
  ) async {
    actions.add(action);
    if (!pending && action['kind'] == 'policy') {
      policy = Map<String, dynamic>.from(action['policy'] as Map);
    }
    return pending ? 'pending_owner' : 'applied';
  }

  @override
  Future<Map<String, dynamic>> searchMessages(
    String conversationId,
    String query, {
    int offset = 0,
  }) async => searchOverride == null
      ? {'messages': [], 'total': 0, 'has_more': false}
      : searchOverride!(query);
  @override
  Future<void> sendReply(
    String conversationId,
    String plaintext,
    String replyTo,
  ) async {}
  @override
  Future<String> joinGroup(String invitationCode) async => 'group';
}
