import 'package:flutter/services.dart';

/// Wraps all MethodChannel('process_text') calls.
class ProcessTextChannelService {
  static const _channel = MethodChannel('process_text');

  Future<Map<String, dynamic>?> getProcessTextData() async {
    return _channel.invokeMapMethod<String, dynamic>('getProcessTextData');
  }

  Future<List<Map<String, dynamic>>> getPrompts() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('getPrompts') ?? [];
    return raw
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  Future<String?> generate({
    required String text,
    required String command,
    String? arg,
    String? context,
  }) async {
    return _channel.invokeMethod<String>('generate', {
      'text': text,
      'command': command,
      if (arg != null) 'arg': arg,
      if (context != null && context.isNotEmpty) 'context': context,
    });
  }

  void finishWithResult(String text) {
    _channel.invokeMethod('finishWithResult', {'text': text});
  }

  void dismiss() {
    _channel.invokeMethod('dismiss');
  }
}
