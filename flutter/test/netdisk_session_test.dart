import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/netdisk_service.dart';
import 'package:marco_movie/core/netdisk_session.dart';
import 'package:marco_movie/core/storage_service.dart';

NetdiskQrSession qr(String provider) => NetdiskQrSession(
    driveKey: provider, token: 'qr-ticket', qrContentUrl: '', qrImageUrl: '');
http.Response response(Object value) => http.Response(jsonEncode(value), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('UC exchanges CAS ticket for account cookie; never stores QR codes',
      () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.host == 'api.open.uc.cn') {
        return response({
          'status': 2000000,
          'data': {
            'members': {'service_ticket': 'cas-value'}
          }
        });
      }
      expect(request.url.host, 'drive.uc.cn');
      expect(request.url.path, '/account/mobileinfo');
      expect(request.url.queryParameters['st'], 'cas-value');
      expect(request.followRedirects, isFalse);
      return response({
        'data': {'__pus': 'account-cookie', 'serviceTicket': 'drive-st'}
      });
    });
    final result =
        await NetdiskService(httpClient: client).pollQrSession(qr('uc'));
    expect(result.state, NetdiskPollState.confirmed);
    expect(result.credential, '__pus=account-cookie');
    expect(paths.length, 2);
  });
  test('failed UC exchange remains error and retries the cached ticket',
      () async {
    var polls = 0;
    var exchanges = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'api.open.uc.cn') {
        polls++;
        return response({
          'status': 2000000,
          'data': {
            'members': {'service_ticket': 'cas-value'}
          }
        });
      }
      exchanges++;
      return response(exchanges == 1
          ? {'data': {}}
          : {
              'data': {'__pus': 'valid-cookie'}
            });
    });
    final service = NetdiskService(httpClient: client);
    final first = await service.pollQrSession(qr('uc'));
    expect(first.state, NetdiskPollState.error);
    expect(first.credential, isEmpty);
    expect((await service.pollQrSession(qr('uc'))).credential,
        '__pus=valid-cookie');
    expect(polls, 1);
    expect(exchanges, 2);
  });
  test('Baidu QR v is exchanged for real BDUSS and STOKEN', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/channel/unicast') {
        return response({
          'errno': 0,
          'channel_v': jsonEncode({'status': 0, 'v': 'one-use-ticket'})
        });
      }
      expect(request.url.host, 'passport.baidu.com');
      expect(request.url.path, '/v3/login/main/qrbdusslogin');
      expect(request.url.queryParameters['bduss'], 'one-use-ticket');
      expect(request.followRedirects, isFalse);
      return http.Response(
          'bd__cbs__4wi6y6(${jsonEncode({
                'data': {
                  'session': jsonEncode(
                      {'bduss': 'account-bduss', 'stoken': 'account-stoken'})
                }
              })});',
          200);
    });
    final result =
        await NetdiskService(httpClient: client).pollQrSession(qr('baidu'));
    expect(result.state, NetdiskPollState.confirmed);
    expect(result.credential, 'BDUSS=account-bduss; STOKEN=account-stoken');
    expect(result.credential, isNot(contains('one-use-ticket')));
  });
  test('missing Baidu session and redirect never create a login', () async {
    for (final status in [200, 302]) {
      final client = MockClient((request) async =>
          request.url.path == '/channel/unicast'
              ? response({
                  'errno': 0,
                  'channel_v': {'status': 0, 'v': 'one-use-ticket'}
                })
              : http.Response('{}', status,
                  headers: {'location': 'https://other.example/'}));
      final result =
          await NetdiskService(httpClient: client).pollQrSession(qr('baidu'));
      expect(result.state, NetdiskPollState.error);
      expect(result.credential, isEmpty);
    }
  });
  test('Ali only confirms a decoded refresh token', () async {
    for (final bizExt in [
      null,
      'not-base64',
      base64Encode(utf8.encode('{}'))
    ]) {
      final client = MockClient((_) async => response({
            'content': {
              'data': {'qrCodeStatus': 'CONFIRMED', 'bizExt': bizExt}
            }
          }));
      final result =
          await NetdiskService(httpClient: client).pollQrSession(qr('ali'));
      expect(result.state, NetdiskPollState.error);
      expect(result.credential, isEmpty);
    }
    final ext = base64Encode(utf8.encode(jsonEncode({
      'pds_login_result': {'refreshToken': 'valid-refresh-token-123456'}
    })));
    expect(NetdiskSession.aliCredential(ext),
        'ali_token=valid-refresh-token-123456');
  });
  test('old placeholder logins are not displayed as authenticated', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    for (final entry in {
      'uc': 'uc_st=old; token=qr',
      'baidu': 'bduss=old-qr-ticket',
      'ali': 'ali_token=bad'
    }.entries) {
      await storage.setNetdiskCredential(entry.key, entry.value);
      expect(storage.isNetdiskLoggedIn(entry.key), isFalse);
      expect(storage.netdiskCredential(entry.key), entry.value,
          reason: 'Do not silently delete saved data');
    }
    for (final entry in {
      'uc': '__pus=cookie',
      'baidu': 'BDUSS=cookie; STOKEN=st',
      'ali': 'ali_token=valid-refresh-token-123456'
    }.entries) {
      await storage.setNetdiskCredential(entry.key, entry.value);
      expect(storage.isNetdiskLoggedIn(entry.key), isTrue);
    }
  });
}
