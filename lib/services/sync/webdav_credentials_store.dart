import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../models/webdav_config.dart';

/// 整组连接信息仅进入平台安全存储，永不进入 L1 备份。
class WebDavCredentialsStore {
  WebDavCredentialsStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 's1_webdav_connection';

  Future<WebDavConfig?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    return WebDavConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> write(WebDavConfig config) =>
      _storage.write(key: _key, value: jsonEncode(config.toJson()));

  Future<void> clear() => _storage.delete(key: _key);
}
