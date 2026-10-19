import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/models/webdav_config.dart';
import 'package:s1er/services/backup/s1_backup_codec.dart';
import 'package:s1er/services/sync/s1_backup_merge.dart';

S1BackupPayload snapshot({
  Map<String, dynamic>? settings,
  List<Map<String, dynamic>> blacklist = const [],
  List<Map<String, dynamic>> pins = const [],
}) =>
    S1BackupPayload(
      manifest: const {
        'contents': ['settings', 'blacklist', 'pinned_threads'],
      },
      settings: settings,
      blacklist: blacklist,
      pinnedThreads: pins,
    );

void main() {
  test('first sync prefers remote conflicts and retains unique rows', () {
    final result = S1BackupMerge.merge(
      local: snapshot(
        settings: {
          'theme_mode': 'light',
        },
        blacklist: [
          {'uid': '1'},
        ],
      ),
      remote: snapshot(
        settings: {
          'theme_mode': 'dark',
        },
        blacklist: [
          {'uid': '2'},
        ],
      ),
    );
    expect(result.settings!['theme_mode'], 'dark');
    expect(result.blacklist.map((row) => row['uid']), ['1', '2']);
  });

  test(
      'three-way merge honors local removals, remote changes and local conflicts',
      () {
    final result = S1BackupMerge.merge(
      base: snapshot(
        settings: {
          'font_size': 14,
        },
        blacklist: [
          {'uid': '1'},
          {'uid': '2'},
        ],
      ),
      local: snapshot(
        settings: {
          'font_size': 18,
        },
        blacklist: [
          {'uid': '2'},
        ],
      ),
      remote: snapshot(
        settings: {
          'font_size': 20,
        },
        blacklist: [
          {'uid': '1'},
          {'uid': '2', 'reason': 'changed'},
        ],
      ),
    );
    expect(result.settings!['font_size'], 18);
    expect(result.blacklist.single['uid'], '2');
    expect(result.blacklist.single['reason'], 'changed');
  });

  test('rejects incompatible cloud settings and too many combined pins', () {
    expect(
      () => S1BackupMerge.merge(
        local: snapshot(settings: {'font_size': 14}),
        remote: snapshot(settings: {'font_size': 'large'}),
      ),
      throwsA(isA<S1BackupException>()),
    );
    expect(
      () => S1BackupMerge.merge(
        local: snapshot(pins: List.generate(6, (i) => {'tid': '$i'})),
        remote: snapshot(pins: List.generate(6, (i) => {'tid': '${i + 6}'})),
      ),
      throwsA(isA<S1BackupException>()),
    );
  });

  test('normalizes encoded directories and rejects unsafe URL forms', () {
    WebDavConfig config(String url) =>
        WebDavConfig(directoryUrl: url, username: 'user', password: 'password');
    expect(
      config('https://dav.example.com/a%20b').fileUri.toString(),
      'https://dav.example.com/a%20b/${WebDavConfig.fileName}',
    );
    for (final url in [
      'ftp://dav.example.com/',
      'https://user:pass@dav.example.com/',
      'https://dav.example.com/?token=secret',
      'not a url',
    ]) {
      expect(() => config(url).fileUri, throwsFormatException);
    }
  });
}
