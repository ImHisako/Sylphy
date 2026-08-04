import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../native/native_core.dart';

enum VeilidPhase { unavailable, offline, connecting, attached, degraded, error }

@immutable
class VeilidSnapshot {
  const VeilidSnapshot({
    required this.phase,
    this.attachmentState = 'unavailable',
    this.livePeerCount = 0,
    this.publicInternetReady = false,
  });

  const VeilidSnapshot.unavailable() : this(phase: VeilidPhase.unavailable);

  final VeilidPhase phase;
  final String attachmentState;
  final int livePeerCount;
  final bool publicInternetReady;

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
    VeilidPhase.unavailable => 'Installa la libreria nativa per connetterti.',
    VeilidPhase.offline => 'Il nodo è pronto ma non è avviato.',
    VeilidPhase.connecting => 'Avvio del nodo privato in corso.',
    VeilidPhase.attached =>
      livePeerCount > 0
          ? '$livePeerCount peer attivi · envelope opachi'
          : 'Collegato · envelope opachi',
    VeilidPhase.degraded => 'Collegamento parziale · riprovo automaticamente',
    VeilidPhase.error => 'Controlla rete e libreria nativa.',
  };

  factory VeilidSnapshot.fromResponse(NativeCoreResponse response) {
    if (!response.ok) {
      return const VeilidSnapshot(phase: VeilidPhase.error);
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
  VeilidService({required NativeCoreClient? nativeCore})
    : _nativeCore = nativeCore,
      _snapshot = nativeCore == null
          ? const VeilidSnapshot.unavailable()
          : const VeilidSnapshot(phase: VeilidPhase.offline);

  final NativeCoreClient? _nativeCore;
  VeilidSnapshot _snapshot;
  Timer? _refreshTimer;
  bool _disposed = false;

  VeilidSnapshot get snapshot => _snapshot;
  bool get hasNativeCore => _nativeCore != null;

  Future<void> start() async {
    final core = _nativeCore;
    if (core == null || _disposed) {
      return;
    }
    _setSnapshot(const VeilidSnapshot(phase: VeilidPhase.connecting));
    try {
      final storage = Directory(_storageDirectory());
      await storage.create(recursive: true);
      final response = core.startVeilid(storage.path);
      _setSnapshot(VeilidSnapshot.fromResponse(response));
      _refreshTimer ??= Timer.periodic(
        const Duration(seconds: 12),
        (_) => refresh(),
      );
    } on FileSystemException {
      _setSnapshot(const VeilidSnapshot(phase: VeilidPhase.error));
    } on NativeCoreException {
      _setSnapshot(const VeilidSnapshot(phase: VeilidPhase.error));
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
      _setSnapshot(const VeilidSnapshot(phase: VeilidPhase.error));
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
      _setSnapshot(const VeilidSnapshot(phase: VeilidPhase.error));
    }
  }

  void _setSnapshot(VeilidSnapshot value) {
    if (_disposed) {
      return;
    }
    _snapshot = value;
    notifyListeners();
  }

  String _storageDirectory() {
    final environment = Platform.environment;
    if (Platform.isWindows) {
      final base = environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      return '$base${Platform.pathSeparator}Sylphy${Platform.pathSeparator}veilid';
    }
    if (Platform.isLinux) {
      final base =
          environment['XDG_DATA_HOME'] ??
          '${environment['HOME'] ?? Directory.systemTemp.path}${Platform.pathSeparator}.local${Platform.pathSeparator}share';
      return '$base${Platform.pathSeparator}sylphy${Platform.pathSeparator}veilid';
    }
    return '${Directory.systemTemp.path}${Platform.pathSeparator}sylphy${Platform.pathSeparator}veilid';
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    super.dispose();
  }
}
