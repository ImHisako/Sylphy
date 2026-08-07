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
  final FlutterSecureStorage _storage;

  @override
  Future<String> getOrCreate() async {
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
  bool _isLoading = false;
  bool _disposed = false;
  UserProfile? _publicProfile;
  bool _shareDisplayName = true;
  bool _shareProfilePhoto = true;

  IdentitySnapshot get snapshot => _snapshot;

  Future<void> initialize({
    UserProfile? profile,
    bool shareDisplayName = true,
    bool shareProfilePhoto = true,
  }) async {
    if (profile != null) _publicProfile = profile;
    _shareDisplayName = shareDisplayName;
    _shareProfilePhoto = shareProfilePhoto;
    final core = _nativeCore;
    if (core == null || _isLoading || _disposed) {
      return;
    }
    _isLoading = true;
    AppLog.instance.record(
      category: 'identity',
      action: 'initialization_started',
      verbose: true,
    );
    _setSnapshot(const IdentitySnapshot(phase: IdentityPhase.loading));
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
      final displayName = _shareDisplayName
          ? _publicProfile?.displayName
          : null;
      final avatarBase64 =
          _shareProfilePhoto && _publicProfile?.photoBytes != null
          ? await _encodePublishedAvatar(_publicProfile!.photoBytes!)
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
    } finally {
      _isLoading = false;
    }
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
