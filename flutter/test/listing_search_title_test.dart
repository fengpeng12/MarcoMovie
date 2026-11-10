import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/csp_bridge.dart';
import 'package:marco_movie/core/models.dart';

void main() {
  test('listing redirects search by title instead of a catalogue number', () {
    for (final id in [
      'msearch:36809913',
      'msearch:36809913###折月亮',
      'msearch:###36809913###https://example.test/poster.jpg###折月亮',
      'msearch:###https://example.test/poster.jpg',
      '36809913',
    ]) {
      expect(
        CspBridge.searchTitleForVideo(CmsVideo(id: id, title: '折月亮')),
        '折月亮',
        reason: id,
      );
    }
  });

  test('named redirects and actual numeric movie titles still work', () {
    expect(
      CspBridge.searchTitleForVideo(
        const CmsVideo(id: 'msearch:折月亮', title: '片单条目'),
      ),
      '折月亮',
    );
    expect(
      CspBridge.searchTitleForVideo(
        const CmsVideo(id: 'msearch:1917', title: '1917'),
      ),
      '1917',
    );
  });
}
