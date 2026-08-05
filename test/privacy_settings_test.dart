import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/privacy/privacy_settings.dart';

void main() {
  test('persists profile and read-receipt privacy choices', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sylphy-privacy-test-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final controller = PrivacySettingsController(
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
      supportDirectory: () async => directory,
    );
    await restored.load();

    expect(restored.value.shareProfilePhoto, isFalse);
    expect(restored.value.sendReadReceipts, isFalse);
    expect(restored.value.showReadReceipts, isFalse);
  });
}
