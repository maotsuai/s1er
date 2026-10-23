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
import 'webdav_metadata.dart';

enum WebDavSyncFailureKind { network, conflict, configuration }

class WebDavSyncException implements Exception {
  const WebDavSyncException(
    this.message, {
    this.kind = WebDavSyncFailureKind.configuration,
  });
  final String message;
  final WebDavSyncFailureKind kind;
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
        final fromDownload = WebDavMetadata.parseEtag(downloaded.etag);
        final validator = fromDownload ?? await _lookupEtag(url, headers);
        if (validator == null) {
          throw const WebDavSyncException(
            '服务器未提供可用 ETag（已检查下载响应、HEAD 和 WebDAV 文件属性），'
            '未修改同步文件；Web 端请允许 HEAD、PROPFIND 并暴露 ETag',
          );
        }
        etag = validator.value;
        // 备用属性可能在下载后发生变化；用条件 GET 绑定到原来的完整内容，
        // 避免将新版本的 ETag 配到旧文件上，再覆盖其他设备的更新。
        verifyContent = fromDownload == null || !validator.isStrong;
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
        final currentRemote = await _download(url, {
          ...headers,
          'If-Match': etag!,
        });
        final currentEtag = WebDavMetadata.parseEtag(currentRemote.etag);
        if ((currentEtag != null && currentEtag.value != etag) ||
            !_sameBytes(currentRemote.bytes, downloaded.bytes!)) {
          _checkStatus(412);
        }
      }
      // 内容没有变化时不改写 ZIP（exported_at 每次不同，不能比较 ZIP 字节）。
      final needsUpload =
          remote == null || !S1BackupMerge.sameContents(merged, remote);
      if (needsUpload) {
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
              kind: WebDavSyncFailureKind.conflict,
            );
          }
        }
      }

      // 上传期间用户仍可阅读/改设置；将这些新改动保留在本机，下次再上传。
      final current = await snapshot();
      final apply =
          S1BackupMerge.merge(local: current, remote: merged, base: local);
      if (!S1BackupMerge.sameContents(current, apply)) {
        await _backup.importPayload(
          apply,
          replaceCollections: true,
          notifySyncChange: false,
        );
      }
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
            ? 'WebDAV 请求超时，请检查网络后重试'
            : '无法连接 WebDAV，请检查地址、网络和证书；Web 端还需配置 CORS',
        kind: timedOut || e.type == DioExceptionType.connectionError
            ? WebDavSyncFailureKind.network
            : WebDavSyncFailureKind.configuration,
      );
    } on S1BackupException catch (e) {
      throw WebDavSyncException('同步文件无效：${e.message}');
    } on FormatException {
      throw const WebDavSyncException('同步文件格式无效，未覆盖本机数据');
    }
  }

  static const _metadataLimit = 64 * 1024;

  Future<WebDavEtag?> _lookupEtag(
    String url,
    Map<String, String> headers,
  ) async {
    final head = await _client.requestExternal<ResponseBody>(
      url,
      method: 'HEAD',
      headers: headers,
      responseType: ResponseType.stream,
    );
    await _readBytes(head, _metadataLimit);
    if (head.statusCode == 404) _checkStatus(412);
    if (head.statusCode != 405 && head.statusCode != 501) {
      _checkStatus(head.statusCode);
      final etag = WebDavMetadata.parseEtag(_singleEtag(head.headers));
      if (etag != null) return etag;
    }
    final properties = await _client.requestExternal<ResponseBody>(
      url,
      method: 'PROPFIND',
      headers: {
        ...headers,
        'Depth': '0',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      data: '<?xml version="1.0" encoding="utf-8"?>'
          '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/>'
          '</d:prop></d:propfind>',
      responseType: ResponseType.stream,
    );
    final bytes = await _readBytes(properties, _metadataLimit);
    if (properties.statusCode == 404) _checkStatus(412);
    if (properties.statusCode == 405 || properties.statusCode == 501) {
      return null;
    }
    if (properties.statusCode != 207) _checkStatus(properties.statusCode);
    try {
      return WebDavMetadata.parseProperties(utf8.decode(bytes), Uri.parse(url));
    } on FormatException {
      throw const WebDavSyncException('服务器返回的 WebDAV 文件属性无效，未修改同步文件');
    }
  }

  static String? _singleEtag(Headers headers) {
    final values = headers['etag'];
    return values?.length == 1 ? values!.single : null;
  }

  Future<Uint8List> _readBytes(
    Response<ResponseBody> response,
    int limit,
  ) async {
    final downloaded = BytesBuilder(copy: false);
    final body = response.data;
    if (body != null) {
      await for (final chunk in body.stream) {
        if (downloaded.length + chunk.length > limit) {
          throw WebDavSyncException(
            limit == _metadataLimit
                ? 'WebDAV 文件属性响应过大，未修改同步文件'
                : '云端同步文件超过 16 MB，未修改本机数据',
          );
        }
        downloaded.add(chunk);
      }
    }
    return downloaded.takeBytes();
  }

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
    final bytes = await _readBytes(response, S1BackupCodec.maxCompressedBytes);
    if (response.statusCode == 404) return (bytes: null, etag: null);
    _checkStatus(response.statusCode);
    if (bytes.isEmpty) {
      throw const WebDavSyncException('云端同步文件为空，未覆盖本机数据');
    }
    return (bytes: bytes, etag: _singleEtag(response.headers));
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
      412 => '另一台设备刚更新了同步文件，本次未覆盖，将重新读取后同步',
      423 => '云端同步文件已锁定，请稍后手动重试',
      507 => 'WebDAV 存储空间不足',
      int code when code >= 300 && code < 400 =>
        'WebDAV 地址发生重定向，请填写重定向后的完整目录地址',
      _ => 'WebDAV 同步失败（HTTP ${status ?? '未知'}）',
    };
    throw WebDavSyncException(
      message,
      kind: switch (status) {
        412 || 423 => WebDavSyncFailureKind.conflict,
        408 || 429 => WebDavSyncFailureKind.network,
        int code when code >= 500 && code != 507 =>
          WebDavSyncFailureKind.network,
        _ => WebDavSyncFailureKind.configuration,
      },
    );
  }
}
