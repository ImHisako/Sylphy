import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/identity/identity_service.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/core/privacy/app_security.dart';
import 'package:sylphy/features/settings/app_security_widgets.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/main.dart';

void main() {
  setUp(() {
    PlatformDeviceSecretStore.passphraseProtected = false;
    FlutterSecureStorage.setMockInitialValues({
      'sylphy_identity_vault_secret_v1': 'a' * 43,
    });
  });
  tearDown(() => PlatformDeviceSecretStore.passphraseProtected = false);

  test(
    'migration removes automatic-unlock key only after a successful commit',
    () async {
      final backend = _SecurityBackend(enabled: false);
      final controller = backend.controller();
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.locked, isFalse);
      backend.rejectEnable = true;
      await expectLater(
        controller.enable('twelve random words'),
        throwsException,
      );
      expect(
        await const FlutterSecureStorage().read(
          key: 'sylphy_identity_vault_secret_v1',
        ),
        'a' * 43,
      );
      backend.rejectEnable = false;
      await controller.enable('twelve random words');
      expect(controller.enabled, isTrue);
      expect(
        await const FlutterSecureStorage().read(
          key: 'sylphy_identity_vault_secret_v1',
        ),
        isNull,
      );
      expect(await PlatformDeviceSecretStore().getOrCreate(), isEmpty);
      await controller.lock();
      expect(controller.locked, isTrue);
      await controller.unlock('incorrect');
      expect(controller.locked, isTrue);
      await controller.unlock('twelve random words');
      expect(controller.locked, isFalse);
    },
  );

  test(
    'startup fails closed when native security configuration is unreadable',
    () async {
      final controller = AppSecurityController(
        command: (_) async => const NativeCoreResponse(
          ok: false,
          code: 'verification_failed',
          data: {},
        ),
        supportDirectory: () async => Directory.systemTemp,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.loaded, isFalse);
      expect(controller.locked, isTrue);
      expect(controller.error, isNotNull);
    },
  );

  test(
    'startup finishes interrupted migration without automatically unlocking',
    () async {
      final backend = _SecurityBackend()..locked = false;
      final controller = backend.controller();
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.loaded, isTrue);
      expect(controller.locked, isTrue);
      expect(
        await const FlutterSecureStorage().read(
          key: 'sylphy_identity_vault_secret_v1',
        ),
        isNull,
      );
    },
  );

  test('a late unlock response cannot undo a newer lock', () async {
    final backend = _SecurityBackend();
    final release = Completer<void>();
    final controller = AppSecurityController(
      supportDirectory: () async => Directory.systemTemp,
      command: (request) async {
        if (request['command'] == 'unlock_vault') await release.future;
        return backend.call(request);
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final opening = controller.unlock('twelve random words');
    await Future<void>.delayed(Duration.zero);
    await controller.lock();
    release.complete();
    await opening;
    expect(controller.locked, isTrue);
    expect(backend.locked, isTrue);
  });

  testWidgets(
    'passphrase settings activate protection and expose lock controls',
    (tester) async {
      final backend = _SecurityBackend(enabled: false);
      final controller = backend.controller();
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              AppSecurityHost(controller: controller, child: child!),
          home: const Scaffold(
            body: SingleChildScrollView(child: AppSecuritySettings()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('passphrase-encryption')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('new-passphrase')),
        'twelve random words',
      );
      await tester.enterText(
        find.byKey(const ValueKey('confirm-passphrase')),
        'twelve random words',
      );
      await tester.tap(find.text('Attiva protezione'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(controller.enabled, isTrue);
      expect(
        find.byKey(const ValueKey('automatic-lock-timeout')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('wipe-and-lock')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'idle deadline resets on input and background policy is configurable',
    (tester) async {
      final backend = _SecurityBackend();
      final controller = backend.controller();
      await controller.initialize();
      await controller.unlock('twelve random words');
      await controller.updatePolicy(seconds: 30, onBackground: false);
      controller.backgrounded();
      expect(controller.locked, isFalse);
      await tester.pump(const Duration(seconds: 20));
      controller.userActivity();
      await tester.pump(const Duration(seconds: 20));
      expect(controller.locked, isFalse);
      await tester.pump(const Duration(seconds: 11));
      expect(controller.locked, isTrue);
      await controller.unlock('twelve random words');
      await controller.updatePolicy(onBackground: true);
      controller.backgrounded();
      expect(controller.locked, isTrue);
      await tester.pump();
      controller.dispose();
    },
  );

  testWidgets(
    'app reads the encrypted profile only after unlocking and reloads after locking',
    (tester) async {
      final backend = _SecurityBackend();
      final controller = backend.controller();
      final profiles = _CountingProfiles();
      await tester.pumpWidget(
        SylphyApp(appSecurity: controller, profileStore: profiles),
      );
      await tester.pumpAndSettle();
      expect(profiles.loads, 0);
      expect(find.text('Sylphy è bloccato'), findsOneWidget);
      await controller.unlock('twelve random words');
      await tester.pumpAndSettle();
      expect(profiles.loads, 1);
      expect(
        find.text('Nessuna conversazione sicura'),
        findsAtLeastNWidgets(1),
      );
      await controller.lock();
      await tester.pumpAndSettle();
      expect(find.text('Nessuna conversazione sicura'), findsNothing);
      await controller.unlock('twelve random words');
      await tester.pumpAndSettle();
      expect(profiles.loads, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'lock disposes sensitive routes and restores a fresh navigator after unlock',
    (tester) async {
      final backend = _SecurityBackend();
      final controller = backend.controller();
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              AppSecurityHost(controller: controller, child: child!),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(
                      body: Text('Sensitive dialog and draft'),
                    ),
                  ),
                ),
                child: const Text('Private home'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private home'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('unlock-passphrase')),
        'incorrect',
      );
      await tester.tap(find.byKey(const ValueKey('unlock-vault')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Passphrase errata'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('unlock-passphrase')),
        'twelve random words',
      );
      await tester.tap(find.byKey(const ValueKey('unlock-vault')));
      await tester.pumpAndSettle();
      expect(find.text('Private home'), findsOneWidget);
      await tester.tap(find.text('Private home'));
      await tester.pumpAndSettle();
      expect(find.text('Sensitive dialog and draft'), findsOneWidget);
      await controller.lock();
      await tester.pumpAndSettle();
      expect(find.text('Sensitive dialog and draft'), findsNothing);
      expect(find.text('Private home'), findsNothing);
      await controller.unlock('twelve random words');
      await tester.pumpAndSettle();
      expect(find.text('Private home'), findsOneWidget);
      expect(find.text('Sensitive dialog and draft'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}

class _SecurityBackend {
  _SecurityBackend({this.enabled = true});
  bool enabled;
  bool locked = true;
  bool rejectEnable = false;
  int seconds = 300;
  bool background = true;
  Map<String, dynamic> get status => {
    'enabled': enabled,
    'locked': enabled && locked,
    'policy': {'inactivity_seconds': seconds, 'lock_on_background': background},
  };
  AppSecurityController controller() => AppSecurityController(
    command: call,
    supportDirectory: () async => Directory.systemTemp,
  );
  Future<NativeCoreResponse> call(Map<String, Object> request) async {
    switch (request['command']) {
      case 'enable_passphrase':
        if (rejectEnable) {
          return const NativeCoreResponse(
            ok: false,
            code: 'internal_error',
            data: {},
          );
        }
        expect(request['device_secret'], 'a' * 43);
        enabled = true;
        locked = false;
      case 'unlock_vault':
        if (request['passphrase'] != 'twelve random words') {
          return const NativeCoreResponse(
            ok: false,
            code: 'authentication_failed',
            data: {},
          );
        }
        locked = false;
      case 'lock_vault':
        locked = true;
      case 'set_lock_policy':
        seconds = request['inactivity_seconds'] as int;
        background = request['lock_on_background'] as bool;
    }
    return NativeCoreResponse(ok: true, code: 'ok', data: status);
  }
}

class _CountingProfiles implements UserProfileStore {
  int loads = 0;
  @override
  Future<UserProfile?> load() async {
    loads++;
    return const UserProfile(displayName: 'Ada');
  }

  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async => UserProfile(displayName: displayName, photoBytes: photoBytes);
}
