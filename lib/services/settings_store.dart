import 'dart:async';
import 'dart:convert';

import 'app_database.dart';
import 'talker.dart';

/// In-memory settings with async Drift persistence (sync reads).
class SettingsStore {
  SettingsStore(this._db);

  /// 仅用户写入发出通知，load 不把备份恢复/云端合并误报为本机改动。
  void Function(String key, Object? previous, Object? next)? onChanged;

  final AppDatabase _db;
  final Map<String, Object?> _cache = {};
  Map<String, Object?>? _changesDuringLoad;

  Future<void> load() async {
    final changes = <String, Object?>{};
    _changesDuringLoad = changes;
    try {
      final rows = await _db.select(_db.settingsEntries).get();
      _cache.clear();
      for (final row in rows) {
        try {
          _cache[row.key] = jsonDecode(row.value);
        } on FormatException catch (e, st) {
          talker.handle(
            e,
            st,
            'Decode settings cache failed for key: ${row.key}',
          );
          _cache[row.key] = row.value;
        }
      }
      for (final entry in changes.entries) {
        if (entry.value == null) {
          _cache.remove(entry.key);
        } else {
          _cache[entry.key] = entry.value;
        }
      }
    } finally {
      if (identical(_changesDuringLoad, changes)) _changesDuringLoad = null;
    }
  }

  T? get<T>(String key, {T? defaultValue}) {
    final value = _cache[key];
    if (value == null) return defaultValue;
    return value as T?;
  }

  void put(String key, Object? value) {
    final previous = _cache[key];
    _changesDuringLoad?[key] = value;
    if (value == null) {
      _cache.remove(key);
      unawaited(_db.setSetting(key, null));
      onChanged?.call(key, previous, value);
      return;
    }
    _cache[key] = value;
    unawaited(_db.setSetting(key, value));
    onChanged?.call(key, previous, value);
  }

  /// 用于同步基线等必须确认落盘后才能报告成功的数据。
  Future<void> putAsync(String key, Object? value) async {
    final previous = _cache[key];
    await _db.setSetting(key, value);
    _changesDuringLoad?[key] = value;
    if (value == null) {
      _cache.remove(key);
    } else {
      _cache[key] = value;
    }
    onChanged?.call(key, previous, value);
  }
}
