import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/core/quark_drive.dart';

http.Response ok(Object data, {int? total}) => http.Response(
    jsonEncode({
      'code': 0,
      'status': 200,
      'data': data,
      if (total != null) 'metadata': {'_total': total},
    }),
    200);
Map<String, Object> video(String id) => {
      'fid': id,
      'file_name': '$id.mp4',
      'file_type': 1,
      'category': 1,
      'share_fid_token': 'temporary-file-$id'
    };
Map<String, Object> folder(String id) =>
    {'fid': id, 'file_name': id, 'file_type': 0, 'dir': true};
Matcher error(String code) =>
    isA<QuarkDriveException>().having((e) => e.code, 'code', code);

class Accounts extends QuarkAccountProvider {
  Accounts()
      : super(
            readCredential: () async => '',
            writeCredential: (_) async {},
            httpClient: MockClient(
                (_) async => throw StateError('Unexpected account request')));
  final current = QuarkAccountSession(
      driveSt: 'fixture-drive-st',
      cookie: '__pus=fixture; __puus=session',
      accountId: 'account-a',
      validatedAt: DateTime.utc(2026, 11, 10));
  int revision = 0;
  @override
  int get generation => revision;
  @override
  Future<QuarkAccountSession> requireSession() async => current;
  @override
  Future<void> assertCurrentSession(QuarkAccountSession session,
      {int? generation}) async {
    if (generation != revision) throw StateError('account_changed');
  }
}

void main() {
  test('cancelled public share read stops before issuing a request', () async {
    final client =
        MockClient((_) async => throw StateError('Must not request'));
    await expectLater(
        QuarkDriveClient.listPublicShareEpisodes(
            'https://pan.quark.cn/s/share123',
            httpClient: client,
            isCancelled: () => true),
        throwsA(error('cancelled')));
  });

  test('cancellation after account folder read prevents saving shared files',
      () async {
    final accounts = Accounts();
    var cancelled = false;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/token')) return ok({'stoken': 'fresh'});
      if (request.url.path.endsWith('/detail')) {
        return ok({
          'list': [video('target')]
        });
      }
      if (request.url.path.endsWith('/file/sort')) {
        cancelled = true;
        return ok({
          'list': [folder('temp')..['file_name'] = '0000temp']
        });
      }
      throw StateError('Cancelled operation must not save');
    });
    await expectLater(
        QuarkDriveClient(
            accounts: accounts,
            httpClient: client,
            isCancelled: () =>
                cancelled).resolveWoggShare(const CmsEpisode(
            name: 'File',
            url: 'mmwogg://quark?v=1&pwd_id=share123&fid=target&pdir_fid=0')),
        throwsA(error('cancelled')));
  });

  test('public directory paginates beyond 200 and persists no temporary tokens',
      () async {
    final pages = <String>[];
    final client = MockClient((request) async {
      expect(request.followRedirects, isFalse);
      expect(request.headers['Cookie'], isNull);
      if (request.url.path.endsWith('/token')) {
        return ok({'stoken': 'temporary-share'});
      }
      pages.add(request.url.queryParameters['_page']!);
      final page = int.parse(pages.last);
      return ok({
        'list': [
          for (var i = page == 1 ? 0 : 200; i < (page == 1 ? 200 : 201); i++)
            video('file-$i')
        ]
      }, total: 201);
    });
    final episodes = await QuarkDriveClient.listPublicShareEpisodes(
        'https://pan.quark.cn/s/share123?pwd=abcd',
        httpClient: client);
    expect(pages, ['1', '2']);
    expect(episodes.length, 201);
    final ref = Uri.parse(episodes.last.url).queryParameters;
    expect(ref, {
      'v': '1',
      'pwd_id': 'share123',
      'fid': 'file-200',
      'pdir_fid': '0',
      'passcode': 'abcd'
    });
    expect(episodes.last.url, isNot(contains('temporary')));
    expect(episodes.last.name, 'file-200.mp4');
  });

  test(
      'all sibling folders and nested folders are retained without guessed quality',
      () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        return ok({'stoken': 'temporary-share'});
      }
      final parent = request.url.queryParameters['pdir_fid'];
      if (parent == '0') {
        return ok({
          'list': [for (var i = 0; i < 10; i++) folder('dir-$i')]
        });
      }
      if (parent == 'dir-9') {
        return ok({
          'list': [folder('deep-1')]
        });
      }
      if (parent == 'deep-1') {
        return ok({
          'list': [folder('deep-2')]
        });
      }
      if (parent == 'deep-2') {
        return ok({
          'list': [folder('4K-label')]
        });
      }
      return ok({
        'list': [video('file-$parent')]
      });
    });
    final episodes = await QuarkDriveClient.listPublicShareEpisodes(
        'https://pan.quark.cn/s/share123',
        httpClient: client);
    expect(episodes.length, 10);
    expect(
        episodes.last.name, 'dir-9/deep-1/deep-2/4K-label/file-4K-label.mp4');
    expect(episodes.any((e) => e.name.contains('[4K原画]')), false);
    expect(
        Uri.parse(episodes.last.url).queryParameters['pdir_fid'], '4K-label');
  });

  test('excessive depth reports a limit instead of silently truncating',
      () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        return ok({'stoken': 'temporary-share'});
      }
      final depth = int.parse(request.url.queryParameters['pdir_fid']!);
      return ok({
        'list': [folder('${depth + 1}')]
      });
    });
    await expectLater(
        QuarkDriveClient.listPublicShareEpisodes(
            'https://pan.quark.cn/s/share123',
            httpClient: client),
        throwsA(error('share_limit_exceeded')));
  });

  test('server repeating pages reports incomplete listing', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        return ok({'stoken': 'temporary-share'});
      }
      return ok({
        'list': [video('repeated')]
      }, total: 2);
    });
    await expectLater(
        QuarkDriveClient.listPublicShareEpisodes(
            'https://pan.quark.cn/s/share123',
            httpClient: client),
        throwsA(error('incomplete_share')));
  });

  test('hostname lookalikes never receive public share requests', () async {
    final client =
        MockClient((_) async => throw StateError('Must not request'));
    expect(
        await QuarkDriveClient.listPublicShareEpisodes(
            'https://pan.quark.cn.attacker.invalid/s/share123',
            httpClient: client),
        isEmpty);
  });

  for (final legacy in [false, true]) {
    test(
        '${legacy ? 'legacy' : 'stable'} reference refreshes tokens and saves real parent',
        () async {
      final accounts = Accounts();
      final mutations = <String>[];
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/sharepage/token')) {
          expect(request.headers['Cookie'], isNull);
          return ok({'stoken': 'fresh-share-token'});
        }
        if (path.endsWith('/sharepage/detail')) {
          expect(request.url.queryParameters['stoken'], 'fresh-share-token');
          if (request.url.queryParameters['pdir_fid'] == '0') {
            return ok({
              'list': [folder('real-parent')]
            });
          }
          return ok({
            'list': [video('target')]
          });
        }
        expect(request.headers['Cookie'], accounts.current.cookie);
        if (path.endsWith('/file/sort')) {
          return ok({
            'list': [folder('temp')..['file_name'] = '0000temp']
          });
        }
        if (path.endsWith('/sharepage/save')) {
          mutations.add(path);
          final body = jsonDecode(request.body);
          expect(body['stoken'], 'fresh-share-token');
          expect(body['fid_token_list'], ['temporary-file-target']);
          expect(body['pdir_fid'], 'real-parent');
          return ok({
            'task_resp': {
              'data': {
                'save_as': {
                  'save_as_top_fids': ['owned-target']
                }
              }
            }
          });
        }
        if (path.endsWith('/file/download')) {
          return ok([
            {
              'fid': 'owned-target',
              'download_url': 'https://media.invalid/raw.mp4'
            }
          ]);
        }
        if (path.endsWith('/file/v2/play')) return ok({'video_list': []});
        throw StateError('Unexpected request $path');
      });
      final drive = QuarkDriveClient(accounts: accounts, httpClient: client);
      final uri = Uri(scheme: 'mmwogg', host: 'quark', queryParameters: {
        'pwd_id': 'share123',
        'fid': 'target',
        if (legacy) ...{'stoken': 'expired', 'fid_token': 'expired'},
        if (!legacy) ...{'v': '1', 'pdir_fid': 'real-parent'},
      });
      final resolved = await drive
          .resolveWoggShare(CmsEpisode(name: 'Original', url: uri.toString()));
      expect(mutations.length, 1);
      expect(resolved.url, 'https://media.invalid/raw.mp4');
      expect(resolved.headers['Cookie'], isNull);
      expect(resolved.variants.first.name, '原画');
    });
  }

  test('account changes during share read prevent every account mutation',
      () async {
    final accounts = Accounts();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        accounts.revision++;
        return ok({'stoken': 'fresh'});
      }
      if (request.url.path.endsWith('/detail')) {
        return ok({
          'list': [video('target')]
        });
      }
      throw StateError('Account mutation must not occur');
    });
    await expectLater(
        QuarkDriveClient(accounts: accounts, httpClient: client)
            .resolveWoggShare(const CmsEpisode(
                name: 'File',
                url:
                    'mmwogg://quark?v=1&pwd_id=share123&fid=target&pdir_fid=0')),
        throwsStateError);
  });
}
