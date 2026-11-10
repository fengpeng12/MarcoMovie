// Synthetic protocol responses only. These tests do not authenticate an account,
// call a live share, modify cloud storage, or establish iPhone playback success.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cloud_share.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';
import 'package:marco_movie/core/models.dart';

http.Response response(Object value,
        {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(value), 200, headers: {
      'content-type': 'application/json; charset=utf-8',
      ...headers
    });

Map<String, Object> ucFile(String id, {String? name, int size = 4294967296}) =>
    {
      'fid': id,
      'file_name': name ?? '$id.2160p.mkv',
      'file_type': 1,
      'category': 1,
      'size': size,
      'share_fid_token': 'temporary-file-$id',
    };

Map<String, Object> baiduFile(String id) => {
      'fs_id': id,
      'server_filename': '原始_$id.2160p.mkv',
      'isdir': 0,
      'category': 1,
      'size': 8589934592,
      'path': '/原始_$id.2160p.mkv',
    };

void main() {
  test('provider recognizers reject other hosts and embedded credentials', () {
    expect(
        CloudShareClient.supportsShare('https://drive.uc.cn/s/abcdef'), isTrue);
    expect(
        CloudShareClient.supportsShare('https://fast.uc.cn/s/abcdef'), isTrue);
    expect(
        CloudShareClient.supportsShare(
            'https://pan.baidu.com/s/1abcde?pwd=1234'),
        isTrue);
    expect(CloudShareClient.supportsShare('https://pan.quark.cn/s/abcdef'),
        isFalse);
    expect(
        CloudShareClient.supportsShare(
            'https://drive.uc.cn.evil.test/s/abcdef'),
        isFalse);
    expect(CloudShareClient.supportsShare('https://x@drive.uc.cn/s/abcdef'),
        isFalse);
    expect(CloudShareClient.supportsEpisode('mmcloud://ali?fid=1'), isFalse);
    expect(CloudShareClient.supportsEpisode('mmcloud://baidu?fid=1'), isTrue);
  });

  test('UC walks all pages and directories, preserves names and true bytes',
      () async {
    final requestedPages = <String>[];
    final client = CloudShareClient(
        credentialReader: (_) async => '',
        client: MockClient((request) async {
          expect(request.url.host, 'pc-api.uc.cn');
          expect(request.headers.containsKey('cookie'), isFalse);
          if (request.url.path.endsWith('/token')) {
            expect(jsonDecode(request.body),
                {'pwd_id': 'abcdef', 'passcode': '1234'});
            return response({
              'status': 200,
              'code': 0,
              'data': {'stoken': 'temporary-share'}
            });
          }
          final dir = request.url.queryParameters['pdir_fid'];
          final page = request.url.queryParameters['_page'];
          requestedPages.add('$dir:$page');
          final rows = dir == '0'
              ? page == '1'
                  ? List.generate(100, (index) => ucFile('$index'))
                  : [
                      {'fid': 'folder', 'file_name': '原始目录', 'file_type': 0}
                    ]
              : [
                  ucFile('nested', name: '第101集.HDR.mkv'),
                  {'fid': 'folder', 'file_name': 'cycle', 'file_type': 0}
                ];
          return response({
            'status': 200,
            'code': 0,
            'metadata': {'_total': dir == '0' ? 101 : 2},
            'data': {'list': rows}
          });
        }));
    final episodes =
        await client.listShare('https://drive.uc.cn/s/abcdef?pwd=1234');
    expect(episodes, hasLength(101));
    expect(requestedPages, ['0:1', '0:2', 'folder:1']);
    expect(episodes.last.name, '第101集.HDR.mkv');
    expect(episodes.last.playbackSession['sizeBytes'], 4294967296);
    expect(episodes.last.playbackSession['path'], '原始目录/第101集.HDR.mkv');
    expect(episodes.last.url, isNot(contains('temporary')));
    expect(Uri.parse(episodes.last.url).queryParameters['fid'], 'nested');
  });

  test(
      'UC refreshes tokens and uses original fast share download with no account cookie',
      () async {
    var tokenCalls = 0;
    var downloadCalls = 0;
    final client = CloudShareClient(
        credentialReader: (_) async => throw StateError('No account needed'),
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.headers.containsKey('cookie'), isFalse);
          if (request.url.path.endsWith('/token')) {
            tokenCalls++;
            return response({
              'code': 0,
              'data': {'stoken': 'fresh-$tokenCalls'}
            });
          }
          if (request.url.path.endsWith('/detail')) {
            return response({
              'code': 0,
              'data': {
                'list': [ucFile('one')]
              }
            });
          }
          downloadCalls++;
          expect(request.url.path, '/1/clouddrive/file/download');
          expect(request.url.queryParameters,
              {'entry': 'ft', 'fr': 'pc', 'pr': 'UCBrowser'});
          expect(request.headers['referer'], 'https://fast.uc.cn/');
          expect(jsonDecode(request.body), {
            'fids': ['one'],
            'pwd_id': 'abcdef',
            'stoken': 'fresh-2',
            'fids_token': ['temporary-file-one']
          });
          return response({
            'code': 0,
            'data': [
              {'download_url': 'https://media.test/original.mkv'}
            ]
          });
        }));
    final episodes = await client.listShare('https://drive.uc.cn/s/abcdef');
    final resolved = await client.resolve(episodes.single);
    expect(tokenCalls, 2);
    expect(downloadCalls, 1);
    expect(resolved.url, 'https://media.test/original.mkv');
    expect(resolved.variants.single.name, '原画');
    expect(resolved.headers.containsKey('Cookie'), isFalse);
    expect(resolved.playbackSession['sizeBytes'], 4294967296);
  });

  test('UC fails explicitly without returning substitute lines or thumbnails',
      () async {
    final client = CloudShareClient(
        credentialReader: (_) async => '',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            return response({
              'data': {'stoken': 'fresh'},
              'code': 0
            });
          }
          if (request.url.path.endsWith('/detail')) {
            return response({
              'data': {
                'list': [ucFile('one')]
              },
              'code': 0
            });
          }
          return response({
            'data': [
              {'download_url': 'https://media.test/preview.webp'}
            ],
            'code': 0
          });
        }));
    final episodes = await client.listShare('https://drive.uc.cn/s/abcdef');
    await expectLater(client.resolve(episodes.single), throwsFormatException);
  });

  test('UC missing file membership never requests playback', () async {
    final client = CloudShareClient(
        credentialReader: (_) async => '',
        client: MockClient((request) async {
          expect(request.url.path, isNot(endsWith('/download')));
          return request.url.path.endsWith('/token')
              ? response({
                  'data': {'stoken': 'fresh'},
                  'code': 0
                })
              : response({
                  'data': {'list': []},
                  'code': 0
                });
        }));
    final episode = CmsEpisode(
        name: 'missing',
        url: Uri(scheme: 'mmcloud', host: 'uc', queryParameters: {
          'share': 'https://drive.uc.cn/s/abcdef',
          'fid': 'gone'
        }).toString());
    await expectLater(client.resolve(episode), throwsFormatException);
  });

  test(
      'repeated pagination is reported instead of silently truncating the share',
      () async {
    var pages = 0;
    final client = CloudShareClient(
        credentialReader: (_) async => '',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            return response({
              'data': {'stoken': 'fresh'},
              'code': 0
            });
          }
          pages++;
          return response({
            'data': {'list': List.generate(100, (i) => ucFile('$i'))},
            'code': 0
          });
        }));
    await expectLater(client.listShare('https://drive.uc.cn/s/abcdef'),
        throwsFormatException);
    expect(pages, 2);
  });

  test('Baidu verifies passcode and walks original nested share directories',
      () async {
    final dirs = <String?>[];
    final client = CloudShareClient(
        credentialReader: (_) async => '',
        client: MockClient((request) async {
          expect(request.headers['cookie'] ?? '', isNot(contains('BDUSS')));
          if (request.url.path.startsWith('/s/')) {
            return http.Response('share page', 200);
          }
          if (request.url.path == '/share/verify') {
            expect(request.url.queryParameters['surl'], 'abcde');
            expect(Uri.splitQueryString(request.body)['pwd'], '1234');
            return response({'errno': 0, 'randsk': 'temporary-share-key'});
          }
          dirs.add(request.url.queryParameters['dir']);
          expect(request.headers['cookie'], 'BDCLND=temporary-share-key');
          return response({
            'errno': 0,
            'uk': 'owner',
            'share_id': 'share-id',
            'list': request.url.queryParameters['root'] == '1'
                ? [
                    {
                      'fs_id': 'folder',
                      'isdir': 1,
                      'server_filename': '4K目录',
                      'path': '/sharelinkowner-root/4K目录'
                    }
                  ]
                : [baiduFile('one')]
          });
        }));
    final episodes =
        await client.listShare('https://pan.baidu.com/s/1abcde?pwd=1234');
    expect(episodes.single.name, '原始_one.2160p.mkv');
    expect(episodes.single.playbackSession['sizeBytes'], 8589934592);
    expect(dirs, [null, '/sharelinkowner-folder/4K目录']);
    expect(episodes.single.url, isNot(contains('temporary-share-key')));
  });

  test(
      'Baidu original share DLNA signing uses validated current account and no cloud writes',
      () async {
    final now = DateTime.utc(2026, 11, 10);
    final methods = <String>[];
    final hosts = <String>[];
    final client = CloudShareClient(
        clock: () => now,
        credentialReader: (_) async =>
            'BDUSS=synthetic-bduss; STOKEN=synthetic-stoken',
        client: MockClient((request) async {
          methods.add(request.method);
          hosts.add(request.url.host);
          expect(request.followRedirects, isFalse);
          if (request.url.path.startsWith('/s/')) {
            return http.Response('page', 200);
          }
          if (request.url.host == 'mbd.baidu.com') {
            expect(request.headers['cookie'],
                'BDUSS=synthetic-bduss; STOKEN=synthetic-stoken');
            return response({
              'errno': 0,
              'data': {
                'fields': {'uid': 'synthetic-account-uid'}
              }
            });
          }
          if (request.url.queryParameters['origin'] == 'dlna') {
            final timestamp = '${now.millisecondsSinceEpoch}';
            final expected = sha1
                .convert(utf8.encode(
                    '${sha1.convert(utf8.encode('synthetic-bduss'))}synthetic-account-uid'
                    'ebrcUYiuxaZv2XGu7KIYKxUrqfnOfpDF$timestamp'
                    '73CED981D0F186D12BC18CAE1684FFD5|VSRCQTF6W'
                    '11.30.2ae5821440fab5e1a61a025f014bd8972'))
                .toString();
            expect(request.url.queryParameters['rand'], expected);
            expect(request.url.queryParameters['shareid'], 'share-id');
            expect(request.url.queryParameters['uk'], 'owner');
            expect(request.url.queryParameters['fid'], 'one');
            return response({
              'errno': 0,
              'list': [
                {'fs_id': 'one', 'dlink': 'https://media.test/baidu.mkv'}
              ]
            });
          }
          return response({
            'errno': 0,
            'uk': 'owner',
            'share_id': 'share-id',
            'list': [baiduFile('one')]
          });
        }));
    final episodes = await client.listShare('https://pan.baidu.com/s/1abcde');
    final resolved = await client.resolve(episodes.single);
    expect(resolved.url, 'https://media.test/baidu.mkv');
    expect(resolved.headers.containsKey('Cookie'), isFalse);
    expect(resolved.variants.single.headers.containsKey('Cookie'), isFalse);
    expect(methods.every((method) => method == 'GET'), isTrue);
    expect(hosts.toSet(), {'pan.baidu.com', 'mbd.baidu.com'});
  });

  test('Baidu incomplete legacy QR ticket is not treated as an account',
      () async {
    final client = CloudShareClient(
        credentialReader: (_) async => 'bduss=unexchanged-qr-ticket',
        client: MockClient((request) async {
          expect(request.url.host, 'pan.baidu.com');
          expect(request.url.queryParameters['origin'], isNull);
          if (request.url.path.startsWith('/s/')) {
            return http.Response('page', 200);
          }
          return response({
            'errno': 0,
            'uk': 'owner',
            'share_id': 'share-id',
            'list': [baiduFile('one')]
          });
        }));
    final episodes = await client.listShare('https://pan.baidu.com/s/1abcde');
    await expectLater(client.resolve(episodes.single), throwsFormatException);
  });

  test('Baidu changing account while fetching identity cancels before DLNA',
      () async {
    var account = 'BDUSS=first; STOKEN=first';
    final client = CloudShareClient(
        credentialReader: (_) async => account,
        client: MockClient((request) async {
          if (request.url.path.startsWith('/s/')) {
            return http.Response('page', 200);
          }
          if (request.url.host == 'mbd.baidu.com') {
            account = 'BDUSS=second; STOKEN=second';
            return response({
              'errno': 0,
              'data': {
                'fields': {'uid': 'first'}
              }
            });
          }
          expect(request.url.queryParameters['origin'], isNull);
          return response({
            'errno': 0,
            'uk': 'owner',
            'share_id': 'share-id',
            'list': [baiduFile('one')]
          });
        }));
    final episodes = await client.listShare('https://pan.baidu.com/s/1abcde');
    await expectLater(client.resolve(episodes.single), throwsFormatException);
  });

  test('cross-provider references and redirects never leak account credentials',
      () async {
    var calls = 0;
    final client = CloudShareClient(
        credentialReader: (_) async => 'BDUSS=secret; STOKEN=secret',
        client: MockClient((request) async {
          calls++;
          return http.Response('', 302,
              headers: {'location': 'https://evil.test/collect'});
        }));
    await expectLater(
        client.resolve(CmsEpisode(
            name: 'mixed',
            url: Uri(scheme: 'mmcloud', host: 'baidu', queryParameters: {
              'share': 'https://drive.uc.cn/s/abcdef',
              'fid': 'one'
            }).toString())),
        throwsFormatException);
    expect(calls, 0);
    await expectLater(client.listShare('https://pan.baidu.com/s/1abcde'),
        throwsFormatException);
    expect(calls, 1);
  });

  test(
      'large nested shares have a global request limit and are never silently truncated',
      () async {
    var calls = 0;
    final client = CloudShareClient(
        credentialReader: (_) async => '',
        client: MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/token')) {
            return response({
              'data': {'stoken': 'fresh'},
              'code': 0
            });
          }
          return response({
            'data': {
              'list': [
                {'fid': 'folder-$calls', 'file_name': 'next', 'file_type': 0},
              ]
            },
            'code': 0
          });
        }));
    await expectLater(client.listShare('https://drive.uc.cn/s/abcdef'),
        throwsFormatException);
    expect(calls, 120);
  });

  test(
      'UC guest restriction reuses logged-in account and returns an independent range proxy',
      () async {
    final requests = <http.Request>[];
    final cloud = CloudShareClient(
        credentialReader: (_) async =>
            '__pus=synthetic-account; __puus=expired',
        mediaClientFactory: () => MockClient((request) async {
              expect(
                  request.url.toString(), 'https://video.uc.cn/original.mkv');
              expect(request.headers['cookie'],
                  '__pus=synthetic-account; __puus=refreshed');
              expect(request.headers['range'], 'bytes=1-3');
              expect(request.followRedirects, isFalse);
              return http.Response.bytes([1, 2, 3], 206,
                  headers: {
                    'content-type': 'video/x-matroska',
                    'content-range': 'bytes 1-3/8589934592'
                  });
            }),
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/token')) {
            return response({
              'code': 0,
              'data': {'stoken': 'fresh'}
            });
          }
          if (request.url.path.endsWith('/detail')) {
            return response({
              'code': 0,
              'data': {
                'list': [ucFile('one', size: 8589934592)]
              }
            });
          }
          if (request.url.path.endsWith('/config')) {
            expect(request.headers['cookie'], '__pus=synthetic-account');
            return response({'code': 0, 'data': {}},
                headers: {'set-cookie': '__puus=refreshed; Path=/; Secure'});
          }
          if (!request.headers.containsKey('cookie'))
            return response({'code': 23018, 'status': 403});
          expect(jsonDecode(request.body)['fids'], ['one']);
          return response({
            'code': 0,
            'data': [
              {
                'fid': 'one',
                'size': 8589934592,
                'download_url': 'https://video.uc.cn/original.mkv'
              }
            ]
          });
        }));
    final list = await cloud.listShare('https://drive.uc.cn/s/abcdef');
    final result = await cloud.resolve(list.single);
    final lease = result.playbackSession['cloudMediaLease'] as CloudMediaLease;
    try {
      expect(
          identical(
              lease, result.variants.single.playbackSession['cloudMediaLease']),
          isTrue);
      expect(result.url, startsWith('http://127.0.0.1:'));
      expect(result.headers.containsKey('Cookie'), isFalse);
      expect(result.playbackSession['sizeBytes'], 8589934592);
      cloud.close();
      final media = await http
          .get(Uri.parse(result.url), headers: {'Range': 'bytes=1-3'});
      expect(media.statusCode, 206);
      expect(media.bodyBytes, [1, 2, 3]);
      expect(media.headers['content-range'], 'bytes 1-3/8589934592');
      expect(
          requests.any((request) =>
              request.url.path.contains('save') ||
              request.url.path.contains('delete')),
          isFalse);
    } finally {
      await lease.close();
    }
  });

  test(
      'UC login fallback rejects an untrusted media origin without exposing cookies',
      () async {
    final cloud = CloudShareClient(
        credentialReader: (_) async => '__pus=account',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/token'))
            return response({
              'code': 0,
              'data': {'stoken': 'fresh'}
            });
          if (request.url.path.endsWith('/detail'))
            return response({
              'code': 0,
              'data': {
                'list': [ucFile('one')]
              }
            });
          if (request.url.path.endsWith('/config'))
            return response({'code': 0});
          if (!request.headers.containsKey('cookie'))
            return response({'code': 31001});
          return response({
            'code': 0,
            'data': [
              {'download_url': 'https://evil.test/file.mkv'}
            ]
          });
        }));
    final list = await cloud.listShare('https://drive.uc.cn/s/abcdef');
    await expectLater(cloud.resolve(list.single), throwsFormatException);
  });

  test(
      'Baidu anonymous directory restriction reuses existing account on the same request',
      () async {
    var anonymous = 0;
    var authenticated = 0;
    final cloud = CloudShareClient(
        credentialReader: (_) async => 'BDUSS=account; STOKEN=session',
        client: MockClient((request) async {
          expect(request.url.host, 'pan.baidu.com');
          if (request.url.path.startsWith('/s/'))
            return http.Response('page', 200);
          if (!(request.headers['cookie'] ?? '').contains('BDUSS=')) {
            anonymous++;
            return response({'errno': -6});
          }
          authenticated++;
          return response({
            'errno': 0,
            'uk': 'owner',
            'share_id': 'share-id',
            'list': [baiduFile('one')]
          });
        }));
    final list = await cloud.listShare('https://pan.baidu.com/s/1abcde');
    expect(list.single.name, '原始_one.2160p.mkv');
    expect(anonymous, 1);
    expect(authenticated, 1);
    expect(list.single.url, isNot(contains('account')));
  });

  test(
      'UC only uses the guest cookie bound to the exact fast-download response',
      () async {
    var downloadCount = 0;
    final client = CloudShareClient(
        credentialReader: (_) async => '__pus=account; __puus=account',
        client: MockClient((request) async {
          expect(request.headers.containsKey('cookie'), isFalse);
          if (request.url.path.endsWith('/token')) {
            return response({
              'data': {'stoken': 'fresh'},
              'code': 0
            }, headers: {
              'set-cookie':
                  '__pugs=unrelated-old; Path=/, __pus=account; Path=/'
            });
          }
          if (request.url.path.endsWith('/detail')) {
            return response({
              'data': {
                'list': [ucFile('one')]
              },
              'code': 0
            });
          }
          expect(
              request.headers['user-agent'], contains('uc-cloud-drive/2.5.20'));
          expect(request.headers['sec-ch-ua'], contains('Chromium'));
          downloadCount++;
          return response({
            'code': 0,
            'data': [
              {
                'fid': 'one',
                'size': 4294967296,
                'download_url': 'https://media.test/one-$downloadCount.mkv'
              }
            ]
          }, headers: {
            if (downloadCount == 1)
              'set-cookie':
                  '__pugs=fresh-guest; Path=/; Secure, __pus=account-secret; Path=/, __puus=account-secret-2; Path=/'
          });
        }));
    final episodes = await client.listShare('https://drive.uc.cn/s/abcdef');
    final first = await client.resolve(episodes.single);
    expect(first.url, 'https://media.test/one-1.mkv');
    expect(first.headers['Cookie'], '__pugs=fresh-guest');
    expect(first.variants.single.headers['Cookie'], '__pugs=fresh-guest');
    expect(first.headers.values.join(), isNot(contains('account-secret')));
    expect(first.playbackSession.toString(), isNot(contains('fresh-guest')));
    final second = await client.resolve(episodes.single);
    expect(second.url, 'https://media.test/one-2.mkv');
    expect(second.headers.containsKey('Cookie'), isFalse);
  });

  test('UC placeholder videos and wrong file identity are rejected', () async {
    for (final badRow in [
      {'fid': 'different'},
      {'size': 1024},
      {'md5': 'ffc6341c056de41cf4ab95343d9c22fe'},
    ]) {
      final client = CloudShareClient(
          credentialReader: (_) async => '',
          client: MockClient((request) async {
            if (request.url.path.endsWith('/token')) {
              return response({
                'data': {'stoken': 'fresh'},
                'code': 0
              });
            }
            if (request.url.path.endsWith('/detail')) {
              return response({
                'data': {
                  'list': [ucFile('one')]
                },
                'code': 0
              });
            }
            return response({
              'code': 0,
              'data': [
                {'download_url': 'https://media.test/ad.mp4', ...badRow}
              ]
            });
          }));
      final episodes = await client.listShare('https://drive.uc.cn/s/abcdef');
      await expectLater(client.resolve(episodes.single), throwsFormatException);
    }
  });

  test('cancellation prevents requests and discards a late playback result',
      () async {
    var cancelled = true;
    var calls = 0;
    final client = CloudShareClient(
        isCancelled: () => cancelled,
        credentialReader: (_) async => '',
        client: MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/token')) {
            return response({
              'data': {'stoken': 'fresh'},
              'code': 0
            });
          }
          if (request.url.path.endsWith('/detail')) {
            return response({
              'data': {
                'list': [ucFile('one')]
              },
              'code': 0
            });
          }
          cancelled = true;
          return response({
            'code': 0,
            'data': [
              {'download_url': 'https://media.test/file.mkv'}
            ]
          });
        }));
    await expectLater(client.listShare('https://drive.uc.cn/s/abcdef'),
        throwsFormatException);
    expect(calls, 0);
    cancelled = false;
    final episodes = await client.listShare('https://drive.uc.cn/s/abcdef');
    await expectLater(client.resolve(episodes.single), throwsFormatException);
  });
}
