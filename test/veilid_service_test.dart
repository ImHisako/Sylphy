import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/core/platform/android_bootstrap.dart';
import 'package:sylphy/core/veilid/veilid_service.dart';

void main() {
  testWidgets(
    'background recovery slows down and resumes at the foreground rate',
    (tester) async {
      final core = _FakeNativeCore();
      var attempts = 0;
      final service = VeilidService(
        nativeCore: core,
        ensureAndroidBootstrap: () async {
          attempts++;
          return const AndroidBootstrapResult(ready: false, code: 'not_ready');
        },
      );
      await service.start();
      expect(attempts, 1);
      service.setForeground(false);
      await tester.pump(const Duration(seconds: 59));
      expect(attempts, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(attempts, 2);
      service.setForeground(true);
      await tester.pump();
      expect(
        attempts,
        3,
      ); // Bootstrap retries immediately on foreground resume.
      await tester.pump(const Duration(seconds: 7));
      expect(attempts, 3);
      await tester.pump(const Duration(seconds: 1));
      expect(attempts, 4);
      service.dispose();
    },
  );

  test('maps an attached native response without exposing routing data', () {
    const response = NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {
        'compiled': true,
        'running': true,
        'attachment_state': 'attached_good',
        'public_internet_ready': true,
        'live_peer_count': '7',
        'route_needs_publish': true,
      },
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.attached);
    expect(snapshot.livePeerCount, 7);
    expect(snapshot.routeNeedsPublish, isTrue);
    expect(response.data, isNot(contains('node_id')));
    expect(response.data, isNot(contains('route_blob')));
  });

  test('reports a missing native library truthfully', () {
    final service = VeilidService(nativeCore: null);
    addTearDown(service.dispose);

    expect(service.snapshot.phase, VeilidPhase.unavailable);
    expect(service.snapshot.title, 'Core Veilid non incluso');
  });

  test('starts the node in persistent application support storage', () async {
    final supportDirectory = await Directory.systemTemp.createTemp(
      'sylphy-veilid-test-',
    );
    addTearDown(() => supportDirectory.delete(recursive: true));
    final core = _FakeNativeCore();
    final service = VeilidService(
      nativeCore: core,
      applicationSupportDirectory: () async => supportDirectory,
    );
    addTearDown(service.dispose);

    await service.start();

    expect(service.snapshot.phase, VeilidPhase.attached);
    expect(core.storageDirectory, endsWith('${Platform.pathSeparator}veilid'));
    expect(Directory(core.storageDirectory!).existsSync(), isTrue);
  });

  test(
    'copies legacy messaging vault files without overwriting imports',
    () async {
      final supportDirectory = await Directory.systemTemp.createTemp(
        'sylphy-storage-migration-test-',
      );
      addTearDown(() => supportDirectory.delete(recursive: true));
      final legacyMessaging = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}veilid'
        '${Platform.pathSeparator}messaging',
      );
      final accountMessaging = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}native'
        '${Platform.pathSeparator}messaging',
      );
      await legacyMessaging.create(recursive: true);
      await accountMessaging.create(recursive: true);
      await File(
        '${legacyMessaging.path}${Platform.pathSeparator}contacts-v2.vault',
      ).writeAsString('legacy contacts');
      await File(
        '${legacyMessaging.path}${Platform.pathSeparator}messages-v2.log',
      ).writeAsString('legacy messages');
      await File(
        '${legacyMessaging.path}${Platform.pathSeparator}groups-v1.vault',
      ).writeAsString('legacy groups');
      await File(
        '${accountMessaging.path}${Platform.pathSeparator}contacts-v2.vault',
      ).writeAsString('imported contacts');
      final service = VeilidService(
        nativeCore: _FakeNativeCore(),
        applicationSupportDirectory: () async => supportDirectory,
      );
      addTearDown(service.dispose);

      await service.start();

      expect(
        await File(
          '${accountMessaging.path}${Platform.pathSeparator}contacts-v2.vault',
        ).readAsString(),
        'imported contacts',
      );
      expect(
        await File(
          '${accountMessaging.path}${Platform.pathSeparator}messages-v2.log',
        ).readAsString(),
        'legacy messages',
      );
      expect(
        await File(
          '${accountMessaging.path}${Platform.pathSeparator}groups-v1.vault',
        ).readAsString(),
        'legacy groups',
      );
    },
  );

  test('keeps the native startup error code without sensitive details', () {
    const response = NativeCoreResponse(
      ok: false,
      code: 'feature_unavailable',
      data: {},
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.error);
    expect(snapshot.diagnosticCode, 'feature_unavailable');
    expect(snapshot.detail, contains('retry non può risolvere'));
  });

  test('distinguishes a retryable network startup failure', () {
    const response = NativeCoreResponse(
      ok: false,
      code: 'network_startup_failed',
      data: {},
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.error);
    expect(snapshot.diagnosticCode, 'network_startup_failed');
    expect(snapshot.detail, contains('nuovo tentativo automatico'));
  });

  test('identifies an Android protected-store startup failure', () {
    const response = NativeCoreResponse(
      ok: false,
      code: 'veilid_protected_store_failed',
      data: {},
    );

    final snapshot = VeilidSnapshot.fromResponse(response);

    expect(snapshot.phase, VeilidPhase.error);
    expect(snapshot.detail, contains('Archivio sicuro Android'));
  });

  test(
    'retries Android platform bootstrap without restarting the app',
    () async {
      final supportDirectory = await Directory.systemTemp.createTemp(
        'sylphy-bootstrap-test-',
      );
      addTearDown(() => supportDirectory.delete(recursive: true));
      final core = _FakeNativeCore();
      var bootstrapAttempts = 0;
      final service = VeilidService(
        nativeCore: core,
        applicationSupportDirectory: () async => supportDirectory,
        ensureAndroidBootstrap: () async {
          bootstrapAttempts += 1;
          return AndroidBootstrapResult(
            ready: bootstrapAttempts > 1,
            code: bootstrapAttempts > 1 ? 'ready' : 'jni_initialization_failed',
          );
        },
      );
      addTearDown(service.dispose);

      await service.start();
      expect(service.snapshot.diagnosticCode, 'platform_not_initialized');
      expect(core.storageDirectory, isNull);

      await service.retry();
      expect(service.snapshot.phase, VeilidPhase.attached);
      expect(bootstrapAttempts, 2);
    },
  );
  test(
    'native attachment events coalesce and recover detached nodes before periodic polling',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sylphy-network-events-',
      );
      addTearDown(() => root.delete(recursive: true));
      final core = _EventCore();
      addTearDown(core.events.close);
      final timers = <_EventTimer>[];
      final service = VeilidService(
        nativeCore: core,
        applicationSupportDirectory: () async => root,
        eventTimerFactory: (delay, callback) {
          final timer = _EventTimer(callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(service.dispose);
      await service.start();
      core.statusResponse = const NativeCoreResponse(
        ok: true,
        code: 'ok',
        data: {
          'compiled': true,
          'running': true,
          'attachment_state': 'detached',
        },
      );
      core.events.add(null);
      core.events.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(timers.length, 1);
      timers.single.fire();
      await service.refresh();
      expect(core.starts, 2);
      expect(service.snapshot.isAttached, isTrue);
      expect(core.statusReads, 1);
      await service.stop();
      core.events.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(timers.length, 1);
    },
  );

  test(
    'resuming requests network status immediately and background events stay quiet',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sylphy-network-resume-',
      );
      addTearDown(() => root.delete(recursive: true));
      final core = _EventCore();
      addTearDown(core.events.close);
      final service = VeilidService(
        nativeCore: core,
        applicationSupportDirectory: () async => root,
      );
      addTearDown(service.dispose);
      await service.start();
      service.setForeground(false);
      core.events.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(core.statusReads, 0);
      service.setForeground(true);
      await service.refresh();
      expect(core.statusReads, 1);
    },
  );

  test(
    'stopping during bootstrap prevents a delayed startup from reviving the node',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'sylphy-network-stop-',
      );
      addTearDown(() => root.delete(recursive: true));
      final core = _EventCore();
      addTearDown(core.events.close);
      final bootstrap = Completer<AndroidBootstrapResult>();
      final service = VeilidService(
        nativeCore: core,
        applicationSupportDirectory: () async => root,
        ensureAndroidBootstrap: () => bootstrap.future,
      );
      addTearDown(service.dispose);
      final starting = service.start();
      final stopping = service.stop();
      bootstrap.complete(
        const AndroidBootstrapResult(ready: true, code: 'ready'),
      );
      await Future.wait([starting, stopping]);
      expect(core.starts, 0);
      expect(service.snapshot.phase, VeilidPhase.offline);
    },
  );
}

class _FakeNativeCore implements NativeCoreApi {
  @override
  NativeCoreResponse sendAttachment({
    required String conversationId,
    required String fileName,
    required String bytesBase64,
  }) => throw UnimplementedError();
  String? storageDirectory;

  @override
  NativeCoreResponse ensureIdentity({
    required String storageDirectory,
    required String vaultPassword,
    String? displayName,
    String? avatarBase64,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse addContact({
    required String displayName,
    required String invitationCode,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse sendText({
    required String conversationId,
    required String plaintext,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse markConversationRead(String conversationId) =>
      throw UnimplementedError();

  @override
  NativeCoreResponse deleteConversation(String conversationId) =>
      throw UnimplementedError();

  @override
  NativeCoreResponse setContactVerified({
    required String conversationId,
    required bool verified,
  }) => throw UnimplementedError();

  @override
  NativeCoreResponse startVeilid(String storageDirectory) {
    this.storageDirectory = storageDirectory;
    return _attachedResponse;
  }

  @override
  NativeCoreResponse veilidStatus() => _attachedResponse;

  @override
  NativeCoreResponse stopVeilid() => const NativeCoreResponse(
    ok: true,
    code: 'ok',
    data: {
      'compiled': true,
      'running': false,
      'attachment_state': 'detached',
      'public_internet_ready': false,
      'live_peer_count': '0',
    },
  );

  @override
  NativeCoreResponse listConversations() => throw UnimplementedError();

  @override
  NativeCoreResponse listMessages(String conversationId) =>
      throw UnimplementedError();

  @override
  NativeCoreResponse status() => throw UnimplementedError();

  @override
  NativeCoreResponse verifyDoubleRatchet() => throw UnimplementedError();

  @override
  NativeCoreResponse verifyHybridPrimitives() => throw UnimplementedError();
}

const _attachedResponse = NativeCoreResponse(
  ok: true,
  code: 'ok',
  data: {
    'compiled': true,
    'running': true,
    'attachment_state': 'attached_good',
    'public_internet_ready': true,
    'live_peer_count': '4',
  },
);

class _EventCore extends _FakeNativeCore implements NativeActivityEventsApi {
  final events = StreamController<void>.broadcast();
  int starts = 0;
  int statusReads = 0;
  NativeCoreResponse statusResponse = _attachedResponse;
  @override
  Stream<void> get activityEvents => events.stream;
  @override
  NativeCoreResponse startVeilid(String storageDirectory) {
    starts++;
    return super.startVeilid(storageDirectory);
  }

  @override
  NativeCoreResponse veilidStatus() {
    statusReads++;
    return statusResponse;
  }
}

class _EventTimer implements Timer {
  _EventTimer(this.callback);
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int get tick => isActive ? 0 : 1;
  @override
  void cancel() {
    isActive = false;
  }

  void fire() {
    if (isActive) {
      isActive = false;
      callback();
    }
  }
}
