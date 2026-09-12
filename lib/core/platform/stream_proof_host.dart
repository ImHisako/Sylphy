import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../privacy/privacy_settings.dart';

bool get supportsStreamProof =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Covers every route until Windows has applied the saved capture preference.
class StreamProofHost extends StatefulWidget {
  const StreamProofHost({
    super.key,
    required this.settings,
    required this.child,
  });

  final PrivacySettingsController settings;
  final Widget child;

  @override
  State<StreamProofHost> createState() => _StreamProofHostState();
}

class _StreamProofHostState extends State<StreamProofHost> {
  static const _channel = MethodChannel('sylphy/screen_capture');
  bool _applied = false;
  bool _running = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
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
    if (!supportsStreamProof || !widget.settings.loaded || _running) return;
    _running = true;
    try {
      // Serialize native calls; a quick second toggle must win over the first.
      while (mounted && _applied != widget.settings.value.streamProof) {
        final enabled = widget.settings.value.streamProof;
        try {
          await _channel.invokeMethod<void>('setStreamProof', enabled);
          _applied = enabled;
        } on PlatformException {
          _failed = true;
          break;
        } on MissingPluginException {
          _failed = true;
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
    if (!supportsStreamProof) return widget.child;
    final blocked =
        !widget.settings.loaded ||
        _running ||
        _failed ||
        _applied != widget.settings.value.streamProof;
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
                          const Text(
                            'Impossibile applicare lo stream proof.\n'
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
                                widget.settings.value.copyWith(
                                  streamProof: _applied,
                                ),
                              );
                              if (mounted) _changed();
                            },
                            child: Text(
                              _applied
                                  ? 'Mantieni lo stream proof attivo'
                                  : 'Continua senza stream proof',
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
