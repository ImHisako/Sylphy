import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

final Map<String, Future<void>> _fileOperationTails = {};

Future<T> _serializeFileOperation<T>(
  String path,
  Future<T> Function() operation,
) async {
  final previous = _fileOperationTails[path] ?? Future<void>.value();
  final gate = Completer<void>();
  final tail = gate.future;
  _fileOperationTails[path] = tail;
  try {
    await previous.onError((_, _) {});
    return await operation();
  } finally {
    gate.complete();
    if (identical(_fileOperationTails[path], tail)) {
      _fileOperationTails.remove(path);
    }
  }
}

Future<void> writeFileRecoverably(File destination, Uint8List bytes) =>
    _serializeFileOperation(destination.absolute.path, () async {
      await destination.parent.create(recursive: true);
      final suffix = Random.secure().nextInt(0x7fffffff).toRadixString(16);
      final temporary = File('${destination.path}.$suffix.tmp');
      final backup = File('${destination.path}.bak');
      await temporary.writeAsBytes(bytes, flush: true);
      var movedPrevious = false;
      try {
        if (await backup.exists()) await backup.delete();
        if (await destination.exists()) {
          await destination.rename(backup.path);
          movedPrevious = true;
        }
        await temporary.rename(destination.path);
        if (await backup.exists()) await backup.delete();
      } on Object {
        if (await temporary.exists()) await temporary.delete();
        if (movedPrevious &&
            !await destination.exists() &&
            await backup.exists()) {
          await backup.rename(destination.path);
        }
        rethrow;
      }
    });

Future<File?> recoverFile(File destination) async {
  if (await destination.exists()) return destination;
  final backup = File('${destination.path}.bak');
  if (!await backup.exists()) return null;
  await backup.rename(destination.path);
  return destination;
}

Future<void> eraseFileBestEffort(File file) async {
  if (!await file.exists()) return;
  RandomAccessFile? handle;
  try {
    final length = await file.length();
    handle = await file.open(mode: FileMode.writeOnly);
    final zeros = Uint8List(64 * 1024);
    var remaining = length;
    while (remaining > 0) {
      final count = min(remaining, zeros.length);
      await handle.writeFrom(zeros, 0, count);
      remaining -= count;
    }
    await handle.flush();
  } on Object {
    // Filesystems with copy-on-write may not support meaningful overwrites.
  } finally {
    try {
      await handle?.close();
    } on Object {
      // Continue with the best-effort deletion below.
    }
  }
  try {
    if (await file.exists()) await file.delete();
  } on Object {
    // Secure erasure is best-effort and must not break the completed write.
  }
}
