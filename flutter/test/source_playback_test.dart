import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/source_playback.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('plain CMS streams inherit same-origin credentials only at resolution', () async {
    SharedPreferences.setMockInitialValues({});
    const site = CmsSite(key:'cms', name:'Fixture', type:1,
      api:'https://source.test/api.php', headers:{'Authorization':'Source fixture',
        'Cookie':'session=fixture', 'User-Agent':'Fixture'});
    final screen = PlayerScreen(site:site,
      video:const CmsVideo(id:'one', title:'Fixture'), initialLineIndex:0,
      initialEpisodeIndex:0, storage:StorageService(await SharedPreferences.getInstance()));
    final client = CmsClient();
    for (final target in ['https://source.test/media.mp4', 'https://cdn.test/media.mp4',
      'http://source.test/media.mp4', 'https://source.test:8443/media.mp4']) {
      final resolved = await client.resolveEpisodeForPlayback(site, CmsEpisode(name:'Episode',url:target));
      expect(screen.mediaForPlayback(resolved).httpHeaders,
        target == 'https://source.test/media.mp4' ? site.headers : {'User-Agent':'Fixture'});
    }
    final explicit = await client.resolveEpisodeForPlayback(site,
      const CmsEpisode(name:'Episode', url:'https://source.test/media.mp4',
        headers:{'authorization':'Media fixture', 'cookie':'media=fixture'}));
    expect(screen.mediaForPlayback(explicit).httpHeaders,
      {'User-Agent':'Fixture', 'authorization':'Media fixture','cookie':'media=fixture'});
  });
  test('native player uses resolved headers without restoring source credentials', () async {
    SharedPreferences.setMockInitialValues({});
    const credentials = {
      'Authorization': 'Source fixture', 'Cookie': 'session=fixture',
      'Cookie2': 'legacy=fixture', 'Proxy-Authorization': 'Proxy fixture',
      'User-Agent': 'Fixture',
    };
    const site = CmsSite(key: 'media', name: 'Fixture', type: 3,
        api: 'https://source.test/rule.js', headers: credentials);
    final screen = PlayerScreen(site: site,
        video: const CmsVideo(id: 'one', title: 'Fixture'),
        initialLineIndex: 0, initialEpisodeIndex: 0,
        storage: StorageService(await SharedPreferences.getInstance()));
    final resolved = await SourcePlayback.decode({'url': [
      'https://source.test/video.mp4',
      'https://cdn.test/video.mp4',
      'http://source.test/video.mp4',
      'https://source.test:8443/video.mp4',
      'catpaw://bundle/proxy',
      {'url': 'https://cdn.test/explicit.mp4',
        'header': {'Authorization': 'CDN fixture', 'Cookie': 'cdn=fixture'}},
    ]}, const CmsEpisode(name: 'Episode', url: 'mmjs://play?id=one'),
        localUrl: (_) async => Uri.parse('http://127.0.0.1:1234/fixture/proxy'),
        sourceOrigin: Uri.parse(site.api), sourceHeaders: credentials);
    expect(screen.mediaForPlayback(resolved.variants.first).httpHeaders, credentials);
    for (final choice in resolved.variants.skip(1).take(4)) {
      expect(screen.mediaForPlayback(choice).httpHeaders, {'User-Agent': 'Fixture'},
          reason: 'Source credentials must not be restored for ${Uri.parse(choice.url).origin}');
    }
    final explicit = screen.mediaForPlayback(resolved.variants.last,
        start: const Duration(seconds: 12));
    expect(explicit.httpHeaders, {'User-Agent': 'Fixture',
      'Authorization': 'CDN fixture', 'Cookie': 'cdn=fixture'});
    expect(explicit.start, const Duration(seconds: 12));
  });
  test('configured detail preserves real providers without cross-source requests', () async {
    const original = CmsVideo(id: 'one', title: 'Fixture');
    const site = CmsSite(key: 'fixture', name: 'Fixture', type: 3,
        api: 'csp_Portable', ext: 'https://source.test/vod');
    final requests = <Uri>[];
    final resolved = await CspBridge.fetchDetail(site, original,
      (String url, {Map<String, String> headers = const {}, Duration? requestTimeout}) async {
        requests.add(Uri.parse(url));
        return r'{"list":[{"vod_id":"one","vod_name":"Fixture","vod_play_from":"真实来源","vod_play_url":"第08集$https://media.test/e8.mp4"}]}';
      });
    expect(requests, hasLength(1));
    expect(requests.single.host, 'source.test');
    expect(resolved.lines.length, 1);
    expect(resolved.lines.single.name, '真实来源');
    expect(resolved.lines.single.episodes.single.name, '第08集');
    expect(resolved.lines.single.episodes.single.url, 'https://media.test/e8.mp4');
  });
  test('failed imported detail never substitutes cached or pooled lines', () async {
    const site = CmsSite(key: 'original', name: 'Original', type: 3,
        api: 'csp_Portable', ext: 'https://original.invalid/vod');
    const cached = CmsVideo(id: 'one', title: 'Fixture', lines: [
      CmsLine(name: 'Old unrelated line', episodes: [
        CmsEpisode(name: '1', url: 'https://foreign.invalid/one.mp4'),
      ]),
    ]);
    final requests = <Uri>[];
    final result = await CspBridge.fetchDetail(site, cached,
        (url, {headers = const {}, requestTimeout}) async {
      requests.add(Uri.parse(url));
      return '{"list":[]}';
    });
    expect(result.lines, isEmpty);
    expect(requests, hasLength(1));
    expect(requests.single.host, 'original.invalid');
  });
  test('HTML plugin website is not advertised as a JSON source adapter', () {
    const site = CmsSite(key: 'html', name: 'HTML', type: 3, api: 'csp_SixVGuard', ext: 'https://example.test/');
    expect(CspBridge.backendsForSite(site), isEmpty);
    expect(site.canBrowse, isFalse);
  });
  const episode=CmsEpisode(name:'Episode',url:'mmpaw://play?id=one');
  Future<Uri> local(String value) async => Uri.parse('http://127.0.0.1:1234/local.mp4');
  test('alternating qualities keep labels, headers and local playback routes',()async{
    final result=await SourcePlayback.decode({'parse':0,'url':['原画','catpaw://bundle/api/stream','高清','https://media.test/video.mp4'],
      'header':'{"Referer":"https://origin.test/"}', 'extra':{'audio':'https://media.test/audio.m4s'}},episode,localUrl:local,sourceHeaders:{'X-Source':'fixture'});
    expect(result.url,'http://127.0.0.1:1234/local.mp4');
    expect(result.variants.map((v)=>v.name),['原画','高清']);
    expect(result.variants.last.headers,{'X-Source':'fixture','Referer':'https://origin.test/'});
    expect(result.name,'Episode');
    expect(result.externalAudioUrl,'https://media.test/audio.m4s');
    expect(result.variants.last.externalAudioUrl,result.externalAudioUrl);
  });
  test('object alternatives select only network media and keep per-quality headers',()async{
    final result=await SourcePlayback.decode({'url':[
      {'name':'invalid','url':'file:///private/movie.mp4'},
      {'name':'HD','url':'https://media.test/hd.mp4','headers':{'X-Quality':'hd'}},
      {'name':'duplicate','url':'https://media.test/hd.mp4'},
    ]},episode,localUrl:local);
    expect(result.variants.length,1);
    expect(result.headers['X-Quality'],'hd');
    await expectLater(SourcePlayback.decode({'url':'file:///private/movie.mp4'},episode,localUrl:local),throwsFormatException);
    await expectLater(SourcePlayback.decode({'parse':1,'url':'https://media.test/page'},episode,localUrl:local),throwsFormatException);
  });
  test('inherited source credentials follow only the same playback origin', () async {
    final result = await SourcePlayback.decode({'url': [
      'https://source.test/video.mp4', 'https://source.test:8443/video.mp4',
      'http://source.test/video.mp4', 'https://cdn.test/video.mp4',
      {'url': 'https://cdn.test/explicit.mp4', 'header': {'Authorization': 'CDN fixture'}},
    ]}, episode, localUrl: local, sourceOrigin: Uri.parse('https://source.test/rule.js'),
        sourceHeaders: {'Authorization': 'Source fixture', 'Cookie': 'session=fixture',
          'Cookie2': 'legacy=fixture', 'Proxy-Authorization': 'Proxy fixture', 'User-Agent': 'Fixture'});
    expect(result.variants.first.headers['Authorization'], 'Source fixture');
    for (final choice in result.variants.skip(1).take(3)) {
      expect(choice.headers, {'User-Agent': 'Fixture'});
    }
    expect(result.variants.last.headers, {'User-Agent': 'Fixture', 'Authorization': 'CDN fixture'});
  });
}
