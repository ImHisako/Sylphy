import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../native/native_core.dart';
import '../profile/user_profile.dart';
import 'identity_service.dart';

class AccountTransferService {
  AccountTransferService({
    required NativeCoreClient nativeCore,
    DeviceSecretStore? deviceSecretStore,
    UserProfileStore? profileStore,
    Future<Directory> Function()? applicationSupportDirectory,
  }) : _nativeCore = nativeCore,
       _deviceSecretStore = deviceSecretStore ?? PlatformDeviceSecretStore(),
       _profileStore = profileStore ?? FileUserProfileStore(),
       _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory;

  static const fileExtension = 'sylphy-account';
  final NativeCoreClient _nativeCore;
  final DeviceSecretStore _deviceSecretStore;
  final UserProfileStore _profileStore;
  final Future<Directory> Function() _applicationSupportDirectory;

  Future<String?> exportToFile({
    required UserProfile profile,
    required String transferPassword,
  }) async {
    final response = await _nativeCore.exportAccountInBackground(
      transferPassword: transferPassword,
      displayName: profile.displayName,
      avatarBase64: profile.photoBytes == null
          ? null
          : base64Encode(profile.photoBytes!),
    );
    _requireSuccess(response);
    final encrypted = response.data['backup_base64'];
    if (encrypted is! String || encrypted.isEmpty) {
      throw const AccountTransferException('invalid_native_response');
    }
    final document = utf8.encode(
      jsonEncode({
        'format': 'sylphy-account-backup',
        'version': 1,
        'backup_base64': encrypted,
      }),
    );
    final location = await getSaveLocation(
      suggestedName: 'Sylphy-account.$fileExtension',
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Account Sylphy cifrato',
          extensions: [fileExtension],
        ),
      ],
    );
    if (location == null) return null;
    await XFile.fromData(
      document,
      mimeType: 'application/vnd.sylphy.account+json',
      name: 'Sylphy-account.$fileExtension',
    ).saveTo(location.path);
    return location.path;
  }

  Future<UserProfile?> importFromFile({
    required String transferPassword,
  }) async {
    final selected = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Account Sylphy cifrato',
          extensions: [fileExtension],
        ),
      ],
    );
    if (selected == null) return null;
    final bytes = await selected.readAsBytes();
    if (bytes.isEmpty || bytes.length > 130 * 1024 * 1024) {
      throw const AccountTransferException('limit_exceeded');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'sylphy-account-backup' ||
        decoded['version'] != 1 ||
        decoded['backup_base64'] is! String) {
      throw const AccountTransferException('invalid_backup');
    }
    final support = await _applicationSupportDirectory();
    final nativeDirectory = Directory(
      '${support.path}${Platform.pathSeparator}native',
    );
    await nativeDirectory.create(recursive: true);
    final response = await _nativeCore.importAccountInBackground(
      transferPassword: transferPassword,
      backupBase64: decoded['backup_base64'] as String,
      storageDirectory: nativeDirectory.path,
      vaultPassword: await _deviceSecretStore.getOrCreate(),
    );
    _requireSuccess(response);
    final displayName = response.data['display_name'];
    if (displayName is! String || displayName.trim().isEmpty) {
      throw const AccountTransferException('invalid_native_response');
    }
    final avatar = response.data['avatar_base64'];
    final avatarBytes = avatar is String && avatar.isNotEmpty
        ? base64Decode(avatar)
        : null;
    return _profileStore.save(
      displayName: displayName,
      photoBytes: avatarBytes,
    );
  }

  void _requireSuccess(NativeCoreResponse response) {
    if (!response.ok) throw AccountTransferException(response.code);
  }
}

class AccountTransferException implements Exception {
  const AccountTransferException(this.code);
  final String code;
}
