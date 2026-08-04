import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/main.dart';

void main() {
  testWidgets('renders the protected messenger shell', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const SylphyApp());

    expect(find.text('Sylphy'), findsOneWidget);
    expect(find.text('Lina Moretti'), findsAtLeastNWidgets(1));
    expect(find.text('Anteprima protetta'), findsAtLeastNWidgets(1));
    expect(find.text('Core nativo richiesto'), findsAtLeastNWidgets(1));
  });

  testWidgets('sends a local demonstration message', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const SylphyApp());
    await tester.enterText(
      find.byKey(const ValueKey('message-composer')),
      'Messaggio di prova',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pump();

    expect(find.text('Messaggio di prova'), findsAtLeastNWidgets(1));
  });

  testWidgets('keeps the Veilid status readable on a mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const SylphyApp());
    await tester.pump();

    expect(find.text('Core Veilid non incluso'), findsOneWidget);
    expect(find.text('Scrivi'), findsOneWidget);
    await tester.tap(find.byTooltip('Stato protezione'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy di Sylphy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
