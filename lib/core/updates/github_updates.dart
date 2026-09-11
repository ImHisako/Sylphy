import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const updateRepository = 'ImHisako/Sylphy';
const maxUpdateBytes = 1024 * 1024 * 1024;

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum UpdatePlatform { android, windows, linux }

class AppVersion implements Comparable<AppVersion> {
  AppVersion(this.version, this.build) {
    if (!RegExp(
          r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
        ).hasMatch(version) ||
        build < 1 ||
        build > 2100000000) {
      throw const UpdateException('Numero di versione non valido.');
    }
  }
  final String version;
  final int build;
  @override
  int compareTo(AppVersion other) {
    final left = version.split('.').map(int.parse).toList();
    final right = other.version.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final comparison = left[i].compareTo(right[i]);
      if (comparison != 0) return comparison;
    }
    return build.compareTo(other.build);
  }
}

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url, this.size, this.sha256Hex);
  final String name;
  final Uri url;
  final int size;
  final String sha256Hex;

  factory ReleaseAsset.fromJson(Map<String, dynamic> json, String tag) {
    final name = json['name'];
    final size = json['size'];
    final digest = json['digest'];
    final url = Uri.tryParse(json['browser_download_url'] as String? ?? '');
    if (name is! String ||
        !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(name) ||
        size is! int ||
        size < 1 ||
        size > maxUpdateBytes ||
        digest is! String ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest) ||
        json['state'] != 'uploaded' ||
        url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.userInfo.isNotEmpty ||
        url.port != 443 ||
        url.hasQuery ||
        url.hasFragment ||
        url.path != '/$updateRepository/releases/download/$tag/$name') {
      throw const UpdateException(
        'File della release non valido o privo di verifica SHA-256.',
      );
    }
    return ReleaseAsset(name, url, size, digest.substring(7).toLowerCase());
  }
}

class AvailableUpdate {
  const AvailableUpdate(this.version, this.asset, this.notes);
  final AppVersion version;
  final ReleaseAsset asset;
  final String notes;
  String get tag => 'v${version.version}';
}

class UpdateResponse {
  const UpdateResponse(this.status, this.bytes, {this.length = -1});
  final int status;
  final Stream<List<int>> bytes;
  final int length;
}

abstract interface class UpdateTransport {
  Future<UpdateResponse> get(Uri uri);
  void close();
}

/// Redirects may only lead to GitHub's HTTPS release asset CDN.
class GithubUpdateTransport implements UpdateTransport {
  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..autoUncompress = false;

  static bool allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      {
        'api.github.com',
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
        'github-releases.githubusercontent.com',
      }.contains(uri.host);

  @override
  Future<UpdateResponse> get(Uri uri) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!allowed(uri)) {
        throw const UpdateException(
          'Destinazione del download non autorizzata.',
        );
      }
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 25));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Sylphy-Updater');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(
        HttpHeaders.acceptHeader,
        uri.host == 'api.github.com'
            ? 'application/vnd.github+json'
            : 'application/octet-stream',
      );
      if (uri.host == 'api.github.com') {
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen(null).cancel();
        if (location == null || uri.host == 'api.github.com') {
          throw const UpdateException('Redirect della release non valido.');
        }
        uri = uri.resolve(location);
        continue;
      }
      return UpdateResponse(
        response.statusCode,
        response.timeout(const Duration(seconds: 30)),
        length: response.contentLength,
      );
    }
    throw const UpdateException('Troppi redirect durante il download.');
  }

  @override
  void close() => _client.close(force: true);
}

class GithubUpdates {
  GithubUpdates({UpdateTransport Function()? transport})
    : _transportFactory = transport ?? GithubUpdateTransport.new;
  final UpdateTransport Function() _transportFactory;
  UpdateTransport? _active;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _active?.close();
  }

  void _ensureActive() {
    if (_cancelled) throw const UpdateException('Download annullato.');
  }

  Future<Uint8List> _read(Uri uri, int limit, {ReleaseAsset? asset}) async {
    final response = await _active!.get(uri);
    _checkResponse(response, limit);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.bytes) {
      _ensureActive();
      if (bytes.length + chunk.length > limit) {
        throw const UpdateException('Risposta troppo grande.');
      }
      bytes.add(chunk);
    }
    final result = bytes.takeBytes();
    if (asset != null &&
        (result.length != asset.size ||
            sha256.convert(result).toString() != asset.sha256Hex)) {
      throw const UpdateException('Verifica della release non riuscita.');
    }
    return result;
  }

  void _checkResponse(UpdateResponse response, int limit) {
    if (response.status == 403 || response.status == 429) {
      throw const UpdateException(
        'GitHub ha limitato le richieste. Riprova più tardi.',
      );
    }
    if (response.status != 200) {
      throw const UpdateException('Release non disponibile su GitHub.');
    }
    if (response.length > limit) {
      throw const UpdateException('File troppo grande.');
    }
  }

  Future<AvailableUpdate?> check(
    AppVersion current,
    UpdatePlatform platform,
  ) async {
    _cancelled = false;
    _active = _transportFactory();
    final deadline = Timer(const Duration(seconds: 60), () => _active?.close());
    try {
      final release =
          jsonDecode(
                utf8.decode(
                  await _read(
                    Uri.https(
                      'api.github.com',
                      '/repos/$updateRepository/releases/latest',
                    ),
                    2 * 1024 * 1024,
                  ),
                ),
              )
              as Map<String, dynamic>;
      if (release['draft'] != false || release['prerelease'] != false) {
        return null;
      }
      final tag = release['tag_name'] as String? ?? '';
      if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) return null;
      // Do not require the new manifest on older, already installed releases.
      if (AppVersion(
            tag.substring(1),
            1,
          ).compareTo(AppVersion(current.version, 1)) <=
          0) {
        return null;
      }
      final rawAssets = (release['assets'] as List)
          .cast<Map<String, dynamic>>();
      ReleaseAsset assetNamed(String name) {
        final matches = rawAssets
            .where((asset) => asset['name'] == name)
            .toList();
        if (matches.length != 1) {
          throw const UpdateException(
            'Questa release non contiene un aggiornamento compatibile.',
          );
        }
        return ReleaseAsset.fromJson(matches.single, tag);
      }

      final manifest = assetNamed('sylphy-update.json');
      if (manifest.size > 16384) {
        throw const UpdateException('Manifest della release troppo grande.');
      }
      final metadata =
          jsonDecode(
                utf8.decode(await _read(manifest.url, 16384, asset: manifest)),
              )
              as Map<String, dynamic>;
      if (metadata['schema'] != 1 ||
          'v${metadata['version']}' != tag ||
          metadata['build'] is! int) {
        throw const UpdateException('Formato della release non supportato.');
      }
      final version = AppVersion(
        metadata['version'] as String,
        metadata['build'] as int,
      );
      if (version.compareTo(current) <= 0) return null;
      if (version.build <= current.build) {
        throw const UpdateException(
          'La release non ha un numero di build più recente.',
        );
      }
      final suffix = switch (platform) {
        UpdatePlatform.android => 'android.apk',
        UpdatePlatform.windows => 'windows-x64-setup.exe',
        UpdatePlatform.linux => 'linux-x64.run',
      };
      final notes = release['body'] as String? ?? '';
      return AvailableUpdate(
        version,
        assetNamed('sylphy-$tag-$suffix'),
        notes.length <= 12000 ? notes : '${notes.substring(0, 12000)}…',
      );
    } finally {
      deadline.cancel();
      _active?.close();
      _active = null;
    }
  }

  Future<File> download(
    AvailableUpdate update,
    Directory directory,
    void Function(int received, int total) progress,
  ) async {
    _cancelled = false;
    _active = _transportFactory();
    final deadline = Timer(const Duration(minutes: 30), () => _active?.close());
    final target = File('${directory.path}/${update.asset.name}');
    final partial = File('${target.path}.part');
    RandomAccessFile? output;
    try {
      await directory.create(recursive: true);
      if (await verified(target, update.asset)) {
        _ensureActive();
        return target;
      }
      final response = await _active!.get(update.asset.url);
      _checkResponse(response, update.asset.size);
      output = await partial.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in response.bytes) {
        _ensureActive();
        if (received + chunk.length > update.asset.size) {
          throw const UpdateException('Dimensione del download non valida.');
        }
        await output.writeFrom(chunk);
        received += chunk.length;
        progress(received, update.asset.size);
      }
      await output.flush();
      await output.close();
      output = null;
      _ensureActive();
      if (!await verified(partial, update.asset)) {
        throw const UpdateException(
          'Download incompleto o verifica SHA-256 fallita. Riprova.',
        );
      }
      _ensureActive();
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } finally {
      deadline.cancel();
      _active?.close();
      _active = null;
      await output?.close();
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<bool> verified(File file, ReleaseAsset asset) async {
    if (!await file.exists() || await file.length() != asset.size) return false;
    return (await sha256.bind(file.openRead()).first).toString() ==
        asset.sha256Hex;
  }
}
