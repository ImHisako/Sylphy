import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/privacy/privacy_settings.dart';
import 'package:sylphy/core/profile/user_profile.dart';

void main() {
  test('accepts the first authenticated contact request by default', () {
    expect(const PrivacySettings().allowUnknownContacts, isTrue);
  });

  test('migrates the version 1 incoming-contact default to enabled', () {
    final migrated = PrivacySettings.fromJson({
      'version': 1,
      'allow_unknown_contacts': false,
    });

    expect(migrated.allowUnknownContacts, isTrue);
    expect(migrated.toJson()['version'], 2);
  });

  test('preserves an explicit version 2 incoming-contact opt-out', () {
    final settings = PrivacySettings.fromJson({
      'version': 2,
      'allow_unknown_contacts': false,
    });

    expect(settings.allowUnknownContacts, isFalse);
  });

  test('persists profile and read-receipt privacy choices', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sylphy-privacy-test-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final controller = PrivacySettingsController(
      cipher: const _TestCipher(),
      supportDirectory: () async => directory,
    );
    await controller.load();
    await controller.update(
      controller.value.copyWith(
        shareProfilePhoto: false,
        sendReadReceipts: false,
        showReadReceipts: false,
      ),
    );

    final restored = PrivacySettingsController(
      cipher: const _TestCipher(),
      supportDirectory: () async => directory,
    );
    await restored.load();

    expect(restored.value.shareProfilePhoto, isFalse);
    expect(restored.value.sendReadReceipts, isFalse);
    expect(restored.value.showReadReceipts, isFalse);
  });

  test('corrupt encrypted settings fail closed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sylphy-privacy-corrupt-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final privacyDirectory = Directory('${directory.path}/privacy');
    await privacyDirectory.create(recursive: true);
    await File(
      '${privacyDirectory.path}/settings-v2.vault',
    ).writeAsString('not-a-valid-record');

    final controller = PrivacySettingsController(
      cipher: const _RejectingCipher(),
      supportDirectory: () async => directory,
    );
    await controller.load();

    expect(controller.storageError, isNotNull);
    expect(controller.value.shareProfilePhoto, isFalse);
    expect(controller.value.shareDisplayName, isFalse);
    expect(controller.value.showOnlineStatus, isFalse);
    expect(controller.value.allowUnknownContacts, isFalse);
  });

  test(
    'serializes rapid privacy updates without losing the last value',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sylphy-privacy-concurrent-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final controller = PrivacySettingsController(
        cipher: const _TestCipher(),
        supportDirectory: () async => directory,
      );
      await controller.load();

      await Future.wait([
        controller.update(controller.value.copyWith(shareProfilePhoto: false)),
        controller.update(
          controller.value.copyWith(
            shareProfilePhoto: false,
            shareDisplayName: false,
          ),
        ),
      ]);
      final restored = PrivacySettingsController(
        cipher: const _TestCipher(),
        supportDirectory: () async => directory,
      );
      await restored.load();
      expect(restored.value.shareProfilePhoto, isFalse);
      expect(restored.value.shareDisplayName, isFalse);
    },
  );
}

class _TestCipher implements LocalDataCipher {
  const _TestCipher();

  @override
  Future<Uint8List> open(Uint8List record) async =>
      Uint8List.fromList(record.reversed.toList());

  @override
  Future<Uint8List> protect(Uint8List plaintext) async =>
      Uint8List.fromList(plaintext.reversed.toList());
}

class _RejectingCipher implements LocalDataCipher {
  const _RejectingCipher();

  @override
  Future<Uint8List> open(Uint8List record) =>
      Future.error(const FormatException('corrupt'));

  @override
  Future<Uint8List> protect(Uint8List plaintext) async => plaintext;
}
