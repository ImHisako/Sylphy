import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/features/messenger/message_text.dart';

void main() {
  test('web destinations exclude non-web schemes and credentials', () {
    for (final token in [
      'javascript:alert(1)',
      'file:///tmp/video.mp4',
      'mailto:alice@example.com',
      'sylphy:invite',
      'alice@example.com',
      'https://alice@example.com',
      'https://example.com\\evil',
      'https://example.com/\u202etxt',
    ]) {
      expect(messageWebUri(token), isNull, reason: token);
    }
    expect(
      messageWebUri('www.example.com/video'),
      Uri.parse('https://www.example.com/video'),
    );
    expect(
      messageWebUri('example.com:8080/video'),
      Uri.parse('https://example.com:8080/video'),
    );
    expect(
      messageWebUri('https://example.com/watch?v=1&t=2).'),
      Uri.parse('https://example.com/watch?v=1&t=2'),
    );
    expect(
      messageWebUri('https://example.com/video_(1).'),
      Uri.parse('https://example.com/video_(1)'),
    );
    expect(memberMention('Alice Rossi-Bianchi'), '@Alice_Rossi_Bianchi');
  });

  testWidgets(
    'link requires confirmation and launches only the displayed URL',
    (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageText(
              'https://example.com/watch?v=123).',
              outgoing: false,
              openUrl: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(MessageText));
      await tester.pumpAndSettle();
      expect(
        find.text('Si aprirà una pagina nel browser esterno:'),
        findsOneWidget,
      );
      expect(find.text('https://example.com/watch?v=123'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await tester.tap(find.byType(MessageText));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apri nel browser'));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://example.com/watch?v=123')]);
    },
  );

  testWidgets('failed launch shows a useful error', (tester) async {
    for (final throwsError in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageText(
              'https://example.com',
              outgoing: false,
              openUrl: (_) async {
                if (throwsError) throw StateError('No browser');
                return false;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(MessageText));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apri nel browser'));
      await tester.pumpAndSettle();
      expect(
        find.text('Impossibile aprire il link nel browser.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets(
    'mentions are tappable without opening the browser and update safely',
    (tester) async {
      final mentions = <String>[];
      final opened = <Uri>[];
      Widget message(String text) => MaterialApp(
        home: Scaffold(
          body: MessageText(
            text,
            outgoing: true,
            onMention: mentions.add,
            openUrl: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pumpWidget(message('@Alice_Rossi'));
      await tester.tap(find.byType(MessageText));
      await tester.pumpAndSettle();
      expect(mentions, ['@Alice_Rossi']);
      expect(opened, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(message('@Bob'));
      await tester.tap(find.byType(MessageText));
      expect(mentions, ['@Alice_Rossi', '@Bob']);
      await tester.pumpWidget(
        message(
          'https://example.com/@Alice #tag alice@example.com javascript:alert(1)',
        ),
      );
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.byType(MessageText),
          matching: find.byType(RichText),
        ),
      );
      final interactive = <InlineSpan>[];
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.recognizer is TapGestureRecognizer) {
          interactive.add(span);
        }
        return true;
      });
      expect(interactive.length, 1);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

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
