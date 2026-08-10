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
  static Future<String>? _sharedSecret;
  final FlutterSecureStorage _storage;

  @override
  Future<String> getOrCreate() {
    final pending = _sharedSecret;
    if (pending != null) return pending;
    final created = _readOrCreate();
    _sharedSecret = created;
    return created.onError((error, stackTrace) {
      if (identical(_sharedSecret, created)) _sharedSecret = null;
      Error.throwWithStackTrace(
        error ?? StateError('device_secret_unavailable'),
        stackTrace,
      );
    });
  }

  Future<String> _readOrCreate() async {
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

class IdentityService extends ChangeNotifier {
  IdentityService({
    required NativeCoreApi? nativeCore,
    DeviceSecretStore? deviceSecretStore,
    Future<Directory> Function()? applicationSupportDirectory,
  }) : _nativeCore = nativeCore,
       _deviceSecretStore = deviceSecretStore ?? PlatformDeviceSecretStore(),
       _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory,
       _snapshot = nativeCore == null
           ? const IdentitySnapshot.unavailable()
           : const IdentitySnapshot(phase: IdentityPhase.loading);

  final NativeCoreApi? _nativeCore;
  final DeviceSecretStore _deviceSecretStore;
  final Future<Directory> Function() _applicationSupportDirectory;
  IdentitySnapshot _snapshot;
  bool _disposed = false;
  UserProfile? _publicProfile;
  bool _shareDisplayName = true;
  bool _shareProfilePhoto = true;
  UserProfile? _lastPublishedProfile;
  bool? _lastShareDisplayName;
  bool? _lastShareProfilePhoto;
  Future<void>? _initializationLoop;
  bool _refreshPending = false;

  IdentitySnapshot get snapshot => _snapshot;

  Future<void> initialize({
    UserProfile? profile,
    bool shareDisplayName = true,
    bool shareProfilePhoto = true,
  }) {
    if (profile != null) _publicProfile = profile;
    _shareDisplayName = shareDisplayName;
    _shareProfilePhoto = shareProfilePhoto;
    if (_nativeCore == null || _disposed) {
      return Future.value();
    }
    if (_snapshot.phase == IdentityPhase.ready &&
        _snapshot.hasShortInvitation &&
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
    } while (_refreshPending && !_disposed);
  }

  Future<void> _initializeOnce() async {
    final core = _nativeCore;
    if (core == null || _disposed) return;
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
      final response = core is NativeCoreClient
          ? await core.ensureIdentityInBackground(
              storageDirectory: nativeDirectory.path,
              vaultPassword: vaultPassword,
              displayName: displayName,
              avatarBase64: avatarBase64,
            )
          : core.ensureIdentity(
              storageDirectory: nativeDirectory.path,
              vaultPassword: vaultPassword,
              displayName: displayName,
              avatarBase64: avatarBase64,
            );
      if (!response.ok) {
        AppLog.instance.record(
          category: 'identity',
          action: 'initialization_rejected',
          level: AppLogLevel.error,
          result: response.code,
          force: true,
        );
        _setSnapshot(
          IdentitySnapshot(
            phase: IdentityPhase.error,
            errorCode: response.code,
          ),
        );
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
      AppLog.instance.recordError(
        category: 'identity',
        action: 'initialization_failed',
        error: error,
      );
      _setSnapshot(
        const IdentitySnapshot(
          phase: IdentityPhase.error,
          errorCode: 'identity_initialization_failed',
        ),
      );
    } finally {}
  }

  void invalidateAfterAccountImport() {
    _lastPublishedProfile = null;
    _lastShareDisplayName = null;
    _lastShareProfilePhoto = null;
    _refreshPending = true;
    if (_snapshot.phase == IdentityPhase.ready) {
      _setSnapshot(const IdentitySnapshot(phase: IdentityPhase.loading));
    }
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
