import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/diagnostics/performance_timings.dart';
import 'package:sylphy/core/messaging/models.dart';

void main() {
  tearDown(PerformanceTimings.clear);
  test(
    'late completions from a reset measurement cannot repopulate the report',
    () {
      final old = PerformanceTimings.generation;
      PerformanceTimings.clear();
      PerformanceTimings.record(
        PerformanceStage.commandQueue,
        const Duration(seconds: 5),
        generation: old,
      );
      expect(
        ((PerformanceTimings.snapshot()['stages'] as Map)['commandQueue']
            as Map)['total'],
        0,
      );
    },
  );
  test(
    'outgoing uploads stay available locally and replicated downloads retain their states',
    () {
      ChatMessage message(String state) => ChatMessage(
        id: 'file',
        authorId: 'me',
        body: 'file',
        sentAt: DateTime.fromMillisecondsSinceEpoch(1),
        isOutgoing: true,
        attachmentName: 'file.bin',
        attachmentState: state,
      );
      for (final state in ['upload_queued', 'uploading', 'upload_failed']) {
        expect(message(state).attachmentAvailable, isTrue);
        expect(message(state).attachmentDownloading, isFalse);
      }
      expect(message('pending').canDownloadAttachment, isTrue);
      expect(message('queued').attachmentDownloading, isTrue);
      expect(message('downloading').attachmentDownloading, isTrue);
    },
  );
  test(
    'bounded timing report preserves counts and honest empty percentiles',
    () {
      for (var i = 0; i < 200; i++) {
        PerformanceTimings.record(
          PerformanceStage.commandQueue,
          Duration(milliseconds: i),
        );
      }
      final report = PerformanceTimings.snapshot();
      final stages = report['stages'] as Map;
      final queued = stages['commandQueue'] as Map;
      expect(queued['sampled'], 128);
      expect(queued['total'], 200);
      expect(queued['p50_ms'], 135.0);
      expect(queued['p95_ms'], 193.0);
      expect((stages['inboxRefreshToFrame'] as Map)['p50_ms'], isNull);
      expect(jsonEncode(report), isNot(contains('message_id')));
      PerformanceTimings.clear();
      expect(
        ((PerformanceTimings.snapshot()['stages'] as Map)['commandQueue']
            as Map)['total'],
        0,
      );
    },
  );
}
