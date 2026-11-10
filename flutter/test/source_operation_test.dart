import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';

void main() {
  test(
    'screen cancellation aborts HTTP while another source stays usable',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      server.listen((request) async {
        if (request.uri.path == '/slow') {
          started.complete();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"class":[],"list":[]}');
        await request.response.close();
      });
      try {
        final client = CmsClient();
        final cancel = Completer<void>();
        final slow = CmsSite(
          key: 'slow',
          name: 'Slow',
          type: 1,
          api: 'http://127.0.0.1:${server.port}/slow',
        );
        final result = client.runSourceOperation(
          () => client.fetchHome(slow),
          cancellation: cancel,
        );
        final rejected = expectLater(result, throwsStateError);
        await started.future;
        cancel.complete();
        await rejected.timeout(const Duration(seconds: 1));
        final fast = CmsSite(
          key: 'fast',
          name: 'Fast',
          type: 1,
          api: 'http://127.0.0.1:${server.port}/fast',
        );
        final (_, listing) = await client.runSourceOperation(
          () => client.fetchHome(fast),
          cancellation: Completer<void>(),
        );
        expect(listing.videos, isEmpty);
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'nested screen cancellation discards late results without replay',
    () async {
      final client = CmsClient();
      final cancelled = Completer<void>();
      final started = Completer<void>();
      final late = Completer<String>();
      var executions = 0;
      final result = client.runSourceOperation(
        () => client.runSourceOperation(() {
          executions++;
          started.complete();
          return late.future;
        }, cancellation: Completer<void>()),
        cancellation: cancelled,
      );
      final rejected = expectLater(result, throwsStateError);
      await started.future;
      cancelled.complete();
      await rejected;
      late.complete('stale response');
      await Future<void>.delayed(Duration.zero);
      expect(executions, 1);
      await expectLater(
        client.runSourceOperation(() async {
          executions++;
          return 'must not run';
        }, cancellation: cancelled),
        throwsStateError,
      );
      expect(executions, 1);
    },
  );
}
