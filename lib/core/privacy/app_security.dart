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
  Timer? _inactivityTimer;
  Future<void>? _locking;
  DateTime? _lastNativeTouch;
  bool _disposed = false;
  int _lockGeneration = 0;

  Future<void> initialize() async {
    final generation = _lockGeneration;
    try {
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
      }
      await _protectSnapshots();
      loaded = true;
      error = null;
      _armTimer();
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
    _lockGeneration++;
    _inactivityTimer?.cancel();
    locked = true;
    _notify(); // Remove all routes and Flutter caches before waiting for FFI.
    return _locking ??=
        Future.wait<void>([
              _send({'command': 'lock_vault'}).then<void>((_) {}),
              _wipePlatformBuffers(),
            ])
            .then<void>((_) {})
            .catchError((Object _) {
              error =
                  'Pulizia nativa non completata. Il contenuto resta bloccato; riprova.';
              _notify();
            })
            .whenComplete(() => _locking = null);
  }

  Future<void> updatePolicy({int? seconds, bool? onBackground}) async {
    final generation = _lockGeneration;
    _accept(
      await _send({
        'command': 'set_lock_policy',
        'inactivity_seconds': seconds ?? inactivitySeconds,
        'lock_on_background': onBackground ?? lockOnBackground,
      }),
      generation: generation,
    );
    _armTimer();
    _notify();
  }

  void userActivity() {
    if (!loaded || !enabled || locked || busy) return;
    _armTimer();
    // Do not let network polling renew this deadline. Only user input counts.
    final now = DateTime.now();
    if (_lastNativeTouch != null &&
        now.difference(_lastNativeTouch!) < const Duration(seconds: 1)) {
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
    if (!loaded || !enabled) return;
    try {
      final wasLocked = locked;
      final generation = _lockGeneration;
      _accept(
        await _send({'command': 'security_status'}),
        generation: generation,
      );
      if (locked && !wasLocked) {
        await lock();
      }
      _notify();
    } on Object {
      await lock();
    }
  }

  void backgrounded() {
    if (lockOnBackground) {
      _lockGeneration++;
      if (enabled) unawaited(lock());
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
    locked =
        (enabled && generation != _lockGeneration) || data['locked'] as bool;
    PlatformDeviceSecretStore.passphraseProtected = enabled;
    final policy = data['policy'] as Map;
    inactivitySeconds = policy['inactivity_seconds'] as int;
    lockOnBackground = policy['lock_on_background'] as bool;
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
    super.dispose();
  }
}
