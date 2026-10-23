import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/models/open_scroll_target.dart';
import 'package:s1er/models/reading_record.dart';
import 'package:s1er/models/thread_open_intent.dart';
import 'package:s1er/providers/post_provider.dart';
import 'package:s1er/providers/reading_history_provider.dart';
import 'package:s1er/providers/thread_open_intent_provider.dart';
import 'package:s1er/providers/thread_rate_logs_provider.dart';
import 'package:s1er/services/http_client.dart';

void main() {
  group('PostNotifier open intent', () {
    late _ThreadDetailAdapter adapter;
    late ProviderContainer container;

    ProviderContainer buildContainer({
      // ignore: strict_raw_type
      List extraOverrides = const [],
    }) {
      final dio = Dio()..httpClientAdapter = adapter;
      late ProviderContainer c;
      c = ProviderContainer(
        overrides: [
          httpClientProvider.overrideWith(
            (ref) => S1HttpClient.test(c, dio),
          ),
          ...extraOverrides,
        ],
      );
      return c;
    }

    setUp(() {
      adapter = _ThreadDetailAdapter();
    });

    tearDown(() {
      container.dispose();
    });

    test('page mode loads explicit page on first request', () async {
      container = buildContainer(
        extraOverrides: [
          threadOpenIntentProvider('100').overrideWithValue(
            const ThreadOpenIntent.page(5),
          ),
        ],
      );

      final state = await container.read(postProvider('100').future);

      expect(state.currentPage, 5);
      expect(adapter.requestedPages, [5]);
      expect(adapter.requestedPages, isNot(contains(1)));
      expect(state.openScrollTarget, isA<ScrollToPageTop>());
    });

    test('page=1 forces first page over resume record', () async {
      container = buildContainer(
        extraOverrides: [
          threadOpenIntentProvider('100').overrideWithValue(
            const ThreadOpenIntent.page(1),
          ),
          readingRecordProvider('100').overrideWithValue(
            ReadingRecord(
              tid: '100',
              subject: 't',
              author: 'a',
              fid: '4',
              lastReadPage: 4,
              lastReadFloor: 120,
              totalPages: 8,
              totalReplies: 0,
              perPage: 40,
              lastReadAt: 1,
              firstReadAt: 1,
              readCount: 1,
            ),
          ),
        ],
      );

      final state = await container.read(postProvider('100').future);
      expect(state.currentPage, 1);
      expect(adapter.requestedPages, [1]);
      expect(state.openScrollTarget, isA<ScrollToPageTop>());
    });

    test('post mode locates page before loading detail', () async {
      adapter.locatePageForPid['999'] = 187;
      container = buildContainer(
        extraOverrides: [
          threadOpenIntentProvider('100').overrideWithValue(
            const ThreadOpenIntent.post('999'),
          ),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      final state = await container.read(postProvider('100').future);

      expect(state.currentPage, 187);
      expect(adapter.locateRequests, contains('100:999'));
      expect(adapter.requestedPages, [187]);
      expect(adapter.requestedPages, isNot(contains(1)));
      expect(state.openScrollTarget, isA<ScrollToPid>());
      expect((state.openScrollTarget as ScrollToPid).pid, '999');
      expect(state.locateError, isNull);
    });

    test('post mode sets locateError when pid missing on page', () async {
      adapter.locatePageForPid['999'] = 2;
      adapter.omitPidFromPostlist = true;
      container = buildContainer(
        extraOverrides: [
          threadOpenIntentProvider('100').overrideWithValue(
            const ThreadOpenIntent.post('999'),
          ),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      final state = await container.read(postProvider('100').future);
      expect(state.locateError, '未找到目标楼层');
      expect(state.openScrollTarget, isA<ScrollToPageTop>());
    });

    test('reading record resume loads lastReadPage with ScrollToFloor',
        () async {
      container = buildContainer(
        extraOverrides: [
          readingRecordProvider('100').overrideWithValue(
            ReadingRecord(
              tid: '100',
              subject: 't',
              author: 'a',
              fid: '4',
              lastReadPage: 3,
              lastReadFloor: 85,
              totalPages: 8,
              totalReplies: 319,
              perPage: 40,
              lastReadAt: 1,
              firstReadAt: 1,
              readCount: 1,
            ),
          ),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      final state = await container.read(postProvider('100').future);

      expect(state.currentPage, 3);
      expect(adapter.requestedPages, [3]);
      expect(state.openScrollTarget, isA<ScrollToFloor>());
      expect((state.openScrollTarget as ScrollToFloor).absoluteFloor, 85);
    });

    test('B3 finished with new pages opens new page at top', () async {
      container = buildContainer(
        extraOverrides: [
          readingRecordProvider('100').overrideWithValue(
            ReadingRecord(
              tid: '100',
              subject: 't',
              author: 'a',
              fid: '4',
              lastReadPage: 2,
              lastReadFloor: 80,
              totalPages: 2,
              totalReplies: 79,
              perPage: 40,
              lastReadAt: 1,
              firstReadAt: 1,
              readCount: 1,
            ),
          ),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);
      // adapter replies=159 → totalPages = ceil(160/40)=4
      final state = await container.read(postProvider('100').future);

      expect(state.currentPage, 3);
      expect(state.openScrollTarget, isA<ScrollToFloor>());
      expect(
        (state.openScrollTarget as ScrollToFloor).absoluteFloor,
        81,
      );
      expect(adapter.requestedPages, contains(3));
    });

    test('fetches rate logs when commentcount is zero', () async {
      adapter.commentCount = {'1': 0};
      container = buildContainer(
        extraOverrides: [
          readingRecordProvider('100').overrideWithValue(null),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      await container.read(postProvider('100').future);
      await pumpEventQueue();

      expect(adapter.rateLogRequests, isNotEmpty);
    });

    test('fetches rate logs when commentcount is missing', () async {
      container = buildContainer(
        extraOverrides: [
          readingRecordProvider('100').overrideWithValue(null),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      await container.read(postProvider('100').future);
      await pumpEventQueue();

      expect(adapter.rateLogRequests, isNotEmpty);
    });

    test('auto-fetches rate logs on page load when commentcount > 0', () async {
      adapter.commentCount = {'1': 2};
      container = buildContainer(
        extraOverrides: [
          readingRecordProvider('100').overrideWithValue(null),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      await container.read(postProvider('100').future);
      await pumpEventQueue();

      expect(adapter.rateLogRequests, isNotEmpty);
    });

    test('reuses the current page rate log cache', () async {
      container = buildContainer(
        extraOverrides: [
          readingRecordProvider('100').overrideWithValue(null),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      await container.read(postProvider('100').future);
      await pumpEventQueue();
      final requestsAfterLoad = adapter.rateLogRequests.length;

      await container
          .read(threadRateLogsProvider('100').notifier)
          .ensurePageRateLogs(1);

      expect(adapter.rateLogRequests, hasLength(requestsAfterLoad));
    });

    test('rate log merge does not mutate postProvider state', () async {
      adapter.commentCount = {'1': 2};
      adapter.rateLogHtml = '''
<div id="ratelog_1">
  <ul class="post_box cl">
    <li class="flex-box mli p0">
      <div class="flex-2"><a> 参与人数 <span class="xi1">1</span></a></div>
      <div class="flex-2">战斗力 <i><span class="xi1">+2</span></i></div>
      <div class="flex-3">理由</div>
    </li>
    <li class="flex-box mli p0">
      <div class="flex-2"><a href="home.php?mod=space&uid=1">userA</a></div>
      <div class="flex-2 xi1"> + 2</div>
      <div class="flex-3">good</div>
    </li>
  </ul>
</div>
''';
      container = buildContainer(
        extraOverrides: [
          readingRecordProvider('100').overrideWithValue(null),
        ],
      );

      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      final initial = await container.read(postProvider('100').future);
      await pumpEventQueue();
      final postsBefore = initial.posts;

      expect(adapter.rateLogRequests, isNotEmpty);

      final after = container.read(postProvider('100')).asData!.value;
      expect(identical(after.posts, postsBefore), isTrue);
      expect(adapter.rateLogRequests, isNotEmpty);
      expect(
        container.read(threadRateLogsProvider('100')),
        isNotEmpty,
      );
    });
  });

  group('PostNotifier page cache', () {
    late _ThreadDetailAdapter adapter;
    late ProviderContainer container;
    late ProviderSubscription<AsyncValue<PostListState>> subscription;

    PostListState getState() =>
        container.read(postProvider('100')).requireValue;
    PostNotifier getNotifier() => container.read(postProvider('100').notifier);

    setUp(() async {
      adapter = _ThreadDetailAdapter()..replies = 799;
      final dio = Dio()..httpClientAdapter = adapter;
      container = ProviderContainer(
        overrides: [
          httpClientProvider
              .overrideWith((ref) => S1HttpClient.test(container, dio)),
          readingRecordProvider('100').overrideWithValue(null),
        ],
      );
      subscription = container.listen(postProvider('100'), (_, __) {});
      await container.read(postProvider('100').future);
      getNotifier().clearOpenScrollTarget();
    });

    tearDown(() {
      subscription.close();
      container.dispose();
    });

    test('cached page appears before revalidation and receives edited content',
        () async {
      await getNotifier().goToPage(2);
      final gate = adapter.pageGates[1] = Completer<void>();
      adapter.messages[1] = 'edited remote post';
      final notifier = getNotifier();
      await notifier.goToPage(1);
      expect(getState().currentPage, 1);
      expect(getState().posts.single.message, 'body');
      expect(getState().openScrollTarget, isA<ScrollToPageTop>());
      notifier.clearOpenScrollTarget();
      gate.complete();
      await pumpEventQueue();
      expect(adapter.requestedPages, [1, 2, 1]);
      expect(getState().posts.single.message, 'edited remote post');
      expect(getState().openScrollTarget, isNull);
    });

    test('failed revalidation keeps cached content without an error page',
        () async {
      await getNotifier().goToPage(2);
      adapter.failPages.add(1);
      await getNotifier().goToPage(1);
      await pumpEventQueue();
      expect(getState().currentPage, 1);
      expect(getState().posts.single.message, 'body');
      expect(container.read(postProvider('100')).hasError, isFalse);
    });

    test('late revalidation cannot replace a newer page', () async {
      await getNotifier().goToPage(2);
      final gate = adapter.pageGates[1] = Completer<void>();
      await getNotifier().goToPage(1);
      await getNotifier().goToPage(3);
      gate.complete();
      await pumpEventQueue();
      expect(getState().currentPage, 3);
    });

    test('ten pages remain cached; the eleventh keeps both neighboring pairs',
        () async {
      for (final page in [2, 3, 4, 6, 7, 8, 9, 10, 11]) {
        await getNotifier().goToPage(page);
      }
      var gate = adapter.pageGates[1] = Completer<void>();
      await getNotifier().goToPage(1);
      expect(getState().currentPage, 1);
      gate.complete();
      await pumpEventQueue();

      // Page 5 is the eleventh distinct page: keep exactly 3, 4, 5, 6, 7.
      await getNotifier().goToPage(5);
      await pumpEventQueue();
      for (final page in [3, 4, 6, 7]) {
        gate = adapter.pageGates[page] = Completer<void>();
        await getNotifier().goToPage(page);
        expect(getState().currentPage, page);
        gate.complete();
        await pumpEventQueue();
      }
      final rateLogs = container.read(threadRateLogsProvider('100').notifier);
      final rateRequests = adapter.rateLogRequests.length;
      await rateLogs.ensurePageRateLogs(3);
      expect(adapter.rateLogRequests, hasLength(rateRequests));
      await rateLogs.ensurePageRateLogs(2);
      expect(adapter.rateLogRequests, hasLength(rateRequests + 1));
      for (final page in [2, 8]) {
        gate = adapter.pageGates[page] = Completer<void>();
        final before = getState().currentPage;
        final loading = getNotifier().goToPage(page);
        await pumpEventQueue();
        expect(getState().currentPage, before);
        gate.complete();
        await loading;
        expect(getState().currentPage, page);
      }
    });

    test(
        'a newly added pid on a cached page is checked remotely before reporting it missing',
        () async {
      adapter.locatePageForPid['999'] = 1;
      await getNotifier().locatePid('999');
      expect(adapter.requestedPages, [1, 1]);
      expect(getState().locateError, isNull);
      expect((getState().openScrollTarget as ScrollToPid).pid, '999');
    });

    test('an evicted in-flight revalidation cannot repopulate page caches',
        () async {
      for (var page = 2; page <= 10; page++) {
        await getNotifier().goToPage(page);
      }
      final stale = adapter.pageGates[1] = Completer<void>();
      await getNotifier().goToPage(1);
      await pumpEventQueue();
      await getNotifier().goToPage(11);
      await pumpEventQueue();
      final rateRequests = adapter.rateLogRequests.length;
      stale.complete();
      await pumpEventQueue();
      expect(adapter.rateLogRequests, hasLength(rateRequests));
      final gate = adapter.pageGates[1] = Completer<void>();
      final loading = getNotifier().goToPage(1);
      await pumpEventQueue();
      expect(getState().currentPage, 11);
      gate.complete();
      await loading;
      expect(getState().currentPage, 1);
    });

    test(
        'restoreToFloor uses the cached page and preserves the floor during revalidation',
        () async {
      await getNotifier().goToPage(2);
      final gate = adapter.pageGates[1] = Completer<void>();
      expect(
        await getNotifier().restoreToFloor(page: 1, absoluteFloor: 3),
        isTrue,
      );
      expect(getState().currentPage, 1);
      expect((getState().openScrollTarget as ScrollToFloor).absoluteFloor, 3);
      gate.complete();
      await pumpEventQueue();
      expect((getState().openScrollTarget as ScrollToFloor).absoluteFloor, 3);
    });

    test(
        'changing author filter cannot reuse or be overwritten by unfiltered cache',
        () async {
      await getNotifier().goToPage(2);
      final gate = adapter.pageGates[1] = Completer<void>();
      await getNotifier().goToPage(1);
      await pumpEventQueue();
      adapter.pageGates.remove(1);
      await getNotifier().filterByAuthor('7', 'filtered author');
      gate.complete();
      await pumpEventQueue();
      expect(getState().filterAuthorId, '7');
      await getNotifier().clearFilter();
      expect(getState().isFiltering, isFalse);
      expect(adapter.requestedPages.where((page) => page == 1), hasLength(4));
    });

    test(
        'leaving discards page and rate log caches including pending responses',
        () async {
      await getNotifier().goToPage(2);
      await pumpEventQueue();
      final gate = adapter.pageGates[1] = Completer<void>();
      await getNotifier().goToPage(1);
      await pumpEventQueue();
      final oldNotifier = getNotifier();
      subscription.close();
      await container.pump();
      gate.complete();
      await pumpEventQueue();
      adapter.pageGates.remove(1);
      final rateRequests = adapter.rateLogRequests.length;
      subscription = container.listen(postProvider('100'), (_, __) {});
      await container.read(postProvider('100').future);
      await pumpEventQueue();
      expect(getNotifier(), isNot(same(oldNotifier)));
      expect(adapter.rateLogRequests.length, greaterThan(rateRequests));
      final gate2 = adapter.pageGates[2] = Completer<void>();
      final loading = getNotifier().goToPage(2);
      await pumpEventQueue();
      expect(getState().currentPage, 1);
      gate2.complete();
      await loading;
      expect(getState().currentPage, 2);
    });
  });

  group('PostNotifier.restoreToFloor', () {
    late _ThreadDetailAdapter adapter;
    late ProviderContainer container;

    ProviderContainer buildContainer({
      // ignore: strict_raw_type
      List extraOverrides = const [],
    }) {
      final dio = Dio()..httpClientAdapter = adapter;
      late ProviderContainer c;
      c = ProviderContainer(
        overrides: [
          httpClientProvider.overrideWith(
            (ref) => S1HttpClient.test(c, dio),
          ),
          readingRecordProvider('100').overrideWithValue(null),
          ...extraOverrides,
        ],
      );
      return c;
    }

    setUp(() {
      adapter = _ThreadDetailAdapter();
    });

    tearDown(() {
      container.dispose();
    });

    test('same-page restore returns true and sets ScrollToFloor', () async {
      container = buildContainer(
        extraOverrides: [
          threadOpenIntentProvider('100').overrideWithValue(
            const ThreadOpenIntent.page(2),
          ),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      await container.read(postProvider('100').future);
      final ok =
          await container.read(postProvider('100').notifier).restoreToFloor(
                page: 2,
                absoluteFloor: 45,
              );

      expect(ok, isTrue);
      final state = container.read(postProvider('100')).asData!.value;
      expect(state.currentPage, 2);
      expect(state.openScrollTarget, isA<ScrollToFloor>());
      expect((state.openScrollTarget! as ScrollToFloor).absoluteFloor, 45);
      expect(adapter.requestedPages, [2]);
    });

    test('cross-page restore success returns true', () async {
      container = buildContainer(
        extraOverrides: [
          threadOpenIntentProvider('100').overrideWithValue(
            const ThreadOpenIntent.page(2),
          ),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      await container.read(postProvider('100').future);
      final ok =
          await container.read(postProvider('100').notifier).restoreToFloor(
                page: 1,
                absoluteFloor: 3,
              );

      expect(ok, isTrue);
      final state = container.read(postProvider('100')).asData!.value;
      expect(state.currentPage, 1);
      expect(state.openScrollTarget, isA<ScrollToFloor>());
      expect(adapter.requestedPages, [2, 1]);
    });

    test('cross-page restore failure returns false and keeps previous page',
        () async {
      container = buildContainer(
        extraOverrides: [
          threadOpenIntentProvider('100').overrideWithValue(
            const ThreadOpenIntent.page(2),
          ),
        ],
      );
      final sub = container.listen(postProvider('100'), (_, __) {});
      addTearDown(sub.close);

      await container.read(postProvider('100').future);
      adapter.failPages.add(1);

      final ok =
          await container.read(postProvider('100').notifier).restoreToFloor(
                page: 1,
                absoluteFloor: 3,
              );

      expect(ok, isFalse);
      final state = container.read(postProvider('100')).asData!.value;
      expect(state.currentPage, 2);
      expect(container.read(postProvider('100')).hasError, isFalse);
    });
  });
}

class _ThreadDetailAdapter implements HttpClientAdapter {
  final requestedPages = <int>[];
  final locateRequests = <String>[];
  final locatePageForPid = <String, int>{};
  final rateLogRequests = <Uri>[];
  final failPages = <int>{};
  final pageGates = <int, Completer<void>>{};
  final messages = <int, String>{};
  int replies = 159;
  Map<String, int>? commentCount;
  String rateLogHtml = '<html></html>';
  bool omitPidFromPostlist = false;
  String? _lastLocatedPid;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;

    if (uri.queryParameters['goto'] == 'findpost') {
      final ptid = uri.queryParameters['ptid'] ?? '';
      final pid = uri.queryParameters['pid'] ?? '';
      locateRequests.add('$ptid:$pid');
      _lastLocatedPid = pid;
      final page = locatePageForPid[pid] ?? 1;
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [
            'https://stage1st.com/2b/forum.php?mod=viewthread&tid=$ptid&page=$page',
          ],
        },
      );
    }

    if (uri.query.contains('module=viewthread')) {
      final page = int.tryParse(uri.queryParameters['page'] ?? '1') ?? 1;
      requestedPages.add(page);
      await pageGates[page]?.future;
      if (failPages.contains(page)) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: 500),
          message: 'simulated page $page failure',
        );
      }
      final pid = omitPidFromPostlist ? '1' : (_lastLocatedPid ?? '1');
      final variables = <String, dynamic>{
        'ppp': '40',
        'thread': {
          'subject': 'Test Thread',
          'fid': '4',
          'replies': replies.toString(),
          'allowreply': '1',
        },
        'postlist': [
          {
            'pid': pid,
            'author': 'user',
            'authorid': '1',
            'message': messages[page] ?? 'body',
            'dateline': '1700000000',
            'floor': '1',
          },
        ],
      };
      if (commentCount != null) {
        variables['commentcount'] = commentCount;
      }
      return ResponseBody.fromString(
        jsonEncode({
          'Variables': variables,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    if (uri.query.contains('mod=viewthread')) {
      rateLogRequests.add(uri);
      return ResponseBody.fromString(rateLogHtml, 200);
    }

    return ResponseBody.fromString('{}', 200);
  }
}
