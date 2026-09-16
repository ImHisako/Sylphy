import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/features/messenger/safe_attachment_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rejects excessive dimensions and pixel budget', () {
    for (final size in [
      (0, 1),
      (8193, 1),
      (1, 8193),
      (8192, 8192),
      (4097, 4096),
    ]) {
      expect(
        () => validateAttachmentImageDimensions(size.$1, size.$2),
        throwsA(isA<UnsafeAttachmentImage>()),
      );
    }
    validateAttachmentImageDimensions(4096, 4096);
  });

  test(
    'huge compressed PNG is rejected from metadata before bitmap decode',
    () async {
      // A valid IHDR advertises a huge canvas, with tiny compressed content.
      final bytes = png(10000, 10000, pixels: Uint8List(5));
      expect(bytes.length, lessThan(1024));
      await expectLater(
        decodeAttachmentImage(bytes),
        throwsA(isA<UnsafeAttachmentImage>()),
      );
      await expectLater(
        decodeAttachmentImage(bytes, targetEdge: 2048),
        throwsA(isA<UnsafeAttachmentImage>()),
      );
    },
  );

  test(
    'valid images decode to a bounded thumbnail without upscaling',
    () async {
      final image = await decodeAttachmentImage(
        png(1200, 800),
        targetEdge: 300,
      );
      expect(image.width, 300);
      expect(image.height, 200);
      image.dispose();
      final tiny = await decodeAttachmentImage(png(1, 1), targetEdge: 2048);
      expect(tiny.width, 1);
      expect(tiny.height, 1);
      tiny.dispose();
    },
  );

  test('animated GIF is rejected before decoding any frame', () async {
    final header = [
      ...ascii.encode('GIF89a'),
      1,
      0,
      1,
      0,
      0x80,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255,
    ];
    final frame = [
      0x21,
      0xf9,
      4,
      1,
      0,
      0,
      0,
      0,
      0x2c,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      0x44,
      1,
      0,
    ];
    await expectLater(
      decodeAttachmentImage(
        Uint8List.fromList([...header, ...frame, ...frame, 0x3b]),
      ),
      throwsA(isA<UnsafeAttachmentImage>()),
    );
  });

  test(
    'corrupt, oversized and cancelled images do not poison later decodes',
    () async {
      await expectLater(
        decodeAttachmentImage(Uint8List.fromList([1, 2, 3])),
        throwsA(anything),
      );
      await expectLater(
        decodeAttachmentImage(Uint8List(2 * 1024 * 1024 + 1)),
        throwsA(isA<UnsafeAttachmentImage>()),
      );
      await expectLater(
        decodeAttachmentImage(png(1, 1), isCurrent: () => false),
        throwsA(isA<UnsafeAttachmentImage>()),
      );
      final image = await decodeAttachmentImage(png(1, 1));
      image.dispose();
    },
  );

  testWidgets(
    'rejected preview offers saving and survives disposal during decode',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SafeAttachmentImage(
            bytes: png(10000, 10000, pixels: Uint8List(5)),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(
        find.text('Anteprima non disponibile.\nPuoi salvare il file.'),
        findsOneWidget,
      );
      await tester.pumpWidget(
        MaterialApp(home: SafeAttachmentImage(bytes: png(1200, 800))),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Uint8List png(int width, int height, {Uint8List? pixels}) {
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final builder = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    var crc = 0xffffffff;
    for (final byte in body) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
      }
    }
    builder.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    builder.add(body);
    builder.add(
      (ByteData(4)..setUint32(0, crc ^ 0xffffffff)).buffer.asUint8List(),
    );
  }

  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', zlib.encode(pixels ?? Uint8List(height * (1 + width * 4))));
  chunk('IEND', []);
  return builder.takeBytes();
}
