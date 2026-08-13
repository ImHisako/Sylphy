import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/identity/account_transfer_service.dart';

void main() {
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
