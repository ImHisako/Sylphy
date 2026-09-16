import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/native/native_core.dart';

void main() {
  const busy = NativeCoreResponse(
    ok: false,
    code: 'feature_unavailable',
    data: {},
  );
  const details = NativeCoreResponse(
    ok: true,
    code: 'ok',
    data: {
      'channels': [
        {'id': 'general', 'name': 'Generale'},
      ],
    },
  );

  test(
    'group reads wait behind account changes after a busy local read',
    () async {
      final accountTransition = Completer<void>();
      var queuedReads = 0;
      var completed = false;
      final result =
          readGroupDetailsWithAccountRetry(
            read: () async => busy,
            queuedRead: () async {
              queuedReads++;
              await accountTransition.future;
              return details;
            },
          ).then((value) {
            completed = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(queuedReads, 1);
      expect(completed, isFalse);
      accountTransition.complete();
      expect(await result, same(details));
    },
  );

  test(
    'successful local reads and permanent failures never enter the queue',
    () async {
      for (final response in [
        details,
        const NativeCoreResponse(ok: false, code: 'invalid_input', data: {}),
      ]) {
        expect(
          await readGroupDetailsWithAccountRetry(
            read: () async => response,
            queuedRead: () async => throw StateError('unexpected retry'),
          ),
          same(response),
        );
      }
    },
  );

  test('an unavailable core is retried only once', () async {
    var attempts = 0;
    expect(
      await readGroupDetailsWithAccountRetry(
        read: () async => busy,
        queuedRead: () async {
          attempts++;
          return busy;
        },
      ),
      same(busy),
    );
    expect(attempts, 1);
  });
}
