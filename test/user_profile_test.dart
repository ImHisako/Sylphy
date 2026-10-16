import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/profile/user_profile.dart';

void main() {
  test(
    'committed import profile recovers after a failed frontend save',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sylphy-profile-import-',
      );
      final cipher = _FlakyCipher();
      final store = FileUserProfileStore(
        cipher: cipher,
        supportDirectory: () async => root,
      );
      final pending = File(
        '${root.path}/native/identity/imported-profile.vault',
      );
      try {
        cipher.failWrites = false;
        await store.save(displayName: 'Previous account');
        await pending.parent.create(recursive: true);
        final plaintext = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'version': 2,
              'display_name': 'Imported account',
              'photo_base64': base64Encode([1, 2, 3]),
            }),
          ),
        );
        await pending.writeAsBytes(
          await const _TestCipher().protect(plaintext),
        );
        cipher.failWrites = true;
        expect(await store.load(), isNull);
        expect(await pending.exists(), true);
        cipher.failWrites = false;
        final imported = await store.load();
        expect(imported?.displayName, 'Imported account');
        expect(imported?.photoBytes, [1, 2, 3]);
        expect(await pending.exists(), false);
        expect((await store.load())?.displayName, 'Imported account');
      } finally {
        for (final file in root.listSync(recursive: true).whereType<File>()) {
          await file.delete();
        }
        await pending.parent.delete();
        await Directory('${root.path}/native').delete();
        await Directory('${root.path}/profile').delete();
        await root.delete();
      }
    },
  );
  test('persists the first-run profile and optional photo locally', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'sylphy-profile-test-',
    );
    addTearDown(() => supportDirectory.delete(recursive: true));
    final store = FileUserProfileStore(
      cipher: const _TestCipher(),
      supportDirectory: () async => supportDirectory,
    );
    final photo = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

    await store.save(displayName: '  Ada   Lovelace  ', photoBytes: photo);
    final restored = await store.load();

    expect(restored?.displayName, 'Ada Lovelace');
    expect(restored?.initials, 'AL');
    expect(restored?.photoBytes, photo);
    final stored = await File(
      '${supportDirectory.path}${Platform.pathSeparator}profile'
      '${Platform.pathSeparator}profile-v2.vault',
    ).readAsBytes();
    expect(String.fromCharCodes(stored), isNot(contains('Ada Lovelace')));
  });

  test('requires a non-empty bounded display name', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'sylphy-profile-invalid-test-',
    );
    addTearDown(() => supportDirectory.delete(recursive: true));
    final store = FileUserProfileStore(
      cipher: const _TestCipher(),
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

class _TestCipher implements LocalDataCipher {
  const _TestCipher();

  @override
  Future<Uint8List> open(Uint8List record) async =>
      Uint8List.fromList(record.reversed.toList());

  @override
  Future<Uint8List> protect(Uint8List plaintext) async =>
      Uint8List.fromList(plaintext.reversed.toList());
}

class _FlakyCipher extends _TestCipher {
  bool failWrites = false;
  @override
  Future<Uint8List> protect(Uint8List plaintext) => failWrites
      ? Future.error(StateError('storage busy'))
      : super.protect(plaintext);
}
