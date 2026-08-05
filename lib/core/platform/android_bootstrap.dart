import 'dart:io';

import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';

class AndroidBootstrapResult {
  const AndroidBootstrapResult({required this.ready, required this.code});

  final bool ready;
  final String code;
}

class AndroidBootstrap {
  const AndroidBootstrap();

  static const _channel = MethodChannel('sylphy/platform');

  Future<AndroidBootstrapResult> ensureVeilidInitialized() async {
    if (!Platform.isAndroid) {
      return const AndroidBootstrapResult(ready: true, code: 'not_android');
    }
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'ensureVeilidInitialized',
      );
      final ready = response?['ready'] == true;
      final code = response?['code'] as String? ?? 'invalid_response';
      AppLog.instance.record(
        category: 'android',
        action: 'veilid_platform_bootstrap',
        level: ready ? AppLogLevel.info : AppLogLevel.error,
        result: code,
        force: !ready,
      );
      return AndroidBootstrapResult(ready: ready, code: code);
    } on PlatformException catch (error) {
      AppLog.instance.record(
        category: 'android',
        action: 'veilid_platform_channel_failed',
        level: AppLogLevel.error,
        result: error.code,
        force: true,
      );
      return AndroidBootstrapResult(ready: false, code: error.code);
    } on MissingPluginException {
      AppLog.instance.record(
        category: 'android',
        action: 'veilid_platform_channel_missing',
        level: AppLogLevel.error,
        result: 'missing_plugin',
        force: true,
      );
      return const AndroidBootstrapResult(
        ready: false,
        code: 'platform_channel_missing',
      );
    }
  }
}
