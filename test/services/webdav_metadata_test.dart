import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:s1er/services/sync/webdav_metadata.dart';

void main() {
  final target = Uri.parse('https://dav.example/dav/S1er/s1er.s1backup.zip');

  String properties({
    String href = '/dav/S1er/s1er.s1backup.zip',
    String etag = '"revision"',
    String status = 'HTTP/1.1 200 OK',
    String namespace = 'DAV:',
  }) =>
      '<multistatus xmlns="$namespace"><response>'
      '<href>${htmlEscape.convert(href)}</href><propstat>'
      '<prop><getetag>${htmlEscape.convert(etag)}</getetag></prop>'
      '<status>$status</status></propstat></response></multistatus>';

  test('accepts exact quoted ETags and opaque base64 values', () {
    expect(
      WebDavMetadata.parseEtag(' "revision,1" '),
      (value: '"revision,1"', isStrong: true),
    );
    expect(
      WebDavMetadata.parseEtag('+revision/1=='),
      (value: '+revision/1==', isStrong: false),
    );
  });

  test(
      'weak validators, wildcards, lists and embedded controls remain unusable',
      () {
    for (final value in [
      null,
      '',
      'W/"1"',
      'w/1',
      '*',
      '1,2',
      '"1", "2"',
      'a\nb',
      'a b',
    ]) {
      expect(WebDavMetadata.parseEtag(value), isNull, reason: '$value');
    }
  });

  test('reads DAV getetag for the exact resource with XML entity decoding', () {
    expect(
      WebDavMetadata.parseProperties(properties(etag: '"a&b"'), target),
      (value: '"a&b"', isStrong: true),
    );
    expect(
      WebDavMetadata.parseProperties(
        properties(href: target.toString()),
        target,
      ),
      (value: '"revision"', isStrong: true),
    );
    expect(
      WebDavMetadata.parseProperties(
        properties(href: 's1er.s1backup.zip'),
        target,
      ),
      (value: '"revision"', isStrong: true),
    );
  });

  test('ignores validators for other resources, origins or failed properties',
      () {
    for (final href in [
      '/dav/S1er/',
      '/dav/other/s1er.s1backup.zip',
      'https://other.example/dav/S1er/s1er.s1backup.zip',
      '/dav/S1er/s1er.s1backup.zip?other=1',
    ]) {
      expect(
        WebDavMetadata.parseProperties(properties(href: href), target),
        isNull,
      );
    }
    expect(
      WebDavMetadata.parseProperties(
        properties(status: 'HTTP/1.1 404 Not Found'),
        target,
      ),
      isNull,
    );
    expect(
      WebDavMetadata.parseProperties(properties(namespace: 'foreign:'), target),
      isNull,
    );
  });

  test('rejects ambiguous responses, malformed XML and DTDs', () {
    final response = '<response><href>${target.path}</href><propstat>'
        '<prop><getetag>"1"</getetag></prop>'
        '<status>HTTP/1.1 200 OK</status></propstat></response>';
    expect(
      () => WebDavMetadata.parseProperties(
        '<multistatus xmlns="DAV:">$response$response</multistatus>',
        target,
      ),
      throwsFormatException,
    );
    expect(
      () => WebDavMetadata.parseProperties('<broken', target),
      throwsFormatException,
    );
    expect(
      () => WebDavMetadata.parseProperties(
        '<!DOCTYPE multistatus SYSTEM "https://other.example/entity">'
        '${properties()}',
        target,
      ),
      throwsFormatException,
    );
  });
}
