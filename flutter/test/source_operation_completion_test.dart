import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';

void main() {
  for (final fails in [false, true]) {
    testWidgets(
      'completed source ${fails ? 'failure' : 'result'} settles before cancellation',
      (tester) async {
        final cancellation = Completer<void>();
        final start = Completer<void>();
        final operation = CmsClient().runSourceOperation(() async {
          await start.future;
          if (fails) throw StateError('owned source failure');
          return 'loaded';
        }, cancellation: cancellation);
        await tester.pumpWidget(
          MaterialApp(
            home: FutureBuilder<String>(
              future: operation,
              builder: (context, snapshot) =>
                  snapshot.connectionState == ConnectionState.done
                  ? Text(snapshot.hasError ? 'failed' : snapshot.requireData)
                  : const CircularProgressIndicator(),
            ),
          ),
        );
        start.complete();
        await tester.pumpAndSettle();
        expect(cancellation.isCompleted, false);
        expect(find.text(fails ? 'failed' : 'loaded'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        // A later screen exit must not report another error or replace the result.
        cancellation.complete();
        await tester.pumpAndSettle();
        expect(find.text(fails ? 'failed' : 'loaded'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
