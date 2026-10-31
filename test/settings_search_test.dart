import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sylphy/core/privacy/privacy_settings.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/features/settings/settings_search.dart';
import 'package:sylphy/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const captureChannel = MethodChannel('sylphy/screen_capture');
  const platformChannel = MethodChannel('sylphy/platform');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, null);
  });
  test('settings search ignores case, accents, punctuation and word order', () {
    const entry = SettingsSearchEntry(
      'photo',
      'privacy',
      'Mostra la foto profilo',
      'condividi avatar',
    );
    expect(entry.matches('  PRÒFILO   FÒTO '), isTrue);
    expect(entry.matches('avatar'), isTrue);
    expect(entry.matches('foto sconosciuti'), isFalse);
    expect(matchesSettingsSearch('Accessibilità', 'accessibilita'), isTrue);
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'Halloween can be found, selected and replaced at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final privacy = _Privacy();
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
        await tester.tap(find.byKey(const ValueKey('open-settings')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('settings-search')),
          'pipistrelli',
        );
        await tester.pumpAndSettle();
        final result = find.byKey(const ValueKey('settings-result-app-theme'));
        await tester.ensureVisible(result);
        await tester.tap(result);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('app-theme')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Halloween').last);
        await tester.pumpAndSettle();
        expect(privacy.value.themeName, 'halloween');
        expect(wallpaper, findsWidgets);
        expect(
          Theme.of(
            tester.element(find.byKey(const ValueKey('app-theme'))),
          ).colorScheme.primary,
          const Color(0xFFFFAA5C),
        );
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(wallpaper, findsWidgets);
        await tester.tap(find.byKey(const ValueKey('open-settings')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('settings-search')),
          'Halloween',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(result);
        await tester.tap(result);
        await tester.pumpAndSettle();
        expect(find.text('Halloween'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('app-theme')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('White').last);
        await tester.pumpAndSettle();
        expect(privacy.value.themeName, 'white');
        expect(wallpaper, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        privacy.dispose();
      },
    );

    testWidgets(
      'settings profile shows name left and editable photo right at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final oldPhoto = Uint8List.fromList(
          img.encodePng(img.Image(width: 2, height: 2)),
        );
        final newImage = img.Image(width: 2, height: 2)
          ..setPixelRgb(0, 0, 80, 90, 100);
        final newPhoto = Uint8List.fromList(img.encodePng(newImage));
        final profiles = _Profiles(
          UserProfile(displayName: 'Il mio nome profilo', photoBytes: oldPhoto),
        );
        final privacy = _Privacy();
        await tester.pumpWidget(
          SylphyApp(
            profileStore: profiles,
            privacySettings: privacy,
            photoPicker: () async => newPhoto,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('open-settings')));
        await tester.pumpAndSettle();
        final name = find.byKey(const ValueKey('settings-profile-name'));
        final avatar = find.byKey(const ValueKey('settings-profile-avatar'));
        expect(tester.widget<Text>(name).data, 'Il mio nome profilo');
        expect(
          tester.getRect(name).right,
          lessThan(tester.getRect(avatar).left),
        );
        expect(
          tester.getRect(avatar).bottom,
          lessThan(
            tester
                .getRect(find.byKey(const ValueKey('settings-network-status')))
                .top,
          ),
        );
        expect(
          (tester.widget<CircleAvatar>(avatar).backgroundImage as MemoryImage)
              .bytes,
          oldPhoto,
        );
        await tester.tap(avatar);
        await tester.pumpAndSettle();
        expect(find.text('Modifica il tuo profilo'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('choose-profile-photo')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('profile-name')),
          'Nome aggiornato',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('complete-onboarding')),
        );
        await tester.tap(find.byKey(const ValueKey('complete-onboarding')));
        await tester.pumpAndSettle();
        expect(profiles.profile.displayName, 'Nome aggiornato');
        expect(profiles.profile.photoBytes, newPhoto);
        await tester.tap(find.byKey(const ValueKey('open-settings')));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(name).data, 'Nome aggiornato');
        expect(
          (tester.widget<CircleAvatar>(avatar).backgroundImage as MemoryImage)
              .bytes,
          newPhoto,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        privacy.dispose();
      },
    );

    testWidgets(
      'search opens the matching setting and keeps the query on Back at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final privacy = _Privacy();
        await tester.pumpWidget(
          SylphyApp(profileStore: _Profiles(), privacySettings: privacy),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('open-settings')));
        await tester.pumpAndSettle();
        final search = find.byKey(const ValueKey('settings-search'));
        await tester.enterText(search, '  SCONOSCIUTI richieste  ');
        await tester.pumpAndSettle();
        final result = find.byKey(
          const ValueKey('settings-result-unknown-contacts'),
        );
        expect(result, findsOneWidget);
        expect(
          find.byKey(const ValueKey('settings-result-share-profile-photo')),
          findsNothing,
        );
        await tester.ensureVisible(result);
        await tester.tap(result);
        await tester.pumpAndSettle();
        final control = find.widgetWithText(
          SwitchListTile,
          'Richieste da sconosciuti',
        );
        expect(control.hitTestable(), findsOneWidget);
        expect(privacy.value.allowUnknownContacts, isTrue);
        await tester.tap(control);
        await tester.pumpAndSettle();
        expect(privacy.value.allowUnknownContacts, isFalse);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(search).controller!.text,
          '  SCONOSCIUTI richieste  ',
        );
        await tester.ensureVisible(search);
        await tester.enterText(search, 'FOTO PROFILO');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('settings-result-share-profile-photo')),
          findsOneWidget,
        );
        await tester.enterText(search, 'nessuna-voce-del-genere');
        await tester.pumpAndSettle();
        expect(
          find.text('Nessuna impostazione trovata. Prova un’altra parola.'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Cancella ricerca'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(
          find.byKey(const ValueKey('settings-section-account')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        privacy.dispose();
      },
    );
  }

  testWidgets(
    'search lists only settings available on the current platform',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final privacy = _Privacy();
      await tester.pumpWidget(
        SylphyApp(profileStore: _Profiles(), privacySettings: privacy),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-settings')));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('settings-search'));
      await tester.enterText(search, 'vibrazione');
      await tester.pumpAndSettle();
      final android =
          Theme.of(tester.element(search)).platform == TargetPlatform.android;
      expect(
        find.byKey(const ValueKey('settings-result-notification-vibration')),
        android ? findsOneWidget : findsNothing,
      );
      await tester.enterText(search, 'stream proof');
      await tester.pumpAndSettle();
      final windows =
          Theme.of(tester.element(search)).platform == TargetPlatform.windows;
      expect(
        find.byKey(const ValueKey('settings-result-stream-proof')),
        windows ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      privacy.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}

class _Profiles implements UserProfileStore {
  _Profiles([UserProfile? initial])
    : profile = initial ?? const UserProfile(displayName: 'Profilo di test');
  UserProfile profile;

  @override
  Future<UserProfile?> load() async => profile;

  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async =>
      profile = UserProfile(displayName: displayName, photoBytes: photoBytes);
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
