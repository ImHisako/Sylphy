import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/diagnostics/app_log.dart';

void main() {
  late Directory root;
  late File settings;
  late File output;
  late List<String?> console;
  late DebugPrintCallback originalPrint;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sylphy-log-test-');
    final diagnostics = await Directory('${root.path}/diagnostics').create();
    settings = File('${diagnostics.path}/developer-options.json');
    output = File('${diagnostics.path}/sylphy-diagnostics.jsonl');
    await output.writeAsString('');
    console = [];
    originalPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => console.add(message);
  });

  tearDown(() async {
    debugPrint = originalPrint;
    await root.delete(recursive: true);
  });

  test(
    'logging stays off by default and with legacy verbose-only preferences',
    () async {
      for (final existing in [false, true]) {
        if (existing) await settings.writeAsString('{"verbose_logging":true}');
        final log = AppLog.forTesting(supportDirectory: () async => root);
        log.recordError(
          category: 'app',
          action: 'startup',
          error: StateError('test'),
        );
        await log.initialize();
        expect(log.loggingEnabled, false);
        expect(log.entries, isEmpty);
        expect(console, isEmpty);
        expect(await output.readAsString(), isEmpty);
        log.dispose();
      }
    },
  );

  test(
    'disabled logging blocks errors, forced events, disk and console',
    () async {
      await settings.writeAsString(
        '{"logging_enabled":true,"verbose_logging":true}',
      );
      final log = AppLog.forTesting(supportDirectory: () async => root);
      await log.initialize();
      expect(log.loggingEnabled, true);
      expect(log.verboseEnabled, true);
      await log.setLoggingEnabled(false);
      final before = await output.readAsString();
      final count = log.entries.length;
      console.clear();

      log.record(category: 'test', action: 'normal');
      log.record(category: 'test', action: 'forced', force: true);
      log.record(category: 'test', action: 'verbose', verbose: true);
      log.recordError(
        category: 'test',
        action: 'error',
        error: StateError('test'),
      );
      await log.setVerboseEnabled(false);
      await log.setVerboseEnabled(true);
      expect(log.entries.length, count);
      expect(console, isEmpty);
      expect(await output.readAsString(), before);
      expect(jsonDecode(await settings.readAsString()), {
        'logging_enabled': false,
        'verbose_logging': true,
      });

      await log.clear();
      expect(log.entries, isEmpty);
      expect(await output.readAsString(), isEmpty);
      await log.setLoggingEnabled(true);
      log.recordError(
        category: 'test',
        action: 'resumed',
        error: StateError('test'),
      );
      await log.setLoggingEnabled(false);
      expect(log.entries.single.action, 'resumed');
      expect(console, hasLength(1));
      log.dispose();
    },
  );

  test(
    'restart with logging disabled discards buffered startup errors',
    () async {
      await settings.writeAsString(
        '{"logging_enabled":false,"verbose_logging":true}',
      );
      await output.writeAsString('previous log\n');
      final log = AppLog.forTesting(supportDirectory: () async => root);
      log.recordError(
        category: 'app',
        action: 'startup',
        error: StateError('test'),
      );
      expect(console, isEmpty);
      await log.initialize();
      log.recordError(
        category: 'app',
        action: 'later',
        error: StateError('test'),
      );
      expect(log.loggingEnabled, false);
      expect(log.entries, isEmpty);
      expect(console, isEmpty);
      expect(await output.readAsString(), 'previous log\n');
      log.dispose();
    },
  );
}
