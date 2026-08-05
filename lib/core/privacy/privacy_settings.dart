import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class PrivacySettings {
  const PrivacySettings({
    this.shareProfilePhoto = true,
    this.shareDisplayName = true,
    this.sendReadReceipts = true,
    this.showReadReceipts = true,
    this.showOnlineStatus = true,
    this.showLastSeen = true,
    this.allowUnknownContacts = false,
    this.reduceMotion = false,
  });

  final bool shareProfilePhoto;
  final bool shareDisplayName;
  final bool sendReadReceipts;
  final bool showReadReceipts;
  final bool showOnlineStatus;
  final bool showLastSeen;
  final bool allowUnknownContacts;
  final bool reduceMotion;

  PrivacySettings copyWith({
    bool? shareProfilePhoto,
    bool? shareDisplayName,
    bool? sendReadReceipts,
    bool? showReadReceipts,
    bool? showOnlineStatus,
    bool? showLastSeen,
    bool? allowUnknownContacts,
    bool? reduceMotion,
  }) => PrivacySettings(
    shareProfilePhoto: shareProfilePhoto ?? this.shareProfilePhoto,
    shareDisplayName: shareDisplayName ?? this.shareDisplayName,
    sendReadReceipts: sendReadReceipts ?? this.sendReadReceipts,
    showReadReceipts: showReadReceipts ?? this.showReadReceipts,
    showOnlineStatus: showOnlineStatus ?? this.showOnlineStatus,
    showLastSeen: showLastSeen ?? this.showLastSeen,
    allowUnknownContacts: allowUnknownContacts ?? this.allowUnknownContacts,
    reduceMotion: reduceMotion ?? this.reduceMotion,
  );

  Map<String, Object> toJson() => {
    'version': 1,
    'share_profile_photo': shareProfilePhoto,
    'share_display_name': shareDisplayName,
    'send_read_receipts': sendReadReceipts,
    'show_read_receipts': showReadReceipts,
    'show_online_status': showOnlineStatus,
    'show_last_seen': showLastSeen,
    'allow_unknown_contacts': allowUnknownContacts,
    'reduce_motion': reduceMotion,
  };

  factory PrivacySettings.fromJson(Map<String, dynamic> json) {
    bool value(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    return PrivacySettings(
      shareProfilePhoto: value('share_profile_photo', true),
      shareDisplayName: value('share_display_name', true),
      sendReadReceipts: value('send_read_receipts', true),
      showReadReceipts: value('show_read_receipts', true),
      showOnlineStatus: value('show_online_status', true),
      showLastSeen: value('show_last_seen', true),
      allowUnknownContacts: value('allow_unknown_contacts', false),
      reduceMotion: value('reduce_motion', false),
    );
  }
}

class PrivacySettingsController extends ChangeNotifier {
  PrivacySettingsController({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;
  PrivacySettings _value = const PrivacySettings();
  bool _loaded = false;

  PrivacySettings get value => _value;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic> && decoded['version'] == 1) {
          _value = PrivacySettings.fromJson(decoded);
        }
      }
    } on Object {
      _value = const PrivacySettings();
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> update(PrivacySettings value) async {
    if (_value.toJson().toString() == value.toJson().toString()) return;
    _value = value;
    notifyListeners();
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(value.toJson()), flush: true);
    } on Object {
      // The in-memory setting remains active if local persistence is unavailable.
    }
  }

  Future<File> _file() async {
    final root = await _supportDirectory();
    return File(
      '${root.path}${Platform.pathSeparator}privacy${Platform.pathSeparator}settings.json',
    );
  }
}
