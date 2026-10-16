import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/identity/identity_service.dart';
import 'package:sylphy/core/privacy/privacy_settings.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:sylphy/features/settings/identity_rotation_settings.dart';

void main() {
  testWidgets(
    'selects a preset, validates custom hours, and disables automatic changes',
    (tester) async {
      final privacy = _Privacy();
      final identity = _Identity();
      addTearDown(privacy.dispose);
      addTearDown(identity.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IdentityRotationSettings(
                identityService: identity,
                privacySettings: privacy,
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('identity-rotation-interval')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-interval-6')));
      await tester.pumpAndSettle();
      expect(privacy.value.identityRotationHours, 6);
      expect(identity.interval, 21600);
      expect(find.text('Ogni 6 ore'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('identity-rotation-interval')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-interval-custom')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('identity-custom-hours')),
        '0',
      );
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      expect(
        find.text('Inserisci un numero intero da 1 a 8760.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('identity-custom-hours')),
        '13',
      );
      await tester.tap(find.text('Salva'));
      await tester.pumpAndSettle();
      expect(privacy.value.identityRotationHours, 13);
      expect(identity.interval, 46800);
      await tester.tap(
        find.byKey(const ValueKey('identity-rotation-interval')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-interval-0')));
      await tester.pumpAndSettle();
      expect(identity.interval, 0);
      expect(find.text('Il cambio automatico è disattivato.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual action shows loading, prevents duplicate requests and reports completion',
    (tester) async {
      final privacy = _Privacy();
      final identity = _Identity();
      addTearDown(privacy.dispose);
      addTearDown(identity.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IdentityRotationSettings(
              identityService: identity,
              privacySettings: privacy,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('rotate-identity-now')));
      await tester.pump();
      expect(find.text('Cambio ID in corso…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('rotate-identity-now')),
            )
            .onPressed,
        isNull,
      );
      identity.finishRotation();
      await tester.pumpAndSettle();
      expect(
        find.text(
          'ID Sylphy cambiato. Puoi copiare quello nuovo dal tuo profilo.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _Identity extends IdentityService {
  _Identity() : super(nativeCore: null);
  int interval = 0;
  bool _busy = false;
  Completer<bool>? _rotation;
  @override
  bool get canRotate => true;
  @override
  bool get rotationPolicyPending => false;
  @override
  bool get rotationInProgress => _busy;
  @override
  Future<void> initialize({
    UserProfile? profile,
    bool shareDisplayName = true,
    bool shareProfilePhoto = true,
    bool forceRefresh = false,
    int? rotationIntervalSeconds,
  }) async {
    interval = rotationIntervalSeconds ?? interval;
    notifyListeners();
  }

  @override
  Future<bool> rotateNow() {
    _busy = true;
    _rotation = Completer<bool>();
    notifyListeners();
    return _rotation!.future;
  }

  void finishRotation() {
    _busy = false;
    _rotation!.complete(true);
    notifyListeners();
  }
}

class _Privacy extends PrivacySettingsController {
  _Privacy() : super(cipher: _Cipher());
  PrivacySettings _settings = const PrivacySettings();
  @override
  PrivacySettings get value => _settings;
  @override
  Future<void> update(PrivacySettings value) async {
    _settings = value;
    notifyListeners();
  }
}

class _Cipher implements LocalDataCipher {
  @override
  Future<Uint8List> open(Uint8List ciphertext) async => ciphertext;
  @override
  Future<Uint8List> protect(Uint8List plaintext) async => plaintext;
}
