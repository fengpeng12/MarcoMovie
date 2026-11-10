import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/catpaw_host.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';

const bundle = r'''
exports.start = async () => {
  if (catDartServerPort() !== 0) throw Error('unexpected callback');
  const server = catServerFactory((req,res) => {
    const base='http://127.0.0.1:'+server.address().port;
    const url=new URL(req.url,base); const q=url.searchParams;
    res.setHeader('Content-Type','application/json');
    const card={vod_id:'movie',vod_name:'Synthetic movie',vod_year:'2026'};
    if(url.pathname==='/t4') res.end(JSON.stringify({sites:[{key:'demo',name:'Demo',type:4,api:base+'/api/demo'}]}));
    else if(url.pathname==='/website') {res.setHeader('Content-Type','text/html');res.end('<title>Source settings</title>');}
    else if(q.has('play')) res.end(JSON.stringify({parse:0,url:base+'/api/stream.mp4',header:{'X-Fixture':'one'}}));
    else if(q.has('ids')) res.end(JSON.stringify({list:[{vod_name:'Synthetic movie',vod_play_from:'Line',vod_play_url:'Episode$opaque-id'}]}));
    else if(q.has('t') || q.has('wd')) res.end(JSON.stringify({list:[card],page:1,pagecount:1}));
    else if(url.pathname==='/api/stream.mp4') { res.setHeader('Content-Type','video/mp4');res.end(Buffer.from([0,1,255,42])); }
    else res.end(JSON.stringify({class:[{type_id:'1',type_name:'Movies'}],list:[]}));
  });
  await new Promise(resolve=>server.listen(9321,'0.0.0.0',resolve));
};
''';

void main() {
  test('CatPaw checksum import browses, searches, resolves and survives host restart', () async {
    final directory = await Directory.systemTemp.createTemp('marco-paw-test-');
    final node = (await Process.run('node',['-p','process.execPath'])).stdout.toString().trim();
    final host = CatPawHost(directory:() async=>directory,executable:node,
      bootstrap:'${Directory.current.path}/assets/catpaw/host.cjs');
    final previous = CatPawHost.instance;
    CatPawHost.instance = host;
    addTearDown(() async { CatPawHost.instance=previous;await host.close();await directory.delete(recursive:true); });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    addTearDown(()=>server.close(force:true));
    server.listen((request) async {
      request.response.write(request.uri.path.endsWith('.md5') ? md5.convert(utf8.encode(bundle)).toString() : bundle);
      await request.response.close();
    });
    final client = CmsClient();
    final entry = (await client.resolveBatchSubscriptions(urlInput:'http://127.0.0.1:${server.port}/index.js.md5')).single;
    final config = CmsParser.parseConfig(entry.rawContent);
    final site = config.supportedSites.single;
    expect(site.isCatPaw,isTrue);
    expect(site.api, startsWith('catpaw://'));
    expect(entry.rawContent,isNot(contains('127.0.0.1')));
    expect(entry.rawContent,isNot(contains('exports.start')));
    final home = await client.fetchHome(site);
    expect(home.$1.single.name,'Movies');
    expect(home.$2.videos.single.title,'Synthetic movie');
    final found = (await client.fetchSearch(site,'Synthetic')).videos.single;
    final detail = await client.fetchDetail(site,found);
    expect(detail.id, found.id);
    expect(detail.year, found.year);
    final episode = detail.lines.single.episodes.single;
    expect(episode.needsSourceResolution,isTrue);
    final play = await client.resolveEpisodeForPlayback(site,episode);
    expect(play.headers['X-Fixture'],'one');
    final http = HttpClient();
    addTearDown(()=>http.close(force:true));
    final response = await (await http.getUrl(Uri.parse(play.url))).close();
    expect(await response.fold<List<int>>([], (a,b)=>a..addAll(b)),[0,1,255,42]);
    final settings = await host.settings(site.api);
    final entryRequest = await http.getUrl(settings)..followRedirects=false;
    final entryResponse = await entryRequest.close();
    expect(entryResponse.statusCode,303);
    final cookie = entryResponse.cookies.single;
    await entryResponse.drain<void>();
    final settingsRequest = await http.getUrl(settings.replace(path:'/website'));
    settingsRequest.cookies.add(cookie);
    final settingsResponse = await settingsRequest.close();
    expect(await settingsResponse.transform(utf8.decoder).join(),contains('Source settings'));
    await host.close();
    expect((await client.fetchHome(site)).$2.videos.single.title,'Synthetic movie');
    await expectLater(host.resolve('catpaw://bad/api/demo'),throwsFormatException);
  });
}
