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
import '../platform/attachment_downloads.dart';
import '../profile/user_profile.dart';
import 'identity_service.dart';

class AccountTransferService {
  AccountTransferService({
    required NativeAccountTransferApi nativeCore,
    DeviceSecretStore? deviceSecretStore,
    UserProfileStore? profileStore,
    Future<Directory> Function()? applicationSupportDirectory,
    Future<XFile?> Function()? pickFile,
    Future<ShareResult> Function(ShareParams)? share,
    AttachmentDownloads downloads = const AttachmentDownloads(),
  }) : _nativeCore = nativeCore,
       _deviceSecretStore = deviceSecretStore ?? PlatformDeviceSecretStore(),
       _profileStore =
           profileStore ??
           (nativeCore is NativeCoreClient
               ? FileUserProfileStore(
                   cipher: NativeLocalDataCipher(
                     core: nativeCore,
                     password:
                         (deviceSecretStore ?? PlatformDeviceSecretStore())
                             .getOrCreate,
                   ),
                   supportDirectory: applicationSupportDirectory,
                 )
               : throw ArgumentError('profileStore is required for this core')),
       _pickFile = pickFile ?? (() => openFile()),
       _share = share ?? SharePlus.instance.share,
       _downloads = downloads,
       _applicationSupportDirectory =
           applicationSupportDirectory ?? getApplicationSupportDirectory;

  static const fileExtension = 'sylphy-account';
  static const _mimeType = 'application/vnd.sylphy.account+json';
  static const _maxDocumentBytes = 130 * 1024 * 1024;
  final NativeAccountTransferApi _nativeCore;
  final Future<XFile?> Function() _pickFile;
  final Future<ShareResult> Function(ShareParams) _share;
  final AttachmentDownloads _downloads;
  final DeviceSecretStore _deviceSecretStore;
  final UserProfileStore _profileStore;
  final Future<Directory> Function() _applicationSupportDirectory;

  Future<String?> exportToFile({
    required UserProfile profile,
    required String transferPassword,
    bool Function()? isCurrent,
  }) async {
    final document = await createBackupDocument(
      profile: profile,
      transferPassword: transferPassword,
    );
    if (isCurrent?.call() == false) return null;
    if (Platform.isIOS) {
      return _shareDocument(document);
    }
    return _downloads.save(
      fileName: 'Sylphy-account.$fileExtension',
      bytes: document,
      isCurrent: isCurrent,
    );
  }

  Future<String?> shareBackup({
    required UserProfile profile,
    required String transferPassword,
    bool Function()? isCurrent,
  }) async {
    final document = await createBackupDocument(
      profile: profile,
      transferPassword: transferPassword,
    );
    if (isCurrent?.call() == false) return null;
    return _shareDocument(document);
  }

  Future<String?> _shareDocument(Uint8List document) async {
    final result = await _share(
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
        fileNameOverrides: ['Sylphy-account.$fileExtension'],
      ),
    );
    return result.status == ShareResultStatus.dismissed ? null : 'shared';
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
    // File providers and share targets may change the extension/MIME type.
    // Authenticate the document's contents rather than trusting its filename.
    final selected = await _pickFile();
    if (selected == null) return null;
    return readBackupFile(selected);
  }

  Future<UserProfile> importFromDocument({
    required List<int> bytes,
    required String transferPassword,
  }) async {
    final encrypted = parseBackupDocument(bytes);
    final support = await _applicationSupportDirectory();
    final nativeDirectory = Directory(
      '${support.path}${Platform.pathSeparator}native',
    );
    await nativeDirectory.create(recursive: true);
    final response = await _nativeCore.importAccountInBackground(
      transferPassword: transferPassword,
      backupBase64: encrypted,
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
        try {
          await recovery.invalidatePersistedProfile();
        } on Object {
          // Retain the committed import result even if profile cleanup fails.
        }
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
      request.followRedirects = false;
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

/// Checks only the outer transport envelope. Authentication remains native.
String parseBackupDocument(List<int> bytes) {
  if (bytes.isEmpty ||
      bytes.length > AccountTransferService._maxDocumentBytes) {
    throw const AccountTransferException('limit_exceeded');
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'sylphy-account-backup' ||
        decoded['backup_base64'] is! String) {
      throw const AccountTransferException('invalid_backup');
    }
    if (decoded['version'] != 1) {
      throw const AccountTransferException('unsupported_version');
    }
    final encoded = (decoded['backup_base64'] as String).replaceAll(
      RegExp(r'\s+'),
      '',
    );
    if (encoded.isEmpty) throw const AccountTransferException('invalid_backup');
    return base64.normalize(encoded).replaceFirst(RegExp(r'=+$'), '');
  } on FormatException {
    throw const AccountTransferException('invalid_backup');
  }
}

/// Bounds actual bytes as well as provider metadata, which can become stale.
@visibleForTesting
Future<Uint8List> readBackupFile(
  XFile file, {
  int maxBytes = AccountTransferService._maxDocumentBytes,
}) async {
  final length = await file.length();
  if (maxBytes <= 0 || length < 0 || length > maxBytes) {
    throw const AccountTransferException('limit_exceeded');
  }
  final builder = BytesBuilder(copy: false);
  // Stop the subscription before retaining a chunk that exceeds the budget.
  await for (final chunk in file.openRead()) {
    if (chunk.length > maxBytes - builder.length) {
      throw const AccountTransferException('limit_exceeded');
    }
    builder.add(chunk);
  }
  if (builder.isEmpty) {
    throw const AccountTransferException('limit_exceeded');
  }
  return builder.takeBytes();
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
  bool _serving = false;

  static Future<AccountQrTransferSession> start(
    Uint8List document, {
    Future<List<String>> Function()? addressProvider,
  }) async {
    if (document.isEmpty ||
        document.length > AccountTransferService._maxDocumentBytes) {
      throw const AccountTransferException('limit_exceeded');
    }
    final addresses = await (addressProvider ?? _findLanAddresses)();
    if (addresses.isEmpty) {
      throw const AccountTransferException('no_local_network');
    }
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
        _serving ||
        request.method != 'GET' ||
        request.uri.path != _requestPath ||
        state.value != AccountQrTransferState.waiting) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    // Claim the one-time document before yielding to socket I/O. A concurrent
    // request must not pass the waiting check and download the same backup.
    _serving = true;
    try {
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.sylphy.account+json',
      );
      request.response.contentLength = _document.length;
      request.response.add(_document);
      await request.response.close();
      if (!_closed) state.value = AccountQrTransferState.transferred;
      await close();
    } on Object {
      if (!_closed) state.value = AccountQrTransferState.error;
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
  if (payload.length > 16 * 1024) {
    throw const AccountTransferException('invalid_qr');
  }
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
      .take(4)
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

  String get message => switch (code) {
    'authentication_failed' =>
      'La password di trasferimento non è corretta oppure il file è danneggiato. Usa quella scelta sul dispositivo di origine.',
    'invalid_backup' || 'verification_failed' || 'invalid_input' =>
      'Il file non è un backup account Sylphy valido o è incompleto. Esportalo di nuovo dal dispositivo di origine.',
    'unsupported_version' =>
      'Questo backup usa un formato diverso. Aggiorna Sylphy su entrambi i dispositivi.',
    'vault_locked' =>
      'Sylphy è bloccato. Sblocca l’app e ripeti il trasferimento.',
    'feature_unavailable' =>
      'L’identità locale non è ancora pronta. Attendi il caricamento dell’account e riprova.',
    'limit_exceeded' => 'Il file è vuoto o supera il limite di 130 MiB.',
    'qr_download_failed' =>
      'Trasferimento non raggiungibile. Usa la stessa rete Wi-Fi, lascia aperto il QR sull’altro dispositivo e verifica il firewall.',
    'no_local_network' =>
      'Collega i dispositivi alla stessa rete Wi-Fi e riprova.',
    'invalid_qr' => 'Il codice non è un trasferimento account Sylphy valido.',
    'profile_persistence_failed' =>
      'Account importato, ma non è stato possibile salvare il profilo. Controlla lo spazio disponibile e riprova a salvare il profilo.',
    'storage_full' => 'Spazio locale insufficiente per ripristinare l’account.',
    'file_access_failed' =>
      'Non è stato possibile accedere al file. Copialo nella cartella Download e selezionalo di nuovo.',
    _ =>
      'Il trasferimento non è riuscito. Riprova e conserva il codice errore mostrato.',
  };

  @override
  String toString() => 'AccountTransferException($code)';
}
