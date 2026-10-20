import 'package:xml/xml.dart';

typedef WebDavEtag = ({String value, bool isStrong});

/// 只解析文件版本属性；不发请求，也不信任其他资源或失败的 propstat。
class WebDavMetadata {
  static final _strong = RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$');
  // 无引号 opaque 值可包含 base64 的 + / =，但不能变成通配符或列表。
  static final _bare = RegExp(r'^[\x21\x23-\x2b\x2d-\x7e\x80-\xff]+$');

  static WebDavEtag? parseEtag(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    if (_strong.hasMatch(value)) return (value: value, isStrong: true);
    if (value == '*' || value.toUpperCase().startsWith('W/')) return null;
    if (_bare.hasMatch(value)) return (value: value, isStrong: false);
    return null;
  }

  static WebDavEtag? parseProperties(String source, Uri target) {
    // 不接受 DTD / 自定义实体，错误内容也不带回服务端原文。
    if (RegExp(r'<!DOCTYPE', caseSensitive: false).hasMatch(source)) {
      throw const FormatException('WebDAV 文件属性不支持 DTD');
    }
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlException {
      throw const FormatException('WebDAV 文件属性 XML 无效');
    }
    final root = document.rootElement;
    if (!_named(root, 'multistatus')) return null;
    final responses = _children(root, 'response').where((response) {
      final hrefs = _children(response, 'href').toList();
      return hrefs.length == 1 && _sameResource(hrefs.single.innerText, target);
    }).toList();
    if (responses.length > 1) {
      throw const FormatException('WebDAV 文件属性重复');
    }
    if (responses.isEmpty) return null;
    final values = <String>{};
    for (final propstat in _children(responses.single, 'propstat')) {
      final statuses = _children(propstat, 'status').toList();
      if (statuses.length != 1 ||
          !RegExp(r'^HTTP/\S+\s+200(?:\s|$)')
              .hasMatch(statuses.single.innerText.trim())) {
        continue;
      }
      for (final prop in _children(propstat, 'prop')) {
        for (final etag in _children(prop, 'getetag')) {
          values.add(etag.innerText.trim());
        }
      }
    }
    if (values.length > 1) {
      throw const FormatException('WebDAV 文件版本属性不唯一');
    }
    return values.isEmpty ? null : parseEtag(values.single);
  }

  static bool _named(XmlElement node, String name) =>
      node.namespaceUri == 'DAV:' && node.localName == name;

  static Iterable<XmlElement> _children(XmlElement node, String name) =>
      node.childElements.where((child) => _named(child, name));

  static bool _sameResource(String raw, Uri target) {
    if (raw.trim().isEmpty) return false;
    final href = Uri.tryParse(raw.trim());
    if (href == null) return false;
    final resolved = target.resolveUri(href).normalizePath();
    final expected = target.normalizePath();
    return resolved.scheme == expected.scheme &&
        resolved.host == expected.host &&
        resolved.port == expected.port &&
        resolved.userInfo.isEmpty &&
        !resolved.hasQuery &&
        !resolved.hasFragment &&
        resolved.pathSegments.length == expected.pathSegments.length &&
        Iterable<int>.generate(expected.pathSegments.length).every(
          (i) => resolved.pathSegments[i] == expected.pathSegments[i],
        );
  }
}
