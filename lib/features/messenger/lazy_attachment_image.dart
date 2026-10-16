import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'safe_attachment_image.dart';

/// Mounted only for visible previews. Fetched plaintext belongs to this widget.
class LazyAttachmentImage extends StatefulWidget {
  const LazyAttachmentImage({
    super.key,
    required this.id,
    this.bytes,
    this.loadBytes,
    this.expanded = false,
  });
  final String id;
  final Uint8List? bytes;
  final Future<Uint8List> Function()? loadBytes;
  final bool expanded;

  @override
  State<LazyAttachmentImage> createState() => _LazyAttachmentImageState();
}

class _LazyAttachmentImageState extends State<LazyAttachmentImage> {
  Uint8List? _owned;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LazyAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.id != oldWidget.id ||
        !identical(widget.bytes, oldWidget.bytes)) {
      _clear();
      _load();
    }
  }

  void _clear() {
    _generation++;
    _owned?.fillRange(0, _owned!.length, 0);
    _owned = null;
    _failed = false;
  }

  void _load() {
    if (widget.bytes != null) return;
    final generation = _generation;
    final load = widget.loadBytes;
    if (load == null) {
      _failed = true;
      return;
    }
    unawaited(() async {
      try {
        final bytes = await load();
        if (!mounted || generation != _generation) {
          bytes.fillRange(0, bytes.length, 0);
          return;
        }
        setState(() => _owned = bytes);
      } on Object {
        if (mounted && generation == _generation) {
          setState(() => _failed = true);
        }
      }
    }());
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.bytes ?? _owned;
    if (bytes != null) {
      return SafeAttachmentImage(bytes: bytes, expanded: widget.expanded);
    }
    return SizedBox(
      width: 300,
      height: 120,
      child: Center(
        child: _failed
            ? const Text('Anteprima non disponibile. Puoi salvare il file.')
            : const CircularProgressIndicator(),
      ),
    );
  }
}
