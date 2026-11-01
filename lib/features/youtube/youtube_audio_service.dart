import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Extracts audio and muxed video stream URLs from YouTube videos using youtube_explode_dart.
class YouTubeAudioService {
  final _yt = YoutubeExplode();
  final Map<String, StreamManifest> _manifestCache = {};

  Future<StreamManifest?> _getManifest(String videoId) async {
    final cached = _manifestCache[videoId];
    if (cached != null) return cached;
    try {
      final manifest = await _yt.videos.streamsClient.getManifest(videoId);
      _manifestCache[videoId] = manifest;
      return manifest;
    } catch (e) {
      debugPrint('Failed to get manifest for $videoId: $e');
      return null;
    }
  }

  /// Extract the best audio-only stream URL for a given video ID.
  /// Returns null if extraction fails.
  Future<AudioStreamInfo?> getAudioStreamInfo(String videoId) async {
    try {
      final manifest = await _getManifest(videoId);
      if (manifest == null) return null;
      final audioStreams = manifest.audioOnly.sortByBitrate();
      if (audioStreams.isEmpty) return null;
      // Pick the highest bitrate audio stream.
      return audioStreams.last;
    } catch (e) {
      debugPrint('Failed to extract audio for $videoId: $e');
      return null;
    }
  }

  /// Extract the best muxed (video + audio) stream for playing on the Tizen TV.
  Future<MuxedStreamInfo?> getMuxedStreamInfo(String videoId) async {
    try {
      final manifest = await _getManifest(videoId);
      if (manifest == null) return null;
      final muxedStreams = manifest.muxed.sortByVideoQuality();
      if (muxedStreams.isEmpty) return null;
      return muxedStreams.last;
    } catch (e) {
      debugPrint('Failed to extract muxed video for $videoId: $e');
      return null;
    }
  }

  /// Open a byte stream for the given YouTube StreamInfo.
  Stream<List<int>> openStream(StreamInfo streamInfo) {
    return _yt.videos.streamsClient.get(streamInfo);
  }

  /// Get the video title for display.
  Future<String?> getVideoTitle(String videoId) async {
    try {
      final video = await _yt.videos.get(videoId);
      return video.title;
    } catch (e) {
      debugPrint('Failed to get title for $videoId: $e');
      return null;
    }
  }

  void dispose() {
    _manifestCache.clear();
    _yt.close();
  }
}
