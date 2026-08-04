import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _expectedAbiVersion = 3;

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

  NativeCoreResponse verifyHybridPrimitives();

  NativeCoreResponse verifyDoubleRatchet();
}

class NativeCoreClient implements NativeCoreApi {
  NativeCoreClient._(this._call, this._freeString, this.abiVersion);

  final _DartCall _call;
  final _DartFreeString _freeString;
  final int abiVersion;

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
        return null;
      }
      return NativeCoreClient._(
        library.lookupFunction<_NativeCall, _DartCall>('sylphy_core_call'),
        library.lookupFunction<_NativeFreeString, _DartFreeString>(
          'sylphy_core_free_string',
        ),
        abiVersion,
      );
    } on ArgumentError {
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
  NativeCoreResponse verifyHybridPrimitives() {
    return call(const {'command': 'hybrid_self_test'});
  }

  @override
  NativeCoreResponse verifyDoubleRatchet() {
    return call(const {'command': 'ratchet_self_test'});
  }

  NativeCoreResponse call(Map<String, Object> request) {
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
      return NativeCoreResponse.fromJson(decoded);
    } on FormatException {
      throw const NativeCoreException(
        'Risposta JSON non valida dal core nativo.',
      );
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
