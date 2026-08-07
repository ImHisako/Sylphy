import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../diagnostics/app_log.dart';

const _expectedAbiVersion = 7;

typedef _NativeAbiVersion = Uint32 Function();
typedef _DartAbiVersion = int Function();
typedef _NativeCall = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _DartCall = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _NativeFreeString = Void Function(Pointer<Utf8> value);
typedef _DartFreeString = void Function(Pointer<Utf8> value);

abstract interface class NativeCoreApi {
  NativeCoreResponse status();

  NativeCoreResponse startVeilid(String storageDirectory);

  NativeCoreResponse veilidStatus();

  NativeCoreResponse stopVeilid();

  NativeCoreResponse listConversations();

  NativeCoreResponse listMessages(String conversationId);

  NativeCoreResponse addContact({
    required String displayName,
    required String invitationCode,
  });

  NativeCoreResponse sendText({
    required String conversationId,
    required String plaintext,
  });

  NativeCoreResponse sendAttachment({
    required String conversationId,
    required String fileName,
    required String bytesBase64,
  });

  NativeCoreResponse markConversationRead(String conversationId);

  NativeCoreResponse deleteConversation(String conversationId);

  NativeCoreResponse setContactVerified({
    required String conversationId,
    required bool verified,
  });

  NativeCoreResponse ensureIdentity({
    required String storageDirectory,
    required String vaultPassword,
    String? displayName,
    String? avatarBase64,
  });

  NativeCoreResponse verifyHybridPrimitives();

  NativeCoreResponse verifyDoubleRatchet();
}

class NativeCoreClient implements NativeCoreApi {
  NativeCoreClient._(this._call, this._freeString, this.abiVersion);

  final _DartCall _call;
  final _DartFreeString _freeString;
  final int abiVersion;
  int _pendingBackgroundCalls = 0;
  final Queue<_PendingNativeCall> _urgentCalls = Queue();
  final Queue<_PendingNativeCall> _normalCalls = Queue();
  final List<Completer<void>> _idleWaiters = [];
  Future<SendPort>? _workerPort;
  bool _workerBusy = false;

  bool get backgroundCallInProgress => _pendingBackgroundCalls > 0;

  Future<void> waitUntilAvailable() {
    if (!backgroundCallInProgress) return Future.value();
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    return completer.future;
  }

  static NativeCoreClient? tryLoad() {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isAndroid) {
      return null;
    }
    try {
      final library = DynamicLibrary.open(
        Platform.isWindows ? 'sylphy_core.dll' : 'libsylphy_core.so',
      );
      final abiVersion = library
          .lookupFunction<_NativeAbiVersion, _DartAbiVersion>(
            'sylphy_core_abi_version',
          )();
      if (abiVersion != _expectedAbiVersion) {
        AppLog.instance.record(
          category: 'native_core',
          action: 'abi_mismatch',
          level: AppLogLevel.error,
          result: 'expected_$_expectedAbiVersion.actual_$abiVersion',
          force: true,
        );
        return null;
      }
      return NativeCoreClient._(
        library.lookupFunction<_NativeCall, _DartCall>('sylphy_core_call'),
        library.lookupFunction<_NativeFreeString, _DartFreeString>(
          'sylphy_core_free_string',
        ),
        abiVersion,
      );
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'native_core',
        action: 'dynamic_library_load_failed',
        error: error,
      );
      return null;
    }
  }

  @override
  NativeCoreResponse status() => call(const {'command': 'status'});

  @override
  NativeCoreResponse startVeilid(String storageDirectory) =>
      call({'command': 'start_veilid', 'storage_directory': storageDirectory});

  Future<NativeCoreResponse> startVeilidInBackground(String storageDirectory) =>
      _callInBackground({
        'command': 'start_veilid',
        'storage_directory': storageDirectory,
      });

  @override
  NativeCoreResponse veilidStatus() => call(const {'command': 'veilid_status'});

  @override
  NativeCoreResponse stopVeilid() => call(const {'command': 'stop_veilid'});

  Future<NativeCoreResponse> stopVeilidInBackground() =>
      _callInBackground(const {'command': 'stop_veilid'});

  @override
  NativeCoreResponse listConversations() {
    return call(const {'command': 'list_conversations'});
  }

  @override
  NativeCoreResponse listMessages(String conversationId) {
    return call({
      'command': 'list_messages',
      'conversation_id': conversationId,
    });
  }

  Future<NativeCoreResponse> syncInboundInBackground() =>
      _callInBackground(const {'command': 'sync_inbound'});

  @override
  NativeCoreResponse addContact({
    required String displayName,
    required String invitationCode,
  }) {
    return call({
      'command': 'add_contact',
      'display_name': displayName,
      'invitation_code': invitationCode,
    });
  }

  Future<NativeCoreResponse> addContactInBackground({
    required String displayName,
    required String invitationCode,
  }) => _callInBackground({
    'command': 'add_contact',
    'display_name': displayName,
    'invitation_code': invitationCode,
  });

  @override
  NativeCoreResponse sendText({
    required String conversationId,
    required String plaintext,
  }) {
    return call({
      'command': 'send_text',
      'conversation_id': conversationId,
      'plaintext': plaintext,
    });
  }

  Future<NativeCoreResponse> sendTextInBackground({
    required String conversationId,
    required String plaintext,
  }) => _callInBackground({
    'command': 'send_text',
    'conversation_id': conversationId,
    'plaintext': plaintext,
  });

  @override
  NativeCoreResponse sendAttachment({
    required String conversationId,
    required String fileName,
    required String bytesBase64,
  }) {
    return call({
      'command': 'send_attachment',
      'conversation_id': conversationId,
      'file_name': fileName,
      'bytes_base64': bytesBase64,
    });
  }

  Future<NativeCoreResponse> sendAttachmentInBackground({
    required String conversationId,
    required String fileName,
    required String bytesBase64,
  }) => _callInBackground({
    'command': 'send_attachment',
    'conversation_id': conversationId,
    'file_name': fileName,
    'bytes_base64': bytesBase64,
  });

  @override
  NativeCoreResponse markConversationRead(String conversationId) {
    return call({
      'command': 'mark_conversation_read',
      'conversation_id': conversationId,
    });
  }

  Future<NativeCoreResponse> markConversationReadInBackground(
    String conversationId,
  ) => _callInBackground({
    'command': 'mark_conversation_read',
    'conversation_id': conversationId,
  });

  @override
  NativeCoreResponse deleteConversation(String conversationId) {
    return call({
      'command': 'delete_conversation',
      'conversation_id': conversationId,
    });
  }

  Future<NativeCoreResponse> deleteConversationInBackground(
    String conversationId,
  ) => _callInBackground({
    'command': 'delete_conversation',
    'conversation_id': conversationId,
  });

  @override
  NativeCoreResponse setContactVerified({
    required String conversationId,
    required bool verified,
  }) {
    return call({
      'command': 'set_contact_verified',
      'conversation_id': conversationId,
      'verified': verified,
    });
  }

  Future<NativeCoreResponse> setContactVerifiedInBackground({
    required String conversationId,
    required bool verified,
  }) => _callInBackground({
    'command': 'set_contact_verified',
    'conversation_id': conversationId,
    'verified': verified,
  });

  @override
  NativeCoreResponse ensureIdentity({
    required String storageDirectory,
    required String vaultPassword,
    String? displayName,
    String? avatarBase64,
  }) {
    return call({
      'command': 'ensure_identity',
      'storage_directory': storageDirectory,
      'vault_password': vaultPassword,
      if (displayName != null) 'display_name': displayName,
      if (avatarBase64 != null) 'avatar_base64': avatarBase64,
    });
  }

  Future<NativeCoreResponse> ensureIdentityInBackground({
    required String storageDirectory,
    required String vaultPassword,
    String? displayName,
    String? avatarBase64,
  }) => _callInBackground({
    'command': 'ensure_identity',
    'storage_directory': storageDirectory,
    'vault_password': vaultPassword,
    if (displayName != null) 'display_name': displayName,
    if (avatarBase64 != null) 'avatar_base64': avatarBase64,
  });

  Future<NativeCoreResponse> _callInBackground(Map<String, Object> request) {
    final pending = _PendingNativeCall(request);
    _pendingBackgroundCalls += 1;
    if (_isUrgentCommand(request['command'])) {
      _urgentCalls.addLast(pending);
    } else {
      _normalCalls.addLast(pending);
    }
    _drainBackgroundCalls();
    return pending.completer.future;
  }

  bool _isUrgentCommand(Object? command) =>
      command == 'send_text' || command == 'send_attachment';

  void _drainBackgroundCalls() {
    if (_workerBusy) return;
    final pending = _urgentCalls.isNotEmpty
        ? _urgentCalls.removeFirst()
        : _normalCalls.isNotEmpty
        ? _normalCalls.removeFirst()
        : null;
    if (pending == null) return;
    _workerBusy = true;
    unawaited(_executeBackgroundCall(pending));
  }

  Future<void> _executeBackgroundCall(_PendingNativeCall pending) async {
    final request = pending.request;
    final command = request['command'] as String? ?? 'unknown';
    final stopwatch = Stopwatch()..start();
    AppLog.instance.record(
      category: 'native_core',
      action: 'background_call_started:$command',
      verbose: true,
    );
    try {
      final response = await _workerCall(request);
      AppLog.instance.record(
        category: 'native_core',
        action: 'background_call_completed:$command',
        level: response.ok ? AppLogLevel.debug : AppLogLevel.error,
        result: '${response.code}.${stopwatch.elapsedMilliseconds}ms',
        verbose: response.ok,
        force: !response.ok,
      );
      pending.completer.complete(response);
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'native_core',
        action: 'background_call_failed:$command',
        error: error,
      );
      pending.completer.completeError(error);
    } finally {
      _pendingBackgroundCalls -= 1;
      _workerBusy = false;
      if (_pendingBackgroundCalls == 0) {
        for (final waiter in _idleWaiters) {
          waiter.complete();
        }
        _idleWaiters.clear();
      }
      _drainBackgroundCalls();
    }
  }

  Future<NativeCoreResponse> _workerCall(Map<String, Object> request) async {
    final worker = await (_workerPort ??= _spawnWorker());
    final responsePort = ReceivePort();
    try {
      worker.send((responsePort.sendPort, request));
      final response = await responsePort.first;
      if (response is Map) {
        return NativeCoreResponse.fromJson(response.cast<String, dynamic>());
      }
      throw const NativeCoreException('Risposta non valida dal worker nativo.');
    } finally {
      responsePort.close();
    }
  }

  static Future<SendPort> _spawnWorker() async {
    final ready = ReceivePort();
    await Isolate.spawn(_nativeWorkerMain, ready.sendPort);
    final port = await ready.first;
    ready.close();
    if (port is! SendPort) {
      throw const NativeCoreException('Worker nativo non disponibile.');
    }
    return port;
  }

  @override
  NativeCoreResponse verifyHybridPrimitives() {
    return call(const {'command': 'hybrid_self_test'});
  }

  @override
  NativeCoreResponse verifyDoubleRatchet() {
    return call(const {'command': 'ratchet_self_test'});
  }

  NativeCoreResponse call(Map<String, Object> request) {
    final command = request['command'] as String? ?? 'unknown';
    if (backgroundCallInProgress) {
      return const NativeCoreResponse(
        ok: false,
        code: 'native_core_busy',
        data: {},
      );
    }
    final stopwatch = Stopwatch()..start();
    AppLog.instance.record(
      category: 'native_core',
      action: 'call_started:$command',
      verbose: true,
    );
    final requestPointer = jsonEncode(request).toNativeUtf8();
    Pointer<Utf8>? responsePointer;
    try {
      responsePointer = _call(requestPointer);
      if (responsePointer == nullptr) {
        throw const NativeCoreException(
          'Il core nativo non ha restituito risposta.',
        );
      }
      final decoded = jsonDecode(responsePointer.toDartString());
      if (decoded is! Map<String, dynamic>) {
        throw const NativeCoreException('Risposta non valida dal core nativo.');
      }
      final response = NativeCoreResponse.fromJson(decoded);
      AppLog.instance.record(
        category: 'native_core',
        action: 'call_completed:$command',
        level: response.ok ? AppLogLevel.debug : AppLogLevel.error,
        result: '${response.code}.${stopwatch.elapsedMilliseconds}ms',
        verbose: response.ok,
        force: !response.ok,
      );
      return response;
    } on FormatException catch (error) {
      AppLog.instance.recordError(
        category: 'native_core',
        action: 'invalid_json_response:$command',
        error: error,
      );
      throw const NativeCoreException(
        'Risposta JSON non valida dal core nativo.',
      );
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'native_core',
        action: 'call_failed:$command',
        error: error,
      );
      rethrow;
    } finally {
      calloc.free(requestPointer);
      if (responsePointer != null && responsePointer != nullptr) {
        _freeString(responsePointer);
      }
    }
  }
}

class _PendingNativeCall {
  _PendingNativeCall(this.request);

  final Map<String, Object> request;
  final Completer<NativeCoreResponse> completer = Completer();
}

@pragma('vm:entry-point')
void _nativeWorkerMain(SendPort readyPort) {
  final requests = ReceivePort();
  final client = NativeCoreClient.tryLoad();
  readyPort.send(requests.sendPort);
  requests.listen((message) {
    if (message is! (SendPort, Map<String, Object>)) return;
    final (replyPort, request) = message;
    try {
      final response = client?.call(request);
      replyPort.send({
        'ok': response?.ok ?? false,
        'code': response?.code ?? 'feature_unavailable',
        'data': response?.data ?? const <String, dynamic>{},
      });
    } on Object {
      replyPort.send(const {
        'ok': false,
        'code': 'native_call_failed',
        'data': <String, dynamic>{},
      });
    }
  });
}

class NativeCoreResponse {
  const NativeCoreResponse({
    required this.ok,
    required this.code,
    required this.data,
  });

  factory NativeCoreResponse.fromJson(Map<String, dynamic> json) {
    final ok = json['ok'];
    final code = json['code'];
    final data = json['data'];
    if (ok is! bool || code is! String) {
      throw const NativeCoreException(
        'Schema della risposta nativa non valido.',
      );
    }
    return NativeCoreResponse(
      ok: ok,
      code: code,
      data: data is Map<String, dynamic> ? data : const {},
    );
  }

  final bool ok;
  final String code;
  final Map<String, dynamic> data;
}

class NativeCoreException implements Exception {
  const NativeCoreException(this.message);

  final String message;

  @override
  String toString() => message;
}
