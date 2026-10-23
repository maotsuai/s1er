import '../../models/pinned_thread.dart';
import '../backup/s1_backup_codec.dart';

/// 同步层的三方合并；不改变手动导入的 v1 语义。
class S1BackupMerge {
  /// 比较同步数据，忽略导出时间、设备等 manifest 元数据和集合存储顺序。
  static bool sameContents(S1BackupPayload a, S1BackupPayload b) {
    a = _normalize(a);
    b = _normalize(b);
    Map<String, Object> rows(List<Map<String, dynamic>> values, String key) => {
          for (final row in values) '${row['uid'] ?? ''}_${row[key]}': row,
        };
    return equal(a.settings, b.settings) &&
        equal(rows(a.readingHistory, 'tid'), rows(b.readingHistory, 'tid')) &&
        equal(rows(a.pollVotes, 'tid'), rows(b.pollVotes, 'tid')) &&
        equal(rows(a.blacklist, 'uid'), rows(b.blacklist, 'uid')) &&
        equal(rows(a.pinnedThreads, 'tid'), rows(b.pinnedThreads, 'tid'));
  }

  static S1BackupPayload merge({
    required S1BackupPayload local,
    required S1BackupPayload remote,
    S1BackupPayload? base,
  }) {
    local = _normalize(local);
    remote = _normalize(remote);
    base = base == null ? null : _normalize(base);
    final settings = <String, dynamic>{};
    for (final key in {...?local.settings?.keys, ...?remote.settings?.keys}) {
      final l = local.settings?[key];
      final r = remote.settings?[key];
      if (l != null && r != null && !_compatible(l, r)) {
        throw S1BackupException('云端设置 $key 类型无效，未修改同步文件');
      }
      final value = _choose(l, r, base?.settings?[key], base != null);
      if (value != null) settings[key] = value;
    }
    final history = _rows(
      local.readingHistory,
      remote.readingHistory,
      base?.readingHistory,
      (row) => '${row['uid']}_${row['tid']}',
      readingHistory: true,
    );
    final blacklist = _rows(
      local.blacklist,
      remote.blacklist,
      base?.blacklist,
      (row) => '${row['uid']}',
    );
    final votes = _rows(
      local.pollVotes,
      remote.pollVotes,
      base?.pollVotes,
      (row) => '${row['uid']}_${row['tid']}',
    );
    List<Map<String, dynamic>> pins(S1BackupPayload? payload) =>
        payload?.pinnedThreads
            .map((row) => PinnedThread.fromJson(row).toJson())
            .toList() ??
        const [];
    final pinned = _rows(
      pins(local),
      pins(remote),
      base == null ? null : pins(base),
      (row) => '${row['tid']}',
    );
    if (pinned.length > 10) {
      throw S1BackupException('合并后置顶帖超过 10 个，请先在设备上减少置顶帖');
    }
    pinned.sort(
      (a, b) => _int(a['displayOrder']).compareTo(_int(b['displayOrder'])),
    );
    for (var i = 0; i < pinned.length; i++) {
      pinned[i] = {...pinned[i], 'displayOrder': i};
    }
    return S1BackupPayload(
      manifest: {
        ...local.manifest,
        'contents': [
          'settings',
          'reading_history',
          'blacklist',
          'poll_votes',
          'pinned_threads',
        ],
        'counts': {
          'reading_history': history.length,
          'blacklist': blacklist.length,
          'poll_votes': votes.length,
          'pinned_threads': pinned.length,
        },
      },
      settings: settings,
      readingHistory: history,
      blacklist: blacklist,
      pollVotes: votes,
      pinnedThreads: pinned,
    );
  }

  static List<Map<String, dynamic>> _rows(
    List<Map<String, dynamic>> local,
    List<Map<String, dynamic>> remote,
    List<Map<String, dynamic>>? base,
    String Function(Map<String, dynamic>) key, {
    bool readingHistory = false,
  }) {
    final l = {for (final row in local) key(row): row};
    final r = {for (final row in remote) key(row): row};
    final b = {
      for (final row in base ?? <Map<String, dynamic>>[]) key(row): row,
    };
    final result = <Map<String, dynamic>>[];
    for (final id in {...l.keys, ...r.keys, ...b.keys}) {
      var chosen =
          _choose(l[id], r[id], b[id], base != null) as Map<String, dynamic>?;
      if (readingHistory && l[id] != null && r[id] != null) {
        // 两端均有此记录时，进度始终跟随最新一次阅读，而非最大楼层。
        chosen = _int(l[id]!['last_read_at']) >= _int(r[id]!['last_read_at'])
            ? l[id]
            : r[id];
      }
      if (chosen != null) result.add(Map<String, dynamic>.from(chosen));
    }
    return result;
  }

  static Object? _choose(
    Object? local,
    Object? remote,
    Object? base,
    bool hasBase,
  ) {
    if (equal(local, remote)) return local;
    if (hasBase) {
      if (equal(local, base)) return remote;
      if (equal(remote, base)) return local;
      // 同一项两端都改动时本机优先（包括主动删除）。
      return local;
    }
    // 首次接入：保留两端独有项，同项以云端为准，便于新设备恢复偏好。
    return remote ?? local;
  }

  static bool _compatible(Object a, Object b) =>
      (a is num && b is num) ||
      (a is bool && b is bool) ||
      (a is String && b is String) ||
      (a is List && b is List) ||
      (a is Map && b is Map);

  static S1BackupPayload _normalize(S1BackupPayload payload) {
    final settings = <String, dynamic>{};
    for (final key in S1BackupSettingsMapper.appToBackup.values) {
      final value = payload.settings?[key];
      if (value == null) continue;
      final valid = switch (key) {
        'theme_mode' ||
        'theme_color' ||
        'app_icon' ||
        'image_load_policy' ||
        'avatar_load_policy' ||
        'thread_list_density' ||
        'post_list_density' ||
        'share_image_format' ||
        'post_signature_custom' =>
          value is String,
        'font_size' ||
        'image_cache_limit_mb' ||
        'max_images_per_post' =>
          value is int && value >= 0,
        'share_pixel_ratio' ||
        'forum_split_list_pane_width' =>
          value is num && value.isFinite && value > 0,
        'collapsed_forums' ||
        'hidden_forums' ||
        'favorite_forum_order' ||
        'hide_sticky_forum_overrides' =>
          value is List && value.every((item) => item is String),
        _ => value is bool,
      };
      if (!valid ||
          (key == 'font_size' && (value == 0 || (value as int) > 96))) {
        throw S1BackupException('云端设置 $key 无效，未修改同步文件');
      }
      settings[key] = value;
    }
    String id(Map<String, dynamic> row, String key) {
      final value = row[key]?.toString() ?? '';
      if (value.isEmpty) throw S1BackupException('同步记录缺少 $key');
      return value;
    }

    const historyNumbers = {
      'last_read_page': ('lastReadPage', 1),
      'last_read_floor': ('lastReadFloor', 1),
      'total_pages': ('totalPages', 1),
      'total_replies': ('totalReplies', 0),
      'per_page': ('perPage', 0),
      'last_read_at': ('lastReadAt', 0),
      'first_read_at': ('firstReadAt', 0),
      'read_count': ('readCount', 1),
    };
    return S1BackupPayload(
      manifest: payload.manifest,
      settings: settings,
      readingHistory: payload.readingHistory
          .map(
            (row) => <String, dynamic>{
              'uid': id(row, 'uid'),
              'tid': id(row, 'tid'),
              for (final key in ['subject', 'author', 'fid'])
                key: row[key]?.toString() ?? '',
              for (final entry in historyNumbers.entries)
                entry.key:
                    int.tryParse('${row[entry.key] ?? row[entry.value.$1]}') ??
                        entry.value.$2,
            },
          )
          .toList(),
      blacklist: payload.blacklist
          .map(
            (row) => <String, dynamic>{
              'uid': id(row, 'uid'),
              'username': row['username']?.toString() ?? '',
              'created_at': _int(row['created_at'] ?? row['createdAt']),
              'reason': row['reason']?.toString() ?? '',
              'scope': row['scope'] is List ? row['scope'] : <String>[],
            },
          )
          .toList(),
      pollVotes: payload.pollVotes
          .map(
            (row) => <String, dynamic>{
              'uid': id(row, 'uid'),
              'tid': id(row, 'tid'),
              'option_ids': (row['option_ids'] ?? row['optionIds']) is List
                  ? ((row['option_ids'] ?? row['optionIds']) as List)
                      .map((e) => e.toString())
                      .toList()
                  : <String>[],
            },
          )
          .toList(),
      pinnedThreads: payload.pinnedThreads.map((row) {
        id(row, 'tid');
        return PinnedThread.fromJson(row).toJson();
      }).toList(),
    );
  }

  static int _int(Object? value) => int.tryParse('$value') ?? 0;

  static bool equal(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && equal(a[key], b[key]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          Iterable<int>.generate(a.length).every((i) => equal(a[i], b[i]));
    }
    return a == b;
  }
}
