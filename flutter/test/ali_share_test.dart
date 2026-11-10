import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../src/core/ali_share.dart';
import '../src/core/models.dart';

http.Response jsonResponse(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json'});

CmsEpisode reference(
        {String share = 'https://www.alipan.com/s/share1',
        String fid = 'video1'}) =>
    CmsEpisode(
      name: '第01集',
      url: Uri(
          scheme: 'mmcloud',
          host: 'ali',
          queryParameters: {'share': share, 'fid': fid}).toString(),
    );

void main() {
  test(
      'share parsing accepts exact provider origins and validates nested folders',
      () {
    expect(
        AliShareClient.supportsShare(
            'https://www.alipan.com/s/ABC/folder/FID?pwd=1234'),
        isTrue);
    expect(AliShareClient.supportsShare('https://www.aliyundrive.com/s/ABC'),
        isTrue);
    for (final value in [
      'https://www.alipan.com.attacker.test/s/ABC',
      'https://attacker.test/?next=https://www.alipan.com/s/ABC',
      'https://user@www.alipan.com/s/ABC',
      'https://www.alipan.com:8080/s/ABC',
      'https://www.alipan.com/s/ABC/folder/',
      'https://www.alipan.com/s/ABC/other/FID',
    ]) {
      expect(AliShareClient.supportsShare(value), isFalse, reason: value);
    }
  });

  test(
      'lists share pagination and nested videos without reading account credentials',
      () async {
    final requests = <http.Request>[];
    final client = AliShareClient(
        credentialReader: (_) async =>
            throw StateError('Listing must be anonymous'),
        client: MockClient((request) async {
          requests.add(request);
          final body = jsonDecode(request.body) as Map;
          if (request.url.path.endsWith('get_share_token')) {
            expect(body, {'share_id': 'share1', 'share_pwd': '1234'});
            return jsonResponse({'share_token': 'share-secret'});
          }
          expect(request.headers['x-share-token'], 'share-secret');
          expect(request.headers.containsKey('authorization'), isFalse);
          if (body['parent_file_id'] == 'root' && body['marker'] == null) {
            return jsonResponse({
              'items': [
                {'file_id': 'folder1', 'name': '第一季', 'type': 'folder'}
              ],
              'next_marker': 'next'
            });
          }
          if (body['parent_file_id'] == 'folder1') {
            return jsonResponse({
              'items': [
                {
                  'file_id': 'video1',
                  'name': '01.mkv',
                  'type': 'file',
                  'category': 'video'
                },
                {
                  'file_id': 'text1',
                  'name': 'readme.txt',
                  'type': 'file',
                  'category': 'doc'
                },
                {'file_id': 'root', 'name': 'cycle', 'type': 'folder'},
              ]
            });
          }
          expect(body['marker'], 'next');
          return jsonResponse({
            'items': [
              {'file_id': 'video2', 'name': '02.mp4', 'type': 'file'}
            ]
          });
        }));
    final episodes =
        await client.listShare('https://www.alipan.com/s/share1?pwd=1234');
    expect(episodes.map((e) => e.name), ['第一季/01.mkv', '02.mp4']);
    expect(
        episodes.every((e) => AliShareClient.supportsEpisode(e.url)), isTrue);
    expect(episodes.map((e) => e.url).join(), isNot(contains('share-secret')));
    expect(requests.length, 4);
    expect(
        requests.any((r) =>
            r.url.path.contains('copy') || r.url.path.contains('create')),
        isFalse);
  });

  test('repeated pagination fails instead of returning an incomplete share',
      () async {
    final client = AliShareClient(
        credentialReader: (_) async => '',
        client: MockClient((request) async => jsonResponse(
            request.url.path.endsWith('get_share_token')
                ? {'share_token': 'secret'}
                : {'items': [], 'next_marker': 'same'})));
    await expectLater(client.listShare('https://www.alipan.com/s/share1'),
        throwsA(isA<AliShareException>()));
  });

  test('missing login is rejected before any playback network request',
      () async {
    final client = AliShareClient(
        credentialReader: (_) async => '',
        client: MockClient((_) async => throw StateError('No network')));
    await expectLater(
        client.resolve(reference()),
        throwsA(isA<AliShareException>()
            .having((e) => e.message, 'message', contains('登录'))));
  });

  test(
      'copies selected file to dedicated folder and returns original plus measured qualities',
      () async {
    final server = _AliServer();
    var credential = 'ali_token=initial-refresh';
    final client = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => credential,
        credentialWriter: (provider, value) async {
          expect(provider, 'ali');
          credential = value;
        });
    final played = await client.resolve(reference());
    expect(
        played.url, 'https://media.invalid/original.mp4?signature=media');
    expect(played.variants.map((e) => e.name), ['原画', '2160P', '1080P']);
    expect(played.headers,
        isNot(containsPair('Authorization', 'Bearer account-secret')));
    expect(credential, 'ali_token=rotated-refresh');
    final copy =
        server.requests.singleWhere((r) => r.url.path.endsWith('/batch'));
    final body = (jsonDecode(copy.body)['requests'][0]['body']) as Map;
    expect(body['file_id'], 'video1');
    expect(body['to_parent_file_id'], 'source-folder');
    expect(body['to_drive_id'], 'resource-drive');
    expect(body['auto_rename'], isTrue);
    expect(copy.headers['x-share-token'], 'share-secret');
    expect(copy.headers['authorization'], 'Bearer account-secret');
    expect(
        server.requests.any((r) => r.body.contains('/file/delete')), isFalse);
    await client.resolve(reference());
    expect(
        server.requests.where((r) => r.url.path.endsWith('/batch')).length, 1);
    expect(
        server.requests
            .where((r) => r.url.path.endsWith('/account/token'))
            .length,
        1);
  });

  test('creates dedicated folder without replacing existing content', () async {
    final server = _AliServer(existingFolder: false);
    final client = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => 'refresh');
    await client.resolve(reference());
    final creation =
        server.requests.firstWhere((r) => r.url.path == '/v2/file/create');
    expect(jsonDecode(creation.body), {
      'drive_id': 'resource-drive',
      'parent_file_id': 'root',
      'name': 'MarcoMovie分享播放',
      'type': 'folder',
      'check_name_mode': 'refuse',
    });
    expect(
        server.requests.any((r) =>
            r.url.path.contains('delete') || r.body.contains('/file/delete')),
        isFalse);
  });

  test('unavailable original uses actual ready quality and never labels it 4K',
      () async {
    final server = _AliServer(originalStatus: 403, highResolution: false);
    final client = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => 'refresh');
    final played = await client.resolve(reference());
    expect(played.variants.map((e) => e.name), ['1080P']);
    expect(played.url, 'https://media.invalid/1080.m3u8');
  });

  test(
      'copy denial cannot continue with source file id or fabricated video URL',
      () async {
    final server = _AliServer(copyDenied: true);
    final client = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => 'refresh');
    await expectLater(
        client.resolve(reference()), throwsA(isA<AliShareException>()));
    expect(server.requests.any((r) => r.url.path.endsWith('get_download_url')),
        isFalse);
  });

  test('account changes do not reuse another account saved file', () async {
    final server = _AliServer();
    var credential = 'first';
    final client = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => credential);
    await client.resolve(reference());
    credential = 'second';
    await client.resolve(reference());
    expect(
        server.requests.where((r) => r.url.path.endsWith('/batch')).length, 2);
    expect(
        server.requests
            .where((r) => r.url.path.endsWith('/account/token'))
            .length,
        2);
  });

  test('new client reuses only matching source hash and size in stable folder',
      () async {
    final server = _AliServer();
    final first = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => 'refresh');
    await first.resolve(reference());
    final second = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => 'refresh');
    await second.resolve(reference());
    expect(
        server.requests.where((r) => r.url.path.endsWith('/batch')).length, 1);
    final sourceFolders = server.requests
        .where((r) => r.url.path == '/v2/file/create')
        .map((r) => jsonDecode(r.body) as Map)
        .where((r) => r['parent_file_id'] == 'playback-folder');
    expect(sourceFolders.length, 1);
    expect(sourceFolders.single['name'], matches(r'^ali_[a-f0-9]{64}$'));
  });

  test('same filename with different content is never reused or overwritten',
      () async {
    final server = _AliServer(wrongExistingContent: true);
    final client = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => 'refresh');
    await client.resolve(reference());
    expect(
        server.requests.where((r) => r.url.path.endsWith('/batch')).length, 1);
    expect(
        server.requests.any((r) => r.body.contains('/file/delete')), isFalse);
  });

  test('account switch during refresh stops all drive writes', () async {
    final server = _AliServer();
    var credential = 'first';
    final client = AliShareClient(
        credentialReader: (_) async => credential,
        credentialWriter: (_, value) async => credential = value,
        client: MockClient((request) async {
          final response = await server.handle(request);
          if (request.url.path.endsWith('/account/token')) {
            credential = 'second';
          }
          return response;
        }));
    await expectLater(
        client.resolve(reference()),
        throwsA(isA<AliShareException>()
            .having((e) => e.message, 'message', contains('切换'))));
    expect(credential, 'second');
    expect(
        server.requests.any((r) =>
            r.url.path.endsWith('/batch') || r.url.path.endsWith('/create')),
        isFalse);
  });

  test('account switch after listing stops the pending copy', () async {
    final server = _AliServer();
    var credential = 'first';
    final client = AliShareClient(
        credentialReader: (_) async => credential,
        client: MockClient((request) async {
          final response = await server.handle(request);
          if (request.url.path.endsWith('/file/list') &&
              jsonDecode(request.body)['parent_file_id'] == 'source-folder') {
            credential = 'second';
          }
          return response;
        }));
    await expectLater(
        client.resolve(reference()),
        throwsA(isA<AliShareException>()
            .having((e) => e.message, 'message', contains('切换'))));
    expect(server.requests.any((r) => r.url.path.endsWith('/batch')), isFalse);
  });

  test(
      'account switch during media resolution does not return old account media',
      () async {
    final server = _AliServer();
    var credential = 'first';
    final client = AliShareClient(
        credentialReader: (_) async => credential,
        client: MockClient((request) async {
          final response = await server.handle(request);
          if (request.url.path.endsWith('get_video_preview_play_info')) {
            credential = 'second';
          }
          return response;
        }));
    await expectLater(
        client.resolve(reference()),
        throwsA(isA<AliShareException>()
            .having((e) => e.message, 'message', contains('切换'))));
  });

  test('concurrent resolves share token refresh and one file copy', () async {
    final server = _AliServer();
    var credential = 'first';
    final client = AliShareClient(
        client: MockClient(server.handle),
        credentialReader: (_) async => credential,
        credentialWriter: (_, value) async => credential = value);
    final results = await Future.wait(
        [client.resolve(reference()), client.resolve(reference())]);
    expect(results.length, 2);
    expect(
        server.requests
            .where((r) => r.url.path.endsWith('/account/token'))
            .length,
        1);
    expect(
        server.requests.where((r) => r.url.path.endsWith('/batch')).length, 1);
  });

  test('cancel before copy prevents further requests and drive writes',
      () async {
    final server = _AliServer();
    var cancelled = false;
    final client = AliShareClient(
        credentialReader: (_) async => 'refresh',
        isCancelled: () => cancelled,
        client: MockClient((request) async {
          final response = await server.handle(request);
          if (request.url.path.endsWith('/file/list') &&
              jsonDecode(request.body)['parent_file_id'] == 'source-folder') {
            cancelled = true;
          }
          return response;
        }));
    await expectLater(
        client.resolve(reference()),
        throwsA(isA<AliShareException>()
            .having((e) => e.message, 'message', contains('取消'))));
    expect(server.requests.any((r) => r.url.path.endsWith('/batch')), isFalse);
    expect(server.requests.any((r) => r.url.path.endsWith('get_download_url')),
        isFalse);
  });

  test('cancelled resolver does not start any network request', () async {
    final client = AliShareClient(
        credentialReader: (_) async => 'refresh',
        isCancelled: () => true,
        client:
            MockClient((_) async => throw StateError('No request permitted')));
    await expectLater(
        client.resolve(reference()),
        throwsA(isA<AliShareException>()
            .having((e) => e.message, 'message', contains('取消'))));
  });

  test(
      'API errors never echo token or remote response and redirects stay disabled',
      () async {
    final client = AliShareClient(
        credentialReader: (_) async => 'refresh-private',
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          return http.Response('https://evil.test/?token=refresh-private', 302,
              headers: {'location': 'https://evil.test/'});
        }));
    await expectLater(
        client.resolve(reference()),
        throwsA(isA<AliShareException>().having((e) => e.toString(),
            'sanitized', isNot(contains('refresh-private')))));
  });
}

class _AliServer {
  _AliServer(
      {this.existingFolder = true,
      this.originalStatus = 200,
      this.highResolution = true,
      this.copyDenied = false,
      this.wrongExistingContent = false});
  final bool existingFolder;
  final int originalStatus;
  final bool highResolution;
  final bool copyDenied;
  final bool wrongExistingContent;
  final List<http.Request> requests = [];
  String account = 'user1';
  String sourceFolderName = '';
  final Set<String> copiedAccounts = {};
  static const sourceHash = '0123456789012345678901234567890123456789';

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final body = jsonDecode(request.body) as Map;
    switch (request.url.path) {
      case '/v2/account/token':
        account = body['refresh_token'] == 'second' ? 'user2' : 'user1';
        return jsonResponse({
          'access_token': 'account-secret',
          'refresh_token': 'rotated-refresh',
          'user_id': account,
          'resource_drive_id': 'resource-drive',
          'default_drive_id': 'backup-drive',
          'device_id': 'device1',
          'expires_in': 7200
        });
      case '/v2/share_link/get_share_token':
        return jsonResponse({'share_token': 'share-secret'});
      case '/v2/file/get':
        expect(request.headers['x-share-token'], 'share-secret');
        return jsonResponse({
          'file_id': 'video1',
          'type': 'file',
          'name': '01.mkv',
          'size': 1000,
          'content_hash': sourceHash
        });
      case '/adrive/v3/file/list':
        expect(request.headers['authorization'], 'Bearer account-secret');
        if (body['parent_file_id'] == 'playback-folder') {
          return jsonResponse({
            'items': sourceFolderName.isEmpty
                ? []
                : [
                    {
                      'name': sourceFolderName,
                      'type': 'folder',
                      'file_id': 'source-folder'
                    }
                  ]
          });
        }
        if (body['parent_file_id'] == 'source-folder') {
          return jsonResponse({
            'items': [
              if (wrongExistingContent)
                {
                  'file_id': 'other-file',
                  'name': '01.mkv',
                  'type': 'file',
                  'size': 1000,
                  'content_hash': 'abcdef0123456789012345678901234567890123'
                },
              if (copiedAccounts.contains(account))
                {
                  'file_id': 'saved-$account',
                  'name': '01.mkv',
                  'type': 'file',
                  'size': 1000,
                  'content_hash': sourceHash
                },
            ]
          });
        }
        return jsonResponse({
          'items': existingFolder
              ? [
                  {
                    'name': 'MarcoMovie分享播放',
                    'type': 'folder',
                    'file_id': 'playback-folder'
                  }
                ]
              : []
        });
      case '/v2/file/create':
        if (body['parent_file_id'] == 'playback-folder') {
          sourceFolderName = '${body['name']}';
          return jsonResponse({'file_id': 'source-folder'});
        }
        return jsonResponse({'file_id': 'playback-folder'});
      case '/adrive/v2/batch':
        if (!copyDenied) copiedAccounts.add(account);
        return jsonResponse({
          'responses': [
            {
              'status': copyDenied ? 403 : 201,
              'body': copyDenied
                  ? {'code': 'Forbidden'}
                  : {'file_id': 'saved-$account'}
            }
          ]
        });
      case '/v2/file/get_download_url':
        expect(body['file_id'], 'saved-$account');
        return jsonResponse(
            {'url': 'https://media.invalid/original.mp4?signature=media'},
            originalStatus);
      case '/v2/file/get_video_preview_play_info':
        return jsonResponse({
          'video_preview_play_info': {
            'live_transcoding_task_list': [
              {
                'status': 'finished',
                'template_id': 'FHD',
                'template_height': 1080,
                'url': 'https://media.invalid/1080.m3u8'
              },
              if (highResolution)
                {
                  'status': 'finished',
                  'template_id': 'UHD',
                  'template_height': 2160,
                  'url': 'https://media.invalid/2160.m3u8'
                },
              {
                'status': 'running',
                'template_height': 4320,
                'url': 'https://media.invalid/not-ready.m3u8'
              },
            ]
          }
        });
      default:
        throw StateError('Unexpected endpoint ${request.url.path}');
    }
  }
}
