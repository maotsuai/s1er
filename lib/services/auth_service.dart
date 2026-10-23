import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import '../config/env_config.dart';
import '../models/user.dart';
import 'http_client.dart';
import 'api_service.dart';
import 'talker.dart';
import '../utils/error_handler.dart';

class AuthService {
  AuthService({required S1HttpClient httpClient}) : _httpClient = httpClient;
  final S1HttpClient _httpClient;

  User? _currentUser;
  bool _isLoggedIn = false;
  int _authRevision = 0;
  bool _loginInProgress = false;

  User? get currentUser => _currentUser;
  bool get isLoggedIn => _isLoggedIn;

  void setLoggedIn(String username) {
    _isLoggedIn = true;
    _currentUser = User(uid: '', username: username);
    unawaited(_fetchProfile());
  }

  Future<String?> login(
    String username,
    String password, {
    int questionId = 0,
    String answer = '',
  }) async {
    if (_loginInProgress) return '正在登录，请稍候';
    _loginInProgress = true;
    try {
      await logout();
      final revision = _authRevision;
      final apiService = ApiService(_httpClient);
      final session = await apiService.loginApp(
        username,
        password,
        questionId: questionId,
        answer: answer,
      );
      if (revision != _authRevision) {
        await logout();
        return '登录已取消';
      }
      final error = await apiService.login(
        username,
        password,
        questionId: questionId,
        answer: answer,
        expectedUid: session.uid,
      );
      if (revision != _authRevision) {
        await logout();
        return '登录已取消';
      }

      if (error == null) {
        await _httpClient.appSessions.save(session);
        if (revision != _authRevision) {
          await logout();
          return '登录已取消';
        }
        _isLoggedIn = true;
        _currentUser = User(uid: session.uid, username: session.username);
        await _fetchProfile();
        if (revision != _authRevision) return '登录已取消';
        return null;
      }
      await logout();
      return '备用登录失败：$error';
    } catch (e) {
      talker.warning('Dual login failed (${e.runtimeType})');
      try {
        await logout();
      } catch (cleanupError) {
        talker.warning('Login cleanup failed (${cleanupError.runtimeType})');
      }
      return userFacingError(e);
    } finally {
      _loginInProgress = false;
    }
  }

  Future<User?> _fetchProfile() async {
    final revision = _authRevision;
    try {
      final apiService = ApiService(_httpClient);
      final profile = await apiService.getUserProfile();
      if (profile != null && revision == _authRevision) {
        final session = _httpClient.appSessions.current;
        if (session != null && session.uid != profile.uid) {
          talker.warning('Ignoring profile for a different account');
          return null;
        }
        _currentUser = profile;
        return profile;
      }
    } catch (e, st) {
      talker.handle(e, st, 'Fetch profile failed');
    }
    return null;
  }

  Future<User?> fetchProfile() async {
    return await _fetchProfile();
  }

  Future<void> logout() async {
    _authRevision++;
    _currentUser = null;
    _isLoggedIn = false;
    try {
      await _httpClient.appSessions.clear();
    } finally {
      await _clearMobileSession();
    }
  }

  Future<void> _clearMobileSession() async {
    if (kIsWeb) {
      try {
        const proxyUrl =
            'http://localhost:${EnvConfig.proxyPort}/proxy/session/clear';
        final headers = <String, dynamic>{};
        if (EnvConfig.proxyAuthToken.isNotEmpty) {
          headers[proxyAuthHeader] = EnvConfig.proxyAuthToken;
        }
        await _httpClient.post(
          proxyUrl,
          options: Options(headers: headers),
        );
      } catch (e, st) {
        talker.handle(e, st, 'Clear proxy session failed');
        rethrow;
      }
    }
    if (!kIsWeb) {
      await _httpClient.clearCookies();
    }
  }

  Future<bool> checkSession() async {
    final revision = _authRevision;
    final apiService = ApiService(_httpClient);

    try {
      final session = await _httpClient.appSessions.load();
      if (revision != _authRevision) return false;
      if (session != null) {
        _currentUser = User(uid: session.uid, username: session.username);
        _isLoggedIn = true;
        // user 是公开资料接口，不能用于验证 sid；由首次鉴权读帖处理过期。
        unawaited(_fetchProfile());
        return true;
      }
    } catch (e) {
      talker.warning('Restore app session failed (${e.runtimeType})');
    }

    // 1. 优先通过 API 验证会话（Cookie 由 CookieManager 自动附加）
    try {
      final profile = await apiService.getUserProfile();
      if (revision != _authRevision) return false;
      if (profile != null && profile.uid.isNotEmpty && profile.uid != '0') {
        _currentUser = profile;
        _isLoggedIn = true;
        return true;
      }
    } catch (e) {
      talker.warning('Restore mobile session failed (${e.runtimeType})');
    }

    // 2. API 验证失败时，检查本地 PersistCookieJar 中是否有 auth Cookie
    //    尝试多个路径以覆盖 Discuz 不同的 Cookie Path 设置
    if (kIsWeb) return false;
    try {
      final urls = [
        Uri.parse('https://stage1st.com/2b/'),
        Uri.parse('https://stage1st.com'),
      ];
      for (final uri in urls) {
        final cookies = await _httpClient.cookieJar.loadForRequest(uri);
        if (revision != _authRevision) return false;
        final hasAuth =
            cookies.any((c) => c.name.endsWith('auth') && c.value.isNotEmpty);
        if (hasAuth) {
          final memberName = cookies
              .firstWhere(
                (c) => c.name.endsWith('username'),
                orElse: () => Cookie('username', 'S1User'),
              )
              .value;
          _currentUser =
              User(uid: '', username: Uri.decodeComponent(memberName));
          _isLoggedIn = true;
          unawaited(_fetchProfile());
          return true;
        }
      }
    } catch (e) {
      talker.warning('Read saved cookies failed (${e.runtimeType})');
    }
    return false;
  }
}
