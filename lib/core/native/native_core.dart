import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../diagnostics/app_log.dart';

const _expectedAbiVersion = 11;

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

/// Optional command surface kept outside the base interface so existing test
/// and platform adapters remain source compatible.
extension NativeCoreGroupOperations on NativeCoreApi {
  NativeCoreResponse createGroup({
    required String name,
    required List<String> invitationCodes,
    required bool professional,
    required String description,
  }) {
    final client = this;
    if (client is NativeCoreClient) {
      return client.createGroup(
        name: name,
        invitationCodes: invitationCodes,
        professional: professional,
        description: description,
      );
    }
    throw UnsupportedError('create_group');
  }
}

abstract interface class NativeCoreGroupApi {
  NativeCoreResponse createGroup({
    required String name,
    required List<String> invitationCodes,
    required bool professional,
    required String description,
  });
}

abstract interface class NativeCoreMessagePageApi {
  Future<NativeCoreResponse> listMessagesInBackground(
    String conversationId, {
    bool priority = false,
    int? beforeMs,
    String? beforeId,
  });
}

class NativeCoreClient
    implements NativeCoreApi, NativeCoreGroupApi, NativeCoreMessagePageApi {
  NativeCoreClient._(this._call, this._freeString, this.abiVersion);

  final _DartCall _call;
  final _DartFreeString _freeString;
  final int abiVersion;
  int _pendingBackgroundCalls = 0;
  final Queue<_PendingNativeCall> _urgentCalls = Queue();
  final Queue<_PendingNativeCall> _normalCalls = Queue();
  final List<Completer<void>> _idleWaiters = [];
  Future<_NativeWorker>? _worker;
  Future<_NativeWorker>? _readOnlyWorker;
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

  Future<NativeCoreResponse> statusInBackground() =>
      _callInBackground(const {'command': 'status'}, priority: true);

  @override
  NativeCoreResponse startVeilid(String storageDirectory) =>
      call({'command': 'start_veilid', 'storage_directory': storageDirectory});

  Future<NativeCoreResponse> startVeilidInBackground(
    String storageDirectory, {
    String? messagingStorageDirectory,
  }) => _callInBackground({
    'command': 'start_veilid',
    'storage_directory': storageDirectory,
    if (messagingStorageDirectory != null)
      'messaging_storage_directory': messagingStorageDirectory,
  });

  Future<NativeCoreResponse> veilidStatusInBackground() =>
      _callInBackground(const {'command': 'veilid_status'}, priority: true);

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

  Future<NativeCoreResponse> listConversationsInBackground() =>
      _callInBackground(const {'command': 'list_conversations'});

  @override
  NativeCoreResponse listMessages(String conversationId) {
    return call({
      'command': 'list_messages',
      'conversation_id': conversationId,
      'limit': 120,
    });
  }

  @override
  NativeCoreResponse createGroup({
    required String name,
    required List<String> invitationCodes,
    required bool professional,
    required String description,
  }) {
    return call({
      'command': 'create_group',
      'name': name,
      'invitation_codes': invitationCodes,
      'professional': professional,
      'description': description,
    });
  }

  @override
  Future<NativeCoreResponse> listMessagesInBackground(
    String conversationId, {
    bool priority = false,
    int? beforeMs,
    String? beforeId,
  }) => _callInBackground({
    'command': 'list_messages',
    'conversation_id': conversationId,
    if (beforeMs != null) 'before_ms': beforeMs,
    if (beforeId != null) 'before_id': beforeId,
    'limit': 120,
  }, priority: priority);

  Future<NativeCoreResponse> configurePrivacyInBackground({
    required bool allowUnknownContacts,
    bool sendReadReceipts = false,
  }) => _callInBackground({
    'command': 'configure_privacy',
    'allow_unknown_contacts': allowUnknownContacts,
    'send_read_receipts': sendReadReceipts,
  }, priority: true);

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

  Future<NativeCoreResponse> createGroupInBackground({
    required String name,
    required List<String> invitationCodes,
    required bool professional,
    required String description,
  }) => _callInBackground({
    'command': 'create_group',
    'name': name,
    'invitation_codes': invitationCodes,
    'professional': professional,
    'description': description,
  });

  Future<NativeCoreResponse> groupCommandInBackground(
    Map<String, dynamic> request,
  ) => _callInBackground(Map<String, Object>.from(request));

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

  Future<NativeCoreResponse> exportAccountInBackground({
    required String transferPassword,
    required String displayName,
    String? avatarBase64,
  }) => _callInBackground({
    'command': 'export_account',
    'transfer_password': transferPassword,
    'display_name': displayName,
    if (avatarBase64 != null) 'avatar_base64': avatarBase64,
  });

  Future<NativeCoreResponse> importAccountInBackground({
    required String transferPassword,
    required String backupBase64,
    required String storageDirectory,
    required String vaultPassword,
  }) => _callInBackground({
    'command': 'import_account',
    'transfer_password': transferPassword,
    'backup_base64': backupBase64,
    'storage_directory': storageDirectory,
    'vault_password': vaultPassword,
  });

  Future<NativeCoreResponse> protectLocalDataInBackground({
    required String vaultPassword,
    required String valueBase64,
  }) => _callInBackground({
    'command': 'protect_local_data',
    'vault_password': vaultPassword,
    'value_base64': valueBase64,
  }, priority: true);

  Future<NativeCoreResponse> openLocalDataInBackground({
    required String vaultPassword,
    required String recordBase64,
  }) => _callInBackground({
    'command': 'open_local_data',
    'vault_password': vaultPassword,
    'record_base64': recordBase64,
  }, priority: true);

  Future<NativeCoreResponse> _callInBackground(
    Map<String, Object> request, {
    bool priority = false,
  }) {
    if (request['command'] == 'group_details') {
      return _readGroupDetails(request);
    }
    final pending = _PendingNativeCall(request);
    _pendingBackgroundCalls += 1;
    if (priority || _isUrgentCommand(request['command'])) {
      _urgentCalls.addLast(pending);
    } else {
      _normalCalls.addLast(pending);
    }
    _drainBackgroundCalls();
    return pending.completer.future;
  }

  bool _isUrgentCommand(Object? command) =>
      command == 'send_text' ||
      command == 'send_attachment' ||
      command == 'mark_conversation_read' ||
      command == 'ensure_identity';

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

  Future<NativeCoreResponse> _readGroupDetails(
    Map<String, Object> request,
  ) async {
    _pendingBackgroundCalls++;
    try {
      return await _workerCall(request, readOnly: true);
    } finally {
      _pendingBackgroundCalls--;
      if (_pendingBackgroundCalls == 0) {
        for (final waiter in _idleWaiters) {
          waiter.complete();
        }
        _idleWaiters.clear();
      }
    }
  }

  Future<NativeCoreResponse> _workerCall(
    Map<String, Object> request, {
    bool readOnly = false,
  }) async {
    final worker = await (readOnly
        ? (_readOnlyWorker ??= _spawnWorker())
        : (_worker ??= _spawnWorker()));
    final responsePort = ReceivePort();
    try {
      worker.port.send((responsePort.sendPort, request));
      final command = request['command'];
      final timeout = command == 'export_account' || command == 'import_account'
          ? const Duration(minutes: 2)
          : const Duration(seconds: 30);
      // A timeout cannot cancel a native mutation. Keep its result and its
      // place in the queue until completion, including during account import.
      final operation = responsePort.first;
      final response = readOnly
          ? await operation.timeout(const Duration(seconds: 8))
          : await awaitNativeOperation(
              operation,
              warningAfter: timeout,
              onSlow: () => AppLog.instance.record(
                category: 'native_core',
                action: 'background_call_still_running:$command',
                level: AppLogLevel.warning,
                force: true,
              ),
            );
      if (response is Map) {
        return NativeCoreResponse.fromJson(response.cast<String, dynamic>());
      }
      throw const NativeCoreException('Risposta non valida dal worker nativo.');
    } on Object {
      worker.isolate.kill(priority: Isolate.immediate);
      if (readOnly) {
        _readOnlyWorker = null;
      } else {
        _worker = null;
      }
      rethrow;
    } finally {
      responsePort.close();
    }
  }

  static Future<_NativeWorker> _spawnWorker() async {
    final ready = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(_nativeWorkerMain, ready.sendPort);
      final port = await ready.first.timeout(const Duration(seconds: 10));
      if (port is! SendPort) {
        isolate.kill(priority: Isolate.immediate);
        throw const NativeCoreException('Worker nativo non disponibile.');
      }
      return _NativeWorker(isolate: isolate, port: port);
    } on Object {
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      ready.close();
    }
  }

  @override
  NativeCoreResponse verifyHybridPrimitives() {
    return call(const {'command': 'hybrid_self_test'});
  }

  Future<NativeCoreResponse> verifyHybridPrimitivesInBackground() =>
      _callInBackground(const {'command': 'hybrid_self_test'}, priority: true);

  Future<NativeCoreResponse> verifyDoubleRatchetInBackground() =>
      _callInBackground(const {'command': 'ratchet_self_test'}, priority: true);

  @override
  NativeCoreResponse verifyDoubleRatchet() {
    return call(const {'command': 'ratchet_self_test'});
  }

  NativeCoreResponse call(Map<String, Object> request) {
    final command = request['command'] as String? ?? 'unknown';
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

/// A slow operation remains pending: callers must never infer rollback from
/// elapsed time. Separated from FFI so delayed commits can be regression tested.
Future<T> awaitNativeOperation<T>(
  Future<T> operation, {
  required Duration warningAfter,
  required void Function() onSlow,
}) async {
  final warning = Timer(warningAfter, onSlow);
  try {
    return await operation;
  } finally {
    warning.cancel();
  }
}

class _PendingNativeCall {
  _PendingNativeCall(this.request);

  final Map<String, Object> request;
  final Completer<NativeCoreResponse> completer = Completer();
}

class _NativeWorker {
  const _NativeWorker({required this.isolate, required this.port});

  final Isolate isolate;
  final SendPort port;
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
