import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';
import 'package:marco_movie/ui/player_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('desktop quality change retains the current cloud file until it is released', () async {
    var requests = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://media.uc.cn/original'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => true,
        client: MockClient((request) async {
          requests++;
          expect(request.url.host, 'media.uc.cn');
          expect(request.headers['cookie'], '__pus=synthetic');
          return http.Response.bytes([0, 1, 255], 206,
              headers: {'content-type': 'video/mp4'});
        }));
    addTearDown(lease.close);
    final mediaUrl = lease.url;
    final player = PlayerCloudMediaSession()..adopt(lease);
    expect((await http.get(lease.url)).bodyBytes, [0, 1, 255]);
    await player.releaseUnless(lease);
    await player.discard(lease);
    expect((await http.get(lease.url)).statusCode, 206);
    expect(requests, 2);
    await player.releaseUnless(null);
    await expectLater(http.get(mediaUrl), throwsA(isA<http.ClientException>()));
    expect(requests, 2);
  });

  test('desktop cloud transport stops serving when its account changes', () async {
    var currentAccount = true;
    var requests = 0;
    final lease = await CloudMediaLease.open(
        target: Uri.parse('https://media.uc.cn/original'),
        headers: {'Cookie': '__pus=synthetic'},
        isCancelled: () => false,
        isCurrent: () async => currentAccount,
        client: MockClient((request) async {
          requests++;
          return http.Response.bytes([0], 200,
              headers: {'content-type': 'video/mp4'});
        }));
    addTearDown(lease.close);
    currentAccount = false;
    expect((await http.get(lease.url)).statusCode, 410);
    expect(requests, 0);
  });
}
