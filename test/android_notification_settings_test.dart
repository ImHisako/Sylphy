import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/features/settings/android_notification_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sylphy/platform');
  late Map<String, Object> settings;
  late List<MethodCall> calls;
  var failSave = false;

  setUp(() {
    settings = {
      'enabled': true,
      'system_enabled': true,
      'channel_enabled': true,
      'sound_enabled': true,
      'vibration_enabled': false,
    };
    calls = [];
    failSave = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getNotificationSettings':
              return Map<String, Object>.of(settings);
            case 'setNotificationsEnabled':
              if (failSave) throw PlatformException(code: 'storage_failed');
              settings['enabled'] = call.arguments as bool;
              return Map<String, Object>.of(settings);
            case 'openNotificationSettings':
              return null;
            default:
              throw MissingPluginException();
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AndroidNotificationSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester) => tester
      .widget<SwitchListTile>(
        find.byKey(const ValueKey('message-notifications')),
      )
      .value;

  testWidgets(
    'message alerts use the native preference and survive reopening',
    (tester) async {
      await open(tester);
      expect(enabled(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey('message-notifications')));
      await tester.pumpAndSettle();
      expect(settings['enabled'], isFalse);
      expect(enabled(tester), isFalse);
      expect(
        calls
            .where((call) => call.method == 'setNotificationsEnabled')
            .single
            .arguments,
        false,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AndroidNotificationSettings())),
      );
      await tester.pumpAndSettle();
      expect(enabled(tester), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sound and vibration open the message channel and refresh on resume',
    (tester) async {
      await open(tester);
      expect(
        find.text('Disattivata in Android · Tocca per modificare'),
        findsOneWidget,
      );
      for (final key in ['notification-sound', 'notification-vibration']) {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        expect(
          calls
              .lastWhere((call) => call.method == 'openNotificationSettings')
              .arguments,
          true,
        );
      }
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      settings['vibration_enabled'] = true;
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Attiva in Android · Tocca per modificare'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('android-notification-settings')),
      );
      await tester.pumpAndSettle();
      expect(
        calls
            .lastWhere((call) => call.method == 'openNotificationSettings')
            .arguments,
        false,
      );
    },
  );

  testWidgets(
    'blocked permission opens app settings and blocked channel opens channel settings',
    (tester) async {
      settings['system_enabled'] = false;
      await open(tester);
      expect(find.text('Notifiche bloccate da Android'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('notifications-blocked')));
      await tester.pumpAndSettle();
      expect(
        calls
            .lastWhere((call) => call.method == 'openNotificationSettings')
            .arguments,
        false,
      );
      settings['system_enabled'] = true;
      settings['channel_enabled'] = false;
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('notifications-blocked')));
      await tester.pumpAndSettle();
      expect(
        calls
            .lastWhere((call) => call.method == 'openNotificationSettings')
            .arguments,
        true,
      );
    },
  );

  testWidgets('failed save retains the confirmed value and allows retry', (
    tester,
  ) async {
    await open(tester);
    failSave = true;
    await tester.tap(find.byKey(const ValueKey('message-notifications')));
    await tester.pumpAndSettle();
    expect(enabled(tester), isTrue);
    expect(find.textContaining('Impossibile aggiornare'), findsOneWidget);
    failSave = false;
    await tester.tap(find.byKey(const ValueKey('message-notifications')));
    await tester.pumpAndSettle();
    expect(enabled(tester), isFalse);
    expect(find.textContaining('Impossibile aggiornare'), findsNothing);
  });
}
