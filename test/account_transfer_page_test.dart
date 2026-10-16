import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/identity/account_transfer_service.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/core/privacy/privacy_settings.dart';
import 'package:sylphy/core/privacy/app_security.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/core/veilid/veilid_service.dart';
import 'package:sylphy/features/settings/account_transfer_page.dart';
import 'package:sylphy/features/settings/account_transfer_recovery.dart';
import 'package:sylphy/main.dart';

void main() {
  setUpAll(() async {
    if (Platform.environment['SYLPHY_CAPTURE_SETTINGS'] != '1') return;
    final directory = Platform.environment['SYLPHY_TEST_FONTS'];
    if (directory == null) return;
    for (final entry in {
      'Roboto': 'Roboto-Regular.ttf',
      'MaterialIcons': 'MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(
          File(
            '$directory/${entry.value}',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
    }
  });

  testWidgets('the app resumes an encrypted selection only after unlocking', (
    tester,
  ) async {
    final security = _LocalSecurity();
    await tester.pumpWidget(
      SylphyApp(profileStore: _Profiles(), appSecurity: security),
    );
    await tester.pumpAndSettle();
    final recovery = tester
        .widget<AccountTransferRecoveryScope>(
          find.byType(AccountTransferRecoveryScope),
        )
        .recovery;
    security.setLocked(true);
    await tester.pumpAndSettle();
    recovery.retain(_document(), recovery.generation);
    await tester.pumpAndSettle();
    expect(find.byType(AccountTransferPage), findsNothing);
    security.setLocked(false);
    await tester.pumpAndSettle();
    final page = tester.widget<AccountTransferPage>(
      find.byType(AccountTransferPage),
    );
    expect(parseBackupDocument(page.initialDocument!), 'YQ');
    expect(recovery.hasDocument, false);
    await tester.pumpWidget(const SizedBox());
    security.dispose();
  });
  testWidgets(
    'first launch offers importing without creating a dummy profile',
    (tester) async {
      await tester.pumpWidget(SylphyApp(profileStore: _Profiles()));
      await tester.pumpAndSettle();
      final useExisting = find.byKey(
        const ValueKey('onboarding-use-existing-account'),
      );
      await tester.ensureVisible(useExisting);
      await tester.tap(useExisting);
      await tester.pumpAndSettle();
      expect(find.byType(AccountTransferPage), findsOneWidget);
      expect(find.text('Ripristina il tuo account Sylphy'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'wrong transfer password can be retried without choosing the file again',
    (tester) async {
      final service = _Service()..error = 'authentication_failed';
      var restored = 0;
      final veilid = VeilidService(nativeCore: null);
      await tester.pumpWidget(
        MaterialApp(
          home: AccountTransferPage(
            mode: AccountTransferMode.receive,
            veilidService: veilid,
            service: service,
            onAccountImported: (_) => restored++,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('choose-account-file')));
      await tester.pumpAndSettle();
      final password = find.byKey(const ValueKey('transfer-password'));
      final restore = find.byKey(const ValueKey('restore-account'));
      await tester.scrollUntilVisible(password, 250);
      await tester.enterText(password, 'wrong password');
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('account-transfer-error-code')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('account-transfer-error-code')),
            )
            .data,
        'Codice errore: authentication_failed',
      );
      expect(restored, 0);
      expect(service.picks, 1);
      service.error = null;
      await tester.scrollUntilVisible(
        password,
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(password, 'correct password');
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(restored, 1);
      expect(service.imports, 2);
      expect(service.picks, 1);
      expect(find.text('Apri Sylphy'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      veilid.dispose();
    },
  );

  testWidgets('replacing an account requires a concrete confirmation', (
    tester,
  ) async {
    final service = _Service();
    final veilid = VeilidService(nativeCore: null);
    await tester.pumpWidget(
      MaterialApp(
        home: AccountTransferPage(
          mode: AccountTransferMode.receive,
          replaceExisting: true,
          veilidService: veilid,
          service: service,
          onAccountImported: (_) {},
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('choose-account-file')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('transfer-password')),
      250,
    );
    await tester.enterText(
      find.byKey(const ValueKey('transfer-password')),
      'password 123',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('restore-account')));
    await tester.tap(find.byKey(const ValueKey('restore-account')));
    await tester.pumpAndSettle();
    expect(
      find.text('Sostituire l’account su questo dispositivo?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(service.imports, 0);
    await tester.pumpWidget(const SizedBox());
    veilid.dispose();
  });

  testWidgets(
    'a picker completing after locking retains only its encrypted document',
    (tester) async {
      final pending = Completer<Uint8List?>();
      final service = _Service()..selection = pending;
      final recovery = AccountTransferRecovery();
      final veilid = VeilidService(nativeCore: null);
      await tester.pumpWidget(
        MaterialApp(
          home: AccountTransferRecoveryScope(
            recovery: recovery,
            child: AccountTransferPage(
              mode: AccountTransferMode.receive,
              veilidService: veilid,
              service: service,
              onAccountImported: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('choose-account-file')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      final bytes = _document();
      pending.complete(bytes);
      await tester.pump();
      expect(recovery.hasDocument, true);
      expect(service.imports, 0);
      expect(parseBackupDocument(recovery.take()!), 'YQ');
      recovery.dispose();
      veilid.dispose();
    },
  );

  test(
    'closing rejects late encrypted selections and clears retained bytes',
    () {
      final recovery = AccountTransferRecovery();
      final generation = recovery.generation;
      final held = _document();
      recovery.retain(held, generation);
      recovery.clear();
      expect(held.every((byte) => byte == 0), true);
      final late = _document();
      recovery.retain(late, generation);
      expect(late.every((byte) => byte == 0), true);
      expect(recovery.hasDocument, false);
      recovery.dispose();
    },
  );

  for (final width in [390.0, 1200.0]) {
    testWidgets('settings search opens separate categories at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final veilid = VeilidService(nativeCore: null);
      final settings = PrivacySettingsController(
        cipher: const UnavailableLocalDataCipher(),
      );
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: SylphyApp(
            veilidService: veilid,
            privacySettings: settings,
            profileStore: _Profiles(const UserProfile(displayName: 'Test')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-settings')));
      await tester.pumpAndSettle();
      if (Platform.environment['SYLPHY_CAPTURE_SETTINGS'] == '1') {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/settings-index-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'passphrase',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-section-security')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings-section-account')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'account',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-section-account')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('export-account')), findsOneWidget);
      expect(find.byKey(const ValueKey('import-account')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-index')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('settings-search')))
            .controller!
            .text,
        'account',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
      veilid.dispose();
    });
  }
}

Uint8List _document() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'format': 'sylphy-account-backup',
      'version': 1,
      'backup_base64': 'YQ',
    }),
  ),
);

class _Service extends AccountTransferService {
  _Service() : super(nativeCore: _Core(), profileStore: _Profiles());
  String? error;
  int picks = 0;
  int imports = 0;
  Completer<Uint8List?>? selection;
  @override
  Future<Uint8List?> pickBackupDocument() async {
    picks++;
    return selection?.future ?? _document();
  }

  @override
  Future<UserProfile> importFromDocument({
    required List<int> bytes,
    required String transferPassword,
  }) async {
    imports++;
    if (error != null) throw AccountTransferException(error!);
    return const UserProfile(displayName: 'Restored');
  }
}

class _Profiles implements UserProfileStore {
  _Profiles([this.profile]);
  final UserProfile? profile;
  @override
  Future<UserProfile?> load() async => profile;
  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async => UserProfile(displayName: displayName);
}

class _LocalSecurity extends AppSecurityController {
  _LocalSecurity()
    : super(
        command: (_) async =>
            const NativeCoreResponse(ok: true, code: 'ok', data: {}),
      );
  @override
  Future<void> initialize() async {
    loaded = true;
    locked = false;
    notifyListeners();
  }

  void setLocked(bool value) {
    locked = value;
    notifyListeners();
  }

  @override
  Future<void> close() async {}
}

class _Core implements NativeAccountTransferApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
