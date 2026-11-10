import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/core/quark_drive.dart';

QuarkAccountSession _session(String id) => QuarkAccountSession(
      cookie: '__pus=fixture-$id; __puus=fixture-session',
      driveSt: 'fixture-drive-st',
      accountId: id,
      validatedAt: DateTime.utc(2026, 11, 8),
    );

class _Accounts extends QuarkAccountProvider {
  _Accounts()
      : super(
          readCredential: () async => '',
          writeCredential: (_) async {},
          httpClient: MockClient(
            (_) async => throw StateError('Unexpected account HTTP'),
          ),
        );
  QuarkAccountSession? current = _session('account-a');
  int revision = 0;
  @override
  int get generation => revision;
  void switchTo(String id) {
    current = _session(id);
    revision++;
  }

  @override
  Future<QuarkAccountSession> requireSession() async =>
      current ?? (throw StateError('authentication_required'));
  @override
  Future<void> assertCurrentSession(
    QuarkAccountSession session, {
    int? generation,
  }) async {
    if (generation != revision || !identical(session, current)) {
      throw StateError('account_changed');
    }
  }
}

http.Response _ok(Object data, {Map<String, Object>? metadata}) =>
    http.Response(
      jsonEncode({
        'status': 200,
        'code': 0,
        'data': data,
        if (metadata != null) 'metadata': metadata,
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

const _episode = CmsEpisode(
  name: '影片',
  url: 'mmquark://owned?account=account-a&fid=owned-1',
);
Matcher _error(String code) =>
    isA<QuarkDriveException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'stored validated session flows through owned listing and CmsClient playback',
    () async {
      final accountId =
          sha256.convert(utf8.encode('fixture-integration-account')).toString();
      var stored = QuarkAccountSession(
        cookie:
            '__pus=fixture-integration-account; __puus=fixture-before-refresh',
        driveSt: 'fixture-old-drive-ticket',
        accountId: accountId,
        validatedAt: DateTime.now().toUtc().subtract(
              const Duration(minutes: 10),
            ),
      ).toCredential();
      var writes = 0;
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        expect(request.followRedirects, isFalse);
        if (request.url.path == '/1/clouddrive/member') {
          expect(request.headers['Cookie'], contains('fixture-before-refresh'));
          return http.Response(
            jsonEncode({
              'status': 200,
              'code': 0,
              'data': {'member_type': 'NORMAL', 'total_capacity': 1000000},
            }),
            200,
            headers: {'set-cookie': '__puus=fixture-refreshed; Path=/; Secure'},
          );
        }
        expect(
          request.headers['Cookie'],
          '__pus=fixture-integration-account; __puus=fixture-refreshed',
        );
        switch (request.url.path) {
          case '/account/mobileinfo':
            expect(request.url.host, 'pan.quark.cn');
            return _ok({'serviceTicket': 'fixture-new-drive-ticket'});
          case '/1/clouddrive/file/sort':
            return _ok(
              {
                'list': [
                  {
                    'fid': 'owned-integration',
                    'file_name': '已存影片.mp4',
                    'file_type': 1,
                    'category': 1,
                  },
                ],
              },
              metadata: {'_total': 1},
            );
          case '/1/clouddrive/file/download':
            expect(jsonDecode(request.body), {
              'fids': ['owned-integration'],
            });
            return _ok([
              {
                'fid': 'owned-integration',
                'download_url':
                    'https://signed-cdn.example/owned.mp4?expires=fixture',
              },
            ]);
          case '/1/clouddrive/file/v2/play':
            return _ok({
              'video_list': [
                {
                  'resolution': 'high',
                  'video_info': {
                    'url': 'https://signed-cdn.example/owned.m3u8',
                  },
                },
              ],
            });
          default:
            throw StateError('Unexpected endpoint: ${request.url.path}');
        }
      });
      final accounts = QuarkAccountProvider(
        readCredential: () => stored,
        writeCredential: (value) {
          stored = value;
          writes++;
        },
        httpClient: client,
      );
      final drive = QuarkDriveClient(accounts: accounts, httpClient: client);
      final listed = await drive.listOwned();
      final episode = listed.videos.single.lines.single.episodes.single;
      expect(episode.needsSourceResolution, isTrue);
      expect(Uri.parse(episode.url).queryParameters['account'], accountId);
      final resolved = await CmsClient(quark: drive).resolveEpisodeForPlayback(
        const CmsSite(
          key: 'owned-quark',
          name: '我的夸克',
          type: 3,
          api: 'mmquark://owned',
          headers: {'Cookie': 'must-not-inherit=site-secret'},
        ),
        episode,
      );
      expect(
        resolved.url,
        'https://signed-cdn.example/owned.mp4?expires=fixture',
      );
      expect(resolved.variants.map((v) => v.name), ['原画', '高清']);
      expect(resolved.name, '已存影片.mp4');
      expect(
        resolved.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(writes, 1);
      expect(
        QuarkAccountSession.tryParseCredential(stored)!.driveSt,
        'fixture-new-drive-ticket',
      );
      expect(paths, [
        '/1/clouddrive/member',
        '/account/mobileinfo',
        '/1/clouddrive/file/sort',
        '/1/clouddrive/file/download',
        '/1/clouddrive/file/v2/play',
      ]);
    },
  );

  test(
    'owned directory uses authenticated PC protocol and account-bound page entries',
    () async {
      final accounts = _Accounts();
      final requests = <http.Request>[];
      final drive = QuarkDriveClient(
        accounts: accounts,
        httpClient: MockClient((request) async {
          requests.add(request);
          expect(request.method, 'GET');
          expect(request.url.origin, 'https://drive-pc.quark.cn');
          expect(request.url.path, '/1/clouddrive/file/sort');
          expect(request.url.queryParameters, {
            'pr': 'ucpro',
            'fr': 'pc',
            'uc_param_str': '',
            'pdir_fid': 'folder-1',
            '_page': '2',
            '_size': '50',
            '_fetch_total': '1',
            '_fetch_sub_dirs': '0',
            '_sort': 'file_type:asc,file_name:asc',
          });
          expect(request.followRedirects, isFalse);
          expect(request.headers['Cookie'], accounts.current!.cookie);
          expect(request.headers.containsKey('x-clouddrive-st'), isFalse);
          return _ok(
            {
              'list': [
                {'fid': 'nested', 'file_name': '子目录', 'file_type': 0},
                {
                  'fid': 'owned-1',
                  'file_name': '影片.mp4',
                  'file_type': 1,
                  'category': 1,
                  'size': 1073741824,
                  'thumbnail': 'https://images.example/thumb.webp',
                },
                {
                  'fid': 'notes',
                  'file_name': '说明.txt',
                  'file_type': 1,
                  'category': 3,
                },
              ],
            },
            metadata: {'_total': 101},
          );
        }),
      );
      final listing = await drive.listOwned(
        folder: 'mmquark://folder?account=account-a&fid=folder-1',
        page: 2,
      );
      expect(listing.page, 2);
      expect(listing.pageCount, 3);
      expect(listing.videos.map((v) => v.title), ['子目录', '影片.mp4']);
      expect(
        listing.videos.first.id,
        'mmquark://folder?account=account-a&fid=nested',
      );
      expect(listing.videos.first.lines, isEmpty);
      final movie = listing.videos.last;
      expect(movie.id, _episode.url);
      expect(movie.lines.single.episodes.single.url, movie.id);
      expect(movie.lines.single.episodes.single.headers, isEmpty);
      expect(movie.poster, 'https://images.example/thumb.webp');
      expect(movie.remarks, '1.0 GB');
      expect(requests, hasLength(1));
    },
  );

  test(
    'account switch rejects saved owned and folder IDs without playback requests',
    () async {
      final accounts = _Accounts()..switchTo('account-b');
      final drive = QuarkDriveClient(
        accounts: accounts,
        httpClient: MockClient(
          (_) async => throw StateError('No API may be sent'),
        ),
      );
      await expectLater(
        drive.resolve(_episode),
        throwsA(_error('account_mismatch')),
      );
      await expectLater(
        drive.listOwned(
          folder: 'mmquark://folder?account=account-a&fid=folder-1',
        ),
        throwsA(_error('account_mismatch')),
      );
    },
  );

  test(
    'share IDs and extra share tokens never become owned playback requests',
    () async {
      final drive = QuarkDriveClient(
        accounts: _Accounts(),
        httpClient: MockClient(
          (_) async => throw StateError('No API may be sent'),
        ),
      );
      for (final id in [
        'mmquark://share?fid=share-file',
        'https://pan.quark.cn/s/example',
        'mmquark://folder?account=account-a&fid=folder-1',
      ]) {
        await expectLater(
          drive.resolve(CmsEpisode(name: '分享', url: id)),
          throwsA(_error('owned_file_required')),
        );
      }
      await expectLater(
        drive.resolve(
          CmsEpisode(name: '分享', url: '${_episode.url}&stoken=share-token'),
        ),
        throwsFormatException,
      );
    },
  );

  test('HTTP and API 401 reject expired sessions', () async {
    for (final response in [
      http.Response('unauthorized', 401),
      http.Response(jsonEncode({'status': 401, 'code': 1}), 200),
    ]) {
      final drive = QuarkDriveClient(
        accounts: _Accounts(),
        httpClient: MockClient((_) async => response),
      );
      await expectLater(
        drive.listOwned(),
        throwsA(_error('authentication_required')),
      );
    }
  });

  test(
    'API redirects are refused without sending the account cookie to Location',
    () async {
      var requests = 0;
      final drive = QuarkDriveClient(
        accounts: _Accounts(),
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.host, 'drive-pc.quark.cn');
          expect(request.followRedirects, isFalse);
          expect(request.maxRedirects, 0);
          return http.Response(
            '',
            302,
            headers: {'location': 'https://unrelated.example/steal'},
          );
        }),
      );
      await expectLater(drive.listOwned(), throwsA(_error('redirect_refused')));
      expect(requests, 1);
    },
  );

  test(
    'download and transcode produce only actual available quality variants',
    () async {
      final accounts = _Accounts();
      final paths = <String>[];
      final drive = QuarkDriveClient(
        accounts: accounts,
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.followRedirects, isFalse);
          expect(request.headers['Cookie'], accounts.current!.cookie);
          paths.add(request.url.path);
          if (request.url.path.endsWith('/download')) {
            expect(jsonDecode(request.body), {
              'fids': ['owned-1'],
            });
            return _ok([
              {
                'fid': 'owned-1',
                'download_url': 'https://cdn.example/original.mp4?sign=fixture',
              },
            ]);
          }
          expect(request.url.path, '/1/clouddrive/file/v2/play');
          expect(jsonDecode(request.body), {
            'fid': 'owned-1',
            'resolutions': 'normal,low,high,super,2k,4k',
            'supports': 'fmp4,m3u8',
          });
          return _ok({
            'video_list': [
              {
                'resolution': 'super',
                'video_info': {
                  'url': 'https://cdn.example/super.m3u8',
                  'height': 1080,
                },
              },
              {
                'resolution': 'high',
                'video_info': {
                  'url': 'https://cdn.example/high.m3u8',
                  'height': 720,
                },
              },
              {'resolution': '4k', 'video_info': {}},
              {
                'resolution': '2k',
                'available': false,
                'video_info': {'url': 'https://cdn.example/pending.m3u8'},
              },
              {
                'resolution': 'low',
                'video_info': {'url': 'https://cdn.example/thumb.webp'},
              },
            ],
          });
        }),
      );
      final result = await drive.resolve(_episode);
      expect(paths, [
        '/1/clouddrive/file/download',
        '/1/clouddrive/file/v2/play',
      ]);
      expect(result.name, '影片');
      expect(result.variants.map((v) => v.name), ['原画', '超清', '高清']);
      expect(result.url, 'https://cdn.example/original.mp4?sign=fixture');
      for (final choice in [result, ...result.variants]) {
        expect(choice.headers['Referer'], 'https://pan.quark.cn/');
        expect(
          choice.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('cookie')),
        );
        expect(
          choice.headers.values.join(),
          isNot(contains('fixture-drive-st')),
        );
      }
    },
  );

  test(
    'unavailable original still allows returned transcode without fake original',
    () async {
      final drive = QuarkDriveClient(
        accounts: _Accounts(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/download'))
            return http.Response('unavailable', 403);
          return _ok({
            'video_list': [
              {
                'resolution': 'high',
                'video_info': {'url': 'https://cdn.example/high.m3u8'},
              },
            ],
          });
        }),
      );
      final result = await drive.resolve(_episode);
      expect(result.variants.map((v) => v.name), ['高清']);
    },
  );

  test(
    'preview images and missing video URLs are never a playable fallback',
    () async {
      final drive = QuarkDriveClient(
        accounts: _Accounts(),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/download'))
            return _ok([
              {'preview_url': 'https://cdn.example/image.webp'},
            ]);
          return _ok({
            'video_list': [
              {
                'resolution': '4k',
                'video_info': {'url': 'https://cdn.example/image.webp'},
              },
            ],
          });
        }),
      );
      await expectLater(
        drive.resolve(_episode),
        throwsA(_error('unavailable')),
      );
    },
  );

  test('late directory response is rejected after account switching', () async {
    final accounts = _Accounts();
    final started = Completer<void>(), response = Completer<http.Response>();
    final drive = QuarkDriveClient(
      accounts: accounts,
      httpClient: MockClient((_) async {
        started.complete();
        return response.future;
      }),
    );
    final pending = drive.listOwned();
    await started.future;
    accounts.switchTo('account-b');
    final rejected = expectLater(pending, throwsStateError);
    response.complete(_ok({'list': []}));
    await rejected;
  });

  test(
    'late playback response cannot cross A to B to A account generations',
    () async {
      final accounts = _Accounts();
      final started = Completer<void>(), response = Completer<http.Response>();
      var requests = 0;
      final drive = QuarkDriveClient(
        accounts: accounts,
        httpClient: MockClient((_) async {
          requests++;
          started.complete();
          return response.future;
        }),
      );
      final pending = drive.resolve(_episode);
      await started.future;
      accounts.switchTo('account-b');
      accounts.switchTo('account-a');
      final rejected = expectLater(pending, throwsStateError);
      response.complete(
        _ok([
          {'download_url': 'https://cdn.example/stale.mp4'},
        ]),
      );
      await rejected;
      expect(requests, 1);
    },
  );

  test(
    'wogg share resolution keeps original and actual 4K variants without leaking cookies',
    () async {
      final accounts = _Accounts();
      final client = MockClient((request) async {
        switch (request.url.path) {
          case '/1/clouddrive/share/sharepage/token':
            return _ok({'stoken': 'share-stoken-1'});
          case '/1/clouddrive/share/sharepage/detail':
            return _ok({
              'list': [
                {
                  'fid': 'share-fid-178',
                  'file_name': '斗罗大陆2.S01E178.2160p.HDR.mp4',
                  'file': true,
                  'file_type': 1,
                  'category': 1,
                  'share_fid_token': 'fid-token-178',
                },
              ],
            });
          case '/1/clouddrive/file/sort':
            return _ok({
              'list': [
                {
                  'fid': 'temp-dir-fid',
                  'file_name': '0000temp',
                  'dir': true,
                  'file_type': 0,
                },
              ],
            });
          case '/1/clouddrive/share/sharepage/save':
            return _ok({'task_id': 'task-save-178'});
          case '/1/clouddrive/task':
            return _ok({
              'status': 2,
              'save_as': {
                'save_as_top_fids': ['saved-fid-178'],
              },
            });
          case '/1/clouddrive/file/v2/play':
            return _ok({
              'video_list': [
                {
                  'resolution': 'super',
                  'video_info': {'url': 'https://cdn.example/1080p.m3u8'},
                },
                {
                  'resolution': '4k',
                  'video_info': {'url': 'https://cdn.example/4k.m3u8'},
                },
              ],
            });
          case '/1/clouddrive/file/download':
            return _ok([
              {
                'fid': 'saved-fid-178',
                'download_url': 'https://cdn.example/raw-4k.mp4',
              },
            ]);
          default:
            throw StateError('Unexpected path: ${request.url.path}');
        }
      });
      final episodes = await QuarkDriveClient.listPublicShareEpisodes(
        'https://pan.quark.cn/s/abcdef123456',
        httpClient: client,
      );
      expect(episodes, hasLength(1));
      expect(episodes.single.needsSourceResolution, isTrue);
      final drive = QuarkDriveClient(accounts: accounts, httpClient: client);
      final resolved = await CmsClient(quark: drive).resolveEpisodeForPlayback(
        const CmsSite(key: 'wogg', name: '玩偶哥哥', type: 3, api: 'csp_Wogg'),
        episodes.single,
      );
      expect(resolved.url, 'https://cdn.example/raw-4k.mp4');
      expect(resolved.variants.map((v) => v.name), ['原画', '4K', '超清']);
      expect(resolved.headers['Cookie'], isNull);
    },
  );
}
