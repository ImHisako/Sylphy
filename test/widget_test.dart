import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/diagnostics/app_log.dart';
import 'package:sylphy/core/messaging/models.dart';
import 'package:sylphy/core/messaging/secure_messaging_bridge.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/core/platform/message_notifications.dart';
import 'package:sylphy/core/privacy/privacy_settings.dart';
import 'package:sylphy/main.dart';
import 'package:sylphy/features/messenger/message_text.dart';

void main() {
  for (final notifications in [true, false]) {
    testWidgets(
      'Android pauses UI polling in background (notifications: $notifications)',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final bridge = notifications
            ? _NotifyingTestMessagingBridge()
            : _TestMessagingBridge();
        await tester.pumpWidget(
          SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Contatto di test'));
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pumpAndSettle();
        final before = bridge.refreshCount;
        bridge.injectIncoming('Ricevuto durante la sospensione');
        await tester.pump(const Duration(seconds: 30));
        expect(bridge.refreshCount, before);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(bridge.refreshCount, greaterThan(before));
        expect(find.text('Ricevuto durante la sospensione'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        if (bridge is _NotifyingTestMessagingBridge) {
          bridge.inboxChanges.dispose();
        }
      },
      variant: TargetPlatformVariant({TargetPlatform.android}),
    );
  }

  testWidgets(
    'resuming retries a failed channel read without marking General read',
    (tester) async {
      final bridge = _FailingChannelTestBridge();
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contatto di test'));
      await tester.pumpAndSettle();
      expect(find.text('Riprova a caricare i canali'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.fail = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-channel-list')), findsOneWidget);
      expect(bridge.readChannels, isEmpty);
      await tester.pumpWidget(const SizedBox());
      bridge.inboxChanges.dispose();
    },
  );

  setUpAll(() async {
    if (Platform.environment['SYLPHY_CAPTURE_CHANNELS'] != '1') return;
    final fontDirectory = Platform.environment['SYLPHY_TEST_FONTS'];
    if (fontDirectory == null) return;
    for (final entry in {
      'Roboto': 'roboto-regular.ttf',
      'MaterialIcons': 'materialicons-regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          File(
            '$fontDirectory/${entry.value}',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
    }
  });
  for (final width in [390.0, 900.0, 1266.0]) {
    testWidgets(
      'group channel navigation and conversation rail at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bridge = _ChannelTestBridge(
          includePrivate: true,
          channels: [
            {'id': 'development', 'name': 'Sviluppo'},
            {'id': 'announcements', 'name': 'Annunci'},
            {'id': 'last', 'name': 'Ultimo canale'},
          ],
        );
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: SylphyApp(
              bridge: bridge,
              profileStore: _completedProfileStore(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (width < 900) {
          await tester.tap(find.text('Contatto di test'));
          await tester.pumpAndSettle();
        }
        final list = find.byKey(const ValueKey('group-channel-list'));
        final rail = find.byKey(const ValueKey('conversation-rail'));
        expect(list, findsOneWidget);
        expect(
          tester.getRect(rail).right,
          lessThanOrEqualTo(tester.getRect(list).left),
        );
        expect(find.byKey(const ValueKey('message-composer')), findsNothing);
        expect(bridge.readChannels, isEmpty);
        expect(
          MessageNotifications.isConversationVisible('test-contact'),
          isFalse,
        );
        var previousTop = -1.0;
        for (final id in ['general', 'development', 'announcements', 'last']) {
          final top = tester
              .getTopLeft(find.byKey(ValueKey('group-channel-$id')))
              .dy;
          expect(top, greaterThan(previousTop));
          previousTop = top;
        }
        if (Platform.environment['SYLPHY_CAPTURE_CHANNELS'] == '1') {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'build/channel-navigation-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(
          find.byKey(const ValueKey('group-channel-development')),
        );
        await tester.pumpAndSettle();
        expect(bridge.readChannels.last, 'development');
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('chat-message-list')),
            matching: find.text('Messaggio sviluppo'),
          ),
          findsOneWidget,
        );
        final composer = find.byKey(const ValueKey('message-composer'));
        await tester.enterText(composer, 'Bozza sviluppo');
        if (width < 900) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byKey(const ValueKey('back-to-channels')));
        }
        await tester.pumpAndSettle();
        expect(list, findsOneWidget);
        expect(composer, findsNothing);
        await tester.tap(find.byKey(const ValueKey('group-channel-general')));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
        await tester.tap(find.byKey(const ValueKey('back-to-channels')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('group-channel-development')),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'Bozza sviluppo',
        );
        await tester.tap(find.byKey(const ValueKey('back-to-channels')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('conversation-rail-private-contact')),
        );
        await tester.pumpAndSettle();
        expect(list, findsNothing);
        expect(composer, findsOneWidget);
        if (width < 900) {
          await tester.pageBack();
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Contatto di test'));
        await tester.pumpAndSettle();
        expect(list, findsOneWidget);
        expect(composer, findsNothing);
        if (width < 900) {
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(list, findsNothing);
          expect(find.text('CONVERSAZIONI'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        bridge.inboxChanges.dispose();
      },
    );
  }

  testWidgets(
    'returning from a channel preserves the mobile list scroll position',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bridge = _ChannelTestBridge(
        channels: [
          for (var i = 0; i < 40; i++)
            {'id': 'channel-$i', 'name': 'Canale $i'},
        ],
      );
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contatto di test'));
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('group-channel-list')),
        matching: find.byType(Scrollable),
      );
      final target = find.byKey(const ValueKey('group-channel-channel-30'));
      await tester.scrollUntilVisible(target, 350, scrollable: scrollable);
      final offset = tester.state<ScrollableState>(scrollable).position.pixels;
      await tester.tap(target);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        closeTo(offset, 1),
      );
      expect(target, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      bridge.inboxChanges.dispose();
    },
  );

  testWidgets('failed channel lookup offers retry without opening General', (
    tester,
  ) async {
    final bridge = _FailingChannelTestBridge();
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();
    expect(find.text('Riprova a caricare i canali'), findsOneWidget);
    expect(find.byKey(const ValueKey('message-composer')), findsNothing);
    expect(bridge.readChannels, isEmpty);
    bridge.fail = false;
    await tester.tap(find.text('Riprova a caricare i canali'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-channel-list')), findsOneWidget);
    expect(bridge.readChannels, isEmpty);
    await tester.pumpWidget(const SizedBox());
    bridge.inboxChanges.dispose();
  });

  testWidgets(
    'single-chat groups open directly and delayed groups do not mark messages read',
    (tester) async {
      final bridge = _ChannelTestBridge(deferDetails: true);
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contatto di test'));
      await tester.pump();
      expect(find.byKey(const ValueKey('message-composer')), findsNothing);
      expect(bridge.readChannels, isEmpty);
      bridge.details.complete({
        'channels': [],
        'members': [],
        'permissions': {},
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-channel-list')), findsNothing);
      expect(find.byKey(const ValueKey('message-composer')), findsOneWidget);
      expect(bridge.readChannels, contains(null));
      await tester.pumpWidget(const SizedBox());
      bridge.inboxChanges.dispose();
    },
  );

  testWidgets(
    'themes keep chat readable and incognito disables keyboard learning',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final directory = Directory.systemTemp.createTempSync(
        'sylphy-theme-widget-',
      );
      addTearDown(() => directory.delete(recursive: true));
      late PrivacySettingsController privacy;
      await tester.runAsync(() async {
        privacy = PrivacySettingsController(
          cipher: _WidgetPrivacyCipher(),
          supportDirectory: () async => directory,
        );
        await privacy.load();
        await privacy.update(privacy.value.copyWith(incognitoKeyboard: true));
      });
      final bridge = _TestMessagingBridge()
        ..injectIncoming('Un messaggio privato, in ogni tema.');
      await bridge.sendText(
        conversationId: 'test-contact',
        plaintext: 'Risposta di prova',
      );
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: SylphyApp(
            bridge: bridge,
            profileStore: _completedProfileStore(),
            privacySettings: privacy,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final name in [
        'sylphy',
        'black',
        'cyan',
        'pink',
        'amoled',
        'white',
      ]) {
        await tester.runAsync(
          () => privacy.update(privacy.value.copyWith(themeName: name)),
        );
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('message-composer')),
        );
        expect(field.enableIMEPersonalizedLearning, isFalse);
        final theme = Theme.of(
          tester.element(find.byKey(const ValueKey('message-composer'))),
        );
        expect(
          theme.brightness,
          name == 'white' ? Brightness.light : Brightness.dark,
        );
        final light = theme.colorScheme.onSurface.computeLuminance();
        final dark = theme.colorScheme.surface.computeLuminance();
        expect(
          ((light > dark ? light : dark) + .05) /
              ((light > dark ? dark : light) + .05),
          greaterThan(4.5),
        );
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('SAVE_THEME_PREVIEWS')) {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'diagnostics/theme-$name.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    },
  );

  testWidgets('desktop details close and reopen from the chat header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SylphyApp(
        bridge: _TestMessagingBridge(),
        profileStore: _completedProfileStore(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('DETTAGLI'), findsOneWidget);
    await tester.tap(find.byTooltip('Chiudi dettagli'));
    await tester.pumpAndSettle();
    expect(find.text('DETTAGLI'), findsNothing);
    await tester.tap(find.byTooltip('Apri o chiudi dettagli'));
    await tester.pumpAndSettle();
    expect(find.text('DETTAGLI'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('private chat header opens and closes the other profile', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      SylphyApp(
        bridge: _TestMessagingBridge(),
        profileStore: _completedProfileStore(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();
    expect(find.text('Fingerprint'), findsOneWidget);
    await tester.tap(find.byTooltip('Chiudi profilo'));
    await tester.pumpAndSettle();
    expect(find.text('Fingerprint'), findsNothing);
    expect(find.byKey(const ValueKey('message-composer')), findsOneWidget);
  });

  testWidgets(
    'channels filter messages and send replies to the selected channel',
    (tester) async {
      final bridge = _ChannelTestBridge();
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contatto di test'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-channel-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('message-composer')), findsNothing);
      expect(bridge.readChannels, isEmpty);
      await tester.tap(find.byKey(const ValueKey('group-channel-general')));
      await tester.pumpAndSettle();
      expect(find.text('Messaggio generale'), findsOneWidget);
      expect(find.text('Messaggio sviluppo'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('back-to-channels')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('group-channel-development')));
      await tester.pumpAndSettle();
      expect(find.text('Messaggio sviluppo'), findsOneWidget);
      expect(find.text('Messaggio generale'), findsNothing);
      expect(bridge.readChannels.last, 'development');
      await tester.longPress(find.text('Messaggio sviluppo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rispondi'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('message-composer')),
        'Risposta nel canale',
      );
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pumpAndSettle();
      expect(bridge.sentChannel, 'development');
      expect(bridge.sentReply, 'channel-message');
      expect(find.text('Risposta nel canale'), findsOneWidget);
      final details = await bridge.groupDetails('test-contact');
      details['pinned'] = ['channel-message'];
      details['can_send'] = false;
      bridge.inboxChanges.value++;
      await tester.pumpAndSettle();
      expect(find.text('Fissato'), findsOneWidget);
      expect(find.byKey(const ValueKey('message-composer')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      bridge.inboxChanges.dispose();
    },
  );

  testWidgets('tapping a mention opens the matching group member', (
    tester,
  ) async {
    final bridge = _MenuMessagingBridge()..injectIncoming('@Alice_Rossi');
    bridge.details.complete({
      'members': [
        {'id': 'alice-id', 'name': 'Alice Rossi', 'is_admin': true},
        {'id': 'bob-id', 'name': 'Bob'},
      ],
    });
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MessageText));
    await tester.pumpAndSettle();
    expect(find.text('Alice Rossi'), findsOneWidget);
    expect(find.text('Amministratore del gruppo'), findsOneWidget);
    expect(find.text('alice-id'), findsOneWidget);
    expect(find.text('bob-id'), findsNothing);
  });

  testWidgets('duplicate mention names require choosing a member', (
    tester,
  ) async {
    final bridge = _MenuMessagingBridge()..injectIncoming('@Alice');
    bridge.details.complete({
      'members': [
        {'id': 'alice-one', 'name': 'Alice', 'is_owner': true},
        {'id': 'alice-two', 'name': 'Alice'},
      ],
    });
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MessageText));
    await tester.pumpAndSettle();
    expect(find.text('Scegli la persona menzionata'), findsOneWidget);
    await tester.tap(find.text('alice-two'));
    await tester.pumpAndSettle();
    expect(find.text('Membro del gruppo'), findsOneWidget);
    expect(find.text('alice-two'), findsOneWidget);
    expect(find.text('alice-one'), findsNothing);
  });

  testWidgets(
    'missing mention gives feedback instead of opening another person',
    (tester) async {
      final bridge = _MenuMessagingBridge()..injectIncoming('@Alice');
      bridge.details.complete({
        'members': [
          {'id': 'bob-id', 'name': 'Bob'},
        ],
      });
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contatto di test'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MessageText));
      await tester.pumpAndSettle();
      expect(
        find.text('Persona non trovata tra i membri attuali.'),
        findsOneWidget,
      );
      expect(find.text('bob-id'), findsNothing);
    },
  );

  testWidgets(
    'link moderation preserves existing member restrictions and submits once',
    (tester) async {
      final bridge = _MenuMessagingBridge()
        ..injectIncoming('Guarda example.com');
      bridge.details.complete({
        'permissions': {'manage_members': true},
        'members': [
          {
            'id': 'test-contact',
            'is_owner': false,
            'permissions': null,
            'restriction': {'send_media': false, 'slow_mode_seconds': 30},
          },
        ],
      });
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contatto di test'));
      await tester.pumpAndSettle();
      final detectors = find.ancestor(
        of: find.text('Guarda example.com').last,
        matching: find.byType(GestureDetector),
      );
      tester
          .widgetList<GestureDetector>(detectors)
          .firstWhere((item) => item.onSecondaryTap != null)
          .onSecondaryTap!();
      await tester.pumpAndSettle();
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Blocca i link di questo membro'),
          matching: find.byType(ListTile),
        ),
      );
      tile.onTap!();
      tile.onTap!();
      await tester.pumpAndSettle();
      expect(bridge.actions, [
        {
          'kind': 'restrict',
          'member_id': 'test-contact',
          'policy': {
            'send_media': false,
            'slow_mode_seconds': 30,
            'send_links': false,
          },
        },
      ]);
      expect(find.byKey(const ValueKey('chat-message-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'message actions open immediately and cannot stack while permissions load',
    (tester) async {
      final bridge = _MenuMessagingBridge()
        ..injectIncoming('Messaggio del menu');
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contatto di test'));
      await tester.pumpAndSettle();
      final message = find.text('Messaggio del menu').last;
      final detectors = find.ancestor(
        of: message,
        matching: find.byType(GestureDetector),
      );
      final detector = tester
          .widgetList<GestureDetector>(detectors)
          .firstWhere((item) => item.onSecondaryTap != null);
      detector.onSecondaryTap!();
      detector.onSecondaryTap!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Rispondi'), findsOneWidget);
      expect(bridge.detailCalls, 1);
      expect(find.text('Fissa per tutti'), findsNothing);
      bridge.details.complete({
        'permissions': {'pin_messages': true},
        'pinned': [],
      });
      await tester.pumpAndSettle();
      expect(find.text('Fissa per tutti'), findsOneWidget);
      await tester.tap(find.text('Rispondi'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'notification visibility follows mobile routes and app lifecycle',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bridge = _TestMessagingBridge();
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      expect(
        MessageNotifications.isConversationVisible('test-contact'),
        isFalse,
      );
      await tester.tap(find.text('Contatto di test'));
      await tester.pumpAndSettle();
      expect(
        MessageNotifications.isConversationVisible('test-contact'),
        isTrue,
      );
      expect(
        MessageNotifications.isConversationVisible('another-chat'),
        isFalse,
      );
      final context = tester.element(
        find.byKey(const ValueKey('chat-message-list')),
      );
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Altra pagina')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        MessageNotifications.isConversationVisible('test-contact'),
        isFalse,
      );
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(
        MessageNotifications.isConversationVisible('test-contact'),
        isFalse,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        MessageNotifications.isConversationVisible('test-contact'),
        isTrue,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        MessageNotifications.isConversationVisible('test-contact'),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'group text and attachments show their sender on desktop and mobile',
    (tester) async {
      for (final size in [const Size(1280, 800), const Size(390, 844)]) {
        await tester.binding.setSurfaceSize(size);
        final bridge = _TestMessagingBridge(isGroup: true);
        bridge._messages.addAll([
          ChatMessage(
            id: 'alice',
            authorId: 'id-alice',
            authorName: 'Alice Rossi',
            body: 'Ciao gruppo',
            sentAt: DateTime(2026),
            isOutgoing: false,
          ),
          ChatMessage(
            id: 'bob',
            authorId: 'id-bob',
            authorName: 'Bob',
            body: 'File',
            attachmentName: 'documento.txt',
            sentAt: DateTime(2026),
            isOutgoing: false,
          ),
          ChatMessage(
            id: 'mine',
            authorId: 'me',
            body: 'Ciao',
            sentAt: DateTime(2026),
            isOutgoing: true,
          ),
        ]);
        await tester.pumpWidget(
          SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
        );
        await tester.pumpAndSettle();
        if (size.width < 900) {
          await tester.tap(find.text('Contatto di test'));
          await tester.pumpAndSettle();
        }
        expect(find.text('Alice Rossi'), findsOneWidget);
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Tu'), findsOneWidget);
        expect(
          MessageNotifications.isConversationVisible('test-contact'),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          MessageNotifications.isConversationVisible('test-contact'),
          isFalse,
        );
      }
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'mobile chat shares the home inbox poll and still receives messages',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bridge = _NotifyingTestMessagingBridge();
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contatto di test'));
      await tester.pumpAndSettle();
      final before = bridge.refreshCount;
      bridge.injectIncoming('Un solo polling');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(bridge.refreshCount - before, 1);
      expect(find.text('Un solo polling'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(bridge.inboxChanges.hasSubscribers, isFalse);
      bridge.inboxChanges.dispose();
    },
  );

  testWidgets(
    'desktop updates delivery state without reloading the conversation preview',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bridge = _NotifyingTestMessagingBridge();
      bridge._messages.add(
        ChatMessage(
          id: 'queued-test',
          authorId: 'me',
          body: 'In attesa',
          sentAt: DateTime(2026),
          isOutgoing: true,
          deliveryState: DeliveryState.queued,
        ),
      );
      await tester.pumpWidget(
        SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip(DeliveryState.queued.label), findsOneWidget);
      bridge._messages[0] = bridge._messages[0].copyWith(
        deliveryState: DeliveryState.sent,
      );
      bridge._inboxRevision++;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byTooltip(DeliveryState.sent.label), findsOneWidget);
      expect(find.byTooltip(DeliveryState.queued.label), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(bridge.inboxChanges.hasSubscribers, isFalse);
      bridge.inboxChanges.dispose();
    },
  );

  testWidgets('uses readable text in floating notifications', (tester) async {
    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    final snackBarTheme = Theme.of(context).snackBarTheme;

    expect(snackBarTheme.backgroundColor, const Color(0xFF252B34));
    expect(snackBarTheme.contentTextStyle?.color, const Color(0xFFF4F7F2));
    expect(snackBarTheme.actionTextColor, const Color(0xFFCFF36A));
  });

  testWidgets('opens Developer Options and exposes diagnostic logs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => AppLog.instance.setVerboseEnabled(false));
    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Impostazioni'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('DEVELOPER OPTIONS'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('DEVELOPER OPTIONS'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('developer-log-viewer')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('developer-log-viewer')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('developer-logging-switch')),
      -250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('developer-logging-switch')));
    await tester.pump();
    expect(AppLog.instance.verboseEnabled, isTrue);
  });

  testWidgets('starts closed without demonstration conversations', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    expect(find.text('Sylphy'), findsOneWidget);
    expect(find.text('Nessuna conversazione sicura'), findsAtLeastNWidgets(1));
    expect(find.text('Lina Moretti'), findsNothing);
    expect(find.byKey(const ValueKey('message-composer')), findsNothing);
    expect(find.text('Nessun dato dimostrativo caricato'), findsOneWidget);
  });

  testWidgets('renders explicitly injected test conversations', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge();

    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('message-composer')),
      'Messaggio di prova',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();

    expect(find.text('Messaggio di prova'), findsAtLeastNWidgets(1));
  });

  testWidgets('reloads persisted conversations after native startup', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge(hiddenUntilFirstRefresh: true);

    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();

    expect(bridge.refreshCount, greaterThan(0));
    expect(find.text('Contatto di test'), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('message-composer')), findsOneWidget);
  });

  testWidgets('sends with Enter on desktop', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge();
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('message-composer')),
      'Inviato con Invio',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(find.text('Inviato con Invio'), findsAtLeastNWidgets(1));
  });

  testWidgets('shows outgoing text immediately while transport is pending', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sendGate = Completer<void>();
    final bridge = _TestMessagingBridge(sendGate: sendGate);
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('message-composer')),
      'Invio immediato',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();

    expect(find.text('Invio immediato'), findsOneWidget);
    final sendButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('send-message')),
    );
    expect(sendButton.onPressed, isNotNull);

    sendGate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('inserts emoji and kaomoji from the cross-platform picker', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge();
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-expression-picker')));
    await tester.pumpAndSettle();
    expect(find.text('Faccine ed emozioni'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('emoji-category-food')));
    await tester.pumpAndSettle();
    expect(find.text('Cibo e bevande'), findsOneWidget);
    expect(find.byKey(const ValueKey('emoji-🍇')), findsOneWidget);
    final grapeButton = tester.widget<TextButton>(
      find.byKey(const ValueKey('emoji-🍇')),
    );
    expect(grapeButton.style?.minimumSize?.resolve({}), Size.zero);
    expect(grapeButton.style?.padding?.resolve({}), EdgeInsets.zero);
    await tester.tap(find.byKey(const ValueKey('emoji-category-smileys')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('emoji-😀')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-expression-picker')));
    await tester.pumpAndSettle();
    expect(find.text('Recenti'), findsOneWidget);
    expect(find.byKey(const ValueKey('emoji-😀')), findsOneWidget);
    await tester.tap(find.text('Kaomoji'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('(＾▽＾)'));
    await tester.pumpAndSettle();

    final composer = tester.widget<TextField>(
      find.byKey(const ValueKey('message-composer')),
    );
    expect(composer.controller?.text, '😀(＾▽＾)');
  });

  testWidgets('opens the encrypted file archive and lists attachments', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge();
    await bridge.sendAttachment(
      conversationId: bridge.conversation.id,
      fileName: 'documento-segreto.pdf',
      bytes: [1, 2, 3, 4],
    );
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-encrypted-files')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('encrypted-files-page')), findsOneWidget);
    expect(find.text('documento-segreto.pdf'), findsOneWidget);
    expect(find.textContaining('Contatto di test'), findsOneWidget);
  });

  testWidgets('shows a new mobile message without leaving the chat', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge();
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();
    bridge.injectIncoming('Messaggio arrivato ora');
    await tester.pump(const Duration(seconds: 3));

    expect(find.text('Messaggio arrivato ora'), findsOneWidget);
  });

  testWidgets('scrolls to the latest message when a new one arrives', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge();
    for (var index = 0; index < 30; index++) {
      bridge.injectIncoming('Messaggio precedente $index');
    }
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();
    final messageList = find.byKey(const ValueKey('chat-message-list'));
    await tester.drag(messageList, const Offset(0, -5000));
    await tester.pump();

    bridge.injectIncoming('Ultimo messaggio automatico');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Ultimo messaggio automatico').hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('opens a mobile chat without waiting for the read receipt', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final markReadGate = Completer<void>();
    final bridge = _TestMessagingBridge(markReadGate: markReadGate);
    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Contatto di test'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('message-composer')), findsOneWidget);
    markReadGate.complete();
    await tester.pump();
  });

  testWidgets('lets the user verify a contact without blocking messages', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge(initiallyVerified: false);

    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-composer')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conversation-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sicurezza').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-contact-verification')));
    await tester.pumpAndSettle();

    expect(bridge.conversation.safety, ContactSafety.verified);
  });

  testWidgets('deletes a conversation after explicit confirmation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bridge = _TestMessagingBridge();

    await tester.pumpWidget(
      SylphyApp(bridge: bridge, profileStore: _completedProfileStore()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conversation-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancella chat').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-conversation')));
    await tester.pumpAndSettle();

    expect(bridge.deleted, isTrue);
    expect(find.text('Nessuna conversazione sicura'), findsOneWidget);
  });

  testWidgets('keeps the real empty state readable on a mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    expect(find.text('Core Veilid non incluso'), findsAtLeastNWidgets(1));
    expect(find.text('Nessuna conversazione sicura'), findsOneWidget);
    expect(find.text('Aggiungi contatto'), findsOneWidget);
    await tester.tap(find.byTooltip('Stato protezione'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy di Sylphy'), findsOneWidget);
    expect(find.textContaining('conversazioni dimostrative'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('asks for a name on first launch and accepts no photo', (
    tester,
  ) async {
    final store = _MemoryProfileStore();

    await tester.pumpWidget(SylphyApp(profileStore: store));
    await tester.pumpAndSettle();

    expect(find.text('Crea il tuo profilo'), findsOneWidget);
    expect(find.textContaining('non è obbligatoria'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('profile-name')),
      'Ada Lovelace',
    );
    await tester.tap(find.byKey(const ValueKey('complete-onboarding')));
    await tester.pumpAndSettle();

    expect(store.profile?.displayName, 'Ada Lovelace');
    expect(store.profile?.photoBytes, isNull);
    expect(
      find.byKey(const ValueKey('current-profile-avatar')),
      findsOneWidget,
    );
    expect(find.text('Nessuna conversazione sicura'), findsAtLeastNWidgets(1));
  });

  testWidgets('opens the add-contact flow from the mobile home', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(SylphyApp(profileStore: _completedProfileStore()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('mobile-add-contact')));
    await tester.pumpAndSettle();

    expect(find.text('Aggiungi una persona'), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-name')), findsNothing);
    expect(
      find.byKey(const ValueKey('contact-invitation-code')),
      findsOneWidget,
    );
  });

  testWidgets('opens the own profile and changes the display name', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _completedProfileStore();
    await tester.pumpWidget(SylphyApp(profileStore: store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Il mio profilo'), findsOneWidget);
    expect(find.text('Profilo Test'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('edit-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Modifica il tuo profilo'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('profile-name')),
      'Nuovo Nome',
    );
    await tester.tap(find.byKey(const ValueKey('complete-onboarding')));
    await tester.pumpAndSettle();

    expect(store.profile?.displayName, 'Nuovo Nome');
    await tester.tap(find.byKey(const ValueKey('open-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Nuovo Nome'), findsOneWidget);
  });
}

_MemoryProfileStore _completedProfileStore() =>
    _MemoryProfileStore(const UserProfile(displayName: 'Profilo Test'));

class _MemoryProfileStore implements UserProfileStore {
  _MemoryProfileStore([this.profile]);

  UserProfile? profile;

  @override
  Future<UserProfile?> load() async => profile;

  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async {
    return profile = UserProfile(
      displayName: displayName.trim(),
      photoBytes: photoBytes,
    );
  }
}

class _TestRevisionNotifier extends ValueNotifier<int> {
  _TestRevisionNotifier() : super(0);

  bool get hasSubscribers => hasListeners;
}

class _NotifyingTestMessagingBridge extends _TestMessagingBridge
    implements InboxRevisionNotifications {
  @override
  final _TestRevisionNotifier inboxChanges = _TestRevisionNotifier();

  @override
  Future<int> refreshInbox() async {
    final revision = await super.refreshInbox();
    inboxChanges.value = revision;
    return revision;
  }
}

class _MenuMessagingBridge extends _TestMessagingBridge
    implements GroupManagementBridge {
  _MenuMessagingBridge() : super(isGroup: true);
  final details = Completer<Map<String, dynamic>>();
  int detailCalls = 0;
  final actions = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> groupDetails(String conversationId) {
    detailCalls++;
    return details.future;
  }

  @override
  Future<String> groupAction(
    String conversationId,
    Map<String, dynamic> action,
  ) async {
    actions.add(action);
    return 'applied';
  }

  @override
  Future<Map<String, dynamic>> searchMessages(
    String conversationId,
    String query, {
    int offset = 0,
  }) async => {'messages': [], 'total': 0, 'has_more': false};
  @override
  Future<void> sendReply(
    String conversationId,
    String plaintext,
    String replyTo,
  ) async {}
  @override
  Future<String> joinGroup(String invitationCode) async => 'test-contact';
}

class _ChannelTestBridge extends _MenuMessagingBridge
    implements GroupChannelBridge, InboxRevisionNotifications {
  @override
  final ValueNotifier<int> inboxChanges = ValueNotifier(0);
  _ChannelTestBridge({
    this.includePrivate = false,
    bool deferDetails = false,
    List<Map<String, String>>? channels,
  }) {
    if (!deferDetails) {
      details.complete({
        'channels':
            channels ??
            [
              {'id': 'development', 'name': 'Sviluppo'},
            ],
        'permissions': {},
        'members': [],
      });
    }
    _messages.addAll([
      ChatMessage(
        id: 'general-message',
        authorId: 'test-contact',
        body: 'Messaggio generale',
        sentAt: DateTime(2026),
        isOutgoing: false,
      ),
      ChatMessage(
        id: 'channel-message',
        authorId: 'test-contact',
        body: 'Messaggio sviluppo',
        sentAt: DateTime(2026),
        isOutgoing: false,
        channelId: 'development',
      ),
    ]);
  }
  final readChannels = <String?>[];
  final bool includePrivate;

  @override
  List<Conversation> listConversations() => [
    ...super.listConversations(),
    if (includePrivate)
      Conversation(
        id: 'private-contact',
        name: 'Chat privata',
        initials: 'CP',
        accentValue: 0xFFA5E5D3,
        lastMessage: '',
        lastActivity: DateTime(2026),
        safety: ContactSafety.verified,
        fingerprint: 'PRIVATE',
      ),
  ];

  @override
  List<ChatMessage> listMessages(String conversationId) =>
      conversationId == 'private-contact'
      ? []
      : super.listMessages(conversationId);
  String? sentChannel;
  String? sentReply;
  @override
  Future<bool> markChannelRead(String conversationId, String? channelId) async {
    readChannels.add(channelId);
    return true;
  }

  @override
  Future<void> sendChannelText(
    String conversationId,
    String channelId,
    String text, {
    String? replyTo,
  }) async {
    sentChannel = channelId;
    sentReply = replyTo;
    _messages.add(
      ChatMessage(
        id: 'channel-reply',
        authorId: 'me',
        body: text,
        sentAt: DateTime(2026, 2),
        isOutgoing: true,
        channelId: channelId,
        replyTo: replyTo,
      ),
    );
  }

  @override
  Future<void> sendChannelAttachment(
    String conversationId,
    String channelId,
    String fileName,
    List<int> bytes,
  ) async {}
}

class _FailingChannelTestBridge extends _ChannelTestBridge {
  bool fail = true;

  @override
  Future<Map<String, dynamic>> groupDetails(String conversationId) => fail
      ? Future.error(StateError('offline'))
      : super.groupDetails(conversationId);
}

class _WidgetPrivacyCipher implements LocalDataCipher {
  @override
  Future<Uint8List> open(Uint8List record) async => record;
  @override
  Future<Uint8List> protect(Uint8List plaintext) async => plaintext;
}

class _TestMessagingBridge
    implements SecureMessagingBridge, InboxRefreshingBridge {
  _TestMessagingBridge({
    bool isGroup = false,
    bool initiallyVerified = true,
    this.sendGate,
    this.markReadGate,
    this.hiddenUntilFirstRefresh = false,
  }) : _conversation = Conversation(
         id: 'test-contact',
         isGroup: isGroup,
         name: 'Contatto di test',
         initials: 'CT',
         accentValue: 0xFFA5E5D3,
         lastMessage: '',
         lastActivity: DateTime(2026),
         safety: initiallyVerified
             ? ContactSafety.verified
             : ContactSafety.pending,
         fingerprint: 'TEST',
       );

  Conversation _conversation;
  bool deleted = false;
  final List<ChatMessage> _messages = [];
  final Completer<void>? sendGate;
  final Completer<void>? markReadGate;
  final bool hiddenUntilFirstRefresh;
  int refreshCount = 0;
  int _inboxRevision = 0;

  @override
  int get inboxRevision => _inboxRevision;

  @override
  Future<int> refreshInbox() async {
    refreshCount += 1;
    return _inboxRevision;
  }

  Conversation get conversation => _conversation;

  @override
  Future<void> sendAttachment({
    required String conversationId,
    required String fileName,
    required List<int> bytes,
  }) async {
    final now = DateTime(2026, 1, 1, 12, 2);
    _messages.add(
      ChatMessage(
        id: 'attachment-${_messages.length}',
        authorId: 'me',
        body: '📎 $fileName',
        sentAt: now,
        isOutgoing: true,
        attachmentName: fileName,
        attachmentBytes: Uint8List.fromList(bytes),
      ),
    );
  }

  void injectIncoming(String body) {
    final now = DateTime(2026, 1, 1, 12, 1);
    _messages.add(
      ChatMessage(
        id: 'incoming-${_messages.length}',
        authorId: _conversation.id,
        body: body,
        sentAt: now,
        isOutgoing: false,
        deliveryState: DeliveryState.delivered,
      ),
    );
    _conversation = _conversation.copyWith(
      lastMessage: body,
      lastActivity: now,
      unreadCount: 1,
    );
    _inboxRevision += 1;
  }

  @override
  Future<String> addContact({
    required String displayName,
    required String invitationCode,
  }) async => 'test-contact';

  @override
  List<Conversation> listConversations() =>
      deleted || (hiddenUntilFirstRefresh && refreshCount == 0)
      ? []
      : [_conversation];

  @override
  List<ChatMessage> listMessages(String conversationId) => _messages;

  @override
  Future<void> markConversationRead(String conversationId) async {
    await markReadGate?.future;
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    _messages.clear();
    deleted = true;
  }

  @override
  Future<void> setContactVerified({
    required String conversationId,
    required bool verified,
  }) async {
    _conversation = _conversation.copyWith(
      safety: verified ? ContactSafety.verified : ContactSafety.pending,
    );
  }

  @override
  Future<void> sendText({
    required String conversationId,
    required String plaintext,
  }) async {
    await sendGate?.future;
    final now = DateTime(2026, 1, 1, 12);
    _messages.add(
      ChatMessage(
        id: 'test-message',
        authorId: 'me',
        body: plaintext,
        sentAt: now,
        isOutgoing: true,
      ),
    );
    _conversation = _conversation.copyWith(
      lastMessage: plaintext,
      lastActivity: now,
    );
  }
}
