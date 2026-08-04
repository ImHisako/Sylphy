import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

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

typedef ProfileSupportDirectoryProvider = Future<Directory> Function();

class FileUserProfileStore implements UserProfileStore {
  FileUserProfileStore({ProfileSupportDirectoryProvider? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _profileFileName = 'profile.json';
  static const _photoFileName = 'profile-avatar.bin';
  static const _schemaVersion = 1;

  final ProfileSupportDirectoryProvider _supportDirectory;

  @override
  Future<UserProfile?> load() async {
    final directory = await _profileDirectory();
    final profileFile = File(
      '${directory.path}${Platform.pathSeparator}$_profileFileName',
    );
    if (!await profileFile.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await profileFile.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != _schemaVersion ||
          decoded['display_name'] is! String) {
        return null;
      }
      final displayName = _validateDisplayName(
        decoded['display_name'] as String,
      );
      Uint8List? photoBytes;
      if (decoded['has_photo'] == true) {
        final photoFile = File(
          '${directory.path}${Platform.pathSeparator}$_photoFileName',
        );
        if (await photoFile.exists() &&
            await photoFile.length() <= maxProfilePhotoBytes) {
          photoBytes = await photoFile.readAsBytes();
        }
      }
      return UserProfile(displayName: displayName, photoBytes: photoBytes);
    } on FormatException {
      return null;
    } on FileSystemException {
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
    final photoFile = File(
      '${directory.path}${Platform.pathSeparator}$_photoFileName',
    );
    if (photoBytes != null) {
      await photoFile.writeAsBytes(photoBytes, flush: true);
    } else if (await photoFile.exists()) {
      await photoFile.delete();
    }
    final profileFile = File(
      '${directory.path}${Platform.pathSeparator}$_profileFileName',
    );
    await profileFile.writeAsString(
      jsonEncode({
        'version': _schemaVersion,
        'display_name': validatedName,
        'has_photo': photoBytes != null,
      }),
      flush: true,
    );
    return UserProfile(displayName: validatedName, photoBytes: photoBytes);
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
