import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/config/api_config.dart';
import 'package:s1er/models/app_session.dart';
import 'package:s1er/services/api_service.dart';
import 'package:s1er/services/app_session_store.dart';
import 'package:s1er/services/auth_service.dart';
import 'package:s1er/services/discuz_parser.dart';
import 'package:s1er/services/http_client.dart';

const _session =
    AppSession(uid: '42', username: 'alice', sid: 'test-app-token');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Adapter adapter;
  late S1HttpClient client;
  late _CookieStorage cookieStorage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    container = ProviderContainer();
    adapter = _Adapter();
    cookieStorage = _CookieStorage();
    final jar = PersistCookieJar(storage: cookieStorage);
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(CookieManager(jar));
    client = S1HttpClient.test(container, dio, cookieJar: jar);
  });
  tearDown(() async {
    await client.dispose();
    container.dispose();
  });

  test('one submission persists both sessions and forwards security question',
      () async {
    final auth = AuthService(httpClient: client);
    expect(
      await auth.login('alice', 'secret', questionId: 3, answer: '上海'),
      isNull,
    );
    expect(auth.isLoggedIn, isTrue);
    expect(auth.currentUser?.uid, '42');
    final app = adapter.posts['/2b/api/app/user/login']!.single;
    final mobile = adapter.posts['/2b/api/mobile/index.php']!.single;
    for (final fields in [app, mobile]) {
      expect(fields['username'], 'alice');
      expect(fields['password'], 'secret');
      expect(fields['questionid'], '3');
      expect(fields['answer'], '上海');
    }
    expect(mobile['cookietime'], '2592000');
    final restored = await AppSessionStore().load();
    expect(restored?.sid, _session.sid);
    final restoredCookies = await PersistCookieJar(storage: cookieStorage)
        .loadForRequest(Uri.parse(ApiConfig.baseUrl));
    expect(restoredCookies.any((c) => c.name.endsWith('_auth')), isTrue);
    final stored = await const FlutterSecureStorage().readAll();
    expect(jsonEncode(stored), isNot(contains('secret')));
    expect(jsonEncode(stored), isNot(contains('上海')));
  });

  test('app login failure is shown and does not retry credentials', () async {
    adapter.appLoginCode = 500;
    final auth = AuthService(httpClient: client);
    expect(await auth.login('alice', 'wrong'), '用户名或密码错误');
    expect(auth.isLoggedIn, isFalse);
    expect(adapter.posts['/2b/api/app/user/login'], hasLength(1));
    expect(adapter.posts['/2b/api/mobile/index.php'], isNull);
    expect(await AppSessionStore().load(), isNull);
  });

  test('mobile login failure rolls back both persistent sessions', () async {
    adapter.mobileLoginSucceeds = false;
    final auth = AuthService(httpClient: client);
    expect(await auth.login('alice', 'secret'), contains('备用登录失败'));
    expect(auth.isLoggedIn, isFalse);
    expect(client.appSessions.current, isNull);
    expect(await AppSessionStore().load(), isNull);
    expect(
      await client.cookieJar.loadForRequest(Uri.parse(ApiConfig.baseUrl)),
      isEmpty,
    );
  });

  test('different accounts from app and mobile are rejected', () async {
    adapter.mobileUid = '99';
    expect(
      await AuthService(httpClient: client).login('alice', 'secret'),
      contains('账号不一致'),
    );
    expect(client.appSessions.current, isNull);
    expect(
      await client.cookieJar.loadForRequest(Uri.parse(ApiConfig.baseUrl)),
      isEmpty,
    );
  });

  test('empty security question answer is sent to both endpoints', () async {
    expect(
      await AuthService(httpClient: client)
          .login('alice', 'secret', answer: 'ignored'),
      isNull,
    );
    for (final values in adapter.posts.values) {
      for (final fields in values) {
        expect(fields['questionid'], '0');
        expect(fields['answer'], '');
      }
    }
  });

  test('restart restores app identity and logout clears both credentials',
      () async {
    await client.appSessions.save(_session);
    await client.cookieJar.saveFromResponse(
      Uri.parse(ApiConfig.baseUrl),
      [Cookie('test_auth', 'cookie')],
    );
    final restored = AppSessionStore();
    final restoredClient = S1HttpClient.test(
      container,
      client.dio,
      appSessions: restored,
      cookieJar: client.cookieJar,
    );
    final auth = AuthService(httpClient: restoredClient);
    expect(await auth.checkSession(), isTrue);
    expect(auth.currentUser?.uid, '42');
    await auth.logout();
    expect(auth.isLoggedIn, isFalse);
    expect(auth.currentUser, isNull);
    expect(await AppSessionStore().load(), isNull);
    expect(
      await client.cookieJar.loadForRequest(Uri.parse(ApiConfig.baseUrl)),
      isEmpty,
    );
    await restoredClient.dispose();
  });

  test('cookie-only installation remains logged in', () async {
    final auth = AuthService(httpClient: client);
    expect(await auth.checkSession(), isTrue);
    expect(auth.currentUser?.uid, '42');
    expect(client.appSessions.current, isNull);
  });

  test('logout during login cancels late credentials', () async {
    adapter.loginGate = Completer<void>();
    final auth = AuthService(httpClient: client);
    final pending = auth.login('alice', 'secret');
    await adapter.loginStarted.future;
    expect(await auth.login('alice', 'secret'), contains('正在登录'));
    await auth.logout();
    adapter.loginGate!.complete();
    expect(await pending, '登录已取消');
    expect(auth.isLoggedIn, isFalse);
    expect(await AppSessionStore().load(), isNull);
    expect(adapter.posts['/2b/api/mobile/index.php'], isNull);
  });

  test('secure persistence failure rolls back cookie login', () async {
    final failingClient = S1HttpClient.test(
      container,
      client.dio,
      cookieJar: client.cookieJar,
      appSessions: _FailingSessionStore(),
    );
    final auth = AuthService(httpClient: failingClient);
    expect(await auth.login('alice', 'secret'), isNotNull);
    expect(auth.isLoggedIn, isFalse);
    expect(
      await client.cookieJar.loadForRequest(Uri.parse(ApiConfig.baseUrl)),
      isEmpty,
    );
    expect(await AppSessionStore().load(), isNull);
    await failingClient.dispose();
  });

  test('missing app session uses mobile directly', () async {
    await ApiService(client).getThreadDetail('123');
    expect(adapter.posts, isEmpty);
    expect(adapter.mobileReadCount, 1);
  });

  test('metadata failure falls back once', () async {
    await client.appSessions.save(_session);
    adapter.threadCode = 503;
    await ApiService(client).getThreadDetail('123');
    expect(adapter.mobileReadCount, 1);
    expect(client.appSessions.current, isNull);
  });

  test('unavailable poll form keeps app posts without retrying mobile',
      () async {
    await client.appSessions.save(_session);
    adapter.threadSpecial = 1;
    adapter.mobileBlocked = true;
    final result = await ApiService(client).getThreadDetail('123');
    expect(DiscuzParser.parsePostList(result).single.message, '<p>app 正文</p>');
    expect(adapter.mobileReadCount, 1);
    expect(client.appSessions.current, same(_session));
  });

  test('app page count includes the first post exactly once', () {
    for (final count in [1, 40, 41, 80]) {
      final result = DiscuzParser.adaptAppThreadPage(
        pageData: {
          'pageNo': 1,
          'pageSize': 40,
          'totalCount': count,
          'list': [
            {'pid': 1, 'position': 1, 'message': '<b>首楼</b>'},
          ],
        },
        thread: {'tid': 123, 'fid': 151, 'subject': 'test'},
        tid: '123',
        page: 1,
        uid: '42',
      );
      final replies = DiscuzParser.parseThreadReplies(result)!;
      expect(((replies + 1) / 40).ceil(), (count / 40).ceil());
      expect(DiscuzParser.parsePostList(result).single.isFirst, isTrue);
    }
  });

  test('ordinary reads prefer app and normalize HTML, floors and counts',
      () async {
    await client.appSessions.save(_session);
    final result = await ApiService(client).getThreadDetail('123', page: 2);
    expect(adapter.mobileReadCount, 0);
    expect(
      adapter.posts['/2b/api/app/thread/page']!.single,
      {'sid': _session.sid, 'tid': '123', 'pageNo': '2'},
    );
    final vars = result['Variables'];
    expect(vars['ppp'], 40);
    expect(vars['thread']['replies'], 79); // 80 / 40 == 2, not 3.
    final post = DiscuzParser.parsePostList(result).single;
    expect(post.floor, 41);
    expect(post.dateline, 1700000000);
    expect(post.message, '<p>app 正文</p>');
    expect(post.avatar, 'https://example.com/avatar.jpg');
  });

  test('temporary app failure falls back once and next request tries app again',
      () async {
    await client.appSessions.save(_session);
    adapter.failNextPage = true;
    final api = ApiService(client);
    final first = await api.getThreadDetail('123', page: 2);
    expect(DiscuzParser.parsePostList(first).single.message, 'mobile 正文');
    expect(adapter.mobileReadCount, 1);
    expect(client.appSessions.current, same(_session));
    final second = await api.getThreadDetail('123', page: 2);
    expect(DiscuzParser.parsePostList(second).single.message, '<p>app 正文</p>');
    expect(adapter.mobileReadCount, 1);
  });

  for (final code in [500, 501, 503]) {
    test('app business code $code falls back with correct token lifetime',
        () async {
      await client.appSessions.save(_session);
      adapter.pageCode = code;
      await ApiService(client).getThreadDetail('123', page: 2);
      expect(adapter.mobileReadCount, 1);
      expect(client.appSessions.current == null, code == 501 || code == 503);
      expect(
        (await AppSessionStore().load()) == null,
        code == 501 || code == 503,
      );
    });
  }

  test('invalid JSON, empty data and invalid pagination fall back', () async {
    await client.appSessions.save(_session);
    for (final response in [
      '<br>Warning {bad} no json',
      jsonEncode(_ok({'list': []})),
      jsonEncode(
        _ok({'pageNo': 2, 'pageSize': 0, 'totalCount': 80, 'list': []}),
      ),
    ]) {
      adapter.pageBody = response;
      final before = adapter.mobileReadCount;
      await ApiService(client).getThreadDetail('123', page: 2);
      expect(adapter.mobileReadCount, before + 1);
      expect(client.appSessions.current, same(_session));
    }
  });

  test('only-author requests retain mobile filtering', () async {
    await client.appSessions.save(_session);
    await ApiService(client).getThreadDetail('123', page: 2, authorId: '42');
    expect(adapter.posts, isEmpty);
    expect(adapter.lastMobileUri?.queryParameters['authorid'], '42');
  });

  test('permission error with metadata and no posts is displayed in Chinese',
      () async {
    await client.appSessions.save(_session);
    adapter.pageCode = 500;
    adapter.mobileBlocked = true;
    await expectLater(
      ApiService(client).getThreadDetail('123'),
      throwsA(
        isA<ServerMaintenanceException>()
            .having((e) => e.message, 'message', contains('权限')),
      ),
    );
    expect(adapter.mobileReadCount, 1);
  });

  test('both transports failing surfaces mobile failure after one attempt',
      () async {
    await client.appSessions.save(_session);
    adapter.failNextPage = true;
    adapter.mobileFails = true;
    await expectLater(
      ApiService(client).getThreadDetail('123'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.mobileReadCount, 1);
  });

  test('PHP warning prefix with braces rescues app JSON', () {
    final parsed = ApiService.ensureJson(
      '<br><b>Warning</b> {unrelated}\n${jsonEncode(_ok({'uid': '42'}))}',
    );
    expect(parsed['data']['uid'], '42');
    expect(
      DiscuzParser.rescueJsonFromHtml('<br>{"success":"yes","code":200}'),
      isNull,
    );
  });

  test('late expiry cannot clear a newer login', () async {
    await client.appSessions.save(_session);
    const newer = AppSession(uid: '43', username: 'bob', sid: 'new-token');
    await client.appSessions.save(newer);
    await client.appSessions.clear(expected: _session);
    expect(client.appSessions.current, same(newer));
    expect((await AppSessionStore().load())?.sid, 'new-token');
  });

  test('corrupt saved session is discarded', () async {
    await const FlutterSecureStorage()
        .write(key: AppSessionStore.storageKey, value: '{"sid":"secret"}');
    expect(await AppSessionStore().load(), isNull);
    expect(
      await const FlutterSecureStorage().read(key: AppSessionStore.storageKey),
      isNull,
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test('$platform login, persistent sid, fallback and logout', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final auth = AuthService(httpClient: client);
      expect(await auth.login('alice', 'secret'), isNull);
      expect((await AppSessionStore().load())?.uid, '42');
      adapter.failNextPage = true;
      await ApiService(client).getThreadDetail('123');
      expect(adapter.mobileReadCount, 1);
      expect(client.appSessions.current, isNotNull);
      await auth.logout();
      expect(await AppSessionStore().load(), isNull);
    });
  }
}

Map<String, dynamic> _ok(Map<String, dynamic> data) =>
    {'success': true, 'code': 200, 'data': data};

class _Adapter implements HttpClientAdapter {
  final posts = <String, List<Map<String, String>>>{};
  int appLoginCode = 200;
  int pageCode = 200;
  int threadCode = 200;
  int threadSpecial = 0;
  Completer<void>? loginGate;
  final loginStarted = Completer<void>();
  bool mobileLoginSucceeds = true;
  String mobileUid = '42';
  bool failNextPage = false;
  bool mobileBlocked = false;
  bool mobileFails = false;
  String? pageBody;
  int mobileReadCount = 0;
  Uri? lastMobileUri;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    var fields = <String, String>{};
    if (options.method == 'POST') {
      final bytes = await requestStream!.expand((part) => part).toList();
      fields = Uri.splitQueryString(utf8.decode(bytes));
      posts.putIfAbsent(uri.path, () => []).add(fields);
    }
    Object body;
    final headers = <String, List<String>>{
      Headers.contentTypeHeader: [Headers.jsonContentType],
    };
    if (uri.path.endsWith('/user/login')) {
      if (!loginStarted.isCompleted) loginStarted.complete();
      await loginGate?.future;
      body = appLoginCode == 200
          ? _ok(_session.toJson())
          : {'success': false, 'code': appLoginCode, 'message': '用户名或密码错误'};
    } else if (uri.path.endsWith('/thread/page')) {
      if (failNextPage) {
        failNextPage = false;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }
      body = pageBody ??
          (pageCode != 200
              ? {'success': false, 'code': pageCode, 'message': '请重新登录'}
              : _ok({
                  'pageNo': int.parse(fields['pageNo']!),
                  'pageSize': 40,
                  'totalCount': 80,
                  'list': [
                    {
                      'pid': 99,
                      'author': 'alice',
                      'authorid': 42,
                      'position': 41,
                      'dateline': 1700000000,
                      'avatarurl': 'https://example.com/avatar.jpg',
                      'message': '<p>app 正文</p>',
                    }
                  ],
                }));
    } else if (uri.path.endsWith('/thread')) {
      body = threadCode == 200
          ? _ok({
              'tid': 123,
              'fid': 151,
              'subject': 'test',
              'special': threadSpecial,
            })
          : {'success': false, 'code': threadCode};
    } else if (uri.path.endsWith('/user')) {
      body = _ok({'uid': 42, 'username': 'alice'});
    } else if (uri.queryParameters['module'] == 'viewthread') {
      mobileReadCount++;
      lastMobileUri = uri;
      if (mobileFails) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      }
      body = {
        'Variables': {
          'thread': {'tid': '123', 'fid': '151', 'replies': '79'},
          'ppp': 40,
          'postlist': mobileBlocked
              ? []
              : [
                  {'pid': '99', 'number': '41', 'message': 'mobile 正文'},
                ],
        },
        if (mobileBlocked)
          'Message': {
            'messageval': 'viewperm_login_nopermission//1',
            'messagestr': 'mobile:viewperm_login_nopermission',
          },
      };
    } else if (options.method == 'POST') {
      headers['set-cookie'] = [
        'test_auth=mobile-cookie; Path=/2b; Max-Age=2592000',
      ];
      body = {
        'Message': {
          'messageval': mobileLoginSucceeds ? 'login_succeed' : 'login_invalid',
        },
        'Variables': {'member_uid': mobileUid},
      };
    } else {
      body = {
        'Variables': {
          'formhash': 'hash',
          'member_uid': mobileUid,
          'member_username': 'alice',
        },
      };
    }
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      200,
      headers: headers,
    );
  }
}

class _FailingSessionStore extends AppSessionStore {
  @override
  Future<void> save(AppSession session) async {
    throw StateError('Storage unavailable');
  }
}

class _CookieStorage extends Storage {
  final values = <String, String>{};
  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<void> deleteAll(List<String> keys) async {
    keys.forEach(values.remove);
  }
}
