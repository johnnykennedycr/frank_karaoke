import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frank_karaoke/features/tv/tv_sync_server.dart';
import 'package:frank_karaoke/features/youtube/youtube_audio_service.dart';

void main() {
  group('TvSyncServer', () {
    late YouTubeAudioService audioService;
    late TvSyncServer server;

    setUp(() {
      audioService = YouTubeAudioService();
      server = TvSyncServer(audioService: audioService);
    });

    tearDown(() async {
      await server.dispose();
      audioService.dispose();
    });

    test('starts local server, responds to /ping, and exchanges WebSocket messages', () async {
      final started = await server.start();
      expect(started, isTrue);
      expect(server.isRunning, isTrue);

      // Test /ping HTTP endpoint
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/ping'));
      final res = await req.close();
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      expect(body['app'], 'frank_karaoke');
      client.close(force: true);

      // Test WebSocket connection and bidirectional messaging
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
      final receivedByTv = <Map<String, dynamic>>[];
      ws.listen((dynamic raw) {
        if (raw is String) {
          receivedByTv.add(jsonDecode(raw) as Map<String, dynamic>);
        }
      });

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.hasConnectedTv, isTrue);
      expect(receivedByTv.isNotEmpty, isTrue);
      expect(receivedByTv.first['type'], 'state');

      // Broadcast score from Phone to TV
      server.sendScore(
        liveScore: 88,
        overallScore: 82,
        streakCount: 10,
        modeName: 'Pitch',
        normalizedPitch: 0.5,
        frameScore: 0.85,
        noteName: 'C4',
        normalizedRms: 0.7,
        primaryScore: 0.85,
        confidence: 0.9,
        stability: 0.0,
        rms: 0.05,
        pitchHz: 261.63,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(receivedByTv.any((m) => m['type'] == 'score' && m['liveScore'] == 88), isTrue);

      // Send event from TV to Phone
      final tvEventsFuture = server.tvEvents.first;
      ws.add(jsonEncode({'type': 'timeupdate', 'time': 42.5, 'duration': 180.0}));
      final event = await tvEventsFuture.timeout(const Duration(seconds: 2));
      expect(event['type'], 'timeupdate');
      expect(event['time'], 42.5);

      await ws.close();
    });
  });
}
