import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;
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
    'removing passphrase verifies and stages the existing key before commit',
    () async {
      final backend = _SecurityBackend();
      final controller = backend.controller();
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.unlock('twelve random words');
      await controller.disable('twelve random words');
      expect(controller.enabled, false);
      expect(controller.locked, false);
      expect(await PlatformDeviceSecretStore().getOrCreate(), 'a' * 43);
      expect(
        await const FlutterSecureStorage().read(
          key: 'sylphy_pending_unprotect_secret_v1',
        ),
        isNull,
      );
      await controller.close();
      expect(controller.locked, true);
      await controller.resumed();
      expect(controller.locked, false);
    },
  );

  test(
    'wrong passphrase preserves protection and never stages an opening key',
    () async {
      final backend = _SecurityBackend();
      final controller = backend.controller();
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.unlock('twelve random words');
      await expectLater(controller.disable('incorrect'), throwsException);
      expect(controller.enabled, true);
      expect(
        await const FlutterSecureStorage().read(
          key: 'sylphy_identity_vault_secret_v1',
        ),
        isNull,
      );
      expect(
        await const FlutterSecureStorage().read(
          key: 'sylphy_pending_unprotect_secret_v1',
        ),
        isNull,
      );
    },
  );

  test(
    'restart recovers the staged key after native removal committed',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'sylphy_pending_unprotect_secret_v1': 'a' * 43,
      });
      final backend = _SecurityBackend(enabled: false);
      final controller = backend.controller();
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.enabled, false);
      expect(await PlatformDeviceSecretStore().getOrCreate(), 'a' * 43);
    },
  );

  test('closing wipes and suspends an account without a passphrase', () async {
    final backend = _SecurityBackend(enabled: false);
    final controller = backend.controller();
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.close();
    expect(controller.locked, isTrue);
    expect(backend.suspended, isTrue);
    expect(backend.commands, contains('close_vault'));
    expect(
      await const FlutterSecureStorage().read(
        key: 'sylphy_identity_vault_secret_v1',
      ),
      'a' * 43,
    );
    await controller.resumed();
    expect(controller.locked, isFalse);
    expect(backend.suspended, isFalse);
  });

  test(
    'a foreground return during startup restores a wiped legacy account',
    () async {
      final backend = _SecurityBackend(enabled: false);
      final release = Completer<void>();
      final controller = AppSecurityController(
        supportDirectory: () async => Directory.systemTemp,
        command: (request) async {
          if (request['command'] == 'configure_security') {
            await release.future;
          }
          return backend.call(request);
        },
      );
      addTearDown(controller.dispose);
      final starting = controller.initialize();
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      await controller.resumed();
      release.complete();
      await starting;
      expect(controller.loaded, isTrue);
      expect(controller.locked, isFalse);
      expect(backend.suspended, isFalse);
    },
  );

  test('closing is not lost behind a pending lock', () async {
    final backend = _SecurityBackend();
    final release = Completer<void>();
    var delayLock = false;
    final controller = AppSecurityController(
      supportDirectory: () async => Directory.systemTemp,
      command: (request) async {
        if (delayLock && request['command'] == 'lock_vault') {
          await release.future;
        }
        return backend.call(request);
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.unlock('twelve random words');
    delayLock = true;
    final locking = controller.lock();
    final closing = controller.close();
    release.complete();
    await Future.wait([locking, closing]);
    expect(backend.suspended, isTrue);
    expect(backend.commands.last, 'close_vault');
    await controller.resumed();
    expect(controller.locked, isTrue);
    await controller.unlock('twelve random words');
    expect(controller.locked, isFalse);
  });

  test(
    'a delayed foreground resume cannot reopen a closed legacy account',
    () async {
      final backend = _SecurityBackend(enabled: false);
      final release = Completer<void>();
      var delayResume = false;
      final controller = AppSecurityController(
        supportDirectory: () async => Directory.systemTemp,
        command: (request) async {
          if (delayResume && request['command'] == 'resume_vault') {
            await release.future;
          }
          return backend.call(request);
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      delayResume = true;
      final resuming = controller.resumed();
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      release.complete();
      await resuming;
      expect(controller.locked, isTrue);
      expect(backend.suspended, isTrue);
    },
  );

  test('screen off has an independent lock condition', () async {
    final backend = _SecurityBackend();
    final controller = backend.controller();
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.unlock('twelve random words');
    await controller.updatePolicy(onBackground: false, onScreenOff: true);
    controller.screenOff();
    expect(controller.locked, isTrue);
    await controller.resumed();
    await controller.unlock('twelve random words');
    await controller.updatePolicy(onScreenOff: false);
    controller.screenOff();
    expect(controller.locked, isFalse);
  });

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
    'exit waits for wiping and disposes unprotected UI before native completion',
    (tester) async {
      final backend = _SecurityBackend(enabled: false);
      final release = Completer<void>();
      final profiles = _CountingProfiles();
      final controller = AppSecurityController(
        supportDirectory: () async => Directory.systemTemp,
        command: (request) async {
          if (request['command'] == 'close_vault') await release.future;
          return backend.call(request);
        },
      );
      await tester.pumpWidget(
        SylphyApp(appSecurity: controller, profileStore: profiles),
      );
      await tester.pumpAndSettle();
      expect(profiles.loads, 1);
      final exiting = tester.binding.handleRequestAppExit();
      await tester.pump();
      await tester.pump();
      expect(controller.cleaning, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(controller.locked, isTrue);
      expect(backend.suspended, isFalse);
      expect(find.text('Nessuna conversazione sicura'), findsNothing);
      release.complete();
      expect(await exiting, AppExitResponse.exit);
      expect(controller.cleaning, isFalse);
      expect(backend.suspended, isTrue);
      await controller.resumed();
      await tester.pumpAndSettle();
      expect(controller.locked, isFalse);
      expect(profiles.loads, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

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
      await tester.tap(find.byKey(const ValueKey('passphrase-encryption')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('remove-passphrase-input')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('remove-passphrase-input')),
        'twelve random words',
      );
      await tester.tap(find.byKey(const ValueKey('confirm-remove-passphrase')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(controller.enabled, false);
      expect(
        find.byKey(const ValueKey('automatic-lock-timeout')),
        findsNothing,
      );

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
      await controller.resumed();
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
  bool suspended = false;
  final List<Object?> commands = [];
  bool rejectEnable = false;
  int seconds = 300;
  bool background = true;
  bool screenOff = true;
  Map<String, dynamic> get status => {
    'enabled': enabled,
    'locked': suspended || (enabled && locked),
    'policy': {
      'inactivity_seconds': seconds,
      'lock_on_background': background,
      'lock_on_screen_off': screenOff,
    },
  };
  AppSecurityController controller() => AppSecurityController(
    command: call,
    supportDirectory: () async => Directory.systemTemp,
  );
  Future<NativeCoreResponse> call(Map<String, Object> request) async {
    commands.add(request['command']);
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
      case 'prepare_disable_passphrase':
        if (request['passphrase'] != 'twelve random words') {
          return const NativeCoreResponse(
            ok: false,
            code: 'authentication_failed',
            data: {},
          );
        }
        return NativeCoreResponse(
          ok: true,
          code: 'ok',
          data: {'device_secret': 'a' * 43},
        );
      case 'disable_passphrase':
        expect(
          await const FlutterSecureStorage().read(
            key: 'sylphy_pending_unprotect_secret_v1',
          ),
          request['device_secret'],
        );
        enabled = false;
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
        suspended = false;
      case 'lock_vault':
        locked = true;
      case 'close_vault':
        locked = true;
        suspended = true;
      case 'resume_vault':
        if (!enabled) suspended = false;
      case 'set_lock_policy':
        seconds = request['inactivity_seconds'] as int;
        background = request['lock_on_background'] as bool;
        screenOff = request['lock_on_screen_off'] as bool;
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
