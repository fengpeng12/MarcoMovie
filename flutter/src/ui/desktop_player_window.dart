import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Owns native fullscreen for one player route. Native transitions are serialized
/// so a second double click or leaving the route cannot race a macOS animation.
class DesktopPlayerWindow extends ChangeNotifier with WindowListener {
  DesktopPlayerWindow({bool? macOS}) : _macOS = macOS ?? Platform.isMacOS {
    windowManager.addListener(this);
  }

  final bool _macOS;
  Future<void>? _ready;
  Future<void> _queue = Future<void>.value();
  Future<void>? _closed;
  Completer<void>? _transition;
  bool? _transitionTarget;
  bool? _initialFullscreen;
  bool _fullscreen = false;
  bool _changing = false;
  bool _closing = false;

  bool get fullscreen => _fullscreen;

  Future<void> initialize() => _ready ??= _capture();

  Future<void> _capture() async {
    _initialFullscreen = await windowManager.isFullScreen();
    _update(_initialFullscreen!);
    if (_fullscreen) await _titleBar(true);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // Keep the queue usable after a failed native call; its caller gets the error.
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> toggle() {
    if (_closing) return Future<void>.value();
    return _enqueue(() async {
      await initialize();
      await _setFullscreen(!await windowManager.isFullScreen());
    });
  }

  /// Returns false only when Escape should leave the player route.
  Future<bool> exitFullscreen() {
    if (_closing) return Future<bool>.value(true);
    return _enqueue(() async {
      await initialize();
      if (!await windowManager.isFullScreen()) return false;
      await _setFullscreen(false);
      return true;
    });
  }

  Future<void> _titleBar(bool full) => windowManager.setTitleBarStyle(
    // The generated Mac runner normally uses a transparent, hidden title.
    // Restore its traffic-light buttons on exit, and the normal Windows frame.
    full || _macOS ? TitleBarStyle.hidden : TitleBarStyle.normal,
    windowButtonVisibility: !full,
  );

  Future<void> _setFullscreen(bool full) async {
    _changing = true;
    try {
      if (await windowManager.isFullScreen() != full) {
        if (full) await _titleBar(true);
        final completed = Completer<void>();
        _transition = completed;
        _transitionTarget = full;
        await windowManager.setFullScreen(full);
        // AppKit returns from toggleFullScreen before its animation completes.
        // Do not restore the titlebar or issue another toggle during animation.
        if (_macOS) {
          await completed.future.timeout(const Duration(seconds: 8));
        }
      }
      final actual = await windowManager.isFullScreen();
      if (actual != full) {
        throw StateError('Window fullscreen transition failed');
      }
      await _titleBar(actual);
      _update(actual);
    } catch (_) {
      // A failed entry must not strand a normal window without its controls.
      final actual = await windowManager.isFullScreen();
      await _titleBar(actual);
      _update(actual);
      rethrow;
    } finally {
      _transition = null;
      _transitionTarget = null;
      _changing = false;
    }
  }

  void _update(bool full) {
    if (_fullscreen == full) return;
    _fullscreen = full;
    notifyListeners();
  }

  void _nativeFullscreen(bool full) {
    _update(full);
    if (_transitionTarget == full && !(_transition?.isCompleted ?? true)) {
      _transition!.complete();
    }
    if (!_changing && !_closing) {
      // Also handle the Mac green button / system fullscreen shortcut.
      unawaited(
        _enqueue(() async {
          await _titleBar(await windowManager.isFullScreen());
        }).catchError((Object error) {
          debugPrint('Window titlebar update failed: $error');
        }),
      );
    }
  }

  @override
  void onWindowEnterFullScreen() => _nativeFullscreen(true);

  @override
  void onWindowLeaveFullScreen() => _nativeFullscreen(false);

  Future<void> close() {
    _closing = true;
    return _closed ??= _enqueue(() async {
      try {
        await initialize();
        await _setFullscreen(_initialFullscreen!);
      } finally {
        windowManager.removeListener(this);
        super.dispose();
      }
    });
  }
}
