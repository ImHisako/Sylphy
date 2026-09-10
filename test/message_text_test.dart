import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/features/messenger/message_text.dart';

void main() {
  test(
    'mentions and links keep the complete text and distinct inline colors',
    () {
      const text =
          'Ciao @Alice_Rossi: guarda https://example.com/@Bob e example.org/test #novità';
      for (final outgoing in [false, true]) {
        final span = messageTextSpan(text, outgoing: outgoing);
        expect(span.toPlainText(), text);
        final parts = span.children!.cast<TextSpan>();
        final mention = parts.singleWhere(
          (part) => part.text == '@Alice_Rossi',
        );
        final link = parts.singleWhere(
          (part) => part.text == 'https://example.com/@Bob',
        );
        expect(mention.style!.color, isNot(link.style!.color));
        expect(link.style!.decoration, TextDecoration.underline);
        expect(parts.where((part) => part.text == '@Bob'), isEmpty);
        expect(
          parts
              .singleWhere((part) => part.text == 'example.org/test')
              .style!
              .color,
          link.style!.color,
        );
      }
    },
  );
}
