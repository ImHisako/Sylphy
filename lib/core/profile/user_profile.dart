import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../native/native_core.dart';
import '../storage/atomic_file.dart';

const int maxProfilePhotoBytes = 5 * 1024 * 1024;

class UserProfile {
  const UserProfile({required this.displayName, this.photoBytes});

  final String displayName;
  final Uint8List? photoBytes;

  String get initials {
    final parts = displayName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2);
    return parts.map((part) => part[0].toUpperCase()).join();
  }
}

abstract interface class UserProfileStore {
  Future<UserProfile?> load();

  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  });
}

abstract interface class UserProfileImportRecovery {
  Future<void> invalidatePersistedProfile();
}

typedef ProfileSupportDirectoryProvider = Future<Directory> Function();

abstract interface class LocalDataCipher {
  Future<Uint8List> protect(Uint8List plaintext);

  Future<Uint8List> open(Uint8List record);
}

class UnavailableLocalDataCipher implements LocalDataCipher {
  const UnavailableLocalDataCipher();

  @override
  Future<Uint8List> open(Uint8List record) =>
      Future.error(const ProfileException('native_core_unavailable'));

  @override
  Future<Uint8List> protect(Uint8List plaintext) =>
      Future.error(const ProfileException('native_core_unavailable'));
}

typedef VaultPasswordProvider = Future<String> Function();

class NativeLocalDataCipher implements LocalDataCipher {
  NativeLocalDataCipher({
    required NativeCoreClient core,
    required VaultPasswordProvider password,
  }) : _core = core,
       _password = password;

  final NativeCoreClient _core;
  final VaultPasswordProvider _password;

  @override
  Future<Uint8List> protect(Uint8List plaintext) async {
    final response = await _core.protectLocalDataInBackground(
      vaultPassword: await _password(),
      valueBase64: base64Encode(plaintext).replaceAll('=', ''),
    );
    if (!response.ok || response.data['record_base64'] is! String) {
      throw ProfileException(response.code);
    }
    return _decodeUnpadded(response.data['record_base64'] as String);
  }

  @override
  Future<Uint8List> open(Uint8List record) async {
    final response = await _core.openLocalDataInBackground(
      vaultPassword: await _password(),
      recordBase64: base64Encode(record).replaceAll('=', ''),
    );
    if (!response.ok || response.data['value_base64'] is! String) {
      throw ProfileException(response.code);
    }
    return _decodeUnpadded(response.data['value_base64'] as String);
  }

  Uint8List _decodeUnpadded(String value) {
    final padding = '=' * ((4 - value.length % 4) % 4);
    return base64Decode('$value$padding');
  }
}

class FileUserProfileStore
    implements UserProfileStore, UserProfileImportRecovery {
  FileUserProfileStore({
    required LocalDataCipher cipher,
    ProfileSupportDirectoryProvider? supportDirectory,
  }) : _cipher = cipher,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _profileFileName = 'profile-v2.vault';
  static const _legacyProfileFileName = 'profile.json';
  static const _photoFileName = 'profile-avatar.bin';
  static const _schemaVersion = 2;

  final LocalDataCipher _cipher;
  final ProfileSupportDirectoryProvider _supportDirectory;

  @override
  Future<UserProfile?> load() async {
    final directory = await _profileDirectory();
    final profileFile = await recoverFile(
      File('${directory.path}${Platform.pathSeparator}$_profileFileName'),
    );
    if (profileFile == null) {
      final migrated = await _loadLegacy(directory);
      if (migrated != null) {
        await save(
          displayName: migrated.displayName,
          photoBytes: migrated.photoBytes,
        );
        await _deleteLegacy(directory);
      }
      return migrated;
    }

    try {
      final plaintext = await _cipher.open(await profileFile.readAsBytes());
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != _schemaVersion ||
          decoded['display_name'] is! String) {
        return null;
      }
      final displayName = _validateDisplayName(
        decoded['display_name'] as String,
      );
      final encodedPhoto = decoded['photo_base64'];
      final photoBytes = encodedPhoto is String && encodedPhoto.isNotEmpty
          ? base64Decode(encodedPhoto)
          : null;
      if (photoBytes != null && photoBytes.length > maxProfilePhotoBytes) {
        return null;
      }
      return UserProfile(displayName: displayName, photoBytes: photoBytes);
    } on Object {
      return null;
    }
  }

  @override
  Future<UserProfile> save({
    required String displayName,
    Uint8List? photoBytes,
  }) async {
    final validatedName = _validateDisplayName(displayName);
    if (photoBytes != null && photoBytes.length > maxProfilePhotoBytes) {
      throw const ProfileException('profile_photo_too_large');
    }

    final directory = await _profileDirectory();
    await directory.create(recursive: true);
    final profileFile = File(
      '${directory.path}${Platform.pathSeparator}$_profileFileName',
    );
    final plaintext = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': _schemaVersion,
          'display_name': validatedName,
          if (photoBytes != null) 'photo_base64': base64Encode(photoBytes),
        }),
      ),
    );
    await writeFileRecoverably(profileFile, await _cipher.protect(plaintext));
    await _deleteLegacy(directory);
    return UserProfile(displayName: validatedName, photoBytes: photoBytes);
  }

  @override
  Future<void> invalidatePersistedProfile() async {
    final directory = await _profileDirectory();
    for (final name in [_profileFileName, '$_profileFileName.bak']) {
      await eraseFileBestEffort(
        File('${directory.path}${Platform.pathSeparator}$name'),
      );
    }
  }

  Future<UserProfile?> _loadLegacy(Directory directory) async {
    final profileFile = File(
      '${directory.path}${Platform.pathSeparator}$_legacyProfileFileName',
    );
    if (!await profileFile.exists()) return null;
    final decoded = jsonDecode(await profileFile.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['display_name'] is! String) {
      return null;
    }
    Uint8List? photo;
    final photoFile = File(
      '${directory.path}${Platform.pathSeparator}$_photoFileName',
    );
    if (decoded['has_photo'] == true &&
        await photoFile.exists() &&
        await photoFile.length() <= maxProfilePhotoBytes) {
      photo = await photoFile.readAsBytes();
    }
    return UserProfile(
      displayName: _validateDisplayName(decoded['display_name'] as String),
      photoBytes: photo,
    );
  }

  Future<void> _deleteLegacy(Directory directory) async {
    for (final name in [_legacyProfileFileName, _photoFileName]) {
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      await eraseFileBestEffort(file);
    }
  }

  Future<Directory> _profileDirectory() async {
    final supportDirectory = await _supportDirectory();
    return Directory(
      '${supportDirectory.path}${Platform.pathSeparator}profile',
    );
  }
}

String _validateDisplayName(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty ||
      normalized.length > 64 ||
      normalized.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    throw const ProfileException('invalid_display_name');
  }
  return normalized;
}

class ProfileException implements Exception {
  const ProfileException(this.code);

  final String code;

  @override
  String toString() => code;
}
