import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

class AttachmentDownloads {
  const AttachmentDownloads();

  static const _channel = MethodChannel('sylphy/platform');

  /// Returns the user-visible destination, or `null` when saving is cancelled.
  Future<String?> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>('saveFile', {
        'fileName': fileName,
        'bytes': bytes,
      });
    }
    final destination = await getSaveLocation(suggestedName: fileName);
    if (destination == null) return null;
    await File(destination.path).writeAsBytes(bytes, flush: true);
    return destination.path;
  }
}
