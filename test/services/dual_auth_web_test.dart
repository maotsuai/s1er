import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/config/env_config.dart';
import 'package:s1er/models/app_session.dart';
import 'package:s1er/services/api_service.dart';
import 'package:s1er/services/app_session_store.dart';
import 'package:s1er/services/auth_service.dart';
import 'package:s1er/services/formhash_service.dart';
import 'package:s1er/services/http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'browser auth transport',
    () {
      late ProviderContainer container;
      late S1HttpClient client;
      late _BrowserAdapter adapter;

      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        container = ProviderContainer();
        client = container.read(httpClientProvider);
        await client.init();
        adapter = _BrowserAdapter();
        client.dio.httpClientAdapter = adapter;
      });

      tearDown(() async {
        await client.dispose();
        container.dispose();
      });

      test('app POST uses proxy and sid without injecting formhash', () async {
        await client.appSessions.save(
          const AppSession(uid: '42', username: 'alice', sid: 'browser-token'),
        );
        container.read(formhashProvider.notifier).update('cookie-formhash');
        await ApiService(client).getThreadDetail('123');
        expect(adapter.requests, hasLength(2));
        for (final request in adapter.requests) {
          expect(request.uri.host, 'localhost');
          expect(request.uri.port, EnvConfig.proxyPort);
          expect(request.uri.queryParameters.containsKey('formhash'), isFalse);
        }
        expect(adapter.bodies.first['sid'], 'browser-token');
        expect(adapter.bodies.first.containsKey('formhash'), isFalse);
        adapter.expired = true;
        await ApiService(client).getThreadDetail('123');
        expect(adapter.mobileReads, 1);
        expect(await AppSessionStore().load(), isNull);
      });

      test('one form creates both sessions and logout clears proxy and sid',
          () async {
        final auth = AuthService(httpClient: client);
        expect(await auth.login('alice', 'secret'), isNull);
        expect((await AppSessionStore().load())?.sid, 'browser-token');
        expect(adapter.cookieLoggedIn, isTrue);
        await auth.logout();
        expect(adapter.cookieLoggedIn, isFalse);
        expect(await AppSessionStore().load(), isNull);
      });
    },
    skip: !kIsWeb,
  );
}

class _BrowserAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <Map<String, String>>[];
  bool expired = false;
  bool cookieLoggedIn = false;
  int mobileReads = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final fields = requestStream == null
        ? <String, String>{}
        : Uri.splitQueryString(
            utf8.decode(await requestStream.expand((e) => e).toList()),
          );
    bodies.add(fields);
    final uri = options.uri;
    Object body;
    if (uri.path == '/proxy/session/clear') {
      cookieLoggedIn = false;
      body = {'ok': true};
    } else if (uri.path.endsWith('/user/login')) {
      body = _ok({'uid': 42, 'username': 'alice', 'sid': 'browser-token'});
    } else if (uri.path.endsWith('/thread/page')) {
      body = expired
          ? {'success': false, 'code': 501}
          : _ok({
              'pageNo': 1,
              'pageSize': 40,
              'totalCount': 1,
              'list': [
                {'pid': 1, 'position': 1, 'message': 'app'},
              ],
            });
    } else if (uri.path.endsWith('/thread')) {
      body = _ok({'tid': 123, 'fid': 151, 'subject': 'test'});
    } else if (uri.path.endsWith('/user')) {
      body = _ok({'uid': 42, 'username': 'alice'});
    } else if (uri.queryParameters['module'] == 'viewthread') {
      mobileReads++;
      body = {
        'Variables': {
          'thread': {'replies': 0},
          'ppp': 40,
          'postlist': [
            {'pid': 1, 'number': 1, 'message': 'mobile'},
          ],
        },
      };
    } else if (options.method == 'POST') {
      cookieLoggedIn = true;
      body = {
        'Message': {'messageval': 'login_succeed'},
        'Variables': {'member_uid': 42},
      };
    } else {
      body = {
        'Variables': {'formhash': 'hash'},
      };
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  Map<String, dynamic> _ok(Map<String, dynamic> data) =>
      {'success': true, 'code': 200, 'data': data};
}
