import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../profile/user_profile.dart';
import '../storage/atomic_file.dart';

class PrivacySettings {
  const PrivacySettings({
    this.shareProfilePhoto = true,
    this.shareDisplayName = true,
    this.sendReadReceipts = true,
    this.showReadReceipts = true,
    this.showOnlineStatus = true,
    this.showLastSeen = true,
    this.allowUnknownContacts = true,
    this.reduceMotion = false,
    this.incognitoKeyboard = false,
    this.themeName = 'sylphy',
  });

  final bool shareProfilePhoto;
  final bool shareDisplayName;
  final bool sendReadReceipts;
  final bool showReadReceipts;
  final bool showOnlineStatus;
  final bool showLastSeen;
  final bool allowUnknownContacts;
  final bool reduceMotion;
  final bool incognitoKeyboard;
  final String themeName;

  static const failClosed = PrivacySettings(
    shareProfilePhoto: false,
    shareDisplayName: false,
    sendReadReceipts: false,
    showReadReceipts: false,
    showOnlineStatus: false,
    showLastSeen: false,
    allowUnknownContacts: false,
  );

  PrivacySettings copyWith({
    bool? shareProfilePhoto,
    bool? shareDisplayName,
    bool? sendReadReceipts,
    bool? showReadReceipts,
    bool? showOnlineStatus,
    bool? showLastSeen,
    bool? allowUnknownContacts,
    bool? reduceMotion,
    bool? incognitoKeyboard,
    String? themeName,
  }) => PrivacySettings(
    shareProfilePhoto: shareProfilePhoto ?? this.shareProfilePhoto,
    shareDisplayName: shareDisplayName ?? this.shareDisplayName,
    sendReadReceipts: sendReadReceipts ?? this.sendReadReceipts,
    showReadReceipts: showReadReceipts ?? this.showReadReceipts,
    showOnlineStatus: showOnlineStatus ?? this.showOnlineStatus,
    showLastSeen: showLastSeen ?? this.showLastSeen,
    allowUnknownContacts: allowUnknownContacts ?? this.allowUnknownContacts,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    incognitoKeyboard: incognitoKeyboard ?? this.incognitoKeyboard,
    themeName: themeName ?? this.themeName,
  );

  Map<String, Object> toJson() => {
    'version': 2,
    'share_profile_photo': shareProfilePhoto,
    'share_display_name': shareDisplayName,
    'send_read_receipts': sendReadReceipts,
    'show_read_receipts': showReadReceipts,
    'show_online_status': showOnlineStatus,
    'show_last_seen': showLastSeen,
    'allow_unknown_contacts': allowUnknownContacts,
    'reduce_motion': reduceMotion,
    'incognito_keyboard': incognitoKeyboard,
    'theme_name': themeName,
  };

  factory PrivacySettings.fromJson(Map<String, dynamic> json) {
    bool value(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    return PrivacySettings(
      shareProfilePhoto: value('share_profile_photo', true),
      shareDisplayName: value('share_display_name', true),
      sendReadReceipts:
          value('send_read_receipts', true) &&
          value('show_read_receipts', true),
      showReadReceipts: value('show_read_receipts', true),
      showOnlineStatus: value('show_online_status', true),
      showLastSeen: value('show_last_seen', true),
      // Version 1 shipped with incoming contact requests disabled by default,
      // which forced both people to import each other before the first chat
      // could appear. Migrate that old default to the new one. Version 2 still
      // preserves an explicit opt-out selected by the user.
      allowUnknownContacts: json['version'] == 1
          ? true
          : value('allow_unknown_contacts', true),
      reduceMotion: value('reduce_motion', false),
      incognitoKeyboard: value('incognito_keyboard', false),
      themeName: json['theme_name'] is String
          ? json['theme_name'] as String
          : 'sylphy',
    );
  }
}

class PrivacySettingsController extends ChangeNotifier {
  PrivacySettingsController({
    required LocalDataCipher cipher,
    Future<Directory> Function()? supportDirectory,
  }) : _cipher = cipher,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final LocalDataCipher _cipher;
  final Future<Directory> Function() _supportDirectory;
  PrivacySettings _value = const PrivacySettings();
  bool _loaded = false;
  Object? _storageError;
  Future<void> _updateTail = Future<void>.value();

  PrivacySettings get value => _value;
  bool get loaded => _loaded;
  Object? get storageError => _storageError;

  Future<void> load() async {
    try {
      final file = await _file();
      final recovered = await recoverFile(file);
      if (recovered != null) {
        final plaintext = await _cipher.open(await recovered.readAsBytes());
        final decoded = jsonDecode(utf8.decode(plaintext));
        if (decoded is Map<String, dynamic> &&
            (decoded['version'] == 1 || decoded['version'] == 2)) {
          _value = PrivacySettings.fromJson(decoded);
          if (decoded['version'] == 1) {
            await _persist(_value);
          }
        }
      } else {
        await _migrateLegacy();
      }
    } on Object catch (error) {
      _storageError = error;
      _value = PrivacySettings.failClosed;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> update(PrivacySettings value) {
    if (_value.toJson().toString() == value.toJson().toString()) {
      return Future<void>.value();
    }
    _value = value;
    _storageError = null;
    notifyListeners();
    final operation = _updateTail.then((_) => _persist(value));
    _updateTail = operation.onError((error, _) {
      _storageError = error;
      if (_value.toJson().toString() == value.toJson().toString()) {
        _value = PrivacySettings.failClosed;
      }
      notifyListeners();
    });
    return _updateTail;
  }

  Future<void> _persist(PrivacySettings value) async {
    try {
      final file = await _file();
      final plaintext = Uint8List.fromList(
        utf8.encode(jsonEncode(value.toJson())),
      );
      await writeFileRecoverably(file, await _cipher.protect(plaintext));
      final legacy = await _legacyFile();
      await eraseFileBestEffort(legacy);
    } on Object {
      rethrow;
    }
  }

  Future<File> _file() async {
    final root = await _supportDirectory();
    return File(
      '${root.path}${Platform.pathSeparator}privacy${Platform.pathSeparator}settings-v2.vault',
    );
  }

  Future<File> _legacyFile() async {
    final root = await _supportDirectory();
    return File(
      '${root.path}${Platform.pathSeparator}privacy${Platform.pathSeparator}settings.json',
    );
  }

  Future<void> _migrateLegacy() async {
    final legacy = await _legacyFile();
    if (!await legacy.exists()) return;
    final decoded = jsonDecode(await legacy.readAsString());
    if (decoded is Map<String, dynamic> &&
        (decoded['version'] == 1 || decoded['version'] == 2)) {
      _value = PrivacySettings.fromJson(decoded);
      final file = await _file();
      final plaintext = Uint8List.fromList(
        utf8.encode(jsonEncode(_value.toJson())),
      );
      await writeFileRecoverably(file, await _cipher.protect(plaintext));
      await eraseFileBestEffort(legacy);
    }
  }
}
