import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' show AudioStreamInfo;

import '../../core/audio_preset.dart';
import '../../core/constants.dart';
import '../../core/logo_assets.dart';
import '../../core/scoring_mode.dart';
import '../../core/strings.dart';
import '../../state/providers.dart';
import '../overlay/webview_overlay.dart';
import '../scoring/scoring_session.dart';
import 'youtube_url_parser.dart';

class YouTubeWebView extends ConsumerStatefulWidget {
  const YouTubeWebView({super.key});

  @override
  ConsumerState<YouTubeWebView> createState() => _YouTubeWebViewState();
}

class _YouTubeWebViewState extends ConsumerState<YouTubeWebView> {
  late final WebViewController _controller;
  bool _isReady = false;

  ScoringSession? _scoringSession;
  StreamSubscription<ScoringUpdate>? _scoreSub;
  StreamSubscription<Map<String, dynamic>>? _tvEventSub;
  StreamSubscription<bool>? _tvConnSub;

  int _lastInjectedScore = -1;
  bool _overlayInjected = false;
  Timer? _videoEndTimer;
  bool _celebrationShown = false;
  bool _welcomeShown = false;
  bool _welcomeDismissedPermanently = false;

  // TV Controller UI state on the phone
  bool _showTvRemoteCard = true;
  bool _tvPlaying = false;
  String _currentNote = '--';
  double _currentRms = 0.0;
  String? _calibrationStatus;

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    _initWebView();
    _initTvServer();
  }

  Future<void> _initTvServer() async {
    final tvServer = ref.read(tvSyncServerProvider);
    await tvServer.start();
    if (mounted) {
      setState(() {});
    }

    _tvConnSub = tvServer.onConnectionChanged.listen((connected) {
      if (!mounted) return;
      ref.read(isTvConnectedProvider.notifier).state = connected;
      setState(() {});

      // If TV just connected and a video is already selected, transfer playback to TV
      final videoId = ref.read(currentVideoIdProvider);
      if (connected && videoId != null) {
        _pauseAndMuteLocalVideo();
        tvServer.sendLoadVideo(
          videoId: videoId,
          title: ref.read(currentVideoTitleProvider) ?? '',
          pitchShift: ref.read(pitchShiftProvider),
          preset: ref.read(audioPresetProvider).name,
          mode: ref.read(scoringModeProvider).name,
          modeName: ref.read(scoringModeProvider).label,
        );
      }
    });

    _tvEventSub = tvServer.tvEvents.listen(_onTvEvent);
  }

  void _onTvEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'play':
        setState(() => _tvPlaying = true);
        _onVideoPlay();
      case 'pause':
        setState(() => _tvPlaying = false);
        _onVideoPause();
      case 'seeked':
        _onVideoSeeked();
      case 'timeupdate':
        final time = (event['time'] as num?)?.toDouble() ?? 0;
        final duration = (event['duration'] as num?)?.toDouble() ?? 0;
        _scoringSession?.updateVideoTime(time);
        if (!_celebrationShown && duration > 30 && time > 10 && (duration - time) < 5) {
          _triggerCelebration();
        }
      case 'ended':
        setState(() => _tvPlaying = false);
        if (!_celebrationShown) {
          _triggerCelebration();
        }
      case 'tvStopped':
        setState(() => _tvPlaying = false);
        _stopScoring();
    }
  }

  void _triggerCelebration() {
    _celebrationShown = true;
    _videoEndTimer?.cancel();
    final finalScore = _scoringSession?.finalScore ?? _lastInjectedScore.clamp(0, 100);
    final tvServer = ref.read(tvSyncServerProvider);
    if (tvServer.hasConnectedTv) {
      tvServer.sendCelebration(finalScore);
    } else {
      _runJs(WebviewOverlay.celebrationJs(finalScore));
    }
  }

  Future<void> _loadSavedSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPreset = prefs.getString('audio_preset');
    if (savedPreset != null) {
      final preset = AudioPreset.values.where((p) => p.name == savedPreset).firstOrNull;
      if (preset != null) ref.read(audioPresetProvider.notifier).state = preset;
    }
    final savedMode = prefs.getString('scoring_mode');
    if (savedMode != null) {
      final mode = ScoringMode.values.where((m) => m.name == savedMode).firstOrNull;
      if (mode != null) ref.read(scoringModeProvider.notifier).state = mode;
    }
    _welcomeDismissedPermanently = prefs.getBool('welcome_dismissed') ?? false;
  }

  Future<void> _saveSetting(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _onPageLoaded(),
          onUrlChange: (change) => _onUrlChange(change.url),
        ),
      )
      ..addJavaScriptChannel('FrankKaraoke', onMessageReceived: _onJsMessage)
      ..addJavaScriptChannel('FrankPreset', onMessageReceived: (m) => _onPresetChange(m.message))
      ..addJavaScriptChannel('FrankMode', onMessageReceived: (m) => _onModeChange(m.message))
      ..addJavaScriptChannel('FrankPitch', onMessageReceived: (m) => _onPitchChange(m.message))
      ..addJavaScriptChannel('FrankRestart', onMessageReceived: (_) => _restartScoring())
      ..addJavaScriptChannel('FrankCalibrate', onMessageReceived: (_) => _calibrateMic())
      ..addJavaScriptChannel('FrankDismissWelcome', onMessageReceived: (_) => _dismissWelcome())
      ..addJavaScriptChannel('FrankScoreInfo', onMessageReceived: (_) => _showScoreInfo())
      ..loadRequest(Uri.parse(kYouTubeDesktopUrl));
  }

  void _onPageLoaded() {
    if (!mounted) return;
    setState(() => _isReady = true);
    _injectBridge();
    _runJs(_cleanYouTubeUiJs);
    _runJs(_replaceLogoJs);
    _runJs('''
      (function() {
        window._fkAllowPlay = false;
        function guardVideo(v) {
          if (v._fkGuarded) return;
          v._fkGuarded = true;
          v.addEventListener('play', function() {
            if (!window._fkAllowPlay) { v.pause(); }
          });
          v.addEventListener('playing', function() {
            if (!window._fkAllowPlay) { v.pause(); }
          });
          if (!v.paused) v.pause();
        }
        document.querySelectorAll('video').forEach(guardVideo);
        new MutationObserver(function() {
          document.querySelectorAll('video').forEach(guardVideo);
        }).observe(document.body || document.documentElement, {childList:true, subtree:true});
        var attempts = 0;
        var timer = setInterval(function() {
          document.querySelectorAll('video').forEach(guardVideo);
          if (++attempts > 20) clearInterval(timer);
        }, 500);
      })();
    ''');
    if (!_welcomeShown && !_welcomeDismissedPermanently) {
      _welcomeShown = true;
      _runJs(WebviewOverlay.welcomeOverlayJs);
    }
    if (_overlayInjected) _reinjectOverlay();
  }

  void _pauseAndMuteLocalVideo() {
    _runJs('''
      (function(){
        window._fkAllowPlay = false;
        document.querySelectorAll('video').forEach(function(v){
          v.muted = true;
          v.pause();
        });
      })();
    ''');
  }

  void _injectBridge() {
    _runJs('''
      (function() {
        if (window._fkBridgeObserver) window._fkBridgeObserver.disconnect();
        if (window._fkVideoObserver) window._fkVideoObserver.disconnect();

        let lastUrl = location.href;
        window._fkBridgeObserver = new MutationObserver(() => {
          if (location.href !== lastUrl) {
            lastUrl = location.href;
            FrankKaraoke.postMessage(JSON.stringify({type:'urlChange',url:lastUrl}));
          }
        });
        window._fkBridgeObserver.observe(document.body, {childList:true,subtree:true});

        function guardVideo(v) {
          if (v._fkBridged) return;
          v._fkBridged = true;
          v.addEventListener('play', function() {
            FrankKaraoke.postMessage(JSON.stringify({type:'play'}));
          });
          v.addEventListener('pause', function() {
            FrankKaraoke.postMessage(JSON.stringify({type:'pause'}));
          });
          v.addEventListener('seeked', function() {
            FrankKaraoke.postMessage(JSON.stringify({
              type:'seeked', time: v.currentTime
            }));
          });
          v.addEventListener('timeupdate', function() {
            FrankKaraoke.postMessage(JSON.stringify({
              type:'timeupdate', time: v.currentTime
            }));
          });
        }
        document.querySelectorAll('video').forEach(guardVideo);
        window._fkVideoObserver = new MutationObserver(function() {
          document.querySelectorAll('video').forEach(guardVideo);
        });
        window._fkVideoObserver.observe(document.body || document.documentElement, {childList:true, subtree:true});
      })();
    ''');
  }

  static const _cleanYouTubeUiJs = '''
    (function() {
      if (document.getElementById('fk-yt-cleanup')) return;
      var s = document.createElement('style');
      s.id = 'fk-yt-cleanup';
      s.textContent = '#secondary{display:none!important}'
        + '#comments{display:none!important}'
        + '#related{display:none!important}'
        + 'ytd-watch-next-secondary-results-renderer{display:none!important}'
        + 'ytd-mealbar-promo-renderer{display:none!important}'
        + 'tp-yt-paper-dialog{display:none!important}'
        + 'ytm-promoted-sparkles-web-renderer{display:none!important}'
        + '.c3-module-companion{display:none!important}';
      document.head.appendChild(s);
    })();
  ''';

  static String get _replaceLogoJs => '''
    (function() {
      var logoDataUri = 'data:image/png;base64,$kLogoDarkBase64';
      function replaceLogo() {
        var styleId = 'fk-logo-style';
        if (!document.getElementById(styleId)) {
          var st = document.createElement('style');
          st.id = styleId;
          st.textContent = ''
            + 'c3-icon.mobile-topbar-logo svg,'
            + 'c3-icon#home-icon svg,'
            + 'ytm-home-logo svg,'
            + 'ytd-topbar-logo-renderer svg,'
            + 'ytd-topbar-logo-renderer yt-icon'
            + '{ display:none!important; }'
            + 'ytm-home-logo .mobile-topbar-header-endpoint::before,'
            + 'ytd-topbar-logo-renderer a::before'
            + '{ content:"";display:inline-block;width:120px;height:22px;'
            + 'background:url("' + logoDataUri + '") no-repeat left center/contain;'
            + 'vertical-align:middle; }';
          document.head.appendChild(st);
        }
      }
      replaceLogo();
      setTimeout(replaceLogo, 1000);
      setTimeout(replaceLogo, 3000);
      setTimeout(replaceLogo, 6000);

      function hideOpenApp() {
        var header = document.querySelector('header, #masthead, ytm-mobile-topbar-renderer');
        if (!header) return;
        header.querySelectorAll('a, button').forEach(function(el) {
          var t = (el.textContent || '').trim();
          if (/^(open|open app|get app|use app)\$/i.test(t)) {
            el.style.display = 'none';
          }
        });
      }
      hideOpenApp();
      setTimeout(hideOpenApp, 2000);
      setTimeout(hideOpenApp, 5000);
    })();
  ''';

  void _onUrlChange(String? url) {
    if (url == null) return;
    final videoId = extractVideoId(url);
    final currentId = ref.read(currentVideoIdProvider);

    if (videoId != null && videoId != currentId) {
      ref.read(currentVideoIdProvider.notifier).state = videoId;
      _onVideoDetected(videoId);
    }
  }

  void _onJsMessage(JavaScriptMessage message) {
    final tvServer = ref.read(tvSyncServerProvider);
    // When TV is connected, playback state comes from the TV, not the phone's muted webview.
    try {
      final data = jsonDecode(message.message);
      if (data is! Map) return;
      switch (data['type']) {
        case 'urlChange':
          _onUrlChange(data['url'] as String?);
        case 'play':
          if (!tvServer.hasConnectedTv) _onVideoPlay();
        case 'pause':
          if (!tvServer.hasConnectedTv) _onVideoPause();
        case 'seeked':
          if (!tvServer.hasConnectedTv) _onVideoSeeked();
        case 'timeupdate':
          if (!tvServer.hasConnectedTv) {
            final time = (data['time'] as num?)?.toDouble() ?? 0;
            _scoringSession?.updateVideoTime(time);
          }
      }
    } catch (_) {}
  }

  void _onVideoPlay() {
    debugPrint('Video: play');
    if (_scoringSession != null) {
      if (_scoringSession!.isPaused) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _scoringSession != null) {
            _scoringSession!.resume();
            debugPrint('Scoring: resumed');
          }
        });
      }
    }
  }

  void _onVideoPause() {
    debugPrint('Video: pause');
    _scoringSession?.pause();
  }

  void _onVideoSeeked() {
    debugPrint('Video: seeked — resetting score');
    if (_scoringSession != null) {
      _scoringSession!.resetScore();
    }
  }

  Future<void> _onVideoDetected(String videoId) async {
    final tvServer = ref.read(tvSyncServerProvider);
    final isTvMode = tvServer.hasConnectedTv;

    // Pause local video immediately
    _pauseAndMuteLocalVideo();
    if (isTvMode) {
      tvServer.sendProcessing(true, message: S.processingLoading);
      setState(() {
        _showTvRemoteCard = true;
        _tvPlaying = true;
      });
    } else {
      _runJs(WebviewOverlay.processingOverlayJs(true, message: S.processingLoading));
    }

    ref.read(isAudioSyncingProvider.notifier).state = true;

    final audioService = ref.read(youtubeAudioServiceProvider);
    final title = await audioService.getVideoTitle(videoId);
    if (mounted) {
      ref.read(currentVideoTitleProvider.notifier).state = title;
      setState(() {});
    }

    debugPrint('Video detected: $videoId (TV mode: $isTvMode)');

    if (mounted) {
      ref.read(isAudioSyncingProvider.notifier).state = false;
      ref.read(isVideoPlayingProvider.notifier).state = true;
    }

    final streamInfo = await audioService.getAudioStreamInfo(videoId);

    if (mounted) {
      await _startScoring();
      if (tvServer.hasConnectedTv) {
        // Keep phone video paused & muted; play on Tizen TV!
        _pauseAndMuteLocalVideo();
        tvServer.sendLoadVideo(
          videoId: videoId,
          title: title ?? '',
          pitchShift: ref.read(pitchShiftProvider),
          preset: ref.read(audioPresetProvider).name,
          mode: ref.read(scoringModeProvider).name,
          modeName: ref.read(scoringModeProvider).label,
        );
      } else {
        _runJs('''(function(){window._fkAllowPlay=true;var v=document.querySelector('video');if(v){v.muted=false;v.currentTime=0;v.play();}})();''');
      }
    }

    if (streamInfo != null) {
      _buildOracleInBackground(videoId, streamInfo);
    } else {
      debugPrint('PitchOracle: no stream info for $videoId');
    }
  }

  Future<void> _buildOracleInBackground(String videoId, AudioStreamInfo streamInfo) async {
    final tvServer = ref.read(tvSyncServerProvider);
    if (!tvServer.hasConnectedTv) {
      _runJs(WebviewOverlay.processingOverlayJs(true, message: S.processingLoadingSong));
    }
    try {
      final oracle = ref.read(pitchOracleProvider);
      final built = await oracle.buildForVideo(videoId, streamInfo);
      debugPrint('PitchOracle: ${built ? "ready (${oracle.entryCount} entries)" : "failed"}');

      if (built && mounted && _scoringSession != null) {
        _scoringSession!.setOracle(oracle);
      }
    } catch (e) {
      debugPrint('PitchOracle: error: $e');
    } finally {
      _runJs(WebviewOverlay.processingOverlayJs(false));
      tvServer.sendProcessing(false);
    }
  }

  // --- Scoring ---

  Future<void> _startScoring() async {
    await _stopScoring();

    final mic = ref.read(micCaptureServiceProvider);
    final preset = ref.read(audioPresetProvider);
    final mode = ref.read(scoringModeProvider);
    final calGate = ref.read(calibratedNoiseGateProvider);
    final calSinging = ref.read(calibratedSingingThresholdProvider);
    final tvServer = ref.read(tvSyncServerProvider);

    final pitchShift = ref.read(pitchShiftProvider);
    final oracle = ref.read(pitchOracleProvider);
    _scoringSession = ScoringSession(
      mic: mic,
      preset: preset,
      mode: mode,
      pitchShift: pitchShift,
      oracle: oracle.isReady ? oracle : null,
      calibratedNoiseGate: calGate,
      calibratedSingingThreshold: calSinging,
    );

    final started = await _scoringSession!.start();
    if (!started) {
      _scoringSession = null;
    }

    await Future.delayed(const Duration(milliseconds: 500));
    if (!tvServer.hasConnectedTv) {
      _runJs('''(function(){var v=document.querySelector('video');if(v&&v.paused)v.play();})();''');
    } else {
      _pauseAndMuteLocalVideo();
    }

    final title = ref.read(currentVideoTitleProvider) ?? '';
    try {
      await _runJs(WebviewOverlay.injectOverlayJs(
        singerName: title,
        activePreset: preset.name,
        pitchShift: pitchShift,
      ));
      _overlayInjected = true;
      _lastInjectedScore = -1;
      await _runJs(WebviewOverlay.updateScoreJs(0, 0));
    } catch (e) {
      debugPrint('Overlay: injection failed: $e');
    }

    ref.read(currentScoreProvider.notifier).state = 0;
    _scoreSub = _scoringSession?.scoreStream.listen(_onScoreUpdate);

    _celebrationShown = false;
    _videoEndTimer?.cancel();
    if (!tvServer.hasConnectedTv) {
      _videoEndTimer = Timer.periodic(const Duration(seconds: 2), (_) => _checkVideoEnd());
    }
  }

  void _onScoreUpdate(ScoringUpdate update) {
    final tvServer = ref.read(tvSyncServerProvider);
    final modeName = _scoringSession?.mode.label ?? '';

    final normalizedPitch = update.singerPitchHz > 0
        ? _logNormalize(update.singerPitchHz, 100, 800)
        : 0.0;
    final normalizedRms = (update.rmsEnergy * 100).clamp(0.0, 1.0);

    if (mounted && (update.noteName != _currentNote || (normalizedRms - _currentRms).abs() > 0.04)) {
      setState(() {
        _currentNote = update.noteName;
        _currentRms = normalizedRms;
      });
    }

    // Stream real-time score & vocal pitch to the Samsung Tizen TV
    if (tvServer.hasConnectedTv) {
      tvServer.sendScore(
        liveScore: update.totalScore,
        overallScore: update.overallScore,
        streakCount: update.streakCount,
        modeName: modeName,
        normalizedPitch: normalizedPitch,
        frameScore: update.frameScore,
        noteName: update.noteName,
        normalizedRms: normalizedRms,
        primaryScore: update.primaryScore,
        confidence: update.confidence,
        stability: update.stabilityScore,
        rms: update.rmsEnergy,
        pitchHz: update.singerPitchHz,
      );
    }

    if (update.totalScore != _lastInjectedScore ||
        _scoringSession?.mode == ScoringMode.streak) {
      _lastInjectedScore = update.totalScore;
      ref.read(currentScoreProvider.notifier).state = update.totalScore;
      if (_overlayInjected && !tvServer.hasConnectedTv) {
        _runJs(WebviewOverlay.updateScoreJs(
          update.totalScore,
          update.overallScore,
          streakCount: update.streakCount,
          modeName: modeName,
        ));
      }
    }

    if (!_overlayInjected || tvServer.hasConnectedTv) return;

    _runJs(WebviewOverlay.updatePitchTrailJs(normalizedPitch, update.frameScore));
    _runJs(WebviewOverlay.updateNoteAndRmsJs(update.noteName, normalizedRms));
    _runJs(WebviewOverlay.updateDebugJs(
      primaryScore: update.primaryScore,
      confidence: update.confidence,
      stability: update.stabilityScore,
      frameScore: update.frameScore,
      rms: update.rmsEnergy,
      pitchHz: update.singerPitchHz,
      streak: update.streakCount,
    ));
  }

  Future<void> _stopScoring() async {
    _videoEndTimer?.cancel();
    _videoEndTimer = null;
    await _scoreSub?.cancel();
    _scoreSub = null;
    if (_scoringSession != null) {
      await _scoringSession!.dispose();
      _scoringSession = null;
    }
    if (_overlayInjected) {
      _runJs(WebviewOverlay.removeOverlayJs);
      _overlayInjected = false;
    }
  }

  Future<void> _restartScoring() async {
    final tvServer = ref.read(tvSyncServerProvider);
    if (tvServer.hasConnectedTv) {
      tvServer.sendRestart();
      setState(() => _tvPlaying = true);
    } else {
      _runJs('''(function(){var v=document.querySelector('video');if(v){v.currentTime=0;v.play();}})();''');
    }
    await _stopScoring();
    await _startScoring();
  }

  void _reinjectOverlay() {
    if (!_overlayInjected) return;
    final title = ref.read(currentVideoTitleProvider) ?? '';
    final preset = ref.read(audioPresetProvider);
    final pitchShift = ref.read(pitchShiftProvider);
    _runJs(WebviewOverlay.injectOverlayJs(
      singerName: title,
      activePreset: preset.name,
      pitchShift: pitchShift,
    ));
  }

  Future<void> _checkVideoEnd() async {
    if (_celebrationShown) return;
    try {
      final result = await _controller.runJavaScriptReturningResult('''
        (function(){var v=document.querySelector('video');
        if(!v||!v.duration||v.duration===Infinity)return'-1';
        return v.currentTime+'|'+v.duration;})();
      ''');
      final str = result is String ? result : result.toString();
      if (str.contains('|')) {
        final parts = str.replaceAll('"', '').split('|');
        final current = double.tryParse(parts[0]) ?? 0;
        final duration = double.tryParse(parts[1]) ?? 0;
        if (duration > 30 && current > 10 && (duration - current) < 5) {
          _triggerCelebration();
        }
      }
    } catch (_) {}
  }

  // --- Settings handlers ---

  void _onPresetChange(String presetId) {
    final preset = AudioPreset.values.where((p) => p.name == presetId).firstOrNull;
    if (preset == null) return;
    ref.read(audioPresetProvider.notifier).state = preset;
    _saveSetting('audio_preset', preset.name);
    if (_overlayInjected) _runJs(WebviewOverlay.updatePresetJs(preset.name));
    ref.read(tvSyncServerProvider).updateSessionSettings(preset: preset.name);
    if (_scoringSession != null) _restartScoring();
  }

  void _onModeChange(String modeId) {
    final mode = ScoringMode.values.where((m) => m.name == modeId).firstOrNull;
    if (mode == null) return;
    ref.read(scoringModeProvider.notifier).state = mode;
    _saveSetting('scoring_mode', mode.name);
    ref.read(tvSyncServerProvider).updateSessionSettings(
      mode: mode.name,
      modeName: mode.label,
    );
    if (_scoringSession != null) _restartScoring();
  }

  void _onPitchChange(String direction) {
    final current = ref.read(pitchShiftProvider);
    final next = direction == 'up'
        ? (current + 1).clamp(kPitchShiftMin, kPitchShiftMax)
        : (current - 1).clamp(kPitchShiftMin, kPitchShiftMax);
    ref.read(pitchShiftProvider.notifier).state = next;
    if (_overlayInjected) _runJs(WebviewOverlay.updatePitchShiftJs(next));

    final tvServer = ref.read(tvSyncServerProvider);
    if (tvServer.hasConnectedTv) {
      tvServer.sendPitchShift(next);
    } else {
      _runJs('''
        (function(){
          var v=document.querySelector('video');
          if(!v)return;
          v.preservesPitch=false;
          v.playbackRate=Math.pow(2,$next/12);
        })();
      ''');
    }
    if (_scoringSession != null) _restartScoring();
  }

  Future<void> _calibrateMic() async {
    _runJs(WebviewOverlay.updateCalibrateJs(S.calibCountdown(3), active: true));
    if (mounted) setState(() => _calibrationStatus = S.calibCountdown(3));

    final mic = ref.read(micCaptureServiceProvider);
    final wasRecording = mic.isRecording;
    if (!wasRecording) {
      final started = await mic.start();
      if (!started) {
        _runJs(WebviewOverlay.updateCalibrateJs(S.calibMicUnavailable));
        if (mounted) setState(() => _calibrationStatus = S.calibMicUnavailable);
        return;
      }
    }

    final rmsValues = <double>[];
    final sub = mic.pcmStream.listen((frame) {
      rmsValues.add(frame.rawPeak);
    });

    for (var i = 2; i >= 0; i--) {
      await Future.delayed(const Duration(seconds: 1));
      if (i > 0) {
        _runJs(WebviewOverlay.updateCalibrateJs(S.calibCountdown(i), active: true));
        if (mounted) setState(() => _calibrationStatus = S.calibCountdown(i));
      }
    }

    await sub.cancel();
    if (!wasRecording) await mic.stop();

    if (rmsValues.isEmpty) {
      _runJs(WebviewOverlay.updateCalibrateJs(S.calibNoData));
      if (mounted) setState(() => _calibrationStatus = S.calibNoData);
      return;
    }

    rmsValues.sort();
    final p90 = rmsValues[(rmsValues.length * 0.9).floor()];
    final noiseGate = p90 * 2.0;
    final singingThreshold = p90 * 4.0;

    ref.read(calibratedNoiseGateProvider.notifier).state = noiseGate;
    ref.read(calibratedSingingThresholdProvider.notifier).state = singingThreshold;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('calibrated_noise_gate', noiseGate);
    await prefs.setDouble('calibrated_singing_threshold', singingThreshold);

    _runJs(WebviewOverlay.updateCalibrateJs(S.calibDone));
    if (mounted) setState(() => _calibrationStatus = S.calibDone);
    if (_scoringSession != null) _restartScoring();
  }

  void _showScoreInfo() {
    final mode = ref.read(scoringModeProvider);
    _runJs(WebviewOverlay.scoreInfoOverlayJs(mode.name));
  }

  Future<void> _dismissWelcome() async {
    _welcomeDismissedPermanently = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('welcome_dismissed', true);
  }

  Future<void> _showTvConnectionDialog() async {
    final tvServer = ref.read(tvSyncServerProvider);
    await tvServer.refreshLocalIp();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF16213E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final ip = tvServer.localIp ?? 'Wi-Fi';
            final code = tvServer.quickCode;
            final connected = tvServer.hasConnectedTv;
            final tvName = tvServer.discoveredTvName ?? 'Samsung Tizen TV';
            final tvIp = tvServer.discoveredTvIp;

            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.tv,
                        color: connected ? const Color(0xFF00FF88) : const Color(0xFF00D2FF),
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          connected
                              ? 'Conectado à TV Samsung!'
                              : 'Parear com Samsung Tizen TV',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: connected
                              ? const Color(0xFF00FF88).withValues(alpha: 0.15)
                              : const Color(0xFF00D2FF).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          connected ? 'ONLINE' : 'AGUARDANDO',
                          style: TextStyle(
                            color: connected ? const Color(0xFF00FF88) : const Color(0xFF00D2FF),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF6C5CE7).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'IP DO CELULAR NA REDE',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$ip:${tvServer.port}',
                              style: const TextStyle(
                                color: Color(0xFF00D2FF),
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6C5CE7).withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              const Text(
                                'CÓD. RÁPIDO',
                                style: TextStyle(color: Colors.white54, fontSize: 9),
                              ),
                              Text(
                                code,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6C5CE7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () async {
                        final ok = await tvServer.launchTizenAppOnTv();
                        setSheetState(() {});
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok
                                    ? 'App Frank Karaoke TV iniciado na $tvName!'
                                    : 'Abra o app Frank Karaoke TV na sua TV Samsung (IP: $ip)',
                              ),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.rocket_launch),
                      label: Text(
                        tvIp != null
                            ? 'Abrir App na $tvName ($tvIp)'
                            : 'Procurar e Abrir App na TV Samsung',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --- Helpers ---

  Future<void> _runJs(String source) {
    return _controller.runJavaScript(source).catchError((Object e) {
      debugPrint('runJs error: $e');
    });
  }

  double _logNormalize(double hz, double minHz, double maxHz) {
    if (hz <= minHz) return 0;
    if (hz >= maxHz) return 1;
    return (math.log(hz / minHz) / math.log(maxHz / minHz)).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _tvEventSub?.cancel();
    _tvConnSub?.cancel();
    _stopScoring();
    super.dispose();
  }

  Widget _buildTvTopBar() {
    final tvServer = ref.watch(tvSyncServerProvider);
    final isConnected = ref.watch(isTvConnectedProvider) || tvServer.hasConnectedTv;
    final videoId = ref.watch(currentVideoIdProvider);
    final ip = tvServer.localIp ?? '...';

    return Container(
      color: const Color(0xFF121224),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          InkWell(
            onTap: _showTvConnectionDialog,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isConnected
                    ? const Color(0xFF00FF88).withValues(alpha: 0.15)
                    : const Color(0xFF6C5CE7).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isConnected
                      ? const Color(0xFF00FF88).withValues(alpha: 0.5)
                      : const Color(0xFF00D2FF).withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.tv,
                    size: 16,
                    color: isConnected ? const Color(0xFF00FF88) : const Color(0xFF00D2FF),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isConnected ? 'TV Conectada (Modo Mic)' : 'TV: $ip (Cód: ${tvServer.quickCode})',
                    style: TextStyle(
                      color: isConnected ? const Color(0xFF00FF88) : Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (isConnected && videoId != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF00D2FF),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
              onPressed: () {
                setState(() => _showTvRemoteCard = !_showTvRemoteCard);
              },
              icon: Icon(_showTvRemoteCard ? Icons.search : Icons.mic, size: 16),
              label: Text(
                _showTvRemoteCard ? 'Buscar Música' : 'Controle TV',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            )
          else
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF00D2FF),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
              onPressed: _showTvConnectionDialog,
              icon: const Icon(Icons.cast_connected, size: 16),
              label: const Text(
                'Conectar TV',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTvRemoteControllerOverlay() {
    final tvServer = ref.watch(tvSyncServerProvider);
    final title = ref.watch(currentVideoTitleProvider) ?? 'Carregando música...';
    final score = ref.watch(currentScoreProvider);
    final pitchShift = ref.watch(pitchShiftProvider);
    final mode = ref.watch(scoringModeProvider);
    final preset = ref.watch(audioPresetProvider);

    return Container(
      color: const Color(0xFF0D0D1A).withValues(alpha: 0.96),
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: Playing on TV
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF6C5CE7).withValues(alpha: 0.35),
                    const Color(0xFF00D2FF).withValues(alpha: 0.15),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF00D2FF).withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.tv, color: Color(0xFF00FF88), size: 18),
                      SizedBox(width: 8),
                      Text(
                        'REPRODUZINDO NA TV SAMSUNG',
                        style: TextStyle(
                          color: Color(0xFF00FF88),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Live Mic + Score Display on Phone
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'SUA NOTA (MIC)',
                          style: TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 1.5),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _currentNote,
                          style: const TextStyle(
                            color: Color(0xFF00D2FF),
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: LinearProgressIndicator(
                            value: _currentRms.clamp(0.0, 1.0),
                            backgroundColor: Colors.white12,
                            color: const Color(0xFF00FF88),
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'PONTUAÇÃO AO VIVO',
                          style: TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 1.5),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '$score',
                          style: const TextStyle(
                            color: Color(0xFFFFD700),
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          mode.label,
                          style: const TextStyle(
                            color: Color(0xFF6C5CE7),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Playback Controls (Play/Pause & Restart on TV)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _tvPlaying ? const Color(0xFFFF9F43) : const Color(0xFF00FF88),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      if (_tvPlaying) {
                        tvServer.sendPause();
                        setState(() => _tvPlaying = false);
                        _onVideoPause();
                      } else {
                        tvServer.sendPlay();
                        setState(() => _tvPlaying = true);
                        _onVideoPlay();
                      }
                    },
                    icon: Icon(_tvPlaying ? Icons.pause : Icons.play_arrow),
                    label: Text(
                      _tvPlaying ? 'Pausar TV' : 'Tocar na TV',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _restartScoring,
                    icon: const Icon(Icons.replay),
                    label: const Text(
                      'Reiniciar',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Pitch Shift Control
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'AJUSTE DE TOM (TV)',
                    style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => _onPitchChange('down'),
                        icon: const Icon(Icons.remove_circle_outline, color: Color(0xFF00D2FF)),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${pitchShift > 0 ? "+" : ""}$pitchShift',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _onPitchChange('up'),
                        icon: const Icon(Icons.add_circle_outline, color: Color(0xFF00D2FF)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Scoring Mode Selector
            const Text(
              'MODO DE PONTUAÇÃO',
              style: TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.5),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ScoringMode.values.map((m) {
                final active = m == mode;
                return ChoiceChip(
                  label: Text(m.label),
                  selected: active,
                  onSelected: (_) => _onModeChange(m.name),
                  selectedColor: const Color(0xFF00D2FF).withValues(alpha: 0.25),
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                  labelStyle: TextStyle(
                    color: active ? const Color(0xFF00D2FF) : Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),

            // Mic Preset & Calibration
            const Text(
              'AMBIENTE DO MICROFONE',
              style: TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.5),
            ),
            const SizedBox(height: 8),
            Row(
              children: AudioPreset.values.map((p) {
                final active = p == preset;
                final label = switch (p) {
                  AudioPreset.externalMic => S.presetClean,
                  AudioPreset.roomMic => S.presetRoom,
                  AudioPreset.partyMode => S.presetParty,
                };
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(label, style: const TextStyle(fontSize: 12)),
                      selected: active,
                      onSelected: (_) => _onPresetChange(p.name),
                      selectedColor: const Color(0xFF6C5CE7).withValues(alpha: 0.4),
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      labelStyle: TextStyle(
                        color: active ? Colors.white : Colors.white60,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF00D2FF),
                      side: BorderSide(color: const Color(0xFF00D2FF).withValues(alpha: 0.4)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _calibrateMic,
                    icon: const Icon(Icons.mic_none, size: 18),
                    label: Text(_calibrationStatus ?? S.calibrateMic),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6C5CE7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => setState(() => _showTvRemoteCard = false),
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Buscar Outra Música'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tvServer = ref.watch(tvSyncServerProvider);
    final isTvConnected = ref.watch(isTvConnectedProvider) || tvServer.hasConnectedTv;
    final currentVideoId = ref.watch(currentVideoIdProvider);

    return Column(
      children: [
        _buildTvTopBar(),
        Expanded(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (isTvConnected && currentVideoId != null && _showTvRemoteCard)
                Positioned.fill(
                  child: _buildTvRemoteControllerOverlay(),
                ),
              if (!_isReady)
                const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ],
    );
  }
}
