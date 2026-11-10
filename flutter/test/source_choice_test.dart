import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/source_choice_sliver.dart';

void main() {
  for (final width in [320.0, 390.0, 740.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('complete source names at width $width, text $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const title = '🎬 很长的线路名称 | 超清影视与剧集 | 多个网盘解析入口完整版';
        final sites = [
          const CmsSite(
            key: 'long',
            name: title,
            type: 1,
            api: 'https://source.example/api',
          ),
        ];
        String? chosen;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 1000),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    SourceChoiceSliver(
                      sites: sites,
                      selectedKey: 'long',
                      preferredKey: 'long',
                      onPreferred: (_) {},
                      badgeLabel: (_) => 'HTTP',
                      badgeColor: (_) => Colors.blue,
                      onSelected: (s) => chosen = s.key,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(title),
        );
        expect(paragraph.didExceedMaxLines, false);
        final bounds = tester.getRect(find.text(title));
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(width));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(title));
        expect(chosen, 'long');
      });
    }
  }
}
