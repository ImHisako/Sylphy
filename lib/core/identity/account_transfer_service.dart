import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
       _profileStore =
           profileStore ??
           FileUserProfileStore(
             cipher: NativeLocalDataCipher(
               core: nativeCore,
               password: (deviceSecretStore ?? PlatformDeviceSecretStore())
                   .getOrCreate,
             ),
           ),
       _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory;

  static const fileExtension = 'sylphy-account';
  static const _mimeType = 'application/vnd.sylphy.account+json';
  static const _maxDocumentBytes = 130 * 1024 * 1024;
  final NativeCoreClient _nativeCore;
  final DeviceSecretStore _deviceSecretStore;
  final UserProfileStore _profileStore;
  final Future<Directory> Function() _applicationSupportDirectory;

  Future<String?> exportToFile({
    required UserProfile profile,
    required String transferPassword,
  }) async {
    final document = await createBackupDocument(
      profile: profile,
      transferPassword: transferPassword,
    );
    if (Platform.isAndroid || Platform.isIOS) {
      final result = await SharePlus.instance.share(
        ShareParams(
          subject: 'Account Sylphy cifrato',
          text: 'Importa questo file da “Usa un account esistente” in Sylphy.',
          files: [
            XFile.fromData(
              document,
              mimeType: _mimeType,
              name: 'Sylphy-account.$fileExtension',
            ),
          ],
        ),
      );
      return result.status == ShareResultStatus.dismissed ? null : 'shared';
    }
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
      mimeType: _mimeType,
      name: 'Sylphy-account.$fileExtension',
    ).saveTo(location.path);
    return location.path;
  }

  Future<Uint8List> createBackupDocument({
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
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'sylphy-account-backup',
          'version': 1,
          'backup_base64': encrypted,
        }),
      ),
    );
  }

  Future<UserProfile?> importFromFile({
    required String transferPassword,
  }) async {
    final bytes = await pickBackupDocument();
    if (bytes == null) return null;
    return importFromDocument(bytes: bytes, transferPassword: transferPassword);
  }

  Future<Uint8List?> pickBackupDocument() async {
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
    if (bytes.isEmpty || bytes.length > _maxDocumentBytes) {
      throw const AccountTransferException('limit_exceeded');
    }
    return bytes;
  }

  Future<UserProfile> importFromDocument({
    required List<int> bytes,
    required String transferPassword,
  }) async {
    if (bytes.isEmpty || bytes.length > _maxDocumentBytes) {
      throw const AccountTransferException('limit_exceeded');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const AccountTransferException('invalid_backup');
    }
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
    final importedProfile = UserProfile(
      displayName: displayName.trim(),
      photoBytes: avatarBytes,
    );
    try {
      return await _profileStore.save(
        displayName: importedProfile.displayName,
        photoBytes: importedProfile.photoBytes,
      );
    } on Object {
      final recovery = _profileStore is UserProfileImportRecovery
          ? _profileStore as UserProfileImportRecovery
          : null;
      if (recovery != null) {
        await recovery.invalidatePersistedProfile();
      }
      // The native import is already committed. Preserve that fact so the UI
      // can invalidate every old-account cache instead of reporting a wholly
      // failed import and continuing with mixed state.
      throw AccountTransferException(
        'profile_persistence_failed',
        importedProfile: importedProfile,
      );
    }
  }

  Future<Uint8List> downloadFromQrPayload(String payload) async {
    AccountTransferException? lastError;
    for (final endpoint in _parseAccountQrEndpoints(payload)) {
      try {
        return await _downloadAccountEndpoint(endpoint);
      } on AccountTransferException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const AccountTransferException('qr_download_failed');
  }

  Future<Uint8List> _downloadAccountEndpoint(Uri endpoint) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(endpoint);
      request.headers.set(HttpHeaders.acceptHeader, _mimeType);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != HttpStatus.ok ||
          (response.contentLength > _maxDocumentBytes)) {
        throw const AccountTransferException('qr_download_failed');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        builder.add(chunk);
        if (builder.length > _maxDocumentBytes) {
          throw const AccountTransferException('limit_exceeded');
        }
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) {
        throw const AccountTransferException('qr_download_failed');
      }
      return bytes;
    } on AccountTransferException {
      rethrow;
    } on Object {
      throw const AccountTransferException('qr_download_failed');
    } finally {
      client.close(force: true);
    }
  }

  void _requireSuccess(NativeCoreResponse response) {
    if (!response.ok) throw AccountTransferException(response.code);
  }
}

enum AccountQrTransferState { waiting, transferred, expired, error }

class AccountQrTransferSession {
  AccountQrTransferSession._({
    required HttpServer server,
    required this.qrPayload,
    required Uint8List document,
    required String requestPath,
  }) : _server = server,
       _document = document,
       _requestPath = requestPath {
    _subscription = server.listen(_handleRequest, onError: _handleError);
    _expiryTimer = Timer(const Duration(minutes: 5), () {
      if (!_closed && state.value == AccountQrTransferState.waiting) {
        state.value = AccountQrTransferState.expired;
        unawaited(close());
      }
    });
  }

  final HttpServer _server;
  final Uint8List _document;
  final String _requestPath;
  final String qrPayload;
  final ValueNotifier<AccountQrTransferState> state = ValueNotifier(
    AccountQrTransferState.waiting,
  );
  StreamSubscription<HttpRequest>? _subscription;
  Timer? _expiryTimer;
  bool _closed = false;

  static Future<AccountQrTransferSession> start(Uint8List document) async {
    if (document.isEmpty ||
        document.length > AccountTransferService._maxDocumentBytes) {
      throw const AccountTransferException('limit_exceeded');
    }
    final addresses = await _findLanAddresses();
    final random = Random.secure();
    final token = base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final path = '/sylphy-account/$token';
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    } on Object {
      throw const AccountTransferException('qr_server_unavailable');
    }
    final endpoints = addresses
        .map(
          (address) =>
              Uri(scheme: 'http', host: address, port: server.port, path: path),
        )
        .toList(growable: false);
    final payload = jsonEncode({
      'format': 'sylphy-account-qr',
      'version': 1,
      'url': endpoints.first.toString(),
      'urls': endpoints.map((value) => value.toString()).toList(),
    });
    return AccountQrTransferSession._(
      server: server,
      qrPayload: payload,
      document: document,
      requestPath: path,
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_closed ||
        request.method != 'GET' ||
        request.uri.path != _requestPath ||
        state.value != AccountQrTransferState.waiting) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    // Claim the one-time document before yielding to socket I/O. A concurrent
    // request must not pass the waiting check and download the same backup.
    state.value = AccountQrTransferState.transferred;
    try {
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.sylphy.account+json',
      );
      request.response.contentLength = _document.length;
      request.response.add(_document);
      await request.response.close();
      await close();
    } on Object {
      state.value = AccountQrTransferState.error;
      await close();
    }
  }

  void _handleError(Object _) {
    if (!_closed) state.value = AccountQrTransferState.error;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiryTimer?.cancel();
    await _subscription?.cancel();
    await _server.close(force: true);
  }

  Future<void> dispose() async {
    await close();
    state.dispose();
  }
}

Uri parseAccountQrPayload(String payload) {
  return _parseAccountQrEndpoints(payload).first;
}

List<Uri> _parseAccountQrEndpoints(String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    throw const AccountTransferException('invalid_qr');
  }
  if (decoded is! Map<String, dynamic> ||
      decoded['format'] != 'sylphy-account-qr' ||
      decoded['version'] != 1 ||
      decoded['url'] is! String) {
    throw const AccountTransferException('invalid_qr');
  }
  final candidates = <String>{
    decoded['url'] as String,
    if (decoded['urls'] is List)
      ...(decoded['urls'] as List).whereType<String>(),
  };
  final endpoints = candidates
      .map(Uri.tryParse)
      .whereType<Uri>()
      .where(_isValidAccountQrEndpoint)
      .toSet()
      .toList(growable: false);
  if (endpoints.isEmpty) {
    throw const AccountTransferException('invalid_qr');
  }
  return endpoints;
}

bool _isValidAccountQrEndpoint(Uri uri) {
  final address = InternetAddress.tryParse(uri.host);
  return uri.scheme == 'http' &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment &&
      uri.query.isEmpty &&
      uri.hasPort &&
      uri.port > 0 &&
      address != null &&
      address.type == InternetAddressType.IPv4 &&
      _isPrivateIpv4(address.address) &&
      RegExp(r'^/sylphy-account/[A-Za-z0-9_-]{32}$').hasMatch(uri.path);
}

Future<List<String>> _findLanAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  final addresses = interfaces
      .expand(
        (interface) => interface.addresses.map(
          (address) => (name: interface.name, address: address.address),
        ),
      )
      .where((candidate) => _isPrivateIpv4(candidate.address))
      .toList(growable: false);
  if (addresses.isEmpty) {
    throw const AccountTransferException('no_local_network');
  }
  addresses.sort(
    (a, b) => _addressPreference(
      a.address,
      interfaceName: a.name,
    ).compareTo(_addressPreference(b.address, interfaceName: b.name)),
  );
  return addresses.map((value) => value.address).toSet().take(4).toList();
}

bool _isPrivateIpv4(String value) {
  final parts = value.split('.').map(int.tryParse).toList(growable: false);
  if (parts.length != 4 || parts.any((part) => part == null)) return false;
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254);
}

int _addressPreference(String value, {required String interfaceName}) {
  final normalizedName = interfaceName.toLowerCase();
  final looksVirtual = const [
    'vethernet',
    'virtualbox',
    'vmware',
    'hyper-v',
    'wsl',
    'tailscale',
    'zerotier',
  ].any(normalizedName.contains);
  final subnetPreference = value.startsWith('192.168.')
      ? 0
      : value.startsWith('10.')
      ? 1
      : value.startsWith('172.')
      ? 2
      : 3;
  return (looksVirtual ? 100 : 0) + subnetPreference;
}

class AccountTransferException implements Exception {
  const AccountTransferException(this.code, {this.importedProfile});
  final String code;
  final UserProfile? importedProfile;

  @override
  String toString() => 'AccountTransferException($code)';
}
