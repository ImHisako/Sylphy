import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sylphy/core/identity/identity_service.dart';
import 'package:sylphy/core/native/native_core.dart';
import 'package:sylphy/core/profile/user_profile.dart';

void main() {
  late Directory directory;
  late _Publisher native;
  late IdentityService service;
  final timers = <_ManualTimer>[];
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sylphy-rotation-');
    native = _Publisher();
    timers.clear();
    service = IdentityService(
      nativeCore: null,
      publisher: native.publish,
      now: () => native.now,
      deviceSecretStore: _Secret(),
      applicationSupportDirectory: () async => directory,
      timerFactory: (delay, callback) {
        final timer = _ManualTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
  });
  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'manual change preserves the account and profile privacy and resets the deadline',
    () async {
      await service.initialize(
        profile: const UserProfile(displayName: 'Private'),
        shareDisplayName: false,
        shareProfilePhoto: false,
        rotationIntervalSeconds: 3600,
      );
      final account = service.snapshot.identityId;
      final first = service.snapshot.invitationCode;
      native.now = native.now.add(const Duration(minutes: 15));
      expect(await service.rotateNow(), isTrue);
      expect(service.snapshot.identityId, account);
      expect(service.snapshot.invitationCode, isNot(first));
      expect(
        service.nextRotationAt?.millisecondsSinceEpoch,
        native.now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      expect(native.lastDisplayName, isNull);
      await service.retry();
      expect(native.lastDisplayName, isNull);
      expect(timers.where((timer) => timer.isActive).length, 1);
    },
  );

  test(
    'automatic changes run at the native deadline and stop when disabled',
    () async {
      await service.initialize(rotationIntervalSeconds: 3600);
      final first = service.snapshot.invitationCode;
      expect(timers.last.delay, const Duration(hours: 1));
      native.now = native.now.add(const Duration(hours: 1));
      timers.last.fire();
      await service.initialize(forceRefresh: true);
      expect(service.snapshot.invitationCode, isNot(first));
      final rotated = service.snapshot.invitationCode;
      await service.initialize(rotationIntervalSeconds: 0);
      expect(service.snapshot.invitationCode, rotated);
      expect(service.nextRotationAt, isNull);
      expect(timers.where((timer) => timer.isActive), isEmpty);
      expect(await service.rotateNow(), isTrue);
    },
  );

  test(
    'network failures keep the last ID, report failure and retry without spinning',
    () async {
      await service.initialize(rotationIntervalSeconds: 3600);
      final first = service.snapshot.invitationCode;
      native.fail = true;
      expect(await service.rotateNow(), isFalse);
      expect(service.snapshot.phase, IdentityPhase.ready);
      expect(service.snapshot.invitationCode, first);
      expect(service.rotationError, 'network_startup_failed');
      expect(timers.last.delay, const Duration(seconds: 60));
      native.fail = false;
      native.now = native.now.add(const Duration(hours: 2));
      timers.last.fire();
      await service.initialize(forceRefresh: true);
      expect(service.snapshot.invitationCode, isNot(first));
      expect(service.rotationError, isNull);
    },
  );

  test(
    'locking stops timers and rejects an outstanding manual result',
    () async {
      await service.initialize(rotationIntervalSeconds: 3600);
      final block = Completer<void>();
      native.block = block.future;
      final rotating = service.rotateNow();
      expect(service.rotationInProgress, isTrue);
      expect(await service.rotateNow(), isFalse);
      service.suspendForLock();
      block.complete();
      expect(await rotating, isFalse);
      expect(service.snapshot.phase, IdentityPhase.loading);
      expect(service.canRotate, isFalse);
      expect(timers.where((timer) => timer.isActive), isEmpty);
      service.resumeAfterUnlock();
      await service.initialize(rotationIntervalSeconds: 3600);
      expect(service.snapshot.phase, IdentityPhase.ready);
      expect(timers.where((timer) => timer.isActive).length, 1);
    },
  );

  test(
    'pending revocation retries in manual mode without changing the new ID',
    () async {
      native.revocationPending = true;
      await service.initialize();
      final code = service.snapshot.invitationCode;
      expect(service.revocationPending, isTrue);
      expect(timers.last.delay, const Duration(seconds: 60));
      native.revocationPending = false;
      timers.last.fire();
      await service.initialize(forceRefresh: true);
      expect(service.snapshot.invitationCode, code);
      expect(service.revocationPending, isFalse);
      expect(timers.where((timer) => timer.isActive), isEmpty);
    },
  );
}

class _Secret implements DeviceSecretStore {
  @override
  Future<String> getOrCreate() async => 'test-device-secret';
}

class _ManualTimer implements Timer {
  _ManualTimer(this.delay, this.callback);
  final Duration delay;
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
    if (!isActive) return;
    isActive = false;
    callback();
  }
}

class _Publisher {
  DateTime now = DateTime.utc(2030);
  DateTime? next;
  int sequence = 0;
  bool fail = false;
  bool revocationPending = false;
  String? lastDisplayName;
  Future<void>? block;
  Future<NativeCoreResponse> publish({
    required String storageDirectory,
    required String vaultPassword,
    String? displayName,
    String? avatarBase64,
    int? rotationIntervalSeconds,
    bool rotateInvitation = false,
  }) async {
    await block;
    lastDisplayName = displayName;
    if (fail) {
      return const NativeCoreResponse(
        ok: false,
        code: 'network_startup_failed',
        data: {},
      );
    }
    if (sequence == 0 ||
        rotateInvitation ||
        (next != null && !now.isBefore(next!))) {
      sequence++;
      next = rotationIntervalSeconds != null && rotationIntervalSeconds > 0
          ? now.add(Duration(seconds: rotationIntervalSeconds))
          : null;
    }
    if (rotationIntervalSeconds == 0) next = null;
    return NativeCoreResponse(
      ok: true,
      code: 'ok',
      data: {
        'identity_id': 'STABLE ACCOUNT',
        'invitation_code': 'sylphy:VLD0:share-$sequence',
        'expires_at_ms':
            (next ?? now.add(const Duration(days: 30))).millisecondsSinceEpoch,
        'next_rotation_at_ms': next?.millisecondsSinceEpoch,
        'revocation_pending': revocationPending,
      },
    );
  }
}
