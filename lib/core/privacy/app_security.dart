import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../identity/identity_service.dart';
import '../native/native_core.dart';

typedef SecurityCommand =
    Future<NativeCoreResponse> Function(Map<String, Object> request);

class AppSecurityController extends ChangeNotifier {
  AppSecurityController({
    required SecurityCommand command,
    PlatformDeviceSecretStore? secrets,
    Future<Directory> Function()? supportDirectory,
  }) : _command = command,
       _secrets = secrets ?? PlatformDeviceSecretStore(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final SecurityCommand _command;
  final PlatformDeviceSecretStore _secrets;
  final Future<Directory> Function() _supportDirectory;
  bool loaded = false;
  bool enabled = false;
  bool locked = true;
  bool busy = false;
  String? error;
  int inactivitySeconds = 300;
  bool lockOnBackground = true;
  bool lockOnScreenOff = true;
  Timer? _inactivityTimer;
  Future<void>? _locking;
  String? _pendingPurge;
  bool _foreground = true;
  final Stopwatch _touchClock = Stopwatch()..start();
  Duration? _lastNativeTouch;
  bool _disposed = false;
  int _lockGeneration = 0;

  Future<void> initialize() async {
    final generation = _lockGeneration;
    try {
      await _flushPlatformSecurity();
      final directory = await _supportDirectory();
      _accept(
        await _send({
          'command': 'configure_security',
          'storage_directory':
              '${directory.path}${Platform.pathSeparator}native',
        }),
        generation: generation,
      );
      // Recovery for an interrupted migration: the committed envelope is the
      // authority. Never retain an automatic-unlock copy in secure storage.
      if (enabled) {
        await _secrets.removeLegacySecret();
        // An engine/activity restart can share a still-live native library.
        // A new application instance must require its passphrase nonetheless.
        await _send({'command': 'lock_vault'});
        locked = true;
      } else {
        _accept(
          await _send({'command': 'resume_vault'}),
          generation: generation,
        );
        if (locked) await _purge('close_vault');
      }
      if (Platform.isAndroid) {
        const MethodChannel('sylphy/security').setMethodCallHandler((
          call,
        ) async {
          if (call.method == 'screenOff') screenOff();
          if (call.method == 'appClosing') await close();
        });
      }
      await _protectSnapshots();
      loaded = true;
      error = null;
      _armTimer();
      // Android can hide and restore its root task before configuration has
      // finished. Honor that explicit resume after fencing the stale result.
      if (!enabled && locked && _foreground && !_disposed) await resumed();
    } on Object {
      locked = true;
      error =
          'Impossibile aprire la protezione locale. Riprova senza cancellare i dati dell’app.';
    }
    _notify();
  }

  Future<void> enable(String passphrase) async {
    final generation = _lockGeneration;
    busy = true;
    _notify();
    try {
      final secret = await _secrets.getOrCreate();
      _accept(
        await _send({
          'command': 'enable_passphrase',
          'passphrase': passphrase,
          'device_secret': secret,
        }),
        generation: generation,
      );
      await _secrets.removeLegacySecret();
      await _protectSnapshots();
      if (locked) await lock();
      _armTimer();
    } on Object {
      // If commit succeeded but platform cleanup failed, leave the gate closed
      // until initialize can finish removing the old key.
      if (enabled) {
        loaded = false;
        await lock();
      }
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> unlock(String passphrase) async {
    if (busy || !loaded) return;
    busy = true;
    error = null;
    _notify();
    final generation = _lockGeneration;
    try {
      await _locking;
      _accept(
        await _send({'command': 'unlock_vault', 'passphrase': passphrase}),
        generation: generation,
      );
      if (locked) await lock();
      _armTimer();
    } on Object {
      locked = true;
      error = 'Passphrase errata oppure vault non disponibile.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> lock() {
    if (!enabled) return Future.value();
    return _purge('lock_vault');
  }

  /// Closing always purges RAM, including accounts without a passphrase.
  Future<void> close() {
    _foreground = false;
    return _purge('close_vault');
  }

  Future<void> _purge(String command) {
    _lockGeneration++;
    _inactivityTimer?.cancel();
    _lastNativeTouch = null;
    locked = true;
    // A close must never be lost behind an in-progress, weaker lock.
    if (_pendingPurge != 'close_vault') _pendingPurge = command;
    _notify(); // Remove all routes and Flutter caches before waiting for FFI.
    return _locking ??= _drainPurges().whenComplete(() => _locking = null);
  }

  Future<void> _drainPurges() async {
    while (_pendingPurge != null) {
      final command = _pendingPurge!;
      _pendingPurge = null;
      try {
        await Future.wait<void>([
          _send({'command': command}).then<void>((_) {}),
          _wipePlatformBuffers(),
        ]);
        error = null;
      } on Object {
        error =
            'Pulizia nativa non completata. Il contenuto resta bloccato; riprova.';
      }
    }
    _notify();
  }

  Future<void> updatePolicy({
    int? seconds,
    bool? onBackground,
    bool? onScreenOff,
  }) async {
    final generation = _lockGeneration;
    _accept(
      await _send({
        'command': 'set_lock_policy',
        'inactivity_seconds': seconds ?? inactivitySeconds,
        'lock_on_background': onBackground ?? lockOnBackground,
        'lock_on_screen_off': onScreenOff ?? lockOnScreenOff,
      }),
      generation: generation,
    );
    _armTimer();
    _notify();
  }

  void userActivity() {
    if (!loaded || !enabled || locked || busy || !_foreground) return;
    _armTimer();
    // Do not let network polling renew this deadline. Only user input counts.
    final now = _touchClock.elapsed;
    if (_lastNativeTouch != null &&
        now - _lastNativeTouch! < const Duration(seconds: 1)) {
      return;
    }
    _lastNativeTouch = now;
    unawaited(
      _send({'command': 'security_touch'}).catchError((Object _) {
        unawaited(lock());
        return <String, dynamic>{};
      }),
    );
  }

  Future<void> resumed() async {
    _foreground = true;
    if (!loaded) return;
    try {
      await _locking;
      await _flushPlatformSecurity();
      final wasLocked = locked;
      final generation = _lockGeneration;
      _accept(
        await _send({'command': enabled ? 'security_status' : 'resume_vault'}),
        generation: generation,
      );
      if (generation != _lockGeneration && !enabled) {
        await close();
      } else if (locked && !wasLocked) {
        await lock();
      }
      _notify();
    } on Object {
      await close();
    }
  }

  void backgrounded() {
    _foreground = false;
    if (lockOnBackground) {
      _lockGeneration++;
      if (enabled) unawaited(lock());
    }
  }

  void screenOff() {
    _foreground = false;
    if (lockOnScreenOff) {
      _lockGeneration++;
      if (enabled) unawaited(lock());
    }
  }

  Future<void> _flushPlatformSecurity() async {
    if (Platform.isAndroid) {
      await const MethodChannel(
        'sylphy/platform',
      ).invokeMethod<void>('flushSecurityEvents');
    }
  }

  Future<Map<String, dynamic>> _send(Map<String, Object> request) async {
    final response = await _command(request);
    if (!response.ok) throw NativeCoreException(response.code);
    return response.data;
  }

  Future<void> _protectSnapshots() async {
    if (Platform.isAndroid) {
      await const MethodChannel(
        'sylphy/platform',
      ).invokeMethod<void>('setVaultProtected', enabled);
    }
  }

  Future<void> _wipePlatformBuffers() async {
    if (Platform.isAndroid) {
      await const MethodChannel(
        'sylphy/platform',
      ).invokeMethod<void>('wipeSensitiveBuffers');
    }
  }

  void _accept(Map<String, dynamic> data, {required int generation}) {
    if (data['enabled'] is! bool ||
        data['locked'] is! bool ||
        data['policy'] is! Map) {
      throw const NativeCoreException('invalid_security_response');
    }
    enabled = data['enabled'] as bool;
    locked = generation != _lockGeneration || data['locked'] as bool;
    PlatformDeviceSecretStore.passphraseProtected = enabled;
    final policy = data['policy'] as Map;
    inactivitySeconds = policy['inactivity_seconds'] as int;
    lockOnBackground = policy['lock_on_background'] as bool;
    lockOnScreenOff = policy['lock_on_screen_off'] as bool? ?? true;
  }

  void _armTimer() {
    _inactivityTimer?.cancel();
    if (_disposed) return;
    if (enabled && !locked && inactivitySeconds > 0) {
      _inactivityTimer = Timer(
        Duration(seconds: inactivitySeconds),
        () => unawaited(lock()),
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _inactivityTimer?.cancel();
    if (Platform.isAndroid) {
      const MethodChannel('sylphy/security').setMethodCallHandler(null);
    }
    super.dispose();
  }
}
