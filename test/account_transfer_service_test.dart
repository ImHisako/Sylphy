import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/identity/account_transfer_service.dart';
import 'package:sylphy/core/identity/identity_service.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/core/profile/user_profile.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  test('local QR serves the encrypted document once and then closes', () async {
    final bytes = _document('YQ');
    final session = await AccountQrTransferSession.start(
      bytes,
      addressProvider: () async => ['192.168.1.20'],
    );
    final advertised = parseAccountQrPayload(session.qrPayload);
    final endpoint = advertised.replace(host: '127.0.0.1');
    final client = HttpClient();
    try {
      expect(session.state.value, AccountQrTransferState.waiting);
      final response = await (await client.getUrl(endpoint)).close();
      expect(response.statusCode, HttpStatus.ok);
      final received = await response.fold<List<int>>(
        [],
        (result, chunk) => result..addAll(chunk),
      );
      expect(received, bytes);
      await Future<void>.delayed(Duration.zero);
      expect(session.state.value, AccountQrTransferState.transferred);
      await expectLater(
        (() async => (await client.getUrl(endpoint)).close())(),
        // A reused keep-alive socket may close before its next HTTP header.
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
      );
    } finally {
      client.close(force: true);
      await session.dispose();
    }
  });
  test(
    'imports renamed files and normalizes padded transport base64',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sylphy-transfer-',
      );
      final core = _TransferCore();
      final profiles = _Profiles();
      final bytes = _document(' YQ==\n');
      final service = AccountTransferService(
        nativeCore: core,
        deviceSecretStore: _Secret(),
        profileStore: profiles,
        applicationSupportDirectory: () async => directory,
        pickFile: () async => XFile.fromData(bytes, name: 'renamed.bin'),
      );
      try {
        final picked = await service.pickBackupDocument();
        expect(
          await service.importFromDocument(
            bytes: picked!,
            transferPassword: 'transfer password',
          ),
          isA<UserProfile>(),
        );
        expect(core.receivedBackup, 'YQ');
        expect(core.receivedSecret, 'destination-secret');
        expect(profiles.saved?.displayName, 'Restored');
      } finally {
        await Directory('${directory.path}/native').delete();
        await directory.delete();
      }
    },
  );

  test('sharing preserves the actual filename for in-memory backups', () async {
    ShareParams? captured;
    final service = AccountTransferService(
      nativeCore: _TransferCore(),
      profileStore: _Profiles(),
      share: (params) async {
        captured = params;
        return const ShareResult('test', ShareResultStatus.success);
      },
    );
    await service.shareBackup(
      profile: const UserProfile(displayName: 'Source'),
      transferPassword: 'transfer password',
    );
    expect(captured!.fileNameOverrides, ['Sylphy-account.sylphy-account']);
    expect(
      parseBackupDocument(await captured!.files!.single.readAsBytes()),
      'YQ',
    );
  });

  test(
    'invalid documents never invoke import; native errors keep their code',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sylphy-transfer-',
      );
      final core = _TransferCore()..errorCode = 'authentication_failed';
      final profiles = _Profiles();
      final service = AccountTransferService(
        nativeCore: core,
        profileStore: profiles,
        deviceSecretStore: _Secret(),
        applicationSupportDirectory: () async => directory,
      );
      try {
        await expectLater(
          service.importFromDocument(
            bytes: utf8.encode('{}'),
            transferPassword: 'password 123',
          ),
          throwsA(isA<AccountTransferException>()),
        );
        expect(core.imports, 0);
        await expectLater(
          service.importFromDocument(
            bytes: _document('YQ'),
            transferPassword: 'password 123',
          ),
          throwsA(
            isA<AccountTransferException>().having(
              (error) => error.code,
              'code',
              'authentication_failed',
            ),
          ),
        );
        expect(profiles.saved, isNull);
      } finally {
        await Directory('${directory.path}/native').delete();
        await directory.delete();
      }
    },
  );

  test(
    'a committed account survives both profile and cleanup errors',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sylphy-transfer-',
      );
      final profiles = _Profiles()..fail = true;
      final service = AccountTransferService(
        nativeCore: _TransferCore(),
        profileStore: profiles,
        deviceSecretStore: _Secret(),
        applicationSupportDirectory: () async => directory,
      );
      try {
        await expectLater(
          service.importFromDocument(
            bytes: _document('YQ'),
            transferPassword: 'password 123',
          ),
          throwsA(
            isA<AccountTransferException>()
                .having(
                  (error) => error.code,
                  'code',
                  'profile_persistence_failed',
                )
                .having(
                  (error) => error.importedProfile?.displayName,
                  'committed profile',
                  'Restored',
                ),
          ),
        );
        expect(profiles.recoveryAttempted, true);
      } finally {
        await Directory('${directory.path}/native').delete();
        await directory.delete();
      }
    },
  );

  test(
    'transport envelopes reject unsupported formats and malformed base64',
    () {
      for (final bytes in [
        utf8.encode('not json'),
        _document('!!!!'),
        _document(''),
      ]) {
        expect(
          () => parseBackupDocument(bytes),
          throwsA(isA<AccountTransferException>()),
        );
      }
      expect(
        () => parseBackupDocument(
          utf8.encode(
            jsonEncode({
              'format': 'sylphy-account-backup',
              'version': 9,
              'backup_base64': 'YQ',
            }),
          ),
        ),
        throwsA(
          isA<AccountTransferException>().having(
            (error) => error.code,
            'code',
            'unsupported_version',
          ),
        ),
      );
    },
  );
  final exceedsLimit = throwsA(
    isA<AccountTransferException>().having(
      (error) => error.code,
      'code',
      'limit_exceeded',
    ),
  );

  test('rejects oversized backup metadata before opening the stream', () async {
    final file = _BackupFile(length: 131 * 1024 * 1024, chunks: []);
    await expectLater(readBackupFile(file), exceedsLimit);
    expect(file.opened, false);
  });

  test(
    'stops reading a growing backup before retaining the excess chunk',
    () async {
      final file = _BackupFile(
        length: 2,
        chunks: [
          [1, 2],
          [3, 4, 5],
          [6],
        ],
      );
      await expectLater(readBackupFile(file, maxBytes: 4), exceedsLimit);
      expect(file.yielded, 2);
      expect(file.cancelled, true);
    },
  );

  test(
    'accepts the exact limit and handles unknown or stale empty metadata',
    () async {
      for (final length in [0, 4]) {
        final file = _BackupFile(
          length: length,
          chunks: [
            [1, 2],
            [3, 4],
          ],
        );
        expect(await readBackupFile(file, maxBytes: 4), [1, 2, 3, 4]);
      }
      await expectLater(
        readBackupFile(_BackupFile(length: 0, chunks: [])),
        exceedsLimit,
      );
      await expectLater(
        readBackupFile(_BackupFile(length: 3, chunks: [])),
        exceedsLimit,
      );
    },
  );

  test('reads a real backup file as a bounded stream', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sylphy-backup-read-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/account.sylphy-account');
    await file.writeAsBytes([1, 2, 3, 4]);
    expect(await readBackupFile(XFile(file.path), maxBytes: 4), [1, 2, 3, 4]);
    await expectLater(
      readBackupFile(XFile(file.path), maxBytes: 3),
      exceedsLimit,
    );
  });

  String payloadFor(String url) =>
      jsonEncode({'format': 'sylphy-account-qr', 'version': 1, 'url': url});

  test('accepts a one-time Sylphy account endpoint on the local network', () {
    final endpoint = parseAccountQrPayload(
      payloadFor(
        'http://192.168.1.20:43123/sylphy-account/'
        'abcdefghijklmnopqrstuvwxyzABCDEF',
      ),
    );

    expect(endpoint.host, '192.168.1.20');
    expect(endpoint.port, 43123);
  });

  test('rejects account QR codes that target the public internet', () {
    expect(
      () => parseAccountQrPayload(
        payloadFor(
          'http://203.0.113.10:43123/sylphy-account/'
          'abcdefghijklmnopqrstuvwxyzABCDEF',
        ),
      ),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          'invalid_qr',
        ),
      ),
    );
  });

  test('rejects unrelated or malformed QR payloads', () {
    for (final payload in <String>[
      'https://example.com',
      jsonEncode({'format': 'other', 'version': 1}),
      payloadFor('http://192.168.1.2:80/admin'),
    ]) {
      expect(
        () => parseAccountQrPayload(payload),
        throwsA(isA<AccountTransferException>()),
      );
    }
  });

  test('uses a valid fallback address from a multi-interface QR code', () {
    final endpoint = parseAccountQrPayload(
      jsonEncode({
        'format': 'sylphy-account-qr',
        'version': 1,
        'url':
            'http://203.0.113.10:43123/sylphy-account/'
            'abcdefghijklmnopqrstuvwxyzABCDEF',
        'urls': [
          'http://203.0.113.10:43123/sylphy-account/'
              'abcdefghijklmnopqrstuvwxyzABCDEF',
          'http://10.0.0.5:43123/sylphy-account/'
              'abcdefghijklmnopqrstuvwxyzABCDEF',
        ],
      }),
    );

    expect(endpoint.host, '10.0.0.5');
  });

  test('account transfer errors expose their diagnostic code', () {
    expect(
      const AccountTransferException('qr_download_failed').toString(),
      'AccountTransferException(qr_download_failed)',
    );
  });
}

Uint8List _document(String encoded) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'format': 'sylphy-account-backup',
      'version': 1,
      'backup_base64': encoded,
    }),
  ),
);

class _Secret implements DeviceSecretStore {
  @override
  Future<String> getOrCreate() async => 'destination-secret';
}

class _Profiles implements UserProfileStore, UserProfileImportRecovery {
  UserProfile? saved;
  bool fail = false;
  bool recoveryAttempted = false;
  @override
  Future<UserProfile?> load() async => saved;
  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async {
    if (fail) throw StateError('profile storage unavailable');
    return saved = UserProfile(
      displayName: displayName,
      photoBytes: photoBytes,
    );
  }

  @override
  Future<void> invalidatePersistedProfile() async {
    recoveryAttempted = true;
    throw StateError('cleanup unavailable');
  }
}

class _TransferCore implements NativeAccountTransferApi {
  String? receivedBackup;
  String? receivedSecret;
  String? errorCode;
  int imports = 0;
  @override
  Future<NativeCoreResponse> exportAccountInBackground({
    required String transferPassword,
    required String displayName,
    String? avatarBase64,
  }) async => const NativeCoreResponse(
    ok: true,
    code: 'ok',
    data: {'backup_base64': 'YQ'},
  );
  @override
  Future<NativeCoreResponse> importAccountInBackground({
    required String transferPassword,
    required String backupBase64,
    required String storageDirectory,
    required String vaultPassword,
  }) async {
    imports++;
    receivedBackup = backupBase64;
    receivedSecret = vaultPassword;
    return errorCode != null
        ? NativeCoreResponse(ok: false, code: errorCode!, data: const {})
        : const NativeCoreResponse(
            ok: true,
            code: 'ok',
            data: {'display_name': 'Restored'},
          );
  }
}

class _BackupFile extends XFile {
  _BackupFile({required int length, required this.chunks})
    : _length = length,
      super('test-backup');

  final int _length;
  final List<List<int>> chunks;
  bool opened = false;
  bool cancelled = false;
  int yielded = 0;

  @override
  Future<int> length() async => _length;

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    opened = true;
    try {
      for (final chunk in chunks) {
        yielded++;
        yield Uint8List.fromList(chunk);
      }
    } finally {
      cancelled = true;
    }
  }
}
