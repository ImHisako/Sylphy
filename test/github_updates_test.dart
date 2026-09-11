import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/updates/app_updates.dart';
import 'package:sylphy/core/updates/github_updates.dart';

class UpdateFixture {
  final package = utf8.encode('test installer bytes');
  final Map<Uri, List<int>> files = {};
  final List<Uri> requests = [];
  late Map<String, dynamic> release;
  final api = Uri.https(
    'api.github.com',
    '/repos/$updateRepository/releases/latest',
  );
  int build = 3;
  List<List<int>>? packageChunks;

  UpdateFixture({this.build = 3}) {
    release = {
      'tag_name': 'v1.2.0',
      'draft': false,
      'prerelease': false,
      'body': 'Novità',
      'assets': [
        asset(
          'sylphy-update.json',
          utf8.encode(
            jsonEncode({'schema': 1, 'version': '1.2.0', 'build': build}),
          ),
        ),
        for (final suffix in [
          'android.apk',
          'windows-x64-setup.exe',
          'linux-x64.run',
        ])
          asset('sylphy-v1.2.0-$suffix', package),
      ],
    };
  }
  Map<String, dynamic> asset(String name, List<int> bytes) {
    final url = Uri.parse(
      'https://github.com/$updateRepository/releases/download/v1.2.0/$name',
    );
    files[url] = bytes;
    return {
      'name': name,
      'browser_download_url': '$url',
      'size': bytes.length,
      'digest': 'sha256:${sha256.convert(bytes)}',
      'state': 'uploaded',
    };
  }

  GithubUpdates service() =>
      GithubUpdates(transport: () => _FixtureTransport(this));
}

class _FixtureTransport implements UpdateTransport {
  _FixtureTransport(this.fixture);
  final UpdateFixture fixture;
  @override
  Future<UpdateResponse> get(Uri uri) async {
    fixture.requests.add(uri);
    final bytes = uri == fixture.api
        ? utf8.encode(jsonEncode(fixture.release))
        : fixture.files[uri]!;
    final chunks = !uri.path.endsWith('json') && uri != fixture.api
        ? fixture.packageChunks
        : null;
    return UpdateResponse(
      200,
      Stream.fromIterable(chunks ?? [bytes]),
      length: chunks == null ? bytes.length : -1,
    );
  }

  @override
  void close() {}
}

class TestUpdateInstaller implements UpdateInstaller {
  int calls = 0;
  InstallResult result = InstallResult.started;
  @override
  Future<InstallResult> install(File file, AppVersion expected) async {
    calls++;
    return result;
  }

  @override
  Future<void> allowAndroidInstalls() async {}
  @override
  Future<void> restart(File file) async {}
}

void main() {
  test('versions compare numerically and include the build number', () {
    expect(
      AppVersion('1.10.0', 4).compareTo(AppVersion('1.9.9', 3)),
      greaterThan(0),
    );
    expect(
      AppVersion('1.2.0', 4).compareTo(AppVersion('1.2.0', 3)),
      greaterThan(0),
    );
    expect(() => AppVersion('1.2', 1), throwsA(isA<UpdateException>()));
    expect(() => AppVersion('1.2.0', 0), throwsA(isA<UpdateException>()));
  });

  test(
    'each platform selects its own installer from the verified release',
    () async {
      for (final platform in UpdatePlatform.values) {
        final fixture = UpdateFixture();
        final update = await fixture.service().check(
          AppVersion('1.1.0', 2),
          platform,
        );
        expect(update!.version.build, 3);
        expect(update.asset.name, contains(platform.name));
        expect(
          fixture.requests.length,
          2,
        ); // Metadata only: never auto-download an installer.
      }
    },
  );

  test('old, equal, draft and prerelease releases never prompt', () async {
    for (final kind in ['old', 'equal', 'draft', 'prerelease']) {
      final fixture = UpdateFixture();
      if (kind == 'draft' || kind == 'prerelease') fixture.release[kind] = true;
      if (kind == 'old') fixture.release['tag_name'] = 'v1.0.0';
      if (kind == 'equal') fixture.release['tag_name'] = 'v1.1.0';
      expect(
        await fixture.service().check(
          AppVersion('1.1.0', 2),
          UpdatePlatform.android,
        ),
        isNull,
      );
      expect(fixture.requests.length, 1);
    }
  });

  test('new version with a reused Android build is rejected', () async {
    await expectLater(
      UpdateFixture(
        build: 2,
      ).service().check(AppVersion('1.1.0', 2), UpdatePlatform.android),
      throwsA(isA<UpdateException>()),
    );
  });

  test(
    'untrusted URL, missing digest and duplicate installer are rejected',
    () async {
      for (final kind in ['url', 'digest', 'duplicate']) {
        final fixture = UpdateFixture();
        final assets = fixture.release['assets'] as List;
        final asset = assets[1] as Map;
        if (kind == 'url') {
          asset['browser_download_url'] = 'https://evil.example/file.apk';
        }
        if (kind == 'digest') asset['digest'] = null;
        if (kind == 'duplicate') assets.add(Map<String, dynamic>.from(asset));
        await expectLater(
          fixture.service().check(
            AppVersion('1.1.0', 2),
            UpdatePlatform.android,
          ),
          throwsA(isA<UpdateException>()),
        );
      }
      expect(
        GithubUpdateTransport.allowed(Uri.parse('http://github.com/file')),
        false,
      );
      expect(
        GithubUpdateTransport.allowed(
          Uri.parse('https://github.com.evil.example/file'),
        ),
        false,
      );
      expect(
        GithubUpdateTransport.allowed(
          Uri.parse('https://user@github.com/file'),
        ),
        false,
      );
      expect(
        GithubUpdateTransport.allowed(
          Uri.parse('https://release-assets.githubusercontent.com/file'),
        ),
        true,
      );
    },
  );

  test('tampered metadata fails checksum verification', () async {
    final fixture = UpdateFixture();
    fixture.files[fixture.files.keys.first] = utf8.encode('{}');
    await expectLater(
      fixture.service().check(AppVersion('1.1.0', 2), UpdatePlatform.android),
      throwsA(isA<UpdateException>()),
    );
  });

  test('download streams, verifies and reuses the cached package', () async {
    final fixture = UpdateFixture();
    final service = fixture.service();
    final update = (await service.check(
      AppVersion('1.1.0', 2),
      UpdatePlatform.android,
    ))!;
    final directory = await Directory.systemTemp.createTemp(
      'sylphy-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final progress = <int>[];
    final file = await service.download(
      update,
      directory,
      (received, _) => progress.add(received),
    );
    expect(await file.readAsBytes(), fixture.package);
    expect(progress.last, fixture.package.length);
    final requests = fixture.requests.length;
    await service.download(update, directory, (_, _) {});
    expect(fixture.requests.length, requests);
    expect(await File('${file.path}.part').exists(), false);
  });

  test(
    'truncated, oversized and corrupted downloads never become installers',
    () async {
      for (final chunks in [
        <List<int>>[
          [1],
        ],
        [
          [1, 2, 3],
          List.filled(100, 7),
        ],
        [List.filled(20, 1)],
      ]) {
        final fixture = UpdateFixture()..packageChunks = chunks;
        final service = fixture.service();
        final update = (await service.check(
          AppVersion('1.1.0', 2),
          UpdatePlatform.android,
        ))!;
        final directory = await Directory.systemTemp.createTemp(
          'sylphy-update-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        await expectLater(
          service.download(update, directory, (_, _) {}),
          throwsA(isA<UpdateException>()),
        );
        expect(await directory.list().toList(), isEmpty);
      }
    },
  );

  test('cancelling a download removes its partial file', () async {
    final fixture = UpdateFixture()
      ..packageChunks = [
        [1],
        [2],
        [3],
      ];
    final service = fixture.service();
    final update = (await service.check(
      AppVersion('1.1.0', 2),
      UpdatePlatform.android,
    ))!;
    final directory = await Directory.systemTemp.createTemp(
      'sylphy-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    await expectLater(
      service.download(update, directory, (_, _) => service.cancel()),
      throwsA(isA<UpdateException>()),
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'controller persists opt-out, allows manual checks and never auto-installs',
    () async {
      final fixture = UpdateFixture();
      final directory = await Directory.systemTemp.createTemp(
        'sylphy-update-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final installer = TestUpdateInstaller();
      final controller = AppUpdateController(
        platform: UpdatePlatform.android,
        currentVersion: () async => AppVersion('1.1.0', 2),
        directory: () async => directory,
        releases: fixture.service(),
        installer: installer,
      );
      addTearDown(controller.dispose);
      await controller.setAutomatic(false);
      await controller.check();
      expect(fixture.requests, isEmpty);
      await controller.check(manual: true);
      expect(controller.promptRevision, 1);
      await controller.download();
      expect(controller.stage, UpdateStage.ready);
      expect(installer.calls, 0);
      await controller.downloaded!.writeAsString('tampered');
      await controller.install();
      expect(controller.stage, UpdateStage.error);
      expect(installer.calls, 0);
      await controller.download();
      installer.result = InstallResult.permissionRequired;
      await controller.install();
      expect(controller.permissionRequired, true);
      expect(controller.stage, UpdateStage.ready);
      await controller.skip();
      final restored = AppUpdateController(
        platform: UpdatePlatform.android,
        currentVersion: () async => AppVersion('1.1.0', 2),
        directory: () async => directory,
        releases: fixture.service(),
        installer: installer,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.automatic, false);
      expect(restored.skippedTag, 'v1.2.0');
      await restored.setAutomatic(true);
      await restored.check();
      expect(restored.promptRevision, 0);
      await restored.check(manual: true);
      expect(restored.promptRevision, 1);
    },
  );
}
