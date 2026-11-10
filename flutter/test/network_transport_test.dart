import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/cms_parser.dart';
void main() {
  test('cancelled search stops its actual HTTP response', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final started = Completer<void>();
    final disconnected = Completer<void>();
    var cancellationRequested = false;
    server.listen((socket) {
      Timer? chunks;
      var closed = false;
      void finish() {
        if (closed) return;
        closed = true;
        chunks?.cancel();
        socket.destroy();
        expect(cancellationRequested,isTrue,reason:'server must observe the client cancellation');
        if (!disconnected.isCompleted) disconnected.complete();
      }
      // macOS reports a peer reset both on the incoming stream and the sink's
      // done future; both belong to the intentional cancellation in this test.
      socket.done.then((_)=>finish(),onError:(Object error) {
        if (error is! SocketException) throw error;
        finish();
      });
      socket.listen((data) {
        if (started.isCompleted) return;
        socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 5000000\r\n\r\n{"list":['));
        started.complete();
        chunks = Timer.periodic(const Duration(milliseconds: 10), (_) {
          try {socket.add(List.filled(1024, 32));} on SocketException {finish();}
        });
      }, onDone: finish, onError: (Object error) {
        if (error is! SocketException) throw error;
        finish();
      });
      addTearDown(() { chunks?.cancel(); socket.destroy(); });
    });
    final site = CmsParser.parseConfig('{"sites":[{"key":"slow","name":"Slow","type":1,'
        '"api":"http://127.0.0.1:${server.port}/api"}]}').sites.single;
    final subscription = CmsClient().searchAcrossSites([site], 'Example').listen((_) {});
    await started.future.timeout(const Duration(seconds: 3), onTimeout: () => throw StateError('request never started'));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    cancellationRequested = true;
    await subscription.cancel();
    await disconnected.future.timeout(const Duration(seconds: 3), onTimeout: () => throw StateError('request socket stayed open after cancel'));
  });
}
