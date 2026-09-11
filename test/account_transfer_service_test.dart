import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/identity/account_transfer_service.dart';

void main() {
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
