import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/privacy/privacy_settings.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channels = [
    MethodChannel('sylphy/screen_capture'),
    MethodChannel('sylphy/platform'),
  ];
  setUp(() {
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
    }
  });
  tearDown(() {
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'Halloween is listed, applied and retained at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final privacy = _Privacy();
        addTearDown(privacy.dispose);
        await tester.pumpWidget(
          SylphyApp(profileStore: _Profiles(), privacySettings: privacy),
        );
        await tester.pumpAndSettle();

        final wallpaper = find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.key == const ValueKey('theme-wallpaper') &&
              widget.painter != null,
        );
        expect(wallpaper, findsNothing);

        Future<void> openThemes() async {
          await tester.tap(find.byKey(const ValueKey('open-settings')));
          await tester.pumpAndSettle();
          final appearance = find.byKey(
            const ValueKey('settings-section-appearance'),
          );
          await tester.scrollUntilVisible(
            appearance,
            150,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('settings-index')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.tap(appearance);
          await tester.pumpAndSettle();
        }

        await openThemes();
        final selector = find.byKey(const ValueKey('app-theme'));
        await tester.tap(selector);
        await tester.pumpAndSettle();
        expect(find.text('Halloween'), findsOneWidget);
        await tester.tap(find.text('Halloween'));
        await tester.pumpAndSettle();
        expect(privacy.value.themeName, 'halloween');
        expect(wallpaper, findsWidgets);
        expect(
          Theme.of(tester.element(selector)).colorScheme.primary,
          const Color(0xFFFFAA5C),
        );

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await openThemes();
        expect(find.text('Halloween'), findsOneWidget);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text('White').last);
        await tester.pumpAndSettle();
        expect(privacy.value.themeName, 'white');
        expect(wallpaper, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
      }),
    );
  }
}

class _Privacy extends PrivacySettingsController {
  _Privacy() : super(cipher: const UnavailableLocalDataCipher());
  PrivacySettings _settings = const PrivacySettings();

  @override
  PrivacySettings get value => _settings;

  @override
  bool get loaded => true;

  @override
  Future<void> load() async {}

  @override
  Future<void> update(PrivacySettings value) async {
    _settings = value;
    notifyListeners();
  }
}

class _Profiles implements UserProfileStore {
  @override
  Future<UserProfile?> load() async =>
      const UserProfile(displayName: 'Profilo di test');

  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async => UserProfile(displayName: displayName, photoBytes: photoBytes);
}
