import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../diagnostics/app_log.dart';
import '../native/native_core.dart';

enum IdentityPhase { unavailable, loading, ready, error }

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

  IdentitySnapshot get snapshot => _snapshot;

  Future<void> initialize() async {
    final core = _nativeCore;
    if (core == null || _isLoading) {
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
      final response = core.ensureIdentity(
        storageDirectory: nativeDirectory.path,
        vaultPassword: vaultPassword,
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
    _snapshot = value;
    notifyListeners();
  }
}
