import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/netdisk_service.dart';
import 'package:marco_movie/core/quark_account.dart';

const cookie = '__pus=fixture-account; __puus=fixture-session';

http.Response jsonResponse(
  Object value, {
  int status = 200,
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

class AccountFixture {
  final requests = <http.Request>[];
  int passportStatus = 2000000;
  int memberStatus = 200;
  int exchangeStatus = 200;
  int mobileStatus = 200;
  bool exchangeCookies = true;
  bool memberAccepted = true;
  bool driveTicket = true;
  bool redirect = false;
  bool deleteIdentity = false;
  String rotatingCookie = 'rotated-session';
  Completer<void>? memberGate;
  late final http.Client client = MockClient((request) async {
    requests.add(request);
    expect(request.followRedirects, false);
    expect(request.method, 'GET');
    if (request.url.host == 'uop.quark.cn') {
      expect(request.headers.containsKey('cookie'), false);
      if (redirect)
        return http.Response(
          '',
          302,
          headers: {'location': 'https://outside.invalid/'},
        );
      return jsonResponse({
        'status': passportStatus,
        'data': {
          'members': {
            if (request.url.path.endsWith('getTokenForQrcodeLogin'))
              'token': 'fixture-qr',
            if (request.url.path.endsWith('getServiceTicketByQrcodeToken'))
              'service_ticket': 'fixture-cas-st',
          },
        },
      });
    }
    if (request.url.path == '/account/info') {
      expect(request.url.queryParameters['st'], 'fixture-cas-st');
      expect(request.headers.containsKey('cookie'), false);
      return jsonResponse(
        {'status': 200, 'code': 0, 'data': {}},
        status: exchangeStatus,
        headers: exchangeCookies
            ? {
                'set-cookie':
                    '__pus=fixture-account; Domain=.quark.cn; Path=/; Secure; HttpOnly, '
                    '__puus=fixture-session; Domain=.quark.cn; Path=/; Expires=Wed, 01 Jan 2037 00:00:00 GMT, '
                    'discard=wrong-domain; Domain=outside.invalid; Path=/, '
                    'limited=path-cookie; Path=/private',
              }
            : {},
      );
    }
    if (request.url.path == '/1/clouddrive/member') {
      if (memberGate != null) await memberGate!.future;
      if (redirect)
        return http.Response(
          '',
          302,
          headers: {'location': 'https://outside.invalid/'},
        );
      return jsonResponse(
        {
          'status': memberAccepted ? 200 : 401,
          'code': memberAccepted ? 0 : 401,
          'data': {'member_type': 'NORMAL', 'total_capacity': 1000},
        },
        status: memberStatus,
        headers: {
          'set-cookie': deleteIdentity
              ? '__pus=; Path=/; Max-Age=0'
              : '__puus=$rotatingCookie; Domain=.quark.cn; Path=/; Secure; HttpOnly',
        },
      );
    }
    if (request.url.path == '/account/mobileinfo') {
      return jsonResponse({
        'status': 200,
        'code': 0,
        'data': {if (driveTicket) 'serviceTicket': 'fixture-drive-st'},
      }, status: mobileStatus);
    }
    fail('Unexpected account request');
  });
}

QuarkAccountProvider provider(
  AccountFixture fixture, {
  String Function()? read,
  void Function(String)? write,
}) => QuarkAccountProvider(
  readCredential: read ?? () => '',
  writeCredential: write ?? (_) {},
  httpClient: fixture.client,
);

void main() {
  test(
    'QR completes CAS exchange, real cookie validation and distinct Drive ST',
    () async {
      final fixture = AccountFixture();
      final accounts = provider(fixture);
      final service = NetdiskService(
        httpClient: fixture.client,
        quarkAccounts: accounts,
      );
      final qr = await service.startQrSession('quark');
      expect(qr.token, 'fixture-qr');
      expect(qr.qrImageUrl, isEmpty);
      expect(Uri.parse(qr.qrContent).queryParameters['token'], 'fixture-qr');
      final result = await service.pollQrSession(qr);
      expect(result.state, NetdiskPollState.confirmed);
      final session = QuarkAccountSession.tryParseCredential(
        result.credential,
      )!;
      expect(session.cookie, '__pus=fixture-account; __puus=rotated-session');
      expect(session.driveSt, 'fixture-drive-st');
      expect(session.driveSt, isNot('fixture-cas-st'));
      expect(
        session.accountId,
        sha256.convert(utf8.encode('fixture-account')).toString(),
      );
      expect(fixture.requests.map((r) => r.url.path), [
        '/cas/ajax/getTokenForQrcodeLogin',
        '/cas/ajax/getServiceTicketByQrcodeToken',
        '/account/info',
        '/1/clouddrive/member',
        '/account/mobileinfo',
      ]);
      expect(fixture.requests[0].url.queryParameters['client_id'], '532');
      expect(fixture.requests[1].url.queryParameters['client_id'], '532');
      expect(fixture.requests.last.url.queryParameters['st'], 'fixture-cas-st');
      expect(fixture.requests.last.headers['cookie'], session.cookie);
      expect(
        fixture.requests.every((r) => !r.url.host.contains('qrserver')),
        true,
      );
    },
  );

  test(
    'QR creation failure throws instead of returning a fallback homepage',
    () async {
      final fixture = AccountFixture()..passportStatus = 500;
      final service = NetdiskService(httpClient: fixture.client);
      await expectLater(service.startQrSession('quark'), throwsFormatException);
      expect(fixture.requests.length, 1);
      expect(NetdiskService.buildQrRenderUrl('sensitive-qr-content'), isEmpty);
    },
  );

  test('waiting and expired QR states never exchange or confirm', () async {
    final fixture = AccountFixture();
    final service = NetdiskService(httpClient: fixture.client);
    const qr = NetdiskQrSession(
      driveKey: 'quark',
      qrContentUrl: '',
      qrImageUrl: '',
      token: 'fixture-qr',
    );
    fixture.passportStatus = 50004001;
    expect((await service.pollQrSession(qr)).state, NetdiskPollState.waiting);
    fixture.passportStatus = 50004002;
    expect((await service.pollQrSession(qr)).state, NetdiskPollState.expired);
    fixture.passportStatus = 999;
    expect((await service.pollQrSession(qr)).state, NetdiskPollState.error);
    expect(fixture.requests.every((r) => r.url.host == 'uop.quark.cn'), true);
  });

  test('exchange and account failures cannot return confirmed', () async {
    for (final configure in <void Function(AccountFixture)>[
      (f) => f.exchangeStatus = 503,
      (f) => f.exchangeCookies = false,
      (f) => f.memberStatus = 401,
      (f) => f.memberAccepted = false,
      (f) => f.deleteIdentity = true,
    ]) {
      final fixture = AccountFixture();
      configure(fixture);
      final service = NetdiskService(httpClient: fixture.client);
      final result = await service.pollQrSession(
        const NetdiskQrSession(
          driveKey: 'quark',
          qrContentUrl: '',
          qrImageUrl: '',
          token: 'fixture-qr',
        ),
      );
      expect(result.state, NetdiskPollState.error);
      expect(result.credential, isEmpty);
      expect(result.message.contains('fixture'), false);
    }
  });

  test(
    'legacy Cookie validation is read only and does not save automatically',
    () async {
      final fixture = AccountFixture();
      final writes = <String>[];
      final accounts = provider(fixture, write: writes.add);
      final session = await accounts.validateCredential(cookie);
      expect(writes, isEmpty);
      expect(session.driveSt, 'fixture-drive-st');
      expect(fixture.requests.map((r) => r.url.path), [
        '/1/clouddrive/member',
        '/account/mobileinfo',
      ]);
      expect(
        fixture.requests.last.url.queryParameters.containsKey('st'),
        false,
      );
      expect(fixture.requests.first.headers['cookie'], cookie);
      expect(fixture.requests.last.headers['cookie'], session.cookie);
    },
  );

  test(
    'validated PC account remains usable when optional H5 ticket is unavailable',
    () async {
      for (final configure in <void Function(AccountFixture)>[
        (f) => f.driveTicket = false,
        (f) => f.mobileStatus = 503,
      ]) {
        final fixture = AccountFixture();
        configure(fixture);
        final service = NetdiskService(httpClient: fixture.client);
        final result = await service.pollQrSession(
          const NetdiskQrSession(
            driveKey: 'quark',
            qrContentUrl: '',
            qrImageUrl: '',
            token: 'fixture-qr',
          ),
        );
        expect(result.state, NetdiskPollState.confirmed);
        final session = QuarkAccountSession.tryParseCredential(
          result.credential,
        )!;
        expect(session.pcApi, true);
        expect(session.h5Save, false);
        expect(session.driveSt, isEmpty);
        expect(session.cookie, contains('__pus=fixture-account'));
      }
    },
  );

  test(
    'Cookie Max-Age takes precedence and deletion removes only its named cookie',
    () async {
      final client = MockClient(
        (request) async => jsonResponse(
          {
            'status': 200,
            'code': 0,
            'data': request.url.path.endsWith('/member')
                ? {'member_type': 'NORMAL'}
                : {},
          },
          headers: request.url.path.endsWith('/member')
              ? {
                  'set-cookie':
                      '__pus=fixture-account; Path=/; Max-Age=600; Expires=Thu, 01 Jan 1970 00:00:00 GMT, '
                      'old=; Path=/; Max-Age=0',
                }
              : {},
        ),
      );
      final accounts = QuarkAccountProvider(
        readCredential: () => '',
        writeCredential: (_) {},
        httpClient: client,
      );
      final session = await accounts.validateCredential(
        '__pus=fixture-account; old=expired',
      );
      expect(session.cookie, '__pus=fixture-account');
      expect(session.pcApi, true);
    },
  );

  test(
    'non-string QR tokens and CAS tickets are not coerced into credentials',
    () async {
      final service = NetdiskService(
        httpClient: MockClient(
          (_) async => jsonResponse({
            'status': 2000000,
            'data': {
              'members': {'token': 123, 'service_ticket': {}},
            },
          }),
        ),
      );
      await expectLater(service.startQrSession('quark'), throwsFormatException);
      final result = await service.pollQrSession(
        const NetdiskQrSession(
          driveKey: 'quark',
          qrContentUrl: '',
          qrImageUrl: '',
          token: 'fixture-qr',
        ),
      );
      expect(result.state, NetdiskPollState.error);
      expect(result.credential, isEmpty);
    },
  );

  test(
    'Cookie attributes, header injection and fabricated credentials are rejected locally',
    () async {
      final fixture = AccountFixture();
      final accounts = provider(fixture);
      for (final value in [
        '',
        'quark_st=not-a-cookie; token=qr',
        '__puus=qr_auth_fixture; kps=quark_4k_fixture',
        '__pus=qr_auth_fixture',
        '$cookie; Path=/',
        '$cookie; HttpOnly',
        '$cookie\r\nX-Other: injected',
        '__pus=space value',
        '__pus=first; __pus=second',
      ]) {
        await expectLater(
          accounts.validateCredential(value),
          throwsA(isA<QuarkAccountException>()),
        );
      }
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'credential records enforce provider, version, identity and real session fields',
    () async {
      final session = await provider(
        AccountFixture(),
      ).validateCredential(cookie);
      final data = jsonDecode(session.toCredential()) as Map<String, dynamic>;
      expect(
        QuarkAccountSession.tryParseCredential(
          session.toCredential(),
        )!.accountId,
        session.accountId,
      );
      for (final changed in [
        {...data, 'provider': 'uc'},
        {...data, 'version': 2},
        {...data, 'accountId': 'untrusted'},
        {...data, 'driveSt': 'invalid ticket'},
        {...data, 'cookie': 'quark_st=fixture'},
        {...data, 'validatedAt': 'invalid'},
      ]) {
        expect(
          QuarkAccountSession.tryParseCredential(jsonEncode(changed)),
          isNull,
        );
      }
      expect(QuarkAccountSession.tryParseCredential(cookie), isNull);
    },
  );

  test(
    'provider validates once, saves structured credential and keeps account identity on rotation',
    () async {
      final fixture = AccountFixture();
      var saved = cookie;
      final writes = <String>[];
      final accounts = provider(
        fixture,
        read: () => saved,
        write: (value) {
          saved = value;
          writes.add(value);
        },
      );
      final sessions = await Future.wait([
        accounts.requireSession(),
        accounts.requireSession(),
      ]);
      expect(fixture.requests.length, 2);
      expect(writes.length, 1);
      expect(sessions[0].toCredential(), sessions[1].toCredential());
      await accounts.assertCurrentSession(
        sessions[0],
        generation: accounts.generation,
      );
      await accounts.requireSession();
      expect(fixture.requests.length, 2);
      fixture.rotatingCookie = 'new-session';
      accounts.invalidate();
      final refreshed = await accounts.requireSession();
      expect(refreshed.accountId, sessions[0].accountId);
      expect(refreshed.cookie, contains('__puus=new-session'));
      expect(writes.length, 2);
    },
  );

  test(
    'account switch during validation cannot overwrite the new account',
    () async {
      final fixture = AccountFixture()..memberGate = Completer<void>();
      var saved = cookie;
      var writes = 0;
      final accounts = provider(
        fixture,
        read: () => saved,
        write: (value) {
          saved = value;
          writes++;
        },
      );
      final pending = accounts.requireSession();
      while (fixture.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      accounts.invalidate();
      saved = '__pus=another-account; __puus=another-session';
      fixture.memberGate!.complete();
      await expectLater(pending, throwsStateError);
      expect(writes, 0);
      expect(saved, contains('another-account'));
    },
  );

  test(
    'generation rejects A to B to A even when the final stored string matches',
    () async {
      final fixture = AccountFixture();
      var saved = cookie;
      final accounts = provider(
        fixture,
        read: () => saved,
        write: (value) => saved = value,
      );
      final session = await accounts.requireSession();
      final generation = accounts.generation;
      accounts.invalidate();
      saved = '';
      accounts.invalidate();
      saved = session.toCredential();
      await expectLater(
        accounts.assertCurrentSession(session, generation: generation),
        throwsStateError,
      );
      expect(fixture.requests.length, 2);
    },
  );

  test(
    'account and passport redirects never forward cookies or follow foreign URLs',
    () async {
      final fixture = AccountFixture()..redirect = true;
      await expectLater(
        provider(fixture).validateCredential(cookie),
        throwsA(isA<QuarkAccountException>()),
      );
      final service = NetdiskService(httpClient: fixture.client);
      await expectLater(service.startQrSession('quark'), throwsFormatException);
      expect(fixture.requests.length, 2);
      expect(
        fixture.requests.any((r) => r.url.host == 'outside.invalid'),
        false,
      );
      expect(fixture.requests.last.headers.containsKey('cookie'), false);
    },
  );
}
