import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../youtube/youtube_audio_service.dart';

/// Local HTTP + WebSocket server running on the Android phone.
///
/// Allows the dedicated Samsung Tizen TV app (`FrnkKaraok.FrankKaraokeTV`)
/// to auto-discover the phone on the local Wi-Fi network, stream video/audio
/// directly on the TV, and receive real-time vocal pitch & scoring updates.
class TvSyncServer {
  final YouTubeAudioService _audioService;
  HttpServer? _server;
  int _port = 8080;
  String? _localIp;
  String? _discoveredTvIp;
  String? _discoveredTvName;

  final Set<WebSocket> _clients = {};
  final _tvEventController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionChangedController = StreamController<bool>.broadcast();

  // Cached current state to send immediately when a TV connects
  String? _currentVideoId;
  String _currentTitle = '';
  int _currentPitchShift = 0;
  String _currentPreset = 'roomMic';
  String _currentMode = 'pitchClass';
  String _currentModeName = 'Pitch';

  TvSyncServer({required YouTubeAudioService audioService})
      : _audioService = audioService;

  Stream<Map<String, dynamic>> get tvEvents => _tvEventController.stream;
  Stream<bool> get onConnectionChanged => _connectionChangedController.stream;

  bool get isRunning => _server != null;
  bool get hasConnectedTv => _clients.isNotEmpty;
  int get clientCount => _clients.length;
  int get port => _port;
  String? get localIp => _localIp;
  String? get discoveredTvIp => _discoveredTvIp;
  String? get discoveredTvName => _discoveredTvName;

  String get quickCode {
    final ip = _localIp;
    if (ip == null) return '--';
    final parts = ip.split('.');
    return parts.isNotEmpty ? parts.last : ip;
  }

  /// Start the local server on port 8080 (or 8081..8089 if busy).
  Future<bool> start() async {
    if (_server != null) return true;

    _localIp = await _resolveLocalWiFiIp();

    for (var p = 8080; p <= 8089; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p, shared: true);
        _port = p;
        break;
      } catch (_) {}
    }

    if (_server == null) {
      debugPrint('TvSyncServer: failed to bind port 8080..8089');
      return false;
    }

    debugPrint('TvSyncServer: listening on http://${_localIp ?? "0.0.0.0"}:$_port');
    _server!.listen(_handleRequest, onError: (Object e) {
      debugPrint('TvSyncServer: request error: $e');
    });

    // Proactively scan for a Samsung Tizen TV on the local network in background
    unawaited(discoverSamsungTv());
    return true;
  }

  Future<String?> _resolveLocalWiFiIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      String? fallbackIp;
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.')) return ip;
          if (ip.startsWith('10.') || ip.startsWith('172.')) {
            fallbackIp ??= ip;
          }
        }
      }
      return fallbackIp;
    } catch (e) {
      debugPrint('TvSyncServer: error resolving local IP: $e');
      return null;
    }
  }

  Future<void> refreshLocalIp() async {
    _localIp = await _resolveLocalWiFiIp();
  }

  void _addCorsHeaders(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers', '*');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _addCorsHeaders(request.response);

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    if (path == '/ping') {
      _localIp ??= await _resolveLocalWiFiIp();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'app': 'frank_karaoke',
        'ip': _localIp ?? '',
        'port': _port,
        'tvConnected': hasConnectedTv,
        'videoId': _currentVideoId,
      }));
      await request.response.close();
      return;
    }

    if (path == '/ws') {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        try {
          final ws = await WebSocketTransformer.upgrade(request);
          _onWebSocketConnected(ws);
        } catch (e) {
          debugPrint('TvSyncServer: WebSocket upgrade error: $e');
        }
      } else {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      }
      return;
    }

    if (path == '/video') {
      final videoId = request.uri.queryParameters['v'];
      if (videoId == null || videoId.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      await _handleVideoProxy(request, videoId);
      return;
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'app': 'frank_karaoke',
      'status': 'ok',
      'ip': _localIp,
      'port': _port,
    }));
    await request.response.close();
  }

  Future<void> _handleVideoProxy(HttpRequest request, String videoId) async {
    try {
      final muxed = await _audioService.getMuxedStreamInfo(videoId);
      if (muxed == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        muxed.codec.mimeType,
      );
      request.response.bufferOutput = false;

      final stream = _audioService.openStream(muxed);
      await request.response.addStream(stream);
      await request.response.close();
    } catch (e) {
      debugPrint('TvSyncServer: video stream proxy closed/error for $videoId: $e');
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _onWebSocketConnected(WebSocket ws) {
    _clients.add(ws);
    debugPrint('TvSyncServer: TV client connected (${_clients.length} active)');
    _connectionChangedController.add(hasConnectedTv);

    // Send current state immediately
    _sendToSocket(ws, {
      'type': 'state',
      'videoId': _currentVideoId,
      'title': _currentTitle,
      'pitchShift': _currentPitchShift,
      'preset': _currentPreset,
      'mode': _currentMode,
      'modeName': _currentModeName,
    });

    ws.listen(
      (dynamic raw) {
        if (raw is String) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) {
              _tvEventController.add(decoded);
            }
          } catch (_) {}
        }
      },
      onDone: () => _removeClient(ws),
      onError: (_) => _removeClient(ws),
      cancelOnError: true,
    );
  }

  void _removeClient(WebSocket ws) {
    if (_clients.remove(ws)) {
      debugPrint('TvSyncServer: TV client disconnected (${_clients.length} active)');
      _connectionChangedController.add(hasConnectedTv);
    }
  }

  void _sendToSocket(WebSocket ws, Map<String, dynamic> data) {
    if (ws.readyState == WebSocket.open) {
      try {
        ws.add(jsonEncode(data));
      } catch (_) {}
    }
  }

  /// Broadcast a JSON message to all connected Tizen TVs.
  void broadcast(Map<String, dynamic> data) {
    if (_clients.isEmpty) return;
    final encoded = jsonEncode(data);
    final dead = <WebSocket>[];
    for (final ws in _clients) {
      if (ws.readyState == WebSocket.open) {
        try {
          ws.add(encoded);
        } catch (_) {
          dead.add(ws);
        }
      } else {
        dead.add(ws);
      }
    }
    for (final ws in dead) {
      _removeClient(ws);
    }
  }

  void updateSessionSettings({
    String? videoId,
    String? title,
    int? pitchShift,
    String? preset,
    String? mode,
    String? modeName,
  }) {
    if (videoId != null) _currentVideoId = videoId;
    if (title != null) _currentTitle = title;
    if (pitchShift != null) _currentPitchShift = pitchShift;
    if (preset != null) _currentPreset = preset;
    if (mode != null) _currentMode = mode;
    if (modeName != null) _currentModeName = modeName;

    broadcast({
      'type': 'settings',
      'videoId': _currentVideoId,
      'title': _currentTitle,
      'pitchShift': _currentPitchShift,
      'preset': _currentPreset,
      'mode': _currentMode,
      'modeName': _currentModeName,
    });
  }

  void sendLoadVideo({
    required String videoId,
    required String title,
    required int pitchShift,
    required String preset,
    required String mode,
    required String modeName,
  }) {
    _currentVideoId = videoId;
    _currentTitle = title;
    _currentPitchShift = pitchShift;
    _currentPreset = preset;
    _currentMode = mode;
    _currentModeName = modeName;

    broadcast({
      'type': 'loadVideo',
      'videoId': videoId,
      'title': title,
      'pitchShift': pitchShift,
      'preset': preset,
      'mode': mode,
      'modeName': modeName,
    });
  }

  void sendPlay() => broadcast({'type': 'play'});
  void sendPause() => broadcast({'type': 'pause'});
  void sendRestart() => broadcast({'type': 'restart'});
  void sendStopVideo() {
    _currentVideoId = null;
    broadcast({'type': 'stopVideo'});
  }

  void sendPitchShift(int semitones) {
    _currentPitchShift = semitones;
    broadcast({'type': 'pitchShift', 'pitchShift': semitones});
  }

  void sendProcessing(bool show, {String? message}) {
    broadcast({
      'type': 'processing',
      'show': show,
      if (message != null) 'message': message,
    });
  }

  void sendCelebration(int score) {
    broadcast({
      'type': 'celebration',
      'score': score,
    });
  }

  void sendScore({
    required int liveScore,
    required int overallScore,
    required int streakCount,
    required String modeName,
    required double normalizedPitch,
    required double frameScore,
    required String noteName,
    required double normalizedRms,
    required double primaryScore,
    required double confidence,
    required double stability,
    required double rms,
    required double pitchHz,
  }) {
    if (_clients.isEmpty) return;
    broadcast({
      'type': 'score',
      'liveScore': liveScore,
      'overallScore': overallScore,
      'streakCount': streakCount,
      'modeName': modeName,
      'normalizedPitch': normalizedPitch,
      'frameScore': frameScore,
      'noteName': noteName,
      'normalizedRms': normalizedRms,
      'primaryScore': primaryScore,
      'confidence': confidence,
      'stability': stability,
      'rms': rms,
      'pitchHz': pitchHz,
    });
  }

  /// Discover a Samsung Tizen TV on the local subnet (port 8001).
  Future<String?> discoverSamsungTv() async {
    _localIp ??= await _resolveLocalWiFiIp();
    final ip = _localIp;
    if (ip == null) return null;

    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';

    const batchSize = 32;
    for (var start = 1; start <= 254; start += batchSize) {
      final futures = <Future<String?>>[];
      final end = (start + batchSize - 1).clamp(1, 254);
      for (var i = start; i <= end; i++) {
        final candidate = '$prefix$i';
        if (candidate == ip) continue;
        futures.add(_probeSamsungTv(candidate));
      }
      final results = await Future.wait(futures);
      final match = results.whereType<String>().firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  Future<String?> _probeSamsungTv(String tvIp) async {
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
    try {
      final req = await client.getUrl(Uri.parse('http://$tvIp:8001/api/v2/'));
      final res = await req.close().timeout(const Duration(milliseconds: 700));
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        if (data is Map && data['device'] is Map) {
          final dev = data['device'] as Map;
          if (dev['OS'] == 'Tizen') {
            _discoveredTvIp = tvIp;
            _discoveredTvName = (dev['name'] as String?)?.replaceAll('&quot;', '"') ?? 'Samsung TV';
            debugPrint('TvSyncServer: found Samsung Tizen TV at $tvIp ($_discoveredTvName)');
            return tvIp;
          }
        }
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Remotely launch the installed `FrnkKaraok.FrankKaraokeTV` app on a Samsung Tizen TV
  /// using Samsung's local REST API (`POST http://<tvIp>:8001/api/v2/applications/FrnkKaraok.FrankKaraokeTV`).
  Future<bool> launchTizenAppOnTv([String? tvIp]) async {
    final targetIp = tvIp ?? _discoveredTvIp ?? await discoverSamsungTv();
    if (targetIp == null) return false;

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final uri = Uri.parse(
        'http://$targetIp:8001/api/v2/applications/FrnkKaraok.FrankKaraokeTV',
      );
      final req = await client.postUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 3));
      debugPrint('TvSyncServer: launchTizenAppOnTv($targetIp) -> HTTP ${res.statusCode}');
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('TvSyncServer: failed to launch app on TV $targetIp: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> dispose() async {
    for (final ws in _clients.toList()) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    await _tvEventController.close();
    await _connectionChangedController.close();
  }
}
