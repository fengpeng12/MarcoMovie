import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/js_source_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tearDown(CmsClient.closeScriptSessions);

  const javascript = r'''
let ticket = '';
export function home() { ticket='opaque-state'; return {list:[{vod_id:'one',vod_name:'Fixture'}]}; }
export function detail(id) { return {list:[{vod_id:id,vod_play_from:'proxy',vod_play_url:'One$opaque'}]}; }
export function play() { return {url:['Local',proxyUrl({ticket, kind:'bytes'}),'Remote','https://media.example/movie.mp4'], header:{oRiGiN:'https://upstream.example',Host:'upstream.example'}}; }
export function proxy(params) {
  if (ticket !== 'opaque-state' || params.ticket !== ticket) throw Error('state lost');
  if (params.origin !== 'https://upstream.example') throw Error('upstream Origin lost');
  if (params.kind === 'text') return [200,'text/plain','中文回调'];
  if (params.range && params.range !== 'bytes=1-2') throw Error('header bridge');
  return [200,'application/octet-stream',new Uint8Array([0,255,128,65]), {'X-Fixture':ticket}];
}
''';
  const python = r'''
from base.spider import Spider as Base
class Spider(Base):
 def homeContent(self, filter):
  self.ticket = 'opaque-state'
  return {'list':[{'vod_id':'one','vod_name':'Fixture'}]}
 def detailContent(self, ids):
  return {'list':[{'vod_id':ids[0],'vod_play_from':'proxy','vod_play_url':'One$opaque'}]}
 def playerContent(self, flag, id, vip):
  return {'url':['Local',self.getProxyUrl({'ticket':self.ticket,'kind':'bytes'}),'Remote','https://media.example/movie.mp4'],'header':{'oRiGiN':'https://upstream.example','Host':'upstream.example'}}
 def localProxy(self, params):
  assert self.ticket == params['ticket'] == 'opaque-state'
  assert params['origin'] == 'https://upstream.example'
  if params['kind'] == 'text': return [200,'text/plain','中文回调']
  if 'range' in params: assert params['range'] == 'bytes=1-2'
  return [200,'application/octet-stream',bytes([0,255,128,65]),{'X-Fixture':self.ticket}]
''';

  for (final language in ['JS', 'Python']) {
    test(
      '$language source resolves and serves its own retained local proxy',
      () async {
        final client = CmsClient();
        final config = await client.resolveConfigInput(
          rawTextInput: language == 'JS' ? javascript : python,
          subscriptionId: 'proxy-$language',
        );
        final site = config.config.sites.single.copyWith(
          headers: {'Origin': 'https://source.example'},
        );
        final video = (await client.fetchHome(site)).$2.videos.single;
        final detail = await CmsClient().fetchDetail(site, video);
        final release = client.pinPlaybackSource(site);
        addTearDown(release);
        final episode = await CmsClient().resolveEpisodeForPlayback(
          site,
          detail.lines.single.episodes.single,
        );
        final url = Uri.parse(episode.url);
        expect(url.host, '127.0.0.1');
        expect(url.queryParameters['ticket'], 'opaque-state');
        expect(
          episode.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('origin')),
        );
        expect(
          episode.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('host')),
        );
        expect(
          episode.headers['X-MarcoMovie-Proxy-Origin'],
          'https://upstream.example',
        );
        expect(
          episode.variants.last.headers['oRiGiN'],
          'https://upstream.example',
        );

        final http = HttpClient();
        addTearDown(() => http.close(force: true));
        final request = await http.getUrl(url);
        episode.headers.forEach(request.headers.set);
        request.headers.set('Range', 'bytes=1-2');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'), 'bytes 1-2/4');
        expect(response.headers.value('x-fixture'), 'opaque-state');
        expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
          255,
          128,
        ]);

        // Other browsing sessions must not discard a paused player's callback.
        for (var i = 0; i < 8; i++) {
          await JsSourceHost.invoke(
            entry: 'pkg://other/main.js',
            modules: const {
              'pkg://other/main.js': 'export function home(){return {}}',
            },
            method: 'home',
            arguments: [],
            sessionKey: 'browse-$i',
          );
        }
        final textRequest = await http.getUrl(
          url.replace(
            queryParameters: {...url.queryParameters, 'kind': 'text'},
          ),
        );
        episode.headers.forEach(textRequest.headers.set);
        final textResponse = await textRequest.close();
        expect(textResponse.statusCode, 200);
        expect(await utf8.decoder.bind(textResponse).join(), '中文回调');
        await CmsClient.retainScriptSessions([]);
        final removed = await (await http.getUrl(url)).close();
        expect(removed.statusCode, 404);
        await removed.drain<void>();
      },
    );
  }
}
