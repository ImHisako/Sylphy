import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum AppLogLevel { debug, info, warning, error }

@immutable
class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.action,
    this.result,
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String category;
  final String action;
  final String? result;

  String get formatted {
    final suffix = result == null ? '' : ' · $result';
    return '${timestamp.toIso8601String()} '
        '[${level.name.toUpperCase()}] $category · $action$suffix';
  }

  Map<String, Object?> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'category': category,
    'action': action,
    if (result != null) 'result': result,
  };
}

/// Privacy-aware diagnostic log used by Developer Options.
///
/// It records action names and result codes, never message bodies, invitation
/// codes, passwords, keys, file contents, or native request payloads.
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();
  static const int _maxEntries = 1000;
  static const String _settingsFileName = 'developer-options.json';
  static const String _logFileName = 'sylphy-diagnostics.jsonl';

  final List<AppLogEntry> _entries = [];
  File? _settingsFile;
  File? _logFile;
  bool _verboseEnabled = false;
  bool _initialized = false;
  Future<void> _writeQueue = Future.value();

  List<AppLogEntry> get entries => List.unmodifiable(_entries);
  bool get verboseEnabled => _verboseEnabled;
  bool get initialized => _initialized;
  String? get logFilePath => _logFile?.path;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      final diagnosticsDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}diagnostics',
      );
      await diagnosticsDirectory.create(recursive: true);
      _settingsFile = File(
        '${diagnosticsDirectory.path}${Platform.pathSeparator}'
        '$_settingsFileName',
      );
      _logFile = File(
        '${diagnosticsDirectory.path}${Platform.pathSeparator}$_logFileName',
      );
      if (await _settingsFile!.exists()) {
        final decoded = jsonDecode(await _settingsFile!.readAsString());
        if (decoded is Map<String, dynamic>) {
          _verboseEnabled = decoded['verbose_logging'] == true;
        }
      }
      _initialized = true;
      record(
        category: 'app',
        action: 'diagnostics_initialized',
        result: _verboseEnabled ? 'verbose_on' : 'verbose_off',
      );
    } on Object catch (error) {
      _initialized = true;
      record(
        category: 'app',
        action: 'diagnostics_initialization_failed',
        level: AppLogLevel.warning,
        result: error.runtimeType.toString(),
      );
    }
  }

  Future<void> setVerboseEnabled(bool value) async {
    if (_verboseEnabled == value) {
      return;
    }
    _verboseEnabled = value;
    record(
      category: 'developer_options',
      action: value ? 'verbose_logging_enabled' : 'verbose_logging_disabled',
      force: true,
    );
    notifyListeners();
    final settingsFile = _settingsFile;
    if (settingsFile != null) {
      await settingsFile.writeAsString(
        jsonEncode({'verbose_logging': value}),
        flush: true,
      );
    }
  }

  void record({
    required String category,
    required String action,
    AppLogLevel level = AppLogLevel.info,
    String? result,
    bool verbose = false,
    bool force = false,
  }) {
    if (verbose && !_verboseEnabled && !force) {
      return;
    }
    final entry = AppLogEntry(
      timestamp: DateTime.now().toUtc(),
      level: level,
      category: _safeToken(category),
      action: _safeToken(action),
      result: result == null ? null : _safeResult(result),
    );
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListeners();
    if (_verboseEnabled || level == AppLogLevel.error || force) {
      _appendToDisk(entry);
    }
    if (kDebugMode) {
      debugPrint(entry.formatted);
    }
  }

  void recordError({
    required String category,
    required String action,
    required Object error,
  }) {
    record(
      category: category,
      action: action,
      level: AppLogLevel.error,
      result: error.runtimeType.toString(),
      force: true,
    );
  }

  String exportText() {
    final header = [
      'Sylphy diagnostics',
      'generated=${DateTime.now().toUtc().toIso8601String()}',
      'platform=${Platform.operatingSystem}',
      'verbose_logging=$_verboseEnabled',
      'privacy=payloads_and_secrets_omitted',
      '',
    ];
    return [...header, ..._entries.map((entry) => entry.formatted)].join('\n');
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    final logFile = _logFile;
    if (logFile != null && await logFile.exists()) {
      await logFile.writeAsString('', flush: true);
    }
    record(
      category: 'developer_options',
      action: 'diagnostic_log_cleared',
      force: true,
    );
  }

  void _appendToDisk(AppLogEntry entry) {
    final logFile = _logFile;
    if (logFile == null) {
      return;
    }
    _writeQueue = _writeQueue
        .then((_) async {
          if (await logFile.exists() && await logFile.length() > 1024 * 1024) {
            await logFile.writeAsString('', flush: true);
          }
          await logFile.writeAsString(
            '${jsonEncode(entry.toJson())}\n',
            mode: FileMode.append,
            flush: true,
          );
        })
        .catchError((Object _) {
          // Diagnostics must never crash or block the application.
        });
  }

  static String _safeToken(String value) {
    final safe = value.replaceAll(RegExp(r'[^a-zA-Z0-9_.:-]'), '_');
    return safe.length <= 96 ? safe : safe.substring(0, 96);
  }

  static String _safeResult(String value) {
    final normalized = value.replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    return normalized.length <= 160 ? normalized : normalized.substring(0, 160);
  }
}
