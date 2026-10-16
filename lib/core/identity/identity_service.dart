import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as image;
import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_log.dart';
import '../native/native_core.dart';
import '../profile/user_profile.dart';

enum IdentityPhase { unavailable, loading, ready, error }

// Veilid DHT subkeys are capped at 32 KiB. Keep ample room for the signed
// identity bundle, route and mailbox metadata in the same record.
const int maxPublishedAvatarBytes = 8 * 1024;

@immutable
class IdentitySnapshot {
  const IdentitySnapshot({
    required this.phase,
    this.identityId,
    this.invitationCode,
    this.expiresAt,
    this.errorCode,
  });

  const IdentitySnapshot.unavailable() : this(phase: IdentityPhase.unavailable);

  final IdentityPhase phase;
  final String? identityId;
  final String? invitationCode;
  final DateTime? expiresAt;
  final String? errorCode;

  /// Short invitations are Veilid DHT record keys, never inline key bundles.
  bool get hasShortInvitation =>
      invitationCode?.startsWith('sylphy:VLD') == true &&
      invitationCode!.length <= 128;
}

abstract interface class DeviceSecretStore {
  Future<String> getOrCreate();
}

class PlatformDeviceSecretStore implements DeviceSecretStore {
  PlatformDeviceSecretStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const _storageKey = 'sylphy_identity_vault_secret_v1';
  static const _pendingStorageKey = 'sylphy_pending_unprotect_secret_v1';
  static bool passphraseProtected = false;
  static Future<String>? _secretRead;
  final FlutterSecureStorage _storage;

  @override
  Future<String> getOrCreate() {
    // An empty marker asks the native session to use its protected secret.
    // The unwrapped key never returns to Dart once passphrase mode is enabled.
    if (passphraseProtected) return Future.value('');
    return _secretRead ??= _readOrCreate().whenComplete(
      () => _secretRead = null,
    );
  }

  Future<void> removeLegacySecret() async {
    await _storage.delete(key: _storageKey);
    await _storage.delete(key: _pendingStorageKey);
  }

  Future<void> stageUnprotectedSecret(String secret) async {
    if (secret.length < 43 || secret.length > 512) {
      throw StateError('invalid_secret');
    }
    await _storage.write(key: _pendingStorageKey, value: secret);
    if (await _storage.read(key: _pendingStorageKey) != secret) {
      throw StateError('secure_storage_verification_failed');
    }
  }

  Future<void> recoverUnprotectedSecret() async {
    final pending = await _storage.read(key: _pendingStorageKey);
    if (pending == null) return;
    if (pending.length < 43 || pending.length > 512) {
      throw StateError('invalid_secret');
    }
    await _storage.write(key: _storageKey, value: pending);
    if (await _storage.read(key: _storageKey) != pending) {
      throw StateError('secure_storage_verification_failed');
    }
    await _storage.delete(key: _pendingStorageKey);
  }

  Future<String> _readOrCreate() async {
    await recoverUnprotectedSecret();
    final existing = await _storage.read(key: _storageKey);
    if (existing != null && existing.length >= 43) {
      return existing;
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final generated = base64UrlEncode(bytes).replaceAll('=', '');
    await _storage.write(key: _storageKey, value: generated);
    return generated;
  }
}

typedef IdentityPublisher =
    Future<NativeCoreResponse> Function({
      required String storageDirectory,
      required String vaultPassword,
      String? displayName,
      String? avatarBase64,
      int? rotationIntervalSeconds,
      bool rotateInvitation,
    });

class IdentityService extends ChangeNotifier {
  IdentityService({
    required NativeCoreApi? nativeCore,
    IdentityPublisher? publisher,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? timerFactory,
    DeviceSecretStore? deviceSecretStore,
    Future<Directory> Function()? applicationSupportDirectory,
  }) : _nativeCore = nativeCore,
       _publisher = publisher,
       _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new,
       _deviceSecretStore = deviceSecretStore ?? PlatformDeviceSecretStore(),
       _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       _snapshot = nativeCore == null
           ? const IdentitySnapshot.unavailable()
           : const IdentitySnapshot(phase: IdentityPhase.loading);

  final NativeCoreApi? _nativeCore;
  final IdentityPublisher? _publisher;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _timerFactory;
  final DeviceSecretStore _deviceSecretStore;
  final Future<Directory> Function() _applicationSupportDirectory;
  IdentitySnapshot _snapshot;
  bool _disposed = false;
  bool _suspended = false;
  int _generation = 0;
  UserProfile? _publicProfile;
  bool _shareDisplayName = true;
  bool _shareProfilePhoto = true;
  UserProfile? _lastPublishedProfile;
  bool? _lastShareDisplayName;
  bool? _lastShareProfilePhoto;
  Future<void>? _initializationLoop;
  bool _refreshPending = false;
  int _rotationIntervalSeconds = 0;
  int? _lastRotationIntervalSeconds;
  Timer? _rotationTimer;
  DateTime? _nextRotationAt;
  bool _manualRotationPending = false;
  bool _rotationInProgress = false;
  String? _rotationError;
  bool _revocationPending = false;
  bool get revocationPending => _revocationPending;
  bool get rotationPolicyPending =>
      _rotationIntervalSeconds != _lastRotationIntervalSeconds;

  Future<void> retry() => initialize(
    forceRefresh: true,
    shareDisplayName: _shareDisplayName,
    shareProfilePhoto: _shareProfilePhoto,
  );

  DateTime? get nextRotationAt => _nextRotationAt;
  bool get rotationInProgress => _rotationInProgress;
  String? get rotationError => _rotationError;
  bool get canRotate =>
      !_disposed &&
      !_suspended &&
      _snapshot.phase == IdentityPhase.ready &&
      (_nativeCore is NativeCoreClient || _publisher != null);

  Future<bool> rotateNow() async {
    if (!canRotate || _rotationInProgress) return false;
    final previous = _snapshot.invitationCode;
    _rotationInProgress = true;
    _manualRotationPending = true;
    _rotationError = null;
    notifyListeners();
    try {
      await initialize(
        forceRefresh: true,
        shareDisplayName: _shareDisplayName,
        shareProfilePhoto: _shareProfilePhoto,
      );
      return !_suspended &&
          !_disposed &&
          _rotationError == null &&
          _snapshot.hasShortInvitation &&
          _snapshot.invitationCode != previous;
    } finally {
      _rotationInProgress = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _scheduleRotation({bool retry = false}) {
    _rotationTimer?.cancel();
    _rotationTimer = null;
    if (_disposed ||
        _suspended ||
        (_rotationIntervalSeconds == 0 && !_revocationPending)) {
      return;
    }
    final deadline = _nextRotationAt;
    var delay = deadline?.difference(_now()) ?? const Duration(seconds: 60);
    if (retry ||
        delay <= Duration.zero ||
        (_revocationPending && delay > const Duration(seconds: 60))) {
      delay = const Duration(seconds: 60);
    }
    _rotationTimer = _timerFactory(delay, () {
      _rotationTimer = null;
      unawaited(
        initialize(
          forceRefresh: true,
          shareDisplayName: _shareDisplayName,
          shareProfilePhoto: _shareProfilePhoto,
        ),
      );
    });
  }

  IdentitySnapshot get snapshot => _snapshot;

  Future<void> initialize({
    UserProfile? profile,
    bool shareDisplayName = true,
    bool shareProfilePhoto = true,
    bool forceRefresh = false,
    int? rotationIntervalSeconds,
  }) {
    if (rotationIntervalSeconds != null) {
      if (rotationIntervalSeconds != 0 &&
          (rotationIntervalSeconds < 3600 ||
              rotationIntervalSeconds > 31536000)) {
        throw ArgumentError.value(
          rotationIntervalSeconds,
          'rotationIntervalSeconds',
        );
      }
      _rotationIntervalSeconds = rotationIntervalSeconds;
      if (_rotationIntervalSeconds == 0) {
        _rotationTimer?.cancel();
        _rotationTimer = null;
      }
    }
    if (profile != null) _publicProfile = profile;
    _shareDisplayName = shareDisplayName;
    _shareProfilePhoto = shareProfilePhoto;
    if ((_nativeCore == null && _publisher == null) ||
        _disposed ||
        _suspended) {
      return Future.value();
    }
    if (!forceRefresh &&
        _snapshot.phase == IdentityPhase.ready &&
        _snapshot.hasShortInvitation &&
        !_revocationPending &&
        (_snapshot.expiresAt?.isAfter(_now()) ?? false) &&
        !(_nextRotationAt?.isBefore(_now()) ?? false) &&
        _rotationIntervalSeconds == _lastRotationIntervalSeconds &&
        _samePublishedConfiguration()) {
      return Future.value();
    }
    _refreshPending = true;
    return _initializationLoop ??= _runInitializationLoop().whenComplete(() {
      _initializationLoop = null;
    });
  }

  Future<void> _runInitializationLoop() async {
    do {
      _refreshPending = false;
      await _initializeOnce();
    } while (_refreshPending && !_disposed && !_suspended);
  }

  Future<void> _initializeOnce() async {
    final core = _nativeCore;
    if ((core == null && _publisher == null) || _disposed || _suspended) return;
    final rotateInvitation = _manualRotationPending;
    _manualRotationPending = false;
    final rotationIntervalSeconds = _rotationIntervalSeconds;
    final generation = _generation;
    final publishedProfile = _publicProfile;
    final publishDisplayName = _shareDisplayName;
    final publishProfilePhoto = _shareProfilePhoto;
    AppLog.instance.record(
      category: 'identity',
      action: 'initialization_started',
      verbose: true,
    );
    // A refresh can republish profile metadata or renew a short invitation.
    // Keep the already unlocked identity visible while that work continues.
    if (_snapshot.phase != IdentityPhase.ready) {
      _setSnapshot(const IdentitySnapshot(phase: IdentityPhase.loading));
    }
    try {
      final results = await Future.wait<Object>([
        _applicationSupportDirectory(),
        _deviceSecretStore.getOrCreate(),
      ]);
      final supportDirectory = results[0] as Directory;
      final vaultPassword = results[1] as String;
      final nativeDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}native',
      );
      await nativeDirectory.create(recursive: true);
      final displayName = publishDisplayName
          ? publishedProfile?.displayName
          : null;
      final avatarBase64 =
          publishProfilePhoto && publishedProfile?.photoBytes != null
          ? await _encodePublishedAvatar(publishedProfile!.photoBytes!)
          : null;
      if (_suspended || generation != _generation) return;
      final publisher =
          _publisher ??
          (core is NativeCoreClient ? core.ensureIdentityInBackground : null);
      final response = publisher != null
          ? await publisher(
              rotationIntervalSeconds: rotationIntervalSeconds,
              rotateInvitation: rotateInvitation,
              storageDirectory: nativeDirectory.path,
              vaultPassword: vaultPassword,
              displayName: displayName,
              avatarBase64: avatarBase64,
            )
          : core!.ensureIdentity(
              storageDirectory: nativeDirectory.path,
              vaultPassword: vaultPassword,
              displayName: displayName,
              avatarBase64: avatarBase64,
            );
      if (_suspended || generation != _generation) return;
      if (!response.ok) {
        AppLog.instance.record(
          category: 'identity',
          action: 'initialization_rejected',
          level: AppLogLevel.error,
          result: response.code,
          force: true,
        );
        _rotationError = response.code;
        if (_snapshot.phase != IdentityPhase.ready) {
          _setSnapshot(
            IdentitySnapshot(
              phase: IdentityPhase.error,
              errorCode: response.code,
            ),
          );
        } else {
          notifyListeners();
        }
        _scheduleRotation(retry: true);
        return;
      }
      final identityId = response.data['identity_id'];
      final invitationCode = response.data['invitation_code'];
      final expiresAtMs = response.data['expires_at_ms'];
      if (identityId is! String ||
          identityId.isEmpty ||
          invitationCode is! String ||
          !invitationCode.startsWith('sylphy:') ||
          expiresAtMs is! int) {
        AppLog.instance.record(
          category: 'identity',
          action: 'invalid_native_response',
          level: AppLogLevel.error,
          force: true,
        );
        _setSnapshot(
          const IdentitySnapshot(
            phase: IdentityPhase.error,
            errorCode: 'invalid_native_response',
          ),
        );
        return;
      }
      _rotationError = null;
      _revocationPending = response.data['revocation_pending'] == true;
      final nextMs = response.data['next_rotation_at_ms'];
      _nextRotationAt = nextMs is int
          ? DateTime.fromMillisecondsSinceEpoch(nextMs, isUtc: true).toLocal()
          : null;
      _lastRotationIntervalSeconds = rotationIntervalSeconds;
      _scheduleRotation();
      _setSnapshot(
        IdentitySnapshot(
          phase: IdentityPhase.ready,
          identityId: identityId,
          invitationCode: invitationCode,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(
            expiresAtMs,
            isUtc: true,
          ).toLocal(),
        ),
      );
      _lastPublishedProfile = publishedProfile;
      _lastShareDisplayName = publishDisplayName;
      _lastShareProfilePhoto = publishProfilePhoto;
      AppLog.instance.record(
        category: 'identity',
        action: 'initialization_completed',
        verbose: true,
      );
    } on Exception catch (error) {
      if (_suspended || generation != _generation) return;
      AppLog.instance.recordError(
        category: 'identity',
        action: 'initialization_failed',
        error: error,
      );
      _rotationError = 'identity_initialization_failed';
      if (_snapshot.phase != IdentityPhase.ready) {
        _setSnapshot(
          const IdentitySnapshot(
            phase: IdentityPhase.error,
            errorCode: 'identity_initialization_failed',
          ),
        );
      } else {
        notifyListeners();
      }
      _scheduleRotation(retry: true);
    } finally {}
  }

  void invalidateAfterAccountImport() {
    _rotationTimer?.cancel();
    _rotationTimer = null;
    _nextRotationAt = null;
    _revocationPending = false;
    _lastRotationIntervalSeconds = null;
    _lastPublishedProfile = null;
    _lastShareDisplayName = null;
    _lastShareProfilePhoto = null;
    _refreshPending = true;
    if (_snapshot.phase == IdentityPhase.ready) {
      _setSnapshot(const IdentitySnapshot(phase: IdentityPhase.loading));
    }
  }

  void suspendForLock() {
    _suspended = true;
    _rotationTimer?.cancel();
    _rotationTimer = null;
    _manualRotationPending = false;
    _nextRotationAt = null;
    _rotationError = null;
    _generation++;
    _refreshPending = false;
    _publicProfile = null;
    _lastPublishedProfile = null;
    _setSnapshot(const IdentitySnapshot(phase: IdentityPhase.loading));
  }

  void resumeAfterUnlock() {
    _suspended = false;
    invalidateAfterAccountImport();
  }

  bool _samePublishedConfiguration() {
    final current = _publicProfile;
    final previous = _lastPublishedProfile;
    return current?.displayName == previous?.displayName &&
        listEquals(current?.photoBytes, previous?.photoBytes) &&
        _shareDisplayName == _lastShareDisplayName &&
        _shareProfilePhoto == _lastShareProfilePhoto;
  }

  void _setSnapshot(IdentitySnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _rotationTimer?.cancel();
    super.dispose();
  }
}

Future<String?> _encodePublishedAvatar(Uint8List source) async {
  final bytes = await Isolate.run(() => _compactAvatar(source));
  return bytes == null ? null : base64Encode(bytes);
}

Uint8List? _compactAvatar(Uint8List source) {
  final decoded = image.decodeImage(source);
  if (decoded == null) return null;
  if (source.length <= maxPublishedAvatarBytes) return source;

  final oriented = image.bakeOrientation(decoded);
  const sizes = [320, 256, 224, 192, 160, 128, 96, 64];
  const qualities = [82, 72, 62, 52, 42, 32];
  for (final size in sizes) {
    final resized = oriented.width > size || oriented.height > size
        ? image.copyResize(
            oriented,
            width: oriented.width >= oriented.height ? size : null,
            height: oriented.height > oriented.width ? size : null,
            interpolation: image.Interpolation.average,
          )
        : oriented;
    for (final quality in qualities) {
      final encoded = Uint8List.fromList(
        image.encodeJpg(resized, quality: quality),
      );
      if (encoded.length <= maxPublishedAvatarBytes) return encoded;
    }
  }
  return null;
}
