import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/models/reading_record.dart';
import 'package:s1er/services/backup/s1_backup_codec.dart';
import 'package:s1er/services/backup/s1_backup_service.dart';

import '../helpers/test_local_data.dart';

void main() {
  test('sync metadata and drafts do not dirty the backup; settings do',
      () async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    await local.settings.putAsync('webdav_last_success', '2026-10-22');
    await local.settings.putAsync('webdav_auto_state', {'networkFailures': 2});
    await local.settings.putAsync('reply_draft', 'draft');
    expect(local.hasPendingSyncChanges, isFalse);
    await local.settings.putAsync('fontSize', 18);
    expect(local.hasPendingSyncChanges, isTrue);
    final revision = local.syncRevision;
    local.markSyncCompleted(revision);
    expect(local.hasPendingSyncChanges, isFalse);
    await local.settings.putAsync('fontSize', 18);
    expect(local.hasPendingSyncChanges, isFalse);
    await local.settings.putAsync('fontSize', null);
    expect(local.hasPendingSyncChanges, isTrue); // 删除也需要上传。
  });

  test('reading writes stay pending when made after the synchronized revision',
      () async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    final revision = local.syncRevision;
    local.putReadingRecord(
      '1',
      ReadingRecord(
        tid: '2',
        subject: 'thread',
        author: 'author',
        fid: '1',
        lastReadPage: 1,
        lastReadFloor: 2,
        totalPages: 1,
        totalReplies: 3,
        perPage: 30,
        lastReadAt: 100,
        firstReadAt: 100,
        readCount: 1,
      ),
    );
    local.markSyncCompleted(revision);
    expect(local.hasPendingSyncChanges, isTrue);
    await local.load();
    expect(local.readingHistory['1_2']?['lastReadFloor'], 2);
    await local.flushPendingWrites();
    expect(local.hasPendingSyncChanges, isTrue); // 可跨进程恢复。
    local.markSyncCompleted(local.syncRevision);
    local.deleteReadingRecord('1', '2');
    expect(local.hasPendingSyncChanges, isTrue);
  });

  test('settings written during a reload survive its older database snapshot',
      () async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    await local.settings.putAsync('fontSize', 18);
    final loading = local.settings.load();
    local.settings.put('fontSize', 22);
    await loading;
    expect(local.settings.get<int>('fontSize'), 22);
  });

  test('cloud import does not reschedule itself; manual restore does',
      () async {
    final (db, local) = await openTestLocalData();
    addTearDown(db.close);
    final backup = S1BackupService(local);
    final payload = S1BackupPayload(
      manifest: {
        'contents': ['settings'],
      },
      settings: {'font_size': 18},
    );
    await backup.importPayload(payload, notifySyncChange: false);
    expect(local.hasPendingSyncChanges, isFalse);
    await backup.importPayload(payload);
    expect(local.hasPendingSyncChanges, isTrue);
  });
}
