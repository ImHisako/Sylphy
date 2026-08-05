import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../diagnostics/app_log.dart';

const _expectedAbiVersion = 5;

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
  bool _backgroundCallInProgress = false;
  Future<void>? _backgroundCall;

  bool get backgroundCallInProgress => _backgroundCallInProgress;

  Future<void> waitUntilAvailable() => _backgroundCall ?? Future.value();

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

  @override
  NativeCoreResponse veilidStatus() => call(const {'command': 'veilid_status'});

  @override
  NativeCoreResponse stopVeilid() => call(const {'command': 'stop_veilid'});

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

  @override
  NativeCoreResponse markConversationRead(String conversationId) {
    return call({
      'command': 'mark_conversation_read',
      'conversation_id': conversationId,
    });
  }

  @override
  NativeCoreResponse deleteConversation(String conversationId) {
    return call({
      'command': 'delete_conversation',
      'conversation_id': conversationId,
    });
  }

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
  }) async {
    await waitUntilAvailable();
    final completer = Completer<void>();
    _backgroundCallInProgress = true;
    _backgroundCall = completer.future;
    final stopwatch = Stopwatch()..start();
    AppLog.instance.record(
      category: 'native_core',
      action: 'background_call_started:ensure_identity',
      verbose: true,
    );
    try {
      final response = await Isolate.run(() {
        final client = NativeCoreClient.tryLoad();
        if (client == null) {
          return const NativeCoreResponse(
            ok: false,
            code: 'feature_unavailable',
            data: {},
          );
        }
        return client.ensureIdentity(
          storageDirectory: storageDirectory,
          vaultPassword: vaultPassword,
          displayName: displayName,
          avatarBase64: avatarBase64,
        );
      });
      AppLog.instance.record(
        category: 'native_core',
        action: 'background_call_completed:ensure_identity',
        level: response.ok ? AppLogLevel.debug : AppLogLevel.error,
        result: '${response.code}.${stopwatch.elapsedMilliseconds}ms',
        verbose: response.ok,
        force: !response.ok,
      );
      return response;
    } on Object catch (error) {
      AppLog.instance.recordError(
        category: 'native_core',
        action: 'background_call_failed:ensure_identity',
        error: error,
      );
      rethrow;
    } finally {
      _backgroundCallInProgress = false;
      _backgroundCall = null;
      completer.complete();
    }
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
    if (_backgroundCallInProgress) {
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
