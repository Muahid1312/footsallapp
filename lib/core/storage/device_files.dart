import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Android SAF and narrowly scoped FileProvider. No storage/account permissions.
class DeviceFiles {
  static const _channel = MethodChannel('saturday_futsal/files');
  Future<String?> pick(String kind) =>
      _channel.invokeMethod<String>('pick', {'kind': kind});
  Future<bool> save(String source, String name, String mime) async =>
      await _channel.invokeMethod<bool>('save', {
        'path': source,
        'name': name,
        'mime': mime,
      }) ??
      false;
  Future<void> share(String source, String name, String mime) =>
      _channel.invokeMethod<void>('share', {
        'path': source,
        'name': name,
        'mime': mime,
      });
  Future<Uint8List> jpeg(Uint8List png) async {
    final result = await _channel.invokeMethod<Uint8List>('jpeg', {
      'bytes': png,
    });
    if (result == null) {
      throw StateError('The photo could not be prepared.');
    }
    return result;
  }
}
