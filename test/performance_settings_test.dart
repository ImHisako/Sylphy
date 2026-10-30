import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/features/settings/performance_settings.dart';

void main() {
  testWidgets(
    'performance report is local, readable and copyable without message data',
    (tester) async {
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final core = _Core();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PerformanceSettings(nativeCore: core)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('performance-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Upload attivi: 1'), findsOneWidget);
      expect(
        find.textContaining('Consegna diretta: 25.0 / 80.0 ms'),
        findsOneWidget,
      );
      await tester.tap(find.text('Copia report'));
      await tester.pumpAndSettle();
      final report = jsonDecode(clipboard!) as Map;
      expect(report['format'], 'sylphy-performance');
      expect(report['native']['active_uploads'], 1);
      expect(clipboard, isNot(contains('message_id')));
      await tester.tap(find.text('Azzera'));
      await tester.pumpAndSettle();
      expect(core.reset, isTrue);
      expect(find.text('Upload attivi: 1'), findsNothing);
    },
  );
}

class _Core extends Fake implements NativeCoreApi, NativePerformanceApi {
  bool reset = false;
  @override
  Future<NativeCoreResponse> performanceSnapshot({bool reset = false}) async {
    this.reset = reset;
    return const NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {
        'version': 1,
        'active_uploads': 1,
        'stages': {
          'direct': {'p50_ms': 25.0, 'p95_ms': 80.0, 'sampled': 20},
        },
      },
    );
  }
}
