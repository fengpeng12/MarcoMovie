import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/checksum_source.dart';
import 'package:marco_movie/core/catpaw_host.dart';

void main() {
  test(
    'authenticated checksum import verifies sibling bytes and never saves URL credentials',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      const js = 'export default {home(){return {list:[]}}}';
      String digest = md5.convert(utf8.encode(js)).toString(), payload = js;
      server.listen((r) async {
        if (r.headers.value('Authorization') !=
            'Basic ${base64Encode(utf8.encode('fixture:sample-only'))}') {
          r.response.statusCode = 401;
        } else {
          r.response.write(r.uri.path.endsWith('.md5') ? digest : payload);
        }
        await r.response.close();
      });
      final url = Uri(scheme:'http', userInfo:'fixture:sample-only', host:'127.0.0.1', port:server.port, path:'/entry.js.md5').toString();
      final client = CmsClient();
      final entry = (await client.resolveBatchSubscriptions(
        urlInput: url,
      )).single;
      expect(jsonEncode(entry.toJson()), isNot(contains('sample-only')));
      expect(entry.rawContent, contains('export default'));
      digest = '00000000000000000000000000000000';
      await expectLater(
        client.resolveBatchSubscriptions(urlInput: url),
        throwsA(predicate((e) => e.toString().contains('校验不一致'))),
      );
      payload = 'const server = catServerFactory; catDartServerPort();';
      digest = md5.convert(utf8.encode(payload)).toString();
      final verified = await ChecksumSource.read(Uri.parse(url));
      expect(CatPawHost.isBundle(verified.source),isTrue);
    },
  );
}
