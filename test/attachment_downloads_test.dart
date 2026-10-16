import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/platform/attachment_downloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pickerChannel = MethodChannel('plugins.flutter.io/file_selector');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(pickerChannel, null));

  for (final lockWhilePicking in [true, false]) {
    test(
      'desktop save respects a lock during the picker: $lockWhilePicking',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'sylphy-save-test-',
        );
        final file = File('${directory.path}/attachment.bin');
        final picked = Completer<String>();
        final opened = Completer<void>();
        messenger.setMockMethodCallHandler(pickerChannel, (call) {
          expect(call.method, 'getSavePath');
          opened.complete();
          return picked.future;
        });
        var current = true;
        try {
          final saving = const AttachmentDownloads().save(
            fileName: 'attachment.bin',
            bytes: Uint8List.fromList([1, 2, 3]),
            isCurrent: () => current,
          );
          await opened.future;
          current = !lockWhilePicking;
          picked.complete(file.path);
          expect(await saving, lockWhilePicking ? isNull : file.path);
          expect(await file.exists(), !lockWhilePicking);
          if (!lockWhilePicking) expect(await file.readAsBytes(), [1, 2, 3]);
        } finally {
          if (await file.exists()) await file.delete();
          await directory.delete();
        }
      },
      skip: Platform.isAndroid,
    );
  }
}
