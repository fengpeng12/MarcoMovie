import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/core/quark_drive.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/quark_library_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DirectoryCall {
  _DirectoryCall(this.folder, this.page);
  final String folder;
  final int page;
  final result = Completer<CmsListing>();
}

class _PendingDrive extends QuarkDriveClient {
  _PendingDrive()
    : super(
        accounts: QuarkAccountProvider(
          readCredential: () => '',
          writeCredential: (_) {},
          httpClient: MockClient(
            (_) async => throw StateError('Unexpected HTTP'),
          ),
        ),
        httpClient: MockClient(
          (_) async => throw StateError('Unexpected HTTP'),
        ),
      );
  final calls = <_DirectoryCall>[];
  @override
  Future<CmsListing> listOwned({String folder = '0', int page = 1}) {
    final call = _DirectoryCall(folder, page);
    calls.add(call);
    return call.result.future;
  }
}

const _folderId = 'mmquark://folder?account=fixture-account&fid=folder-a';
CmsVideo _folder([String title = '影片文件夹']) =>
    CmsVideo(id: _folderId, title: title, remarks: '文件夹');
CmsVideo _video(String title) => CmsVideo(
  id: Uri(
    scheme: 'mmquark',
    host: 'owned',
    queryParameters: {'account': 'fixture-account', 'fid': title},
  ).toString(),
  title: title,
  remarks: '1.0 GB',
);

Future<void> _open(
  WidgetTester tester,
  _PendingDrive drive, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showQuarkLibrarySheet(context, storage, drive: drive),
            child: const Text('打开我的夸克'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开我的夸克'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(drive.calls, hasLength(1));
}

void main() {
  for (final size in [const Size(320, 568), const Size(844, 360)]) {
    testWidgets(
      'long Quark file and folder names fit ${size.width}x${size.height}',
      (tester) async {
        final drive = _PendingDrive();
        final longFile = '${List.filled(12, '很长的影片文件名_').join()}1080p.mp4';
        final longFolder = List.filled(12, '很长的收藏文件夹名称').join();
        await _open(tester, drive, size: size);
        drive.calls.single.result.complete(
          CmsListing(videos: [_folder(longFolder), _video(longFile)]),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(longFile));
        await tester.pumpAndSettle();
        final fileBounds = tester.getRect(find.text(longFile));
        expect(fileBounds.left, greaterThanOrEqualTo(0));
        expect(fileBounds.right, lessThanOrEqualTo(size.width));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const ValueKey(_folderId)));
        await tester.tap(find.byKey(const ValueKey(_folderId)));
        await tester.pump();
        expect(drive.calls.last.folder, _folderId);
        drive.calls.last.result.complete(
          CmsListing(videos: [_video(longFile)]),
        );
        await tester.pumpAndSettle();
        expect(find.text('上一级'), findsOneWidget);
        expect(find.text(longFolder), findsOneWidget);
        expect(
          tester.getRect(find.text(longFolder)).right,
          lessThanOrEqualTo(size.width),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'entering and returning folders rejects old page and child responses',
    (tester) async {
      final drive = _PendingDrive();
      await _open(tester, drive);
      drive.calls[0].result.complete(
        CmsListing(
          page: 1,
          pageCount: 2,
          videos: [_folder(), _video('根目录旧文件')],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      expect(drive.calls[1].folder, '0');
      expect(drive.calls[1].page, 2);
      await tester.tap(find.byKey(const ValueKey(_folderId)));
      await tester.pump();
      expect(drive.calls[2].folder, _folderId);
      expect(drive.calls[2].page, 1);
      expect(find.text('根目录旧文件'), findsNothing);
      await tester.tap(find.text('上一级'));
      await tester.pump();
      expect(drive.calls[3].folder, '0');
      expect(drive.calls[3].page, 1);
      drive.calls[3].result.complete(
        CmsListing(videos: [_folder(), _video('当前根目录文件')]),
      );
      await tester.pumpAndSettle();
      drive.calls[1].result.complete(
        CmsListing(page: 2, videos: [_video('迟到的根目录第二页')]),
      );
      drive.calls[2].result.complete(CmsListing(videos: [_video('迟到的子目录文件')]));
      await tester.pumpAndSettle();
      expect(find.text('当前根目录文件'), findsOneWidget);
      expect(find.text('迟到的根目录第二页'), findsNothing);
      expect(find.text('迟到的子目录文件'), findsNothing);
      expect(find.text('上一级'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final failure in [false, true]) {
    testWidgets(
      'closing Quark library safely ignores late ${failure ? 'failure' : 'success'}',
      (tester) async {
        final drive = _PendingDrive();
        await _open(tester, drive);
        await tester.tap(find.byIcon(CupertinoIcons.xmark_circle_fill));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        if (failure) {
          drive.calls.single.result.completeError(
            StateError('Late fixture failure'),
          );
        } else {
          drive.calls.single.result.complete(
            CmsListing(videos: [_video('关闭后迟到文件')]),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('夸克网盘 · 我的视频'), findsNothing);
        expect(find.text('打开我的夸克'), findsOneWidget);
        expect(find.text('关闭后迟到文件'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
