import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../models/webdav_config.dart';
import '../app_local_data.dart';
import '../backup/s1_backup_codec.dart';
import '../backup/s1_backup_service.dart';
import '../http_client.dart';
import 's1_backup_merge.dart';

class WebDavSyncException implements Exception {
  const WebDavSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WebDavSyncService {
  WebDavSyncService(this._client, this._local, this._backup);

  final S1HttpClient _client;
  final AppLocalData _local;
  final S1BackupService _backup;
  static const baselineKey = 'webdav_sync_baseline';

  Future<void> synchronize({
    required WebDavConfig config,
    required String? uid,
    required PackageInfo packageInfo,
    required String platform,
  }) async {
    final url = config.fileUri.toString();
    final headers = {
      'Authorization':
          'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
      'Cache-Control': 'no-cache',
    };
    try {
      final downloaded = await _download(url, headers);
      final exists = downloaded.bytes != null;
      S1BackupPayload? remote;
      String? etag;
      var verifyContent = false;
      if (exists) {
        remote = S1BackupCodec.decode(downloaded.bytes!);
        etag = downloaded.etag?.trim();
        final strong = etag != null && _strongEtag.hasMatch(etag);
        // 坚果云等服务返回无引号的 opaque ETag；If-Match 必须保留原值，
        // 不能擅自加引号或去掉弱标记。兼容路径额外核验上传前后的内容。
        final bare = etag != null && _bareEtag.hasMatch(etag);
        if (!strong && !bare) {
          throw const WebDavSyncException(
            '服务器未提供可用的 ETag，无法进行条件同步；Web 端请允许读取 ETag 响应头',
          );
        }
        verifyContent = bare;
      }

      S1BackupPayload? base;
      final baseline = _local.settings.get<Object>(baselineKey);
      if (baseline is Map && baseline['target'] == config.targetId) {
        base = S1BackupCodec.decode(base64Decode(baseline['zip'] as String));
      }
      Future<S1BackupPayload> snapshot() async {
        await _local.flushPendingWrites();
        return (await _backup.exportL1(
          uid: uid,
          packageInfo: packageInfo,
          platform: platform,
        ))
            .payload;
      }

      final local = await snapshot();
      final merged = remote == null
          ? local
          : S1BackupMerge.merge(
              local: local,
              remote: remote,
              base: base,
            );
      final upload = S1BackupCodec.encode(merged);
      // 上传前也验证大小，避免写出自己无法再导入的同步文件。
      S1BackupCodec.decode(upload);
      if (verifyContent) {
        final currentRemote = await _download(url, headers);
        if (currentRemote.etag?.trim() != etag ||
            !_sameBytes(currentRemote.bytes, downloaded.bytes!)) {
          _checkStatus(412);
        }
      }
      final put = await _client.requestExternal<List<int>>(
        url,
        method: 'PUT',
        headers: {
          ...headers,
          'Content-Type': 'application/zip',
          if (exists) 'If-Match': etag! else 'If-None-Match': '*',
        },
        data: Stream.value(upload),
      );
      _checkStatus(put.statusCode);
      if (verifyContent) {
        final saved = await _download(url, headers);
        if (!_sameBytes(saved.bytes, upload)) {
          throw const WebDavSyncException(
            '云端同步文件写入后校验不一致，可能有其他设备同时同步；本机数据已保留，请稍后重试',
          );
        }
      }

      // 上传期间用户仍可阅读/改设置；将这些新改动保留在本机，下次再上传。
      final current = await snapshot();
      final apply =
          S1BackupMerge.merge(local: current, remote: merged, base: local);
      await _backup.importPayload(apply, replaceCollections: true);
      await _local.settings.putAsync(baselineKey, {
        'target': config.targetId,
        'zip': base64Encode(upload),
      });
    } on DioException catch (e) {
      // 不将含 Authorization / URL 的 DioException 交给 UI 或日志。
      final timedOut = const {
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      }.contains(e.type);
      throw WebDavSyncException(
        timedOut
            ? 'WebDAV 请求超时，请检查网络后手动重试'
            : '无法连接 WebDAV，请检查地址、网络和证书；Web 端还需配置 CORS',
      );
    } on S1BackupException catch (e) {
      throw WebDavSyncException('同步文件无效：${e.message}');
    } on FormatException {
      throw const WebDavSyncException('同步文件格式无效，未覆盖本机数据');
    }
  }

  // 标准强 ETag 允许 opaque 部分包含逗号；无引号兼容值只接受单个 token，
  // 拒绝弱 ETag、通配符、列表和控制字符，避免改变 If-Match 的含义。
  static final _strongEtag = RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$');
  static final _bareEtag = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$');

  Future<({Uint8List? bytes, String? etag})> _download(
    String url,
    Map<String, String> headers,
  ) async {
    final response = await _client.requestExternal<ResponseBody>(
      url,
      method: 'GET',
      headers: headers,
      responseType: ResponseType.stream,
    );
    final downloaded = BytesBuilder(copy: false);
    final body = response.data;
    if (body != null) {
      await for (final chunk in body.stream) {
        if (downloaded.length + chunk.length >
            S1BackupCodec.maxCompressedBytes) {
          throw const WebDavSyncException('云端同步文件超过 16 MB，未修改本机数据');
        }
        downloaded.add(chunk);
      }
    }
    if (response.statusCode == 404) return (bytes: null, etag: null);
    _checkStatus(response.statusCode);
    final bytes = downloaded.takeBytes();
    if (bytes.isEmpty) {
      throw const WebDavSyncException('云端同步文件为空，未覆盖本机数据');
    }
    return (bytes: bytes, etag: response.headers.value('etag'));
  }

  static bool _sameBytes(Uint8List? actual, Uint8List expected) {
    if (actual == null || actual.length != expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  static void _checkStatus(int? status) {
    if (status == 200 || status == 201 || status == 204) return;
    final message = switch (status) {
      401 || 403 => 'WebDAV 认证失败或没有读写权限，请检查用户名和应用专用密码',
      404 || 409 => 'WebDAV 目录不存在，请先在服务器创建该目录',
      412 => '另一台设备刚更新了同步文件，本次未覆盖，请手动重试',
      423 => '云端同步文件已锁定，请稍后手动重试',
      507 => 'WebDAV 存储空间不足',
      int code when code >= 300 && code < 400 =>
        'WebDAV 地址发生重定向，请填写重定向后的完整目录地址',
      _ => 'WebDAV 同步失败（HTTP ${status ?? '未知'}）',
    };
    throw WebDavSyncException(message);
  }
}
