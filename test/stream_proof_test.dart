import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/platform/stream_proof_host.dart';
import 'package:sylphy/core/privacy/privacy_settings.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/core/veilid/veilid_service.dart';
import 'package:sylphy/features/settings/settings_page.dart';

const channel = MethodChannel('sylphy/screen_capture');
const platformChannel = MethodChannel('sylphy/platform');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, null);
  });

  testWidgets(
    'saved protection hides all routes until Windows acknowledges it',
    (tester) async {
      final settings = _Settings(
        PrivacySettings(streamProof: true),
        loaded: false,
      );
      final reply = Completer<void>();
      final calls = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'setStreamProof');
        calls.add(call.arguments as bool);
        await reply.future;
        return null;
      });
      await tester.pumpWidget(_app(settings));
      expect(find.text('Private chat'), findsNothing);
      expect(calls, isEmpty);
      settings.finishLoading();
      await tester.pump();
      expect(find.text('Private chat'), findsNothing);
      expect(calls, [true]);
      reply.complete();
      await tester.pumpAndSettle();
      expect(find.text('Private chat'), findsOneWidget);
      await settings.update(settings.value.copyWith(streamProof: false));
      await tester.pumpAndSettle();
      expect(calls, [true, false]);
      expect(find.text('Private chat'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'activation failure stays covered until explicit opt-out',
    (tester) async {
      final settings = _Settings(PrivacySettings(streamProof: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        throw PlatformException(code: 'unsupported');
      });
      await tester.pumpWidget(_app(settings));
      await tester.pumpAndSettle();
      expect(find.text('Private chat'), findsNothing);
      expect(find.text('Riprova'), findsOneWidget);
      await tester.tap(find.text('Continua senza stream proof'));
      await tester.pumpAndSettle();
      expect(settings.value.streamProof, isFalse);
      expect(find.text('Private chat'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'rapid toggles apply in order without revealing pending content',
    (tester) async {
      final settings = _Settings(PrivacySettings());
      final reply = Completer<void>();
      final calls = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.arguments as bool);
        if (call.arguments == true) await reply.future;
        return null;
      });
      await tester.pumpWidget(_app(settings));
      await settings.update(settings.value.copyWith(streamProof: true));
      await tester.pump();
      await settings.update(settings.value.copyWith(streamProof: false));
      await tester.pump();
      expect(find.text('Private chat'), findsNothing);
      reply.complete();
      await tester.pumpAndSettle();
      expect(calls, [true, false]);
      expect(find.text('Private chat'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.linux,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      'settings expose only supported controls on $platform',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(1266, 1800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final settings = _Settings(PrivacySettings(streamProof: true));
        final veilid = VeilidService(nativeCore: null);
        addTearDown(veilid.dispose);
        var nativeCalls = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async {
            nativeCalls++;
            return null;
          },
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          platformChannel,
          (call) async {
            if (call.method == 'getNotificationSettings') {
              return {
                'enabled': true,
                'system_enabled': true,
                'channel_enabled': true,
                'sound_enabled': true,
                'vibration_enabled': false,
              };
            }
            throw MissingPluginException();
          },
        );
        if (platform != TargetPlatform.windows) {
          await tester.pumpWidget(_app(settings));
          await tester.pumpAndSettle();
          expect(find.text('Private chat'), findsOneWidget);
          expect(nativeCalls, 0);
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              inputDecorationTheme: InputDecorationTheme(
                border: OutlineInputBorder(),
              ),
            ),
            home: SettingsPage(
              veilidService: veilid,
              privacySettings: settings,
              profile: UserProfile(displayName: 'Test'),
              onAccountImported: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('incognito-keyboard')),
          platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(ValueKey('stream-proof')),
          platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
        );
        final label = tester.getRect(find.text('Tema di Sylphy'));
        final card = tester.getRect(
          find
              .ancestor(
                of: find.byKey(ValueKey('app-theme')),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(label.top, greaterThan(card.top));
        expect(label.bottom, lessThan(card.bottom));
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}

Widget _app(PrivacySettingsController settings) => MaterialApp(
  builder: (context, child) =>
      StreamProofHost(settings: settings, child: child!),
  home: Scaffold(body: Text('Private chat')),
);

class _Settings extends PrivacySettingsController {
  _Settings(this._settings, {bool loaded = true})
    : _loaded = loaded,
      super(cipher: const UnavailableLocalDataCipher());

  PrivacySettings _settings;
  bool _loaded;

  @override
  PrivacySettings get value => _settings;
  @override
  bool get loaded => _loaded;

  void finishLoading() {
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> update(PrivacySettings value) async {
    _settings = value;
    notifyListeners();
  }
}
