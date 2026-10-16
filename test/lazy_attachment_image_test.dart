import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/features/messenger/lazy_attachment_image.dart';

void main() {
  testWidgets('a preview disposed while loading clears its late plaintext', (
    tester,
  ) async {
    final pending = Completer<Uint8List>();
    var calls = 0;
    Widget preview() => MaterialApp(
      home: LazyAttachmentImage(
        id: 'file',
        loadBytes: () {
          calls++;
          return pending.future;
        },
      ),
    );
    await tester.pumpWidget(preview());
    expect(calls, 1);
    await tester.pumpWidget(preview());
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    final bytes = Uint8List.fromList([1, 2, 3]);
    pending.complete(bytes);
    await tester.pump();
    expect(bytes, [0, 0, 0]);
    expect(tester.takeException(), isNull);
  });
}
