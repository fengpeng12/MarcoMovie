import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../core/cms_client.dart';
import '../core/emby_library.dart';
import '../core/csp_bridge.dart';
import '../core/models.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'desktop_player_window.dart';
import 'mobile_player_chrome.dart';
import 'source_verification_dialog.dart';

/// Apple AVPlayerViewController / Apple TV+ inspired video player with:
/// - Large center transport controls (Rewind 15s, Play/Pause, Fast-Forward 15s)
/// - Dedicated floating Progress Bar capsule (automatically hidden during Live TV)
/// - Compact scrollable Tool Dock (Bottom horizontal in Portrait, Right edge in Landscape)
/// - Full-width iOS 27 Liquid Glass Episode & Line Picker sheet.
class PlayerScreen extends StatefulWidget {
  final CmsSite site;
  final CmsVideo video;
  final int initialLineIndex;
  final int initialEpisodeIndex;
  final int initialPositionMs;
  final StorageService storage;
  final bool isLive;

  const PlayerScreen({
    super.key,
    required this.site,
    required this.video,
    required this.initialLineIndex,
    required this.initialEpisodeIndex,
    required this.storage,
    this.initialPositionMs = 0,
    this.isLive = false,
  });

  /// The resolver already applies origin rules and explicit playback headers.
  /// Re-merging subscription headers here would restore filtered credentials.
  Media mediaForPlayback(CmsEpisode episode, {Duration? start}) => Media(
    episode.url,
    httpHeaders: Map<String, String>.of(episode.headers),
    start: start,
  );

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _controller;
  final CmsClient _client = CmsClient();

  late int _lineIndex;
  late int _episodeIndex;
  late double _normalSpeed;
  late int _skipIntroSec;
  late int _skipOutroSec;
  late bool _autoNext;
  late String _repeatMode;
  late String _playerKernel;

  bool _allowHistory = false;
  bool _controlsVisible = true;
  bool _speedBoosting = false;
  String _hudText = '';
  String _playbackError = '';
  Object? _playbackErrorCause;
  bool _allowEvents = false;
  DesktopPlayerWindow? _desktopWindow;
  final MobilePlayerChrome _mobileChrome = MobilePlayerChrome();
  Future<void> _mediaChanges = Future<void>.value();
  void Function()? _releaseSourceSession;
  List<CmsEpisode> _qualityChoices = const [];
  bool get _desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  BoxFit _fit = BoxFit.contain;
  Timer? _hideTimer;
  Timer? _historyTimer;
  EmbyPlaybackSession? _embySession;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loading = true;
  bool _buffering = false;
  double _dragStartPosMs = 0;
  double _dragStartX = 0;
  int _dragTargetPosMs = 0;
  bool _isDraggingSeek = false;
  bool _isSliderDragging = false;
  double _sliderDragPosMs = 0;
  int _playSession = 0;
  int _pendingResumeMs = 0;
  int _lastKnownPositionMs = 0;
  int _lastKnownDurationMs = 0;
  int _lastPositionUiUpdateMs = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;
  String _videoCodec = '';
  String _audioCodec = '';
  String _activeStreamUrl = '';
  String _activeMediaUri = '';
  bool get _matchesActiveMedia {
    if (_activeMediaUri.isEmpty) return false;
    final playlist = _player.state.playlist;
    if (playlist.medias.isEmpty) return _allowEvents;
    return playlist.index >= 0 &&
        playlist.index < playlist.medias.length &&
        playlist.medias[playlist.index].uri == _activeMediaUri;
  }

  bool _introSkippedForSession = false;
  bool _outroSkippedForSession = false;
  final Set<int> _failedLineIndices = <int>{};

  CmsLine get _currentLine => widget.video.lines[_lineIndex];
  CmsEpisode get _currentEpisode => _currentLine.episodes[_episodeIndex];

  bool get _isLiveStream =>
      widget.isLive ||
      widget.site.key == 'live' ||
      (widget.site.api.isEmpty && widget.site.type == 1) ||
      CspBridge.isHuyaSite(widget.site) ||
      CspBridge.isDouyuSite(widget.site);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lineIndex = widget.initialLineIndex.clamp(
      0,
      widget.video.lines.length - 1,
    );
    _episodeIndex = widget.initialEpisodeIndex.clamp(
      0,
      _currentLine.episodes.length - 1,
    );
    _normalSpeed = widget.storage.playSpeed;
    _skipIntroSec = widget.storage.skipIntroSec;
    _skipOutroSec = widget.storage.skipOutroSec;
    _autoNext = widget.storage.autoNext;
    _repeatMode = widget.storage.repeatMode;
    _playerKernel = widget.storage.playerKernel;
    _fit = switch (widget.storage.defaultAspectMode) {
      'cover' => BoxFit.cover,
      'fill' => BoxFit.fill,
      _ => BoxFit.contain,
    };

    if (_desktop) {
      _desktopWindow = DesktopPlayerWindow()..addListener(_windowChanged);
      _desktopWindow!.initialize().catchError(_windowError);
    }
    _player = Player();
    unawaited(_applyPlayerKernel(_playerKernel));
    // Keep one source lease for this page, including pause and overlapping
    // episode/quality transitions. Release only after the decoder is disposed.
    _releaseSourceSession = _client.pinPlaybackSource(widget.site);
    _controller = VideoController(_player);

    _player.stream.width.listen((w) {
      if (!mounted || w == null || w <= 0 || w == _videoWidth) return;
      setState(() => _videoWidth = w);
    });
    _player.stream.height.listen((h) {
      if (!mounted || h == null || h <= 0 || h == _videoHeight) return;
      setState(() => _videoHeight = h);
    });
    _player.stream.track.listen((track) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      final vCodec = (track.video.codec ?? track.video.decoder ?? '').trim();
      final aCodec = (track.audio.codec ?? track.audio.decoder ?? '').trim();
      if (vCodec != _videoCodec || aCodec != _audioCodec) {
        setState(() {
          _videoCodec = vCodec;
          _audioCodec = aCodec;
        });
      }
    });

    _player.stream.position.listen((pos) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      final nextPos = (!_isDraggingSeek && !_isSliderDragging)
          ? ((_pendingResumeMs > 0 && pos.inMilliseconds < 2000)
                ? Duration(milliseconds: _pendingResumeMs)
                : pos)
          : _position;
      if (pos.inMilliseconds >= 1000) {
        _lastKnownPositionMs = pos.inMilliseconds;
      }
      final shouldClearLoading = pos > Duration.zero && _loading;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final shouldRebuildUi =
          shouldClearLoading ||
          (_controlsVisible &&
              !_isDraggingSeek &&
              !_isSliderDragging &&
              (nowMs - _lastPositionUiUpdateMs >= 250 || !_playing));
      if (shouldRebuildUi) {
        _lastPositionUiUpdateMs = nowMs;
        setState(() {
          _position = nextPos;
          if (shouldClearLoading) {
            _loading = false;
          }
        });
      } else {
        _position = nextPos;
      }
      _embySession?.update(pos.inMilliseconds, !_playing);
      final effectiveDur = _duration.inMilliseconds > 0
          ? _duration
          : Duration(milliseconds: _lastKnownDurationMs);
      if (!_outroSkippedForSession &&
          _skipOutroSec > 0 &&
          effectiveDur.inSeconds > _skipOutroSec + 30 &&
          pos.inSeconds > 10 &&
          (effectiveDur - pos).inSeconds <= _skipOutroSec) {
        _outroSkippedForSession = true;
        _showHud('已自动跳过片尾 ${_skipOutroSec}s');
        _handleEpisodeEnd();
      }
    });

    _player.stream.duration.listen((dur) {
      if (!mounted || !_allowEvents || !_matchesActiveMedia) return;
      setState(() {
        if (dur.inMilliseconds > 0) {
          if (dur.inMilliseconds > _lastKnownDurationMs) {
            _lastKnownDurationMs = dur.inMilliseconds;
          }
          _duration =
              (!_isLiveStream && _lastKnownDurationMs > dur.inMilliseconds)
              ? Duration(milliseconds: _lastKnownDurationMs)
              : dur;
        } else if (!_isLiveStream && _lastKnownDurationMs > 0) {
          _duration = Duration(milliseconds: _lastKnownDurationMs);
        } else {
          _duration = dur;
        }
        if (dur > Duration.zero && _loading) {
          _loading = false;
        }
      });
      if (dur > Duration.zero && _pendingResumeMs > 0) {
        final sessionAtSeek = _playSession;
        final maxSeek = math.max(0, dur.inMilliseconds - 2000);
        final targetMs = _pendingResumeMs.clamp(0, maxSeek);
        _pendingResumeMs = 0;
        _introSkippedForSession = true;
        if (targetMs > 0) {
          _lastKnownPositionMs = targetMs;
          setState(() {
            _position = Duration(milliseconds: targetMs);
          });
          _player.seek(Duration(milliseconds: targetMs));
          _showHud(
            '已为您续播至 ${_formatDuration(Duration(milliseconds: targetMs))}',
          );
          // Reinforce seek after 550ms in case an HLS stream resets to 0 on initial segment decode
          Future.delayed(const Duration(milliseconds: 550), () {
            if (!mounted || sessionAtSeek != _playSession) return;
            if (_position.inMilliseconds < targetMs - 3000) {
              _player.seek(Duration(milliseconds: targetMs));
            }
          });
        }
      } else if (dur > Duration.zero &&
          !_introSkippedForSession &&
          _skipIntroSec > 0 &&
          dur.inSeconds > _skipIntroSec + 30) {
        _introSkippedForSession = true;
        _player.seek(Duration(seconds: _skipIntroSec));
        _showHud('已自动跳过片头 ${_skipIntroSec}s');
      }
    });

    _player.stream.playing.listen((playing) {
      if (mounted && _allowEvents && _matchesActiveMedia) {
        if (playing && widget.site.isEmby && _embySession == null) {
          _openCurrentEpisode(resumeMs: 0);
          return;
        }
        setState(() {
          _playing = playing;
          if (playing) _loading = false;
        });
        if (!playing) {
          _saveProgress();
        }
        if (playing || _position > Duration.zero) {
          _embySession?.update(_position.inMilliseconds, !playing, force: true);
        }
      }
    });

    _player.stream.buffering.listen((buffering) {
      if (mounted && _allowEvents && _matchesActiveMedia)
        setState(() => _buffering = buffering);
    });

    _player.stream.completed.listen((completed) {
      if (completed &&
          mounted &&
          _allowEvents &&
          _matchesActiveMedia &&
          !_outroSkippedForSession) {
        _embySession?.stop(_position.inMilliseconds);
        _embySession = null;
        _handleEpisodeEnd();
      }
    });

    _player.stream.error.listen((message) {
      if (mounted &&
          _allowEvents &&
          _matchesActiveMedia &&
          message.isNotEmpty &&
          !_playing &&
          _duration <= Duration.zero &&
          _position <= Duration.zero) {
        _failPlayback();
      }
    });

    _openCurrentEpisode(resumeMs: widget.initialPositionMs);
    _historyTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _saveProgress(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _saveProgress();
    }
  }

  int _lookupSavedResumeForCurrentEpisode() {
    if (widget.site.isEffectivelyPrivate) return 0;
    for (final entry in widget.storage.getWatchHistory()) {
      if (entry.site == widget.site.key && entry.id == widget.video.id) {
        if ((entry.line == _currentLine.name && entry.index == _episodeIndex) ||
            entry.episode == _currentEpisode.name) {
          if (entry.duration > 0) {
            _lastKnownDurationMs = entry.duration;
          }
          return entry.resumePosition;
        }
        break;
      }
    }
    return 0;
  }

  void _handleEpisodeEnd() {
    if (_repeatMode == 'one') {
      if (widget.site.isEmby) {
        _openCurrentEpisode(resumeMs: 0);
        return;
      }
      _player.seek(Duration.zero);
      _player.play();
      _outroSkippedForSession = false;
      return;
    }
    if (_autoNext) {
      if (_episodeIndex < _currentLine.episodes.length - 1) {
        _stepEpisode(1);
      } else if (_repeatMode == 'all' && _currentLine.episodes.isNotEmpty) {
        _saveProgress();
        setState(() => _episodeIndex = 0);
        _openCurrentEpisode(resumeMs: 0);
      }
    }
  }

  bool _tryAutoSwitchLine({String reason = '当前线路不可用'}) {
    if (_isLiveStream || widget.video.lines.length <= 1) return false;
    _failedLineIndices.add(_lineIndex);
    final totalLines = widget.video.lines.length;
    int? chosenIdx;
    for (int pass = 0; pass < 2 && chosenIdx == null; pass++) {
      for (int step = 1; step < totalLines; step++) {
        final candidateIdx = (_lineIndex + step) % totalLines;
        if (_failedLineIndices.contains(candidateIdx)) continue;
        final candidateLine = widget.video.lines[candidateIdx];
        if (candidateLine.episodes.isEmpty) continue;
        final epIdx = _episodeIndex.clamp(0, candidateLine.episodes.length - 1);
        final candidateEp = candidateLine.episodes[epIdx];
        if (candidateEp.url == _activeStreamUrl ||
            candidateEp.url == _currentEpisode.url) {
          continue;
        }
        if (pass == 0 && CspBridge.isDeadOrStubStreamUrl(candidateEp.url)) {
          continue;
        }
        chosenIdx = candidateIdx;
        break;
      }
    }
    if (chosenIdx == null) return false;
    final nextIdx = chosenIdx;
    final keepPos = _position.inMilliseconds >= 1000
        ? _position.inMilliseconds
        : _lastKnownPositionMs;
    setState(() {
      _lineIndex = nextIdx;
      _episodeIndex = _episodeIndex.clamp(
        0,
        widget.video.lines[nextIdx].episodes.length - 1,
      );
    });
    _showHud('$reason，已自动切换至 ${widget.video.lines[nextIdx].name}');
    _openCurrentEpisode(resumeMs: keepPos);
    return true;
  }

  void _failPlayback([Object? error]) {
    if (!mounted) return;
    _embySession?.stop(_position.inMilliseconds);
    _embySession = null;
    if (!CmsClient.needsSourceVerification(widget.site, error) &&
        _tryAutoSwitchLine(reason: '当前线路不可用')) {
      return;
    }
    setState(() {
      _allowEvents = false;
      _allowHistory = false;
      _loading = false;
      _buffering = false;
      _playing = false;
      _controlsVisible = true;
      _playbackError = '播放失败，请重试或切换线路';
      _playbackErrorCause = error;
      if (CmsClient.needsSourceVerification(widget.site, error)) {
        _playbackError = '此片源需要完成验证码后继续播放';
      }
    });
    _player.pause();
  }

  Future<void> _changeMedia(int session, Future<void> Function() action) {
    final next = _mediaChanges.then((_) async {
      if (mounted && session == _playSession) await action();
    });
    _mediaChanges = next.catchError((_) {});
    return next;
  }

  Future<void> _openCurrentEpisode({int? resumeMs, CmsEpisode? quality}) async {
    final session = ++_playSession;
    if (quality == null) _qualityChoices = const [];
    _embySession?.stop(_position.inMilliseconds);
    _embySession = null;
    _allowHistory = false;
    _allowEvents = false;
    _playbackError = '';
    _playbackErrorCause = null;
    try {
      await _changeMedia(session, () => _player.stop());
    } catch (_) {
      if (session == _playSession) _failPlayback();
      return;
    }
    if (!mounted || session != _playSession) return;
    final effectiveResumeMs = (resumeMs != null && resumeMs > 0)
        ? resumeMs
        : (resumeMs == null ? _lookupSavedResumeForCurrentEpisode() : 0);
    _pendingResumeMs = effectiveResumeMs > 0 ? effectiveResumeMs : 0;
    _lastKnownPositionMs = _pendingResumeMs;
    _lastKnownDurationMs = 0;
    _lookupSavedResumeForCurrentEpisode();
    _introSkippedForSession = _pendingResumeMs > 0;
    _outroSkippedForSession = false;

    if (!_currentEpisode.isDirectPlayable &&
        !_currentEpisode.needsSourceResolution) {
      _pendingResumeMs = 0;
      if (mounted) {
        setState(() {
          _loading = false;
          _playing = false;
          _position = Duration.zero;
          _duration = Duration.zero;
          _playbackError = '当前剧集需要专用插件解析，请切换线路';
          _controlsVisible = true;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
        _videoWidth = 0;
        _videoHeight = 0;
        _videoCodec = '';
        _audioCodec = '';
        _activeStreamUrl = _currentEpisode.url;
        _position = _pendingResumeMs > 0
            ? Duration(milliseconds: _pendingResumeMs)
            : Duration.zero;
        _duration = Duration.zero;
      });
    }

    try {
      var resolvedEpisode = quality ?? (_currentEpisode.isLocalFile
          ? _currentEpisode
          : widget.isLive
          ? _client.resolveLiveEpisodeForPlayback(widget.site, _currentEpisode)
          : await _client.resolveEpisodeForPlayback(
              widget.site,
              _currentEpisode,
            ));
      if (quality == null &&
          resolvedEpisode.variants.length > 1 &&
          widget.storage.preferredQuality == '4k_netdisk') {
        for (final v in resolvedEpisode.variants) {
          final vn = v.name.toLowerCase();
          if (vn.contains('原画') || vn.contains('4k') || vn.contains('2160')) {
            resolvedEpisode = CmsEpisode(
              name: resolvedEpisode.name,
              url: v.url,
              headers: v.headers,
              playbackSession: resolvedEpisode.playbackSession,
              variants: resolvedEpisode.variants,
              externalAudioUrl: v.externalAudioUrl.isNotEmpty
                  ? v.externalAudioUrl
                  : resolvedEpisode.externalAudioUrl,
            );
            break;
          }
        }
      }
      EmbyPlaybackSession? report;
      if (widget.site.isEmby && resolvedEpisode.playbackSession.isNotEmpty) {
        report = (await EmbyLibrary.open(widget.site)).track(resolvedEpisode);
      }
      if (!mounted || session != _playSession) {
        report?.stop();
        return;
      }
      _embySession = report;
      if (quality == null) _qualityChoices = resolvedEpisode.variants;
      final rawResolvedUrl = resolvedEpisode.url;
      final safePlayUrl = (rawResolvedUrl.startsWith('http://') ||
                  rawResolvedUrl.startsWith('https://')) &&
              RegExp(r'[^\x00-\x7F]').hasMatch(rawResolvedUrl)
          ? Uri.encodeFull(rawResolvedUrl)
          : rawResolvedUrl;
      _activeStreamUrl = safePlayUrl;
      _activeMediaUri = Media(safePlayUrl).uri;

      await _changeMedia(session, () async {
        _allowEvents = true;
        final baseMedia = widget.mediaForPlayback(
          resolvedEpisode,
          start: _pendingResumeMs > 0
              ? Duration(milliseconds: _pendingResumeMs)
              : null,
        );
        final headers = Map<String, String>.of(baseMedia.httpHeaders ?? const {});
        if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
          headers['User-Agent'] =
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
        }
        try {
          final dyn = _player.platform as dynamic;
          await dyn.setProperty('tls-verify', 'yes');
          final ua = headers.entries
              .firstWhere(
                (e) => e.key.toLowerCase() == 'user-agent',
                orElse: () => const MapEntry('User-Agent', ''),
              )
              .value;
          if (ua.isNotEmpty) {
            await dyn.setProperty('user-agent', ua);
          }
          final ref = headers.entries
              .firstWhere(
                (e) => e.key.toLowerCase() == 'referer',
                orElse: () => const MapEntry('Referer', ''),
              )
              .value;
          await dyn.setProperty('referrer', ref);
        } catch (_) {}
        await _player.open(
          Media(
            safePlayUrl,
            httpHeaders: headers,
            start: baseMedia.start,
          ),
          play: true,
        );
        if (resolvedEpisode.externalAudioUrl.isNotEmpty) {
          await _player.setAudioTrack(AudioTrack.uri(resolvedEpisode.externalAudioUrl));
        }
      });
      if (!mounted || session != _playSession || !_allowEvents) return;
      _allowHistory = true;
      await _player.setRate(_normalSpeed);
      if (!mounted || session != _playSession) return;
      _scheduleHide();
    } catch (error) {
      if (mounted && session == _playSession) _failPlayback(error);
    }
  }

  Future<void> _saveProgress() async {
    if (!_allowHistory ||
        _isLiveStream ||
        widget.site.key == 'live' ||
        widget.site.isEffectivelyPrivate) {
      return;
    }
    final livePosMs = _position.inMilliseconds;
    final effectivePosMs = _pendingResumeMs > 0
        ? _pendingResumeMs
        : (livePosMs >= 1000 ? livePosMs : _lastKnownPositionMs);
    final effectiveDurMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _lastKnownDurationMs;
    if (effectiveDurMs <= 0 && effectivePosMs <= 0) {
      return;
    }
    var resolvedPoster = widget.video.poster.trim();
    if (resolvedPoster.isEmpty) {
      for (final existing in widget.storage.getWatchHistory()) {
        if ((existing.site == widget.site.key &&
                existing.id == widget.video.id) ||
            existing.title == widget.video.title) {
          if (existing.poster.trim().isNotEmpty) {
            resolvedPoster = existing.poster.trim();
            break;
          }
        }
      }
    }
    await widget.storage.upsertWatchHistory(
      WatchHistoryEntry(
        site: widget.site.key,
        id: widget.video.id,
        title: widget.video.title,
        poster: resolvedPoster,
        line: _currentLine.name,
        episode: _currentEpisode.name,
        index: _episodeIndex,
        position: effectivePosMs,
        duration: effectiveDurMs,
        updated: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _onPointerMove(Offset delta) {
    if (!_desktop || delta.distanceSquared < 0.25) return;
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHide();
  }

  void _windowChanged() {
    if (mounted) setState(() {});
  }

  void _windowError(Object error) {
    debugPrint('Player fullscreen failed: $error');
    if (mounted) _showHud('窗口切换失败，请重试');
  }

  String _fullscreenLabel(bool isLandscape) => _desktop
      ? (_desktopWindow?.fullscreen == true ? '退出全屏' : '全屏')
      : (isLandscape ? '竖屏' : '全屏');

  Future<void> _desktopEscape() async {
    try {
      final exited = await _desktopWindow!.exitFullscreen();
      if (mounted && !exited) Navigator.of(context).maybePop();
    } catch (error) {
      _windowError(error);
    }
  }

  Future<void> _toggleOrientation() async {
    if (_desktop) {
      try {
        await _desktopWindow!.toggle();
        if (mounted) _scheduleHide();
      } catch (error) {
        _windowError(error);
      }
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final currentlyLandscape = size.width > size.height;
    try {
      final applied = await _mobileChrome.setLandscape(!currentlyLandscape);
      if (!mounted || !applied) return;
      _showHud(currentlyLandscape ? '已切换为竖屏观看' : '已切换为全屏横屏观看');
      _scheduleHide();
    } catch (error) {
      _windowError(error);
    }
  }

  void _stepEpisode(int delta) {
    final next = _episodeIndex + delta;
    if (next < 0 || next >= _currentLine.episodes.length) return;
    _failedLineIndices.clear();
    _saveProgress();
    setState(() => _episodeIndex = next);
    _openCurrentEpisode(resumeMs: 0);
  }

  void _seekRelative(int seconds) {
    if (_duration.inMilliseconds <= 0) return;
    final targetMs = (_position.inMilliseconds + seconds * 1000).clamp(
      0,
      _duration.inMilliseconds,
    );
    setState(() => _position = Duration(milliseconds: targetMs));
    _player.seek(Duration(milliseconds: targetMs));
    _showHud(
      '${seconds >= 0 ? "快进" : "快退"} ${_formatDuration(Duration(milliseconds: targetMs))}',
    );
    _scheduleHide();
  }

  void _showHud(String text) {
    if (!mounted) return;
    setState(() => _hudText = text);
    Future.delayed(const Duration(milliseconds: 1100), () {
      if (mounted && !_speedBoosting && _hudText == text) {
        setState(() => _hudText = '');
      }
    });
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get _fitLabel {
    if (_fit == BoxFit.cover) return '裁切';
    if (_fit == BoxFit.fill) return '铺满';
    return '适应';
  }

  String get _repeatLabel {
    if (_repeatMode == 'one') return '单集';
    if (_repeatMode == 'all') return '列表';
    return '关闭';
  }

  String get _kernelShortLabel => switch (_playerKernel) {
    'ijk' => '兼容',
    'mpv' => '大缓冲',
    _ => '均衡',
  };

  double _desktopScale(Size size) {
    if (!_desktop || size.width <= 1200) return 1.0;
    return (1.0 + (size.width - 1200) / 1400.0).clamp(1.0, 1.38);
  }

  Future<void> _applyPlayerKernel(String kernel) async {
    try {
      final dyn = _player.platform as dynamic;
      await dyn.setProperty('tls-verify', 'yes');
      switch (kernel) {
        case 'ijk':
          await dyn.setProperty('hwdec', 'auto-copy');
          await dyn.setProperty('cache', 'yes');
          await dyn.setProperty('demuxer-max-bytes', '67108864');
          await dyn.setProperty('demuxer-readahead-secs', '20');
          await dyn.setProperty('network-timeout', '25');
          await dyn.setProperty(
            'demuxer-lavf-o',
            'reconnect=1,reconnect_delay_max=5,analyzeduration=2000000,probesize=2000000',
          );
          break;
        case 'mpv':
          await dyn.setProperty('hwdec', 'auto-safe');
          await dyn.setProperty('cache', 'yes');
          await dyn.setProperty('demuxer-max-bytes', '134217728');
          await dyn.setProperty('demuxer-readahead-secs', '30');
          await dyn.setProperty('network-timeout', '20');
          await dyn.setProperty(
            'demuxer-lavf-o',
            'reconnect=1,reconnect_delay_max=4',
          );
          break;
        case 'exo':
        default:
          await dyn.setProperty('hwdec', 'auto');
          await dyn.setProperty('cache', 'yes');
          await dyn.setProperty('demuxer-max-bytes', '67108864');
          await dyn.setProperty('demuxer-readahead-secs', '15');
          await dyn.setProperty('network-timeout', '15');
          await dyn.setProperty(
            'demuxer-lavf-o',
            'reconnect=1,reconnect_delay_max=4,fflags=+discardcorrupt+genpts',
          );
          break;
      }
    } catch (_) {}
  }

  String get _videoSpecsLabel {
    final parts = <String>[];
    final epNameLower = _currentEpisode.name.toLowerCase();
    final lineNameLower = _currentLine.name.toLowerCase();
    final siteNameLower = widget.site.name.toLowerCase();
    final is4kContext = epNameLower.contains('4k') ||
        epNameLower.contains('2160p') ||
        epNameLower.contains('remux') ||
        epNameLower.contains('uhd') ||
        lineNameLower.contains('4k') ||
        lineNameLower.contains('原画') ||
        lineNameLower.contains('夸父') ||
        lineNameLower.contains('优汐') ||
        lineNameLower.contains('嘟嘟') ||
        lineNameLower.contains('阿狸') ||
        siteNameLower.contains('4k');
    if (_videoWidth > 0 && _videoHeight > 0) {
      final maxDim = math.max(_videoWidth, _videoHeight);
      final minDim = math.min(_videoWidth, _videoHeight);
      final tier = (maxDim >= 3800 || minDim >= 2100)
          ? '4K '
          : (maxDim >= 2500 || minDim >= 1400)
          ? '2K '
          : (maxDim >= 1900 || minDim >= 1000)
          ? '1080P '
          : (maxDim >= 1200 || minDim >= 700)
          ? '720P '
          : '';
      parts.add('$tier$_videoWidth × $_videoHeight');
    } else if (is4kContext) {
      parts.add('4K UHD');
    }
    if (epNameLower.contains('hdr') || epNameLower.contains('dv')) {
      parts.add('HDR');
    }
    final vc = _videoCodec.toLowerCase();
    if (vc.isNotEmpty) {
      if (vc.contains('hevc') ||
          vc.contains('h265') ||
          vc.contains('hev1')) {
        parts.add('HEVC');
      } else if (vc.contains('avc') || vc.contains('h264')) {
        parts.add('H.264');
      } else if (vc.contains('av01') || vc.contains('av1')) {
        parts.add('AV1');
      } else if (vc.contains('vp9')) {
        parts.add('VP9');
      } else {
        parts.add(_videoCodec.toUpperCase());
      }
    }
    final ac = _audioCodec.toLowerCase();
    if (ac.isNotEmpty) {
      if (ac.contains('eac3') || ac.contains('ec-3')) {
        parts.add('EAC3');
      } else if (ac.contains('ac3') || ac.contains('ac-3')) {
        parts.add('AC3');
      } else if (ac.contains('aac') || ac.contains('mp4a')) {
        parts.add('AAC');
      } else if (ac.contains('flac')) {
        parts.add('FLAC');
      } else if (ac.contains('opus')) {
        parts.add('OPUS');
      }
    }
    final hint = '${_activeStreamUrl.split('?').first} ${_currentEpisode.name}'
        .toLowerCase();
    if (hint.contains('.mkv')) {
      parts.add('MKV');
    } else if (hint.contains('.mp4')) {
      parts.add('MP4');
    } else if (hint.contains('.m3u8')) {
      parts.add('HLS');
    } else if (hint.contains('.flv')) {
      parts.add('FLV');
    } else if (hint.contains('.ts')) {
      parts.add('TS');
    }
    return parts.join(' · ');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _historyTimer?.cancel();
    _saveProgress();
    _embySession?.stop(_position.inMilliseconds);
    _embySession = null;
    _mobileChrome.close().catchError((Object error) {
      debugPrint('Player system UI restore failed: $error');
    });
    _allowEvents = false;
    _desktopWindow?.removeListener(_windowChanged);
    _desktopWindow?.close().catchError((Object error) {
      debugPrint('Player window restore failed: $error');
    });
    final releaseSource = _releaseSourceSession;
    _releaseSourceSession = null;
    _mediaChanges.whenComplete(() async {
      try { await _player.dispose(); } finally { releaseSource?.call(); }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.space ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select) {
            _player.playOrPause();
            setState(() => _controlsVisible = true);
            _scheduleHide();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _seekRelative(15);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _seekRelative(-15);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
              event.logicalKey == LogicalKeyboardKey.arrowDown) {
            final volume =
                (_player.state.volume +
                        (event.logicalKey == LogicalKeyboardKey.arrowUp
                            ? 5
                            : -5))
                    .clamp(0.0, 100.0);
            _player.setVolume(volume);
            _showHud('音量 ${volume.round()}%');
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyF ||
              (_desktop && event.logicalKey == LogicalKeyboardKey.f11)) {
            _toggleOrientation();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_desktop) {
              _desktopEscape();
            } else {
              Navigator.of(context).maybePop();
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: _desktop && !_controlsVisible && _playing
              ? SystemMouseCursors.none
              : SystemMouseCursors.basic,
          onHover: (event) => _onPointerMove(event.delta),
          child: Listener(
            onPointerMove: (event) => _onPointerMove(event.delta),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onDoubleTap: () {
            if (_desktop) {
              _toggleOrientation();
              return;
            }
            _player.playOrPause();
            setState(() => _controlsVisible = true);
            _scheduleHide();
          },
          onLongPressStart: (_) {
            if (_isLiveStream) return;
            if (_playing && _duration.inMilliseconds > 0) {
              setState(() {
                _speedBoosting = true;
                _hudText = '2.0× 倍速播放中 · 松手恢复';
              });
              _player.setRate(2.0);
            }
          },
          onLongPressEnd: (_) {
            if (_speedBoosting) {
              _player.setRate(_normalSpeed);
              setState(() {
                _speedBoosting = false;
                _hudText = '';
              });
            }
          },
          onHorizontalDragStart: (details) {
            if (_isLiveStream || _duration.inMilliseconds <= 0) return;
            _dragStartPosMs = _position.inMilliseconds.toDouble();
            _dragStartX = details.localPosition.dx;
            _dragTargetPosMs = _position.inMilliseconds;
            _isDraggingSeek = true;
          },
          onHorizontalDragUpdate: (details) {
            if (_isLiveStream ||
                _duration.inMilliseconds <= 0 ||
                !_isDraggingSeek) {
              return;
            }
            final width = MediaQuery.sizeOf(context).width.clamp(200.0, 4000.0);
            final dx = details.localPosition.dx - _dragStartX;
            final ratio = (dx.abs() / width).clamp(0.0, 1.0);
            final speedScale = 0.55 + 1.35 * ratio;
            final spanMs = (_duration.inMilliseconds / 5.0).clamp(
              60000.0,
              300000.0,
            );
            final deltaMs = (dx / width) * spanMs * speedScale;
            final previewMs = (_dragStartPosMs + deltaMs).round().clamp(
              0,
              _duration.inMilliseconds,
            );
            setState(() {
              _dragTargetPosMs = previewMs;
              _hudText =
                  '${dx >= 0 ? "快进至" : "快退至"} ${_formatDuration(Duration(milliseconds: previewMs))} / ${_formatDuration(_duration)}';
            });
          },
          onHorizontalDragEnd: (_) {
            if (_isLiveStream || !_isDraggingSeek) return;
            final targetMs = _dragTargetPosMs.clamp(
              0,
              _duration.inMilliseconds,
            );
            setState(() {
              _isDraggingSeek = false;
              _position = Duration(milliseconds: targetMs);
              _hudText = '';
            });
            _player.seek(Duration(milliseconds: targetMs));
            _scheduleHide();
          },
          onHorizontalDragCancel: () {
            if (!_isDraggingSeek) return;
            setState(() {
              _isDraggingSeek = false;
              _hudText = '';
            });
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: RepaintBoundary(
                  child: Video(
                    controller: _controller,
                    fit: _fit,
                    controls: NoVideoControls,
                  ),
                ),
              ),
              if (_hudText.isNotEmpty)
                Align(
                  alignment: const Alignment(0, -0.74),
                  child: AppleGlassSurface(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    child: Text(
                      _hudText,
                      style: const TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (_controlsVisible) _buildAppleChromeOverlay(context),
              if (_playbackError.isNotEmpty)
                Center(
                  child: AppleGlassSurface(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_playbackError, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        if (CmsClient.needsSourceVerification(widget.site, _playbackErrorCause))
                          SourceVerificationButton(key: ValueKey('verification-$_playSession'),
                            client: _client, site: widget.site,
                            onVerified: () => _openCurrentEpisode(resumeMs: _pendingResumeMs)),
                        TextButton(
                          onPressed: () => _openCurrentEpisode(),
                          child: const Text('重试播放'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_loading || _buffering)
                Center(
                  child: AppleGlassSurface(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 15,
                    ),
                    borderRadius: BorderRadius.circular(999),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CupertinoActivityIndicator(radius: 11),
                        const SizedBox(width: 12),
                        Text(
                          '正在加载 ${_currentEpisode.name}…',
                          style: const TextStyle(
                            color: AppleColors.labelPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppleChromeOverlay(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final scale = _desktopScale(size);
    final leftInset = (isLandscape ? 16.0 : 14.0) * scale;
    final rightDockEdge = (isLandscape ? 8.0 : 14.0) * scale;
    final dockReserve = 64.0 * scale;

    return SizedBox.expand(
      child: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Top Header Bar (Back + Title + Live Badge / Orientation Button)
            Positioned(
              left: leftInset,
              right: isLandscape ? rightDockEdge + dockReserve : 14 * scale,
              top: 10 * scale,
              child: _buildTopHeader(context, isLandscape, scale),
            ),

            // 2. Large Center Transport Buttons (Rewind 15s / Play-Pause / Fast-Forward 15s)
            if (!_loading && !_buffering)
              Center(
                child: Padding(
                  padding: EdgeInsets.only(right: isLandscape ? 32 * scale : 0),
                  child: _buildCenterTransportButtons(scale),
                ),
              ),

            // 3. Landscape Right-side Compact Scrollable Tool Dock (tucked near right edge)
            if (isLandscape)
              Positioned(
                right: rightDockEdge,
                top: 14 * scale,
                bottom: 14 * scale,
                child: Center(
                  child: _buildScrollableToolDock(isLandscape: true, scale: scale),
                ),
              ),

            // 4. Bottom Floating Progress Bar Capsule (hidden during Live TV)
            //    + Bottom Scrollable Tool Dock in Portrait
            Positioned(
              left: leftInset,
              right: isLandscape ? rightDockEdge + dockReserve : 14 * scale,
              bottom: 10 * scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_isLiveStream)
                    _buildProgressBarCapsule(context, isLandscape, scale),
                  if (!isLandscape) ...[
                    if (!_isLiveStream) SizedBox(height: 10 * scale),
                    _buildScrollableToolDock(isLandscape: false, scale: scale),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopHeader(BuildContext context, bool isLandscape, double scale) {
    return Row(
      children: [
        CupertinoButton(
          padding: EdgeInsets.zero,
          minSize: 36 * scale,
          onPressed: () => Navigator.of(context).maybePop(),
          child: AppleGlassSurface(
            padding: EdgeInsets.symmetric(
              horizontal: 13 * scale,
              vertical: 7.5 * scale,
            ),
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.chevron_back,
                  color: AppleColors.labelPrimary,
                  size: 16 * scale,
                ),
                SizedBox(width: 4 * scale),
                Text(
                  '返回',
                  style: TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13 * scale,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: 12 * scale),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      widget.video.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 16.5 * scale,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  if (_videoSpecsLabel.isNotEmpty) ...[
                    SizedBox(width: 8 * scale),
                    AppleGlassSurface(
                      key: const Key('player-video-specs'),
                      padding: EdgeInsets.symmetric(
                        horizontal: 7.5 * scale,
                        vertical: 2.5 * scale,
                      ),
                      borderRadius: BorderRadius.circular(999),
                      child: Text(
                        _videoSpecsLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFFE5E7EB),
                          fontSize: 10.5 * scale,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  if (_isLiveStream) ...[
                    SizedBox(width: 8 * scale),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 7 * scale,
                        vertical: 2 * scale,
                      ),
                      decoration: BoxDecoration(
                        color: AppleColors.systemRed.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '直播中',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10.5 * scale,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              SizedBox(height: 2 * scale),
              Text(
                '${_currentEpisode.name} · ${_currentLine.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 12 * scale,
                ),
              ),
            ],
          ),
        ),
        if (_isLiveStream) ...[
          SizedBox(width: 10 * scale),
          CupertinoButton(
            key: const Key('player-fullscreen-toggle'),
            padding: EdgeInsets.zero,
            minSize: 34 * scale,
            onPressed: _toggleOrientation,
            child: AppleGlassSurface(
              padding: EdgeInsets.symmetric(
                horizontal: 11 * scale,
                vertical: 7 * scale,
              ),
              borderRadius: BorderRadius.circular(999),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    (_desktop ? _desktopWindow?.fullscreen == true : isLandscape)
                        ? CupertinoIcons.fullscreen_exit
                        : CupertinoIcons.fullscreen,
                    color: AppleColors.labelPrimary,
                    size: 15 * scale,
                  ),
                  SizedBox(width: 4 * scale),
                  Text(
                    _fullscreenLabel(isLandscape),
                    style: TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 12 * scale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Large center screen transport controls: Rewind 15s, Play/Pause, Fast-Forward 15s.
  /// For Live TV streams, only the central Play/Pause button is shown.
  Widget _buildCenterTransportButtons([double scale = 1.0]) {
    if (_isLiveStream) {
      return _buildCenterCircleButton(
        key: const Key('player-center-play-pause'),
        icon: _playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
        size: 78 * scale,
        iconSize: 36 * scale,
        hero: true,
        onTap: () {
          _player.playOrPause();
          _scheduleHide();
        },
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildCenterCircleButton(
          key: const Key('player-center-rewind'),
          icon: CupertinoIcons.gobackward_15,
          size: 60 * scale,
          iconSize: 26 * scale,
          hero: false,
          onTap: () => _seekRelative(-15),
        ),
        SizedBox(width: 30 * scale),
        _buildCenterCircleButton(
          key: const Key('player-center-play-pause'),
          icon: _playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
          size: 78 * scale,
          iconSize: 36 * scale,
          hero: true,
          onTap: () {
            _player.playOrPause();
            _scheduleHide();
          },
        ),
        SizedBox(width: 30 * scale),
        _buildCenterCircleButton(
          key: const Key('player-center-forward'),
          icon: CupertinoIcons.goforward_15,
          size: 60 * scale,
          iconSize: 26 * scale,
          hero: false,
          onTap: () => _seekRelative(15),
        ),
      ],
    );
  }

  Widget _buildCenterCircleButton({
    Key? key,
    required IconData icon,
    required double size,
    required double iconSize,
    required bool hero,
    required VoidCallback onTap,
  }) {
    return CupertinoButton(
      key: key,
      padding: EdgeInsets.zero,
      minSize: size,
      onPressed: () {
        _scheduleHide();
        onTap();
      },
      child: AppleGlassSurface(
        width: size,
        height: size,
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(size / 2),
        backgroundColor: hero
            ? const Color(0xD8FFFFFF)
            : const Color(0x78242429),
        child: Center(
          child: Icon(
            icon,
            color: hero ? Colors.black : AppleColors.labelPrimary,
            size: iconSize,
          ),
        ),
      ),
    );
  }

  /// Standalone floating Progress Bar capsule with Fullscreen / Orientation toggle button.
  Widget _buildProgressBarCapsule(
    BuildContext context,
    bool isLandscape, [
    double scale = 1.0,
  ]) {
    final effectiveDurationMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : _lastKnownDurationMs;
    final hasDuration = effectiveDurationMs > 0;
    final maxMs = hasDuration ? effectiveDurationMs.toDouble() : 1.0;
    final activePosMs = _isDraggingSeek
        ? _dragTargetPosMs.toDouble()
        : (_isSliderDragging
              ? _sliderDragPosMs
              : _position.inMilliseconds.toDouble());
    final curMs = hasDuration ? activePosMs.clamp(0.0, maxMs) : 0.0;
    final activeDuration = Duration(
      milliseconds: activePosMs.clamp(0.0, 86400000.0).round(),
    );
    final totalDuration = Duration(milliseconds: effectiveDurationMs);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 740 * scale),
      child: AppleGlassSurface(
        key: const Key('player-progress-bar'),
        padding: EdgeInsets.symmetric(
          horizontal: 16 * scale,
          vertical: 8 * scale,
        ),
        borderRadius: BorderRadius.circular(22 * scale),
        child: Row(
          children: [
            Text(
              _formatDuration(activeDuration),
              style: TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 12 * scale,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4.5 * scale,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: 6.5 * scale,
                  ),
                  overlayShape: RoundSliderOverlayShape(
                    overlayRadius: 13 * scale,
                  ),
                  activeTrackColor: AppleColors.labelPrimary,
                  inactiveTrackColor: const Color(0x44FFFFFF),
                  thumbColor: AppleColors.labelPrimary,
                ),
                child: Slider(
                  value: curMs,
                  min: 0,
                  max: maxMs,
                  onChangeStart: hasDuration
                      ? (value) {
                          setState(() {
                            _isSliderDragging = true;
                            _sliderDragPosMs = value;
                          });
                          _hideTimer?.cancel();
                        }
                      : null,
                  onChanged: hasDuration
                      ? (value) {
                          setState(() {
                            _isSliderDragging = true;
                            _sliderDragPosMs = value;
                          });
                        }
                      : null,
                  onChangeEnd: hasDuration
                      ? (value) {
                          final targetMs = value.round().clamp(
                            0,
                            effectiveDurationMs,
                          );
                          setState(() {
                            _isSliderDragging = false;
                            _position = Duration(milliseconds: targetMs);
                          });
                          _player.seek(Duration(milliseconds: targetMs));
                          _scheduleHide();
                        }
                      : null,
                ),
              ),
            ),
            Text(
              hasDuration ? _formatDuration(totalDuration) : '--:--',
              style: TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 12 * scale,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            SizedBox(width: 10 * scale),
            CupertinoButton(
              key: const Key('player-fullscreen-toggle'),
              padding: EdgeInsets.zero,
              minSize: 34 * scale,
              onPressed: _toggleOrientation,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 10 * scale,
                  vertical: 6 * scale,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x28FFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: AppleColors.glassBorder,
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (_desktop ? _desktopWindow?.fullscreen == true : isLandscape)
                          ? CupertinoIcons.fullscreen_exit
                          : CupertinoIcons.fullscreen,
                      color: AppleColors.labelPrimary,
                      size: 15 * scale,
                    ),
                    SizedBox(width: 4 * scale),
                    Text(
                      _fullscreenLabel(isLandscape),
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 12 * scale,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Separate Scrollable Tool Dock:
  /// - Portrait: horizontal scrollable glass strip at the bottom.
  /// - Landscape: slim vertical Liquid Glass capsule near the right edge.
  /// Exposes all adjustable playback controls (omitting VOD-only items during
  /// Live TV). The orientation toggle lives only on the progress bar (or the
  /// header during Live TV), so it is intentionally not duplicated here.
  Widget _buildScrollableToolDock({
    required bool isLandscape,
    double scale = 1.0,
  }) {
    final live = _isLiveStream;
    final actions = <_PlayerAction>[
      if (_episodeIndex > 0)
        _PlayerAction(
          CupertinoIcons.backward_end_fill,
          live ? '上源' : '上集',
          () => _stepEpisode(-1),
        ),
      if (_episodeIndex < _currentLine.episodes.length - 1)
        _PlayerAction(
          CupertinoIcons.forward_end_fill,
          live ? '下源' : '下集',
          () => _stepEpisode(1),
        ),
      if (_currentLine.episodes.length > 1 || !live)
        _PlayerAction(
          CupertinoIcons.square_grid_2x2_fill,
          live ? '信号' : '选集',
          _showEpisodesSheet,
        ),
      if (widget.video.lines.length > 1 || !live)
        _PlayerAction(CupertinoIcons.layers_alt_fill, '线路', _showLinesSheet),
      _PlayerAction(
        CupertinoIcons.slider_horizontal_3,
        '策略·$_kernelShortLabel',
        _showKernelSheet,
        shortLabel: _kernelShortLabel,
        active: _playerKernel != 'exo',
      ),
      if (!live)
        _PlayerAction(
          CupertinoIcons.speedometer,
          '${_normalSpeed}×',
          _showSpeedSheet,
          active: _normalSpeed != 1.0,
        ),
      _PlayerAction(
        CupertinoIcons.play_rectangle,
        '画面·$_fitLabel',
        _cycleAspect,
        shortLabel: _fitLabel,
      ),
      if (!live) ...[
        _PlayerAction(
          CupertinoIcons.forward_fill,
          _skipIntroSec > 0 ? '片头${_skipIntroSec}s' : '跳片头',
          _showSkipIntroSheet,
          shortLabel: '片头',
          active: _skipIntroSec > 0,
        ),
        _PlayerAction(
          CupertinoIcons.forward_end_alt_fill,
          _skipOutroSec > 0 ? '片尾${_skipOutroSec}s' : '跳片尾',
          _showSkipOutroSheet,
          shortLabel: '片尾',
          active: _skipOutroSec > 0,
        ),
        _PlayerAction(
          CupertinoIcons.repeat,
          '连播·${_autoNext ? "开" : "关"}',
          _toggleAutoNext,
          shortLabel: '连播',
          active: _autoNext,
        ),
        _PlayerAction(
          CupertinoIcons.arrow_2_squarepath,
          '循环·$_repeatLabel',
          _cycleRepeatMode,
          shortLabel: '循环',
          active: _repeatMode == 'one' || _repeatMode == 'all',
        ),
      ],
      if (_qualityChoices.length > 1)
        _PlayerAction(CupertinoIcons.slider_horizontal_3, '画质', _showQualityChoices),
      _PlayerAction(CupertinoIcons.speaker_2_fill, '音轨', _showAudioTracksSheet),
      if (!live)
        _PlayerAction(
          CupertinoIcons.captions_bubble_fill,
          '字幕',
          _showSubtitleTracksSheet,
        ),
      _PlayerAction(CupertinoIcons.refresh, live ? '刷新' : '重播', () {
        if (live) {
          _openCurrentEpisode();
          _showHud('正在刷新直播流…');
        } else {
          _player.seek(Duration.zero);
          _player.play();
          _showHud('已从头开始播放');
        }
      }),
    ];

    if (isLandscape) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final itemExtent = 50.0 * scale;
          final vertPad = 8.0 * scale;
          final contentH = actions.length * itemExtent + vertPad * 2;
          final maxH = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : contentH;
          final scrollable = contentH > maxH;
          final dockWidth = 54.0 * scale;
          return LiquidGlass(
            key: const Key('player-tool-dock-landscape'),
            width: dockWidth,
            height: math.min(contentH, maxH),
            borderRadius: dockWidth / 2,
            tint: const Color(0x47141418),
            blur: 18,
            child: AppleEdgeFade(
              axis: Axis.vertical,
              fadeWidth: scrollable ? 18 * scale : 0,
              child: ListView.builder(
                padding: EdgeInsets.symmetric(vertical: vertPad),
                physics: const BouncingScrollPhysics(),
                itemExtent: itemExtent,
                itemCount: actions.length,
                itemBuilder: (ctx, i) => _buildRailButton(actions[i], scale),
              ),
            ),
          );
        },
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 740 * scale),
      child: LiquidGlass(
        key: const Key('player-tool-dock-portrait'),
        borderRadius: 24 * scale,
        tint: const Color(0x47141418),
        blur: 18,
        child: AppleEdgeFade(
          fadeWidth: 14 * scale,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: 10 * scale,
              vertical: 7 * scale,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int i = 0; i < actions.length; i++) ...[
                  if (i > 0) SizedBox(width: 7 * scale),
                  _buildToolTile(actions[i], scale),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Landscape rail button: icon in a soft circular glass well with a short
  /// caption underneath; active toggles take the system tint.
  Widget _buildRailButton(_PlayerAction action, [double scale = 1.0]) {
    final tint = action.active
        ? const Color(0xFF3E9BFF)
        : AppleColors.labelPrimary;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minSize: 44 * scale,
      pressedOpacity: 0.6,
      onPressed: () {
        _scheduleHide();
        action.onTap();
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 30 * scale,
            height: 30 * scale,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: action.active
                  ? const Color(0x2E3E9BFF)
                  : const Color(0x1FFFFFFF),
            ),
            alignment: Alignment.center,
            child: Icon(action.icon, color: tint, size: 15 * scale),
          ),
          SizedBox(height: 3 * scale),
          Text(
            action.shortLabel ?? action.label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: TextStyle(
              color: action.active ? tint : AppleColors.labelSecondary,
              fontSize: 9 * scale,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolTile(_PlayerAction action, [double scale = 1.0]) {
    final tint = action.active
        ? const Color(0xFF3E9BFF)
        : AppleColors.labelPrimary;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minSize: 34 * scale,
      onPressed: () {
        _scheduleHide();
        action.onTap();
      },
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 11 * scale,
          vertical: 6.5 * scale,
        ),
        decoration: BoxDecoration(
          color: action.active
              ? const Color(0x2E3E9BFF)
              : const Color(0x1FFFFFFF),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(action.icon, color: tint, size: 14 * scale),
            SizedBox(width: 5 * scale),
            Text(
              action.label,
              style: TextStyle(
                color: tint,
                fontSize: 12 * scale,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _cycleAspect() {
    setState(() {
      if (_fit == BoxFit.contain) {
        _fit = BoxFit.cover;
        _showHud('画面：裁切填充');
      } else if (_fit == BoxFit.cover) {
        _fit = BoxFit.fill;
        _showHud('画面：铺满屏幕');
      } else {
        _fit = BoxFit.contain;
        _showHud('画面：适应屏幕');
      }
    });
  }

  void _toggleAutoNext() {
    final next = !_autoNext;
    setState(() => _autoNext = next);
    widget.storage.setAutoNext(next);
    _showHud('自动连播：${next ? "已开启" : "已关闭"}');
  }

  void _cycleRepeatMode() {
    final next = _repeatMode == 'off'
        ? 'one'
        : (_repeatMode == 'one' ? 'all' : 'off');
    setState(() => _repeatMode = next);
    widget.storage.setRepeatMode(next);
    _showHud('循环模式：$_repeatLabel');
  }

  void _showSkipIntroSheet() {
    _showPrecisionSkipSheet(isIntro: true);
  }

  void _showSkipOutroSheet() {
    _showPrecisionSkipSheet(isIntro: false);
  }

  void _showPrecisionSkipSheet({required bool isIntro}) {
    const presets = [0, 15, 30, 45, 60, 90, 120, 150, 180];
    int tempSec = (isIntro ? _skipIntroSec : _skipOutroSec).clamp(0, 300);

    void applySec(int sec, void Function(void Function()) setSheetState) {
      final clamped = sec.clamp(0, 300);
      setSheetState(() => tempSec = clamped);
      setState(() {
        if (isIntro) {
          _skipIntroSec = clamped;
        } else {
          _skipOutroSec = clamped;
        }
      });
      if (isIntro) {
        widget.storage.setSkipIntroSec(clamped);
      } else {
        widget.storage.setSkipOutroSec(clamped);
      }
    }

    showAppleModalSheet<void>(
      context: context,
      title: isIntro ? '跳过片头时间节点' : '跳过片尾时间节点',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final formatted = _formatDuration(Duration(seconds: tempSec));
          final currentPlaySec = isIntro
              ? _position.inSeconds.clamp(0, 300)
              : ((_duration.inMilliseconds > 0
                        ? (_duration - _position).inSeconds
                        : _position.inSeconds)
                    .clamp(0, 300));
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppleGlassSurface(
                  padding: const EdgeInsets.all(14),
                  borderRadius: BorderRadius.circular(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isIntro ? '手动拉取精准片头节点' : '手动拉取精准片尾节点',
                            style: const TextStyle(
                              color: AppleColors.labelSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            tempSec == 0
                                ? '不跳过 (00:00)'
                                : '$formatted ($tempSec秒)',
                            style: const TextStyle(
                              color: AppleColors.systemBlue,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SliderTheme(
                        data: SliderTheme.of(ctx).copyWith(
                          trackHeight: 5,
                          activeTrackColor: AppleColors.systemBlue,
                          inactiveTrackColor: const Color(0x38FFFFFF),
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: tempSec.toDouble(),
                          min: 0,
                          max: 300,
                          divisions: 300,
                          onChanged: (v) => applySec(v.round(), setSheetState),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          for (final step in const [-10, -5, -1, 1, 5, 10]) ...[
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2.5,
                                ),
                                child: CupertinoButton(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 7,
                                  ),
                                  minSize: 32,
                                  color: const Color(0x28FFFFFF),
                                  borderRadius: BorderRadius.circular(10),
                                  onPressed: () =>
                                      applySec(tempSec + step, setSheetState),
                                  child: Text(
                                    step > 0 ? '+${step}s' : '${step}s',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (_position.inSeconds > 0) ...[
                        const SizedBox(height: 10),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          minSize: 36,
                          color: AppleColors.systemBlue,
                          borderRadius: BorderRadius.circular(12),
                          onPressed: () {
                            applySec(currentPlaySec, setSheetState);
                            _showHud(
                              '${isIntro ? "片头" : "片尾"}已设为当前时间节点 ${_formatDuration(Duration(seconds: currentPlaySec))}',
                            );
                          },
                          child: Text(
                            isIntro
                                ? '设为当前播放位置 (${_formatDuration(Duration(seconds: currentPlaySec))})'
                                : '设为当前剩余时长 (${_formatDuration(Duration(seconds: currentPlaySec))})',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: presets.map((sec) {
                    final selected = tempSec == sec;
                    return GestureDetector(
                      onTap: () {
                        applySec(sec, setSheetState);
                        _showHud(
                          sec == 0
                              ? '已关闭跳过${isIntro ? "片头" : "片尾"}'
                              : '${isIntro ? "片头" : "片尾"}跳过已设为 ${_formatDuration(Duration(seconds: sec))}',
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 7.5,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppleColors.systemBlue
                              : const Color(0x24FFFFFF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          sec == 0
                              ? '关闭'
                              : '${_formatDuration(Duration(seconds: sec))} (${sec}s)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showQualityChoices() async {
    final session = _playSession;
    final selected = await showCupertinoModalPopup<CmsEpisode>(
      context:context,
      builder:(sheet)=>CupertinoActionSheet(
        title:const Text('切换画质'),
        actions:[for(final choice in _qualityChoices) CupertinoActionSheetAction(
          isDefaultAction:choice.url == _activeStreamUrl,
          onPressed:()=>Navigator.pop(sheet,choice),child:Text(choice.name))],
        cancelButton:CupertinoActionSheetAction(onPressed:()=>Navigator.pop(sheet),child:const Text('取消')),
      ),
    );
    if(!mounted || session != _playSession || selected == null || selected.url == _activeStreamUrl) return;
    await _openCurrentEpisode(resumeMs:_position.inMilliseconds,quality:selected);
  }

  void _showAudioTracksSheet() {
    final tracks = _player.state.tracks.audio;
    final active = _player.state.track.audio;
    showAppleModalSheet<void>(
      context: context,
      title: '切换音轨',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: tracks.isEmpty
                ? [
                    const AppleGroupedTile(
                      icon: CupertinoIcons.speaker_2_fill,
                      title: '默认音轨',
                      subtitle: '当前片源仅包含单一音轨',
                    ),
                  ]
                : tracks.map((t) {
                    final selected = t == active;
                    final label = (t.title ?? t.language ?? t.id).trim();
                    return AppleGroupedTile(
                      icon: CupertinoIcons.speaker_2_fill,
                      iconBgColor: selected
                          ? AppleColors.systemBlue
                          : AppleColors.groupedTertiary,
                      title: label.isEmpty ? '音轨 ${t.id}' : label,
                      trailing: selected
                          ? const Icon(
                              CupertinoIcons.checkmark_alt,
                              color: AppleColors.systemBlue,
                              size: 18,
                            )
                          : null,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _player.setAudioTrack(t);
                        _showHud('已切换音轨：${label.isEmpty ? t.id : label}');
                      },
                    );
                  }).toList(),
          ),
        ],
      ),
    );
  }

  void _showSubtitleTracksSheet() {
    final tracks = _player.state.tracks.subtitle;
    final active = _player.state.track.subtitle;
    showAppleModalSheet<void>(
      context: context,
      title: '切换字幕',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: [
              AppleGroupedTile(
                icon: CupertinoIcons.captions_bubble,
                iconBgColor: active == SubtitleTrack.no()
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: '关闭内嵌字幕',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _player.setSubtitleTrack(SubtitleTrack.no());
                  _showHud('已关闭内嵌字幕');
                },
              ),
              ...tracks.map((t) {
                final selected = t == active;
                final label = (t.title ?? t.language ?? t.id).trim();
                return AppleGroupedTile(
                  icon: CupertinoIcons.captions_bubble_fill,
                  iconBgColor: selected
                      ? AppleColors.systemBlue
                      : AppleColors.groupedTertiary,
                  title: label.isEmpty ? '字幕 ${t.id}' : label,
                  trailing: selected
                      ? const Icon(
                          CupertinoIcons.checkmark_alt,
                          color: AppleColors.systemBlue,
                          size: 18,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _player.setSubtitleTrack(t);
                    _showHud('已切换字幕：${label.isEmpty ? t.id : label}');
                  },
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  void _showKernelSheet() {
    const kernels = <({String key, String title, String subtitle})>[
      (
        key: 'exo',
        title: '均衡播放（默认）',
        subtitle: '自动选择解码方式，使用 64 MB 前向缓冲',
      ),
      (
        key: 'ijk',
        title: '兼容缓冲',
        subtitle: '硬件解码拷贝输出，增加媒体探测时间',
      ),
      (
        key: 'mpv',
        title: '大容量缓冲',
        subtitle: '使用 128 MB 前向缓冲，占用更多内存',
      ),
    ];
    showAppleModalSheet<void>(
      context: context,
      title: '切换播放策略',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: kernels.map((k) {
              final selected = _playerKernel == k.key;
              return AppleGroupedTile(
                icon: CupertinoIcons.slider_horizontal_3,
                iconBgColor: selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: k.title,
                subtitle: k.subtitle,
                trailing: selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  if (_playerKernel == k.key) return;
                  final keepPos = _position.inMilliseconds >= 1000
                      ? _position.inMilliseconds
                      : _lastKnownPositionMs;
                  setState(() => _playerKernel = k.key);
                  widget.storage.setPlayerKernel(k.key);
                  unawaited(
                    _applyPlayerKernel(k.key).then((_) {
                      if (mounted) {
                        _showHud('已切换至 ${k.title}');
                        _openCurrentEpisode(resumeMs: keepPos);
                      }
                    }),
                  );
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  void _showSpeedSheet() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    showAppleModalSheet<void>(
      context: context,
      title: '播放倍速',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: speeds.map((s) {
              final selected = _normalSpeed == s;
              return AppleGroupedTile(
                icon: CupertinoIcons.speedometer,
                iconBgColor: selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: '$s× 倍速',
                trailing: selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() => _normalSpeed = s);
                  _player.setRate(s);
                  widget.storage.setPlaySpeed(s);
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  void _showLinesSheet() {
    showAppleModalSheet<void>(
      context: context,
      title: '切换播放线路',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          AppleGroupedSection(
            children: List.generate(widget.video.lines.length, (i) {
              final selected = i == _lineIndex;
              return AppleGroupedTile(
                icon: CupertinoIcons.layers_alt_fill,
                iconBgColor: selected
                    ? AppleColors.systemBlue
                    : AppleColors.groupedTertiary,
                title: widget.video.lines[i].name,
                subtitle: '${widget.video.lines[i].episodes.length} 集',
                trailing: selected
                    ? const Icon(
                        CupertinoIcons.checkmark_alt,
                        color: AppleColors.systemBlue,
                        size: 18,
                      )
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _failedLineIndices.clear();
                  final keepPos = _position.inMilliseconds >= 1000
                      ? _position.inMilliseconds
                      : _lastKnownPositionMs;
                  _saveProgress();
                  setState(() {
                    _lineIndex = i;
                    _episodeIndex = _episodeIndex.clamp(
                      0,
                      widget.video.lines[i].episodes.length - 1,
                    );
                  });
                  _openCurrentEpisode(resumeMs: keepPos);
                },
              );
            }),
          ),
        ],
      ),
    );
  }

  void _showEpisodesSheet() {
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    showAppleModalSheet<void>(
      context: context,
      title: '选集与线路 (${_currentLine.episodes.length})',
      maxWidth: isLandscape ? math.min(screenSize.width - 24, 760.0) : 560.0,
      builder: (ctx) => _PlayerEpisodePickerSheet(
        lines: widget.video.lines,
        initialLineIndex: _lineIndex,
        activeLineIndex: _lineIndex,
        activeEpisodeIndex: _episodeIndex,
        onSelect: (lineIdx, epIdx) {
          Navigator.of(ctx).pop();
          _failedLineIndices.clear();
          final sameEpisode = epIdx == _episodeIndex;
          final keepPos = sameEpisode
              ? (_position.inMilliseconds >= 1000
                    ? _position.inMilliseconds
                    : _lastKnownPositionMs)
              : 0;
          _saveProgress();
          setState(() {
            _lineIndex = lineIdx;
            _episodeIndex = epIdx;
          });
          _openCurrentEpisode(resumeMs: keepPos);
        },
      ),
    );
  }
}

/// One adjustable playback control shown in the tool dock.
class _PlayerAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Compact caption for the narrow landscape rail.
  final String? shortLabel;

  /// Highlights toggles that are currently on (连播、循环、跳片头…).
  final bool active;
  const _PlayerAction(
    this.icon,
    this.label,
    this.onTap, {
    this.shortLabel,
    this.active = false,
  });
}

class _ParsedEpisodeLabel {
  final String title;
  final String sizeBadge;

  const _ParsedEpisodeLabel({required this.title, required this.sizeBadge});

  factory _ParsedEpisodeLabel.parse(String raw, int index) {
    var text = raw.trim();
    var badge = '';
    final bracketMatch = RegExp(r'^\[([^\]]+)\]\s*(.*)$').firstMatch(text);
    if (bracketMatch != null) {
      badge = (bracketMatch.group(1) ?? '').trim();
      text = (bracketMatch.group(2) ?? '').trim();
    }
    if (text.isEmpty) {
      text = raw.trim().isNotEmpty ? raw.trim() : '第${index + 1}集';
    }
    return _ParsedEpisodeLabel(title: text, sizeBadge: badge);
  }
}

class _PlayerEpisodePickerSheet extends StatefulWidget {
  final List<CmsLine> lines;
  final int initialLineIndex;
  final int activeLineIndex;
  final int activeEpisodeIndex;
  final void Function(int lineIndex, int episodeIndex) onSelect;

  const _PlayerEpisodePickerSheet({
    required this.lines,
    required this.initialLineIndex,
    required this.activeLineIndex,
    required this.activeEpisodeIndex,
    required this.onSelect,
  });

  @override
  State<_PlayerEpisodePickerSheet> createState() =>
      _PlayerEpisodePickerSheetState();
}

class _PlayerEpisodePickerSheetState extends State<_PlayerEpisodePickerSheet> {
  static const int _groupSize = 40;
  late int _previewLineIndex;
  late int _groupIndex;
  bool _descending = false;

  @override
  void initState() {
    super.initState();
    _previewLineIndex = widget.initialLineIndex
        .clamp(0, math.max(0, widget.lines.length - 1))
        .toInt();
    _groupIndex = (widget.activeEpisodeIndex ~/ _groupSize);
  }

  CmsLine get _line => widget.lines.isEmpty
      ? const CmsLine(name: '默认线路', episodes: [])
      : widget.lines[_previewLineIndex
            .clamp(0, widget.lines.length - 1)
            .toInt()];

  @override
  Widget build(BuildContext context) {
    final episodes = _line.episodes;
    final total = episodes.length;
    final groupCount = total <= 0 ? 1 : ((total - 1) ~/ _groupSize) + 1;
    final safeGroup = _groupIndex.clamp(0, math.max(0, groupCount - 1)).toInt();
    final int startIdx = safeGroup * _groupSize;
    final int endIdx = math.min(startIdx + _groupSize, total);

    final indices = <int>[for (int i = startIdx; i < endIdx; i++) i];
    if (_descending) {
      indices.sort((a, b) => b.compareTo(a));
    }

    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final crossAxisCount = isLandscape ? 5 : 3;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部线路切换 + 当前播放状态 + 正倒序切换
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: List.generate(widget.lines.length, (i) {
                      final line = widget.lines[i];
                      final selected = i == _previewLineIndex;
                      final isPlayingLine = i == widget.activeLineIndex;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _previewLineIndex = i;
                              final newGroupCount = line.episodes.isEmpty
                                  ? 1
                                  : ((line.episodes.length - 1) ~/ _groupSize) +
                                        1;
                              if (_groupIndex >= newGroupCount) {
                                _groupIndex = 0;
                              }
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 13,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              gradient: selected
                                  ? const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFF2897FF),
                                        Color(0xFF0A84FF),
                                      ],
                                    )
                                  : const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xD82C2C32),
                                        Color(0xCC1E1E24),
                                      ],
                                    ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: selected
                                    ? const Color(0x90FFFFFF)
                                    : const Color(0x2EFFFFFF),
                                width: 0.7,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isPlayingLine) ...[
                                  Icon(
                                    CupertinoIcons.play_fill,
                                    size: 11.5,
                                    color: selected
                                        ? Colors.white
                                        : AppleColors.systemBlue,
                                  ),
                                  const SizedBox(width: 5),
                                ],
                                Text(
                                  '${line.name} (${line.episodes.length})',
                                  style: TextStyle(
                                    color: selected
                                        ? Colors.white
                                        : AppleColors.labelPrimary,
                                    fontSize: 12.5,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _descending = !_descending),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC26262C),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0x30FFFFFF),
                      width: 0.65,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _descending
                            ? CupertinoIcons.sort_down
                            : CupertinoIcons.sort_up,
                        size: 13.5,
                        color: AppleColors.labelSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _descending ? '倒序' : '正序',
                        style: const TextStyle(
                          color: AppleColors.labelPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // 分段区间快速切换（超过 40 集自动显示分段胶囊）
          if (groupCount > 1) ...[
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: List.generate(groupCount, (g) {
                  final gStart = g * _groupSize + 1;
                  final gEnd = math.min((g + 1) * _groupSize, total);
                  final active = g == safeGroup;
                  return Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: GestureDetector(
                      onTap: () => setState(() => _groupIndex = g),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5.5,
                        ),
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0x330A84FF)
                              : const Color(0x99202026),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: active
                                ? AppleColors.systemBlue
                                : const Color(0x24FFFFFF),
                            width: 0.75,
                          ),
                        ),
                        child: Text(
                          '$gStart-$gEnd',
                          style: TextStyle(
                            color: active
                                ? const Color(0xFF64B5FF)
                                : AppleColors.labelSecondary,
                            fontSize: 12,
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
          const SizedBox(height: 10),
          // 剧集网格卡片
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: isLandscape
                    ? math.min(screenSize.height * 0.6, 300.0)
                    : math.min(screenSize.height * 0.52, 420.0),
              ),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  mainAxisExtent: 52,
                ),
                itemCount: indices.length,
                itemBuilder: (ctx, idx) {
                  final epIndex = indices[idx];
                  final ep = episodes[epIndex];
                  final selected =
                      _previewLineIndex == widget.activeLineIndex &&
                      epIndex == widget.activeEpisodeIndex;
                  final parsed = _ParsedEpisodeLabel.parse(ep.name, epIndex);
                  final numBadge =
                      '#${(epIndex + 1).toString().padLeft(2, '0')}';

                  return GestureDetector(
                    onTap: () => widget.onSelect(_previewLineIndex, epIndex),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        gradient: selected
                            ? const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF1D8BFF), Color(0xFF0A6CE8)],
                              )
                            : const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xCC28282F), Color(0xB81D1D23)],
                              ),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? const Color(0xAAFFFFFF)
                              : const Color(0x28FFFFFF),
                          width: selected ? 0.9 : 0.65,
                        ),
                        boxShadow: selected
                            ? const [
                                BoxShadow(
                                  color: Color(0x450A84FF),
                                  blurRadius: 12,
                                  offset: Offset(0, 4),
                                ),
                              ]
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (selected) ...[
                                const Icon(
                                  CupertinoIcons.play_fill,
                                  size: 11,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                numBadge,
                                style: TextStyle(
                                  color: selected
                                      ? const Color(0xE6FFFFFF)
                                      : AppleColors.labelTertiary,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
                              if (parsed.sizeBadge.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5.5,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? const Color(0x33FFFFFF)
                                        : const Color(0x22FFFFFF),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(
                                    parsed.sizeBadge,
                                    style: TextStyle(
                                      color: selected
                                          ? Colors.white
                                          : AppleColors.labelSecondary,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            parsed.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
