import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../core/messaging/secure_messaging_bridge.dart';

const maxAttachmentImagePixels = 16 * 1024 * 1024;
const maxAttachmentImageDimension = 8192;

class UnsafeAttachmentImage implements Exception {
  const UnsafeAttachmentImage();
}

void validateAttachmentImageDimensions(int width, int height) {
  if (width <= 0 ||
      height <= 0 ||
      width > maxAttachmentImageDimension ||
      height > maxAttachmentImageDimension ||
      width * height > maxAttachmentImagePixels) {
    throw const UnsafeAttachmentImage();
  }
}

// Serialize decoding so a list of attachments cannot allocate many full source
// bitmaps concurrently. Each widget owns and disposes its resized ui.Image.
Future<void> _decodeTail = Future<void>.value();

Future<ui.Image> decodeAttachmentImage(
  Uint8List bytes, {
  int targetEdge = 1024,
  bool Function()? isCurrent,
}) {
  final result = _decodeTail.then((_) async {
    if (bytes.isEmpty ||
        bytes.length > maxAttachmentBytes ||
        isCurrent?.call() == false) {
      throw const UnsafeAttachmentImage();
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // ImageDescriptor reads metadata without decoding a bitmap.
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      validateAttachmentImageDimensions(descriptor.width, descriptor.height);
      if (isCurrent?.call() == false) throw const UnsafeAttachmentImage();
      final edge = targetEdge.clamp(1, 2048);
      final scale = math.min(
        1.0,
        edge / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).floor()),
        targetHeight: math.max(1, (descriptor.height * scale).floor()),
      );
      // Animated files remain downloadable; never decode their frame sequence.
      if (codec.frameCount != 1 || isCurrent?.call() == false) {
        throw const UnsafeAttachmentImage();
      }
      return (await codec.getNextFrame()).image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  });
  _decodeTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  return result;
}

class SafeAttachmentImage extends StatefulWidget {
  const SafeAttachmentImage({
    super.key,
    required this.bytes,
    this.expanded = false,
    this.fallback,
    this.previewEdge = 600,
  });
  final Uint8List bytes;
  final bool expanded;
  final Widget? fallback;
  final int previewEdge;

  @override
  State<SafeAttachmentImage> createState() => _SafeAttachmentImageState();
}

class _SafeAttachmentImageState extends State<SafeAttachmentImage> {
  ui.Image? _image;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SafeAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.bytes, oldWidget.bytes) ||
        widget.expanded != oldWidget.expanded ||
        widget.previewEdge != oldWidget.previewEdge) {
      _image?.dispose();
      _image = null;
      _failed = false;
      _load();
    }
  }

  void _load() {
    final generation = ++_generation;
    unawaited(
      decodeAttachmentImage(
        widget.bytes,
        targetEdge: widget.expanded ? 2048 : widget.previewEdge,
        isCurrent: () => mounted && generation == _generation,
      ).then(
        (image) {
          if (!mounted || generation != _generation) {
            image.dispose();
            return;
          }
          setState(() => _image = image);
        },
        onError: (Object _, StackTrace _) {
          if (mounted && generation == _generation) {
            setState(() => _failed = true);
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return widget.fallback ??
          const SizedBox(
            width: 300,
            height: 120,
            child: Center(
              child: Text(
                'Anteprima non disponibile.\nPuoi salvare il file.',
                textAlign: TextAlign.center,
              ),
            ),
          );
    }
    if (_image == null) {
      return widget.fallback ??
          const SizedBox(
            width: 300,
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          );
    }
    return RawImage(
      image: _image,
      width: widget.expanded ? null : 300,
      height: widget.expanded ? null : 220,
      fit: widget.expanded ? BoxFit.contain : BoxFit.cover,
    );
  }
}
