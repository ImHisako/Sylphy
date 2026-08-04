import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../native/native_core.dart';

enum VeilidPhase { unavailable, offline, connecting, attached, degraded, error }

@immutable
class VeilidSnapshot {
  const VeilidSnapshot({
    required this.phase,
    this.attachmentState = 'unavailable',
    this.livePeerCount = 0,
    this.publicInternetReady = false,
    this.diagnosticCode,
  });

  const VeilidSnapshot.unavailable() : this(phase: VeilidPhase.unavailable);

  final VeilidPhase phase;
  final String attachmentState;
  final int livePeerCount;
  final bool publicInternetReady;
  final String? diagnosticCode;

  bool get isAttached =>
      phase == VeilidPhase.attached || phase == VeilidPhase.degraded;

  String get title => switch (phase) {
    VeilidPhase.unavailable => 'Core Veilid non incluso',
    VeilidPhase.offline => 'Nodo Veilid offline',
    VeilidPhase.connecting => 'Connessione a Veilid…',
    VeilidPhase.attached => 'Rete Veilid connessa',
    VeilidPhase.degraded => 'Rete Veilid limitata',
    VeilidPhase.error => 'Veilid non disponibile',
  };

  String get detail => switch (phase) {
    VeilidPhase.unavailable =>
      diagnosticCode == 'feature_unavailable'
          ? 'Questa build non include Veilid. Installa la build Android ABI 4 più recente.'
          : 'Installa la libreria nativa per connetterti.',
    VeilidPhase.offline => 'Nodo arrestato · nuovo tentativo automatico',
    VeilidPhase.connecting => 'Avvio del nodo privato in corso.',
    VeilidPhase.attached =>
      livePeerCount > 0
          ? '$livePeerCount peer attivi · envelope opachi'
          : 'Collegato · envelope opachi',
    VeilidPhase.degraded => 'Collegamento parziale · riprovo automaticamente',
    VeilidPhase.error => switch (diagnosticCode) {
      'feature_unavailable' =>
        'Core compilato senza Veilid: il retry non può risolvere questa build.',
      'platform_not_initialized' =>
        'Bootstrap Android non completato · nuovo tentativo automatico',
      'network_startup_failed' =>
        'Avvio rete non riuscito · nuovo tentativo automatico',
      null => 'Connessione non riuscita · nuovo tentativo automatico',
      _ =>
        'Connessione non riuscita ($diagnosticCode) · nuovo tentativo automatico',
    },
  };

  factory VeilidSnapshot.fromResponse(NativeCoreResponse response) {
    if (!response.ok) {
      return VeilidSnapshot(
        phase: VeilidPhase.error,
        diagnosticCode: response.code,
      );
    }
    final data = response.data;
    final compiled = data['compiled'] == true;
    final running = data['running'] == true;
    final attachmentState = data['attachment_state'] as String? ?? 'detached';
    final publicInternetReady = data['public_internet_ready'] == true;
    final livePeerCount = int.tryParse('${data['live_peer_count'] ?? 0}') ?? 0;

    if (!compiled) {
      return const VeilidSnapshot.unavailable();
    }
    if (!running || attachmentState == 'detached') {
      return VeilidSnapshot(
        phase: VeilidPhase.offline,
        attachmentState: attachmentState,
      );
    }
    if (attachmentState == 'attaching') {
      return VeilidSnapshot(
        phase: VeilidPhase.connecting,
        attachmentState: attachmentState,
        livePeerCount: livePeerCount,
      );
    }
    return VeilidSnapshot(
      phase: publicInternetReady ? VeilidPhase.attached : VeilidPhase.degraded,
      attachmentState: attachmentState,
      livePeerCount: livePeerCount,
      publicInternetReady: publicInternetReady,
    );
  }
}

class VeilidService extends ChangeNotifier {
  VeilidService({
    required NativeCoreApi? nativeCore,
    Future<Directory> Function()? applicationSupportDirectory,
  }) : _nativeCore = nativeCore,
       _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       _snapshot = nativeCore == null
           ? const VeilidSnapshot.unavailable()
           : const VeilidSnapshot(phase: VeilidPhase.connecting);

  final NativeCoreApi? _nativeCore;
  final Future<Directory> Function() _applicationSupportDirectory;
  VeilidSnapshot _snapshot;
  Timer? _refreshTimer;
  bool _isStarting = false;
  bool _disposed = false;

  VeilidSnapshot get snapshot => _snapshot;
  bool get hasNativeCore => _nativeCore != null;

  Future<void> start() async {
    final core = _nativeCore;
    if (core == null || _disposed || _isStarting) {
      return;
    }
    _isStarting = true;
    _ensureRefreshTimer();
    _setSnapshot(const VeilidSnapshot(phase: VeilidPhase.connecting));
    try {
      final supportDirectory = await _applicationSupportDirectory();
      final storage = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}veilid',
      );
      await storage.create(recursive: true);
      final response = core.startVeilid(storage.path);
      _setSnapshot(VeilidSnapshot.fromResponse(response));
    } on Exception {
      _setSnapshot(
        const VeilidSnapshot(
          phase: VeilidPhase.error,
          diagnosticCode: 'startup_failed',
        ),
      );
    } finally {
      _isStarting = false;
    }
  }

  void refresh() {
    final core = _nativeCore;
    if (core == null || _disposed) {
      return;
    }
    try {
      _setSnapshot(VeilidSnapshot.fromResponse(core.veilidStatus()));
    } on NativeCoreException {
      _setSnapshot(
        const VeilidSnapshot(
          phase: VeilidPhase.error,
          diagnosticCode: 'status_failed',
        ),
      );
    }
  }

  Future<void> retry() => start();

  Future<void> stop() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final core = _nativeCore;
    if (core == null) {
      return;
    }
    try {
      _setSnapshot(VeilidSnapshot.fromResponse(core.stopVeilid()));
    } on NativeCoreException {
      _setSnapshot(
        const VeilidSnapshot(
          phase: VeilidPhase.error,
          diagnosticCode: 'shutdown_failed',
        ),
      );
    }
  }

  void _ensureRefreshTimer() {
    _refreshTimer ??= Timer.periodic(const Duration(seconds: 8), (_) {
      if (_snapshot.phase == VeilidPhase.offline ||
          (_snapshot.phase == VeilidPhase.error &&
              _snapshot.diagnosticCode != 'feature_unavailable')) {
        unawaited(start());
      } else {
        refresh();
      }
    });
  }

  void _setSnapshot(VeilidSnapshot value) {
    if (_disposed) {
      return;
    }
    _snapshot = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    super.dispose();
  }
}
