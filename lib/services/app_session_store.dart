import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/app_session.dart';
import 'talker.dart';

/// 与 Cookie 独立的加密凭据槽；不属于 AppLocalData 的导出范围。
class AppSessionStore {
  AppSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const storageKey = 's1_app_session';
  final FlutterSecureStorage _storage;
  AppSession? _current;
  bool _loaded = false;
  Future<void> _pending = Future.value();

  AppSession? get current => _current;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        talker.warning('App session storage failed (${e.runtimeType})');
      },
    );
    return next;
  }

  Future<AppSession?> load() => _enqueue(() async {
        if (_loaded) return _current;
        final raw = await _storage.read(key: storageKey);
        if (raw != null) {
          try {
            _current = AppSession.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
          } catch (_) {
            // 不记录原始 JSON（其中包含 sid）。
            talker.warning('App session is malformed; discarding credentials');
            await _storage.delete(key: storageKey);
          }
        }
        _loaded = true;
        return _current;
      });

  Future<void> save(AppSession session) => _enqueue(() async {
        await _storage.write(
          key: storageKey,
          value: jsonEncode(session.toJson()),
        );
        _current = session;
        _loaded = true;
      });

  /// 旧请求的过期响应不能删除后来登录的新凭据。
  Future<void> clear({AppSession? expected}) => _enqueue(() async {
        if (expected != null && !identical(expected, _current)) return;
        _current = null;
        _loaded = true;
        await _storage.delete(key: storageKey);
      });
}
