import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../storage/atomic_file.dart';
import 'github_updates.dart';

enum UpdateStage {
  idle,
  checking,
  available,
  downloading,
  ready,
  installing,
  installed,
  error,
}

enum InstallResult { started, permissionRequired, restartRequired }

abstract interface class UpdateInstaller {
  Future<InstallResult> install(File file, AppVersion expected);
  Future<void> allowAndroidInstalls();
  Future<void> restart(File file);
}

class PlatformUpdateInstaller implements UpdateInstaller {
  static const _channel = MethodChannel('sylphy/updates');

  @override
  Future<InstallResult> install(File file, AppVersion expected) async {
    if (Platform.isAndroid) {
      final result = await _channel.invokeMethod<String>('installApk', {
        'path': file.path,
        'version': expected.version,
        'build': expected.build,
      });
      if (result == 'permission_required') {
        return InstallResult.permissionRequired;
      }
      if (result != 'started') {
        throw const UpdateException('Installazione non avviata.');
      }
      return InstallResult.started;
    }
    if (Platform.isWindows) {
      // No shell, silent flags, elevation or forced termination.
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
      return InstallResult.started;
    }
    if (Platform.isLinux) {
      final result = await Process.run('/bin/sh', [
        file.path,
        '--install-only',
      ]).timeout(const Duration(minutes: 10));
      if (result.exitCode != 0) {
        throw const UpdateException(
          'Installazione Linux non riuscita. La versione attuale è ancora disponibile.',
        );
      }
      return InstallResult.restartRequired;
    }
    throw const UpdateException('Sistema operativo non supportato.');
  }

  @override
  Future<void> allowAndroidInstalls() =>
      _channel.invokeMethod<void>('allowInstalls');

  @override
  Future<void> restart(File file) async {
    await Process.start('/bin/sh', [
      file.path,
      '--launch-after-exit',
      '$pid',
    ], mode: ProcessStartMode.detached);
  }
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.platform,
    required Future<AppVersion> Function() currentVersion,
    required Future<Directory> Function() directory,
    GithubUpdates? releases,
    UpdateInstaller? installer,
    this.automaticByDefault = true,
  }) : _versionLoader = currentVersion,
       _directoryLoader = directory,
       _releases = releases ?? GithubUpdates(),
       _installer = installer ?? PlatformUpdateInstaller();

  factory AppUpdateController.production() => AppUpdateController(
    platform: Platform.isAndroid
        ? UpdatePlatform.android
        : Abi.current() == Abi.windowsX64
        ? UpdatePlatform.windows
        : Abi.current() == Abi.linuxX64
        ? UpdatePlatform.linux
        : null,
    currentVersion: () async {
      final info = await PackageInfo.fromPlatform();
      return AppVersion(info.version, int.parse(info.buildNumber));
    },
    directory: () async =>
        Directory('${(await getApplicationSupportDirectory()).path}/updates'),
    automaticByDefault: kReleaseMode,
  );

  final UpdatePlatform? platform;
  final bool automaticByDefault;
  final Future<AppVersion> Function() _versionLoader;
  final Future<Directory> Function() _directoryLoader;
  final GithubUpdates _releases;
  final UpdateInstaller _installer;
  AppVersion? current;
  AvailableUpdate? available;
  File? downloaded;
  UpdateStage stage = UpdateStage.idle;
  String? message;
  bool permissionRequired = false;
  bool automatic = true;
  String? skippedTag;
  double progress = 0;
  int promptRevision = 0;
  DateTime? _lastCheck;
  Future<void>? _initialization;
  Directory? _directory;
  bool _disposed = false;
  bool _cancelRequested = false;
  bool get busy => {
    UpdateStage.checking,
    UpdateStage.downloading,
    UpdateStage.installing,
  }.contains(stage);
  bool get supported => platform != null;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _load();
  Future<void> _load() async {
    automatic = automaticByDefault;
    current = await _versionLoader();
    _directory = await _directoryLoader();
    final file = await recoverFile(
      File('${_directory!.path}/preferences.json'),
    );
    if (file != null && await file.length() < 16384) {
      try {
        final prefs = jsonDecode(await file.readAsString());
        if (prefs is Map) {
          if (prefs['automatic'] is bool) {
            automatic = prefs['automatic'] as bool;
          }
          if (prefs['skipped'] is String) {
            skippedTag = prefs['skipped'] as String;
          }
        }
      } on FormatException {
        /* Ignore damaged, non-sensitive preferences. */
      }
    }
    await _cleanOldPackages();
    _emit();
  }

  Future<void> _cleanOldPackages() async {
    final packages = Directory('${_directory!.path}/packages');
    if (!await packages.exists()) return;
    try {
      await for (final entity in packages.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final match = RegExp(
          r'^sylphy-v(\d+\.\d+\.\d+)-(?:android\.apk|windows-x64-setup\.exe|linux-x64\.run)(?:\.part)?$',
        ).firstMatch(name);
        if (match != null &&
            AppVersion(
                  match[1]!,
                  1,
                ).compareTo(AppVersion(current!.version, 1)) <=
                0) {
          await entity.delete();
        }
      }
    } on FileSystemException {
      /* An installer may still be using its file. */
    }
  }

  Future<void> _save() async {
    if (_directory == null) return;
    try {
      await writeFileRecoverably(
        File('${_directory!.path}/preferences.json'),
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({'automatic': automatic, 'skipped': skippedTag}),
          ),
        ),
      );
    } on FileSystemException {
      message = 'Impossibile salvare la preferenza degli aggiornamenti.';
      _emit();
    }
  }

  Future<void> setAutomatic(bool value) async {
    await initialize();
    automatic = value;
    _emit();
    await _save();
  }

  Future<void> skip() async {
    skippedTag = available?.tag;
    await _save();
  }

  void showAvailable() {
    if (available == null) return;
    promptRevision++;
    _emit();
  }

  Future<void> check({bool manual = false}) async {
    if (busy || !supported || _disposed) return;
    if (!manual &&
        (stage == UpdateStage.ready || stage == UpdateStage.installed)) {
      return;
    }
    final previousStage = stage;
    stage = UpdateStage.checking;
    _emit();
    try {
      await initialize();
      if (_disposed) return;
      if (!manual &&
          (!automatic ||
              (_lastCheck != null &&
                  DateTime.now().difference(_lastCheck!) <
                      const Duration(hours: 6)))) {
        stage = previousStage;
        return;
      }
      _lastCheck = DateTime.now();
      message = null;
      final update = await _releases.check(current!, platform!);
      if (_disposed) return;
      available = update;
      downloaded = null;
      permissionRequired = false;
      stage = update == null ? UpdateStage.idle : UpdateStage.available;
      message = update == null ? 'Sylphy è aggiornato.' : null;
      if (update != null && (manual || skippedTag != update.tag)) {
        promptRevision++;
      }
    } on Object catch (error) {
      if (!_disposed) {
        stage = UpdateStage.error;
        message = error is UpdateException
            ? error.message
            : 'Controllo aggiornamenti non riuscito. Verifica la connessione e riprova.';
        // Allow an automatic retry after 15 minutes instead of six hours.
        _lastCheck = DateTime.now().subtract(
          const Duration(hours: 5, minutes: 45),
        );
        _initialization = null;
      }
    } finally {
      _emit();
    }
  }

  Future<void> download() async {
    if (busy || available == null || _disposed) return;
    stage = UpdateStage.downloading;
    progress = 0;
    message = null;
    _cancelRequested = false;
    _emit();
    try {
      downloaded = await _releases.download(
        available!,
        Directory('${_directory!.path}/packages'),
        (received, total) {
          final next = received / total;
          if (next - progress >= 0.005 || received == total) {
            progress = next;
            _emit();
          }
        },
      );
      stage = UpdateStage.ready;
    } on Object catch (error) {
      stage = _cancelRequested ? UpdateStage.available : UpdateStage.error;
      message = _cancelRequested
          ? 'Download annullato.'
          : error is UpdateException
          ? error.message
          : 'Download non riuscito. Verifica la connessione e lo spazio libero, poi riprova.';
    }
    _emit();
  }

  void cancelDownload() {
    if (stage != UpdateStage.downloading) return;
    _cancelRequested = true;
    _releases.cancel();
  }

  Future<void> install() async {
    if (busy || downloaded == null || available == null || _disposed) return;
    stage = UpdateStage.installing;
    message = null;
    _emit();
    try {
      if (!await GithubUpdates.verified(downloaded!, available!.asset)) {
        downloaded = null;
        throw const UpdateException(
          'Il file è cambiato. Scarica nuovamente l’aggiornamento.',
        );
      }
      if (_disposed) return;
      final result = await _installer.install(downloaded!, available!.version);
      permissionRequired = result == InstallResult.permissionRequired;
      stage = result == InstallResult.restartRequired
          ? UpdateStage.installed
          : UpdateStage.ready;
      message = switch (result) {
        InstallResult.permissionRequired =>
          'Consenti a Sylphy di installare aggiornamenti nelle impostazioni Android, poi torna qui e premi Aggiorna.',
        InstallResult.restartRequired =>
          'Aggiornamento installato. Riavvia Sylphy per usare la nuova versione.',
        InstallResult.started =>
          'Completa l’aggiornamento nella finestra di installazione. Se lo annulli puoi riprovare qui.',
      };
    } on Object catch (error) {
      stage = UpdateStage.error;
      message = error is UpdateException
          ? error.message
          : error is PlatformException
          ? error.message ?? 'Installazione non riuscita.'
          : 'Impossibile avviare l’installazione. Riprova.';
    }
    _emit();
  }

  Future<void> allowAndroidInstalls() async {
    try {
      await _installer.allowAndroidInstalls();
    } on Object {
      message =
          'Apri le impostazioni Android e autorizza Sylphy a installare app.';
      _emit();
    }
  }

  Future<bool> prepareRestart() async {
    if (downloaded == null || stage != UpdateStage.installed) return false;
    stage = UpdateStage.installing;
    _emit();
    try {
      if (!await GithubUpdates.verified(downloaded!, available!.asset)) {
        throw const UpdateException('File di aggiornamento non valido.');
      }
      await _installer.restart(downloaded!);
      return true;
    } on Object {
      stage = UpdateStage.installed;
      message =
          'Riavvio non riuscito. Chiudi Sylphy e riaprilo dal menu applicazioni.';
      _emit();
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _releases.cancel();
    super.dispose();
  }
}
