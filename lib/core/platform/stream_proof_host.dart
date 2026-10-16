import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../privacy/privacy_settings.dart';

bool get supportsStreamProof =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get supportsScreenshotControl =>
    supportsStreamProof ||
    (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

/// Covers routes until the native window acknowledges the capture preference.
class StreamProofHost extends StatefulWidget {
  const StreamProofHost({
    super.key,
    required this.settings,
    required this.child,
    this.androidCaptureAvailable,
  });

  final PrivacySettingsController settings;
  final Widget child;
  final bool? androidCaptureAvailable;

  @override
  State<StreamProofHost> createState() => _StreamProofHostState();
}

class _StreamProofHostState extends State<StreamProofHost> {
  static const _channel = MethodChannel('sylphy/screen_capture');
  bool? _applied;
  bool _lastConfirmed = false;
  bool get _supported =>
      supportsStreamProof ||
      (supportsScreenshotControl &&
          (widget.androidCaptureAvailable ?? Platform.isAndroid));
  bool get _desired => supportsStreamProof
      ? widget.settings.value.streamProof
      : !widget.settings.value.allowScreenshots;
  bool _running = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _applied = supportsStreamProof ? false : null;
    _lastConfirmed = !supportsStreamProof;
    widget.settings.addListener(_changed);
    _synchronize();
  }

  @override
  void didUpdateWidget(StreamProofHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) {
      oldWidget.settings.removeListener(_changed);
      widget.settings.addListener(_changed);
      _synchronize();
    }
  }

  void _changed() {
    setState(() => _failed = false);
    _synchronize();
  }

  Future<void> _synchronize() async {
    if (!_supported || !widget.settings.loaded || _running) return;
    _running = true;
    try {
      // Serialize native calls; a quick second toggle must win over the first.
      while (mounted && _applied != _desired) {
        final enabled = _desired;
        try {
          if (supportsStreamProof) {
            await _channel.invokeMethod<void>('setStreamProof', enabled);
          } else {
            await const MethodChannel(
              'sylphy/platform',
            ).invokeMethod<void>('setAllowScreenshots', !enabled);
          }
          _applied = enabled;
          _lastConfirmed = enabled;
        } on PlatformException {
          _failed = true;
          _applied =
              null; // A failed call may have partially changed native state.
          break;
        } on MissingPluginException {
          _failed = true;
          _applied =
              null; // A failed call may have partially changed native state.
          break;
        }
      }
    } finally {
      _running = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    widget.settings.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return widget.child;
    final blocked =
        !widget.settings.loaded || _running || _failed || _applied != _desired;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Offstage also removes semantics and prevents route contents flashing
        // during startup, including dialogs pushed above the settings page.
        ExcludeFocus(
          excluding: blocked,
          child: TickerMode(
            enabled: !blocked,
            child: Offstage(offstage: blocked, child: widget.child),
          ),
        ),
        if (blocked)
          Material(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _failed
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.screenshot_monitor_outlined,
                            size: 48,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '${supportsStreamProof ? 'Impossibile applicare lo stream proof.' : 'Impossibile applicare la protezione dagli screenshot.'}\n'
                            'Il contenuto resta nascosto finché scegli come proseguire.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _changed,
                            child: const Text('Riprova'),
                          ),
                          TextButton(
                            onPressed: () async {
                              await widget.settings.update(
                                supportsStreamProof
                                    ? widget.settings.value.copyWith(
                                        streamProof: _lastConfirmed,
                                      )
                                    : widget.settings.value.copyWith(
                                        allowScreenshots: !_lastConfirmed,
                                      ),
                              );
                              if (mounted) _changed();
                            },
                            child: Text(
                              _lastConfirmed
                                  ? 'Mantieni la protezione attiva'
                                  : (supportsStreamProof
                                        ? 'Continua senza stream proof'
                                        : 'Riprova la preferenza precedente'),
                            ),
                          ),
                        ],
                      )
                    : const CircularProgressIndicator(),
              ),
            ),
          ),
      ],
    );
  }
}
