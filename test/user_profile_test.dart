import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/profile/user_profile.dart';

void main() {
  test('persists the first-run profile and optional photo locally', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'sylphy-profile-test-',
    );
    addTearDown(() => supportDirectory.delete(recursive: true));
    final store = FileUserProfileStore(
      supportDirectory: () async => supportDirectory,
    );
    final photo = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

    await store.save(displayName: '  Ada   Lovelace  ', photoBytes: photo);
    final restored = await store.load();

    expect(restored?.displayName, 'Ada Lovelace');
    expect(restored?.initials, 'AL');
    expect(restored?.photoBytes, photo);
  });

  test('requires a non-empty bounded display name', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'sylphy-profile-invalid-test-',
    );
    addTearDown(() => supportDirectory.delete(recursive: true));
    final store = FileUserProfileStore(
      supportDirectory: () async => supportDirectory,
    );

    await expectLater(
      store.save(displayName: '   '),
      throwsA(
        isA<ProfileException>().having(
          (error) => error.code,
          'code',
          'invalid_display_name',
        ),
      ),
    );
  });
}
