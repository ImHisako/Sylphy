import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/messaging/secure_messaging_bridge.dart';
import 'package:sylphy/features/messenger/group_management_page.dart';

void main() {
  testWidgets('channels can be moved and deleted with confirmation on mobile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _Groups()
      ..channels = [
        {'id': 'a', 'name': 'Progetti'},
        {'id': 'b', 'name': 'Annunci'},
        {'id': 'c', 'name': 'Supporto'},
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-group-channels')));
    await tester.pumpAndSettle();
    expect(find.text('Generale'), findsOneWidget);
    await tester.tap(find.byTooltip('Gestisci Annunci'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sposta su'));
    await tester.pumpAndSettle();
    expect(bridge.actions.last, {
      'kind': 'move_channel',
      'channel_id': 'b',
      'before_channel_id': 'a',
    });
    expect(
      tester.getTopLeft(find.text('Annunci')).dy,
      lessThan(tester.getTopLeft(find.text('Progetti')).dy),
    );
    await tester.tap(find.byTooltip('Gestisci Annunci'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sposta giù'));
    await tester.pumpAndSettle();
    expect(bridge.actions.last['before_channel_id'], 'c');
    await tester.tap(find.byTooltip('Gestisci Annunci'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina canale'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tutti i suoi messaggi'), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(bridge.actions.length, 2);
    await tester.tap(find.byTooltip('Gestisci Annunci'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina canale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conferma'));
    await tester.pumpAndSettle();
    expect(bridge.actions.last, {'kind': 'delete_channel', 'channel_id': 'b'});
    expect(find.text('Annunci'), findsNothing);
    expect(find.text('Generale'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'channel drag moves stable IDs and pending changes stay unapplied',
    (tester) async {
      final bridge = _Groups()
        ..channels = [
          {'id': 'a', 'name': 'Primo'},
          {'id': 'b', 'name': 'Secondo'},
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: GroupManagementPage.channels(
            bridge: bridge,
            conversationId: 'group',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('drag-channel-a'))),
      );
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 90));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bridge.actions.single, {
        'kind': 'move_channel',
        'channel_id': 'a',
        'before_channel_id': null,
      });
      bridge.pending = true;
      await tester.tap(find.byTooltip('Gestisci Secondo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sposta giù'));
      await tester.pumpAndSettle();
      expect(bridge.channels.first['id'], 'b');
      expect(
        find.text(
          'Modifica dei canali in attesa di conferma del proprietario.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('create-group-channel')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('channel actions honor permissions and update from the inbox', (
    tester,
  ) async {
    final bridge = _LiveGroups()..owner = false;
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage.channels(
          bridge: bridge,
          conversationId: 'group',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('create-group-channel')),
          )
          .onPressed,
      isNull,
    );
    bridge.grantedPermissions.add('change_info');
    bridge.channels = [
      {'id': 'a', 'name': 'Progetti'},
    ];
    bridge.inboxChanges.value++;
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('create-group-channel')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('Gestisci Progetti'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuItem<String>>(
            find.widgetWithText(PopupMenuItem<String>, 'Elimina canale'),
          )
          .enabled,
      isFalse,
    );
    expect(bridge.actions, isEmpty);
    await tester.pumpWidget(const SizedBox());
    bridge.inboxChanges.dispose();
  });

  testWidgets('group notices can be disabled and named channels created', (
    tester,
  ) async {
    final bridge = _Groups();
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-action-notices')));
    await tester.pumpAndSettle();
    expect(bridge.actions.first, {'kind': 'action_notices', 'enabled': false});
    await tester.tap(find.byKey(const ValueKey('open-group-channels')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-group-channel')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Progetti');
    await tester.tap(find.text('Salva'));
    await tester.pumpAndSettle();
    expect(bridge.actions.last, {'kind': 'create_channel', 'name': 'Progetti'});
  });
  testWidgets(
    'saving zero privileges preserves admin; only revoke removes it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bridge = _Groups()..alicePermissions = {'delete_messages': true};
      await tester.pumpWidget(
        MaterialApp(
          home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> openRole() async {
        await tester.ensureVisible(find.byTooltip('Gestisci membro'));
        await tester.tap(find.byTooltip('Gestisci membro'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ruolo e privilegi'));
        await tester.pumpAndSettle();
      }

      await openRole();
      await tester.tap(find.text('Eliminare messaggi'));
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      expect(bridge.actions.single['kind'], 'set_admin');
      expect(
        (bridge.actions.single['permissions'] as Map).values,
        everyElement(false),
      );
      expect(find.text('Amministratore'), findsOneWidget);
      await openRole();
      await tester.tap(find.text('Revoca ruolo'));
      await tester.pumpAndSettle();
      expect(bridge.actions.last['permissions'], isNull);
      expect(find.text('Amministratore'), findsNothing);
    },
  );

  testWidgets('inbox updates do not starve a pending settings load', (
    tester,
  ) async {
    final bridge = _LiveGroups();
    final details = await bridge.groupDetails('group');
    final pending = Completer<Map<String, dynamic>>();
    var calls = 0;
    bridge.detailsOverride = () {
      calls++;
      return pending.future;
    };
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    for (var i = 0; i < 10; i++) {
      bridge.inboxChanges.value++;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(calls, 1);
    pending.complete(details);
    await tester.pumpAndSettle();
    expect(find.text('Team Sylphy'), findsOneWidget);
    expect(calls, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    bridge.inboxChanges.dispose();
  });

  testWidgets('settings timeout offers a working retry', (tester) async {
    final bridge = _Groups();
    final details = await bridge.groupDetails('group');
    final pending = Completer<Map<String, dynamic>>();
    bridge.detailsOverride = () => pending.future;
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(
      find.textContaining('stanno impiegando troppo tempo'),
      findsOneWidget,
    );
    bridge.detailsOverride = () async => details;
    await tester.tap(find.text('Riprova'));
    await tester.pumpAndSettle();
    expect(find.text('Team Sylphy'), findsOneWidget);
    expect(find.text('Riprova'), findsNothing);
    pending.complete(details);
    await tester.pump();
  });

  testWidgets('new permissions are usable without reopening group settings', (
    tester,
  ) async {
    final bridge = _LiveGroups()..owner = false;
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    await tester.pumpAndSettle();
    bridge.grantedPermissions.add('manage_permissions');
    bridge.inboxChanges.value++;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Permessi e antispam'));
    await tester.pumpAndSettle();
    expect(find.text('Permessi del gruppo'), findsOneWidget);
    expect(find.text('Inviare link'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    bridge.inboxChanges.dispose();
  });
  testWidgets('pinned messages show their content without an ID search field', (
    tester,
  ) async {
    final bridge = _Groups()
      ..searchOverride = (query) async {
        expect(query, 'id:D7BFDC');
        return {
          'messages': [
            {
              'id': 'D7BFDC',
              'body': 'Testo fissato completo',
              'author_id': 'alice',
              'author_name': 'Alice',
              'sent_at_ms': 1000,
              'is_outgoing': false,
            },
          ],
          'total': 1,
          'has_more': false,
        };
      };
    await tester.pumpWidget(
      MaterialApp(
        home: ChatSearchPage(
          bridge: bridge,
          conversationId: 'group',
          pinnedMessageIds: const ['D7BFDC'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Messaggi fissati'), findsOneWidget);
    expect(find.text('Testo fissato completo'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Testo fissato completo'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
  });
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
        find.textContaining('In attesa di conferma della modifica'),
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
    expect(
      find.text(
        'Per questa azione chiedi al proprietario di assegnarti il permesso «Cambiare permessi e antispam».',
      ),
      findsOneWidget,
    );
    for (final label in ['Aggiungi persone', 'Crea link di invito']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text(
          'Per questa azione chiedi al proprietario di assegnarti il permesso «Invitare persone».',
        ),
        findsOneWidget,
      );
    }
    expect(find.byIcon(Icons.lock_outline), findsNWidgets(4));
    expect(find.text('Elimina gruppo per tutti'), findsNothing);
    expect(find.byTooltip('Gestisci membro'), findsNothing);
    expect(bridge.actions, isEmpty);
  });

  testWidgets('delegated invite permission enables only the allowed actions', (
    tester,
  ) async {
    final bridge = _Groups()
      ..owner = false
      ..grantedPermissions = {'invite_members'};
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aggiungi persone'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Crea link di invito'));
    await tester.pumpAndSettle();
    expect(bridge.actions.single, {'kind': 'invite_link'});
    await tester.tap(find.text('Permessi e antispam'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.actions, hasLength(1));
    expect(find.byIcon(Icons.lock_outline), findsNWidgets(2));
  });

  testWidgets('closed groups explain why actions are unavailable', (
    tester,
  ) async {
    final bridge = _Groups()..closed = true;
    await tester.pumpWidget(
      MaterialApp(
        home: GroupManagementPage(bridge: bridge, conversationId: 'group'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Crea link di invito'));
    await tester.pumpAndSettle();
    expect(
      find.text('Il gruppo è stato chiuso o non ne fai più parte.'),
      findsOneWidget,
    );
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
    await tester.ensureVisible(
      find.ancestor(
        of: find.byTooltip('Rimuovi dai fissati'),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
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

class _LiveGroups extends _Groups implements InboxRevisionNotifications {
  @override
  final ValueNotifier<int> inboxChanges = ValueNotifier<int>(0);
}

class _Groups implements GroupManagementBridge {
  List<Map<String, dynamic>> channels = [];
  Map<String, dynamic>? alicePermissions;
  Future<Map<String, dynamic>> Function()? detailsOverride;
  bool owner = true;
  bool closed = false;
  Set<String> grantedPermissions = {};
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
  Future<Map<String, dynamic>> groupDetails(String conversationId) async =>
      detailsOverride != null
      ? detailsOverride!()
      : {
          'id': conversationId,
          'name': 'Team Sylphy',
          'description': 'Gruppo aziendale',
          'revision': 1,
          'policy': policy,
          'is_owner': owner,
          'closed': closed,
          'can_send': true,
          'pinned': pinned,
          'channels': channels,
          'pending_actions': pending ? actions : [],
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
              key: owner || grantedPermissions.contains(key),
          },
          'members': [
            {'id': 'owner', 'name': 'Proprietario', 'is_owner': true},
            {
              'id': 'alice',
              'name': 'Alice',
              'is_owner': false,
              'permissions': alicePermissions,
            },
          ],
        };
  @override
  Future<String> groupAction(
    String conversationId,
    Map<String, dynamic> action,
  ) async {
    actions.add(action);
    if (!pending) {
      switch (action['kind']) {
        case 'create_channel':
          channels.add({'id': 'new-${actions.length}', 'name': action['name']});
        case 'rename_channel':
          channels.firstWhere(
            (channel) => channel['id'] == action['channel_id'],
          )['name'] = action['name'];
        case 'delete_channel':
          channels.removeWhere(
            (channel) => channel['id'] == action['channel_id'],
          );
        case 'move_channel':
          final moved = channels.firstWhere(
            (channel) => channel['id'] == action['channel_id'],
          );
          channels.remove(moved);
          final before = action['before_channel_id'];
          channels.insert(
            before == null
                ? channels.length
                : channels.indexWhere((channel) => channel['id'] == before),
            moved,
          );
      }
    }
    if (!pending && action['kind'] == 'set_admin') {
      alicePermissions = action['permissions'] == null
          ? null
          : Map<String, dynamic>.from(action['permissions'] as Map);
    }
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
