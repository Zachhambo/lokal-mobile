import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/discovery/discovery_http.dart';
import '../../features/discovery/discovery_sources.dart';
import '../../features/music_videos/music_video_match.dart';
import '../../models/song.dart';
import '../album_art_service.dart';
import '../lyrics_service.dart';
import 'cast_content_server.dart';
import 'cast_source.dart';

const lokalCastApplicationId = '2060B9B3';
const lokalCastNamespace = 'urn:x-cast:app.lokal.cast';

Map<String, dynamic> castLyrics(String trackId, LyricsData? lyrics) => {
  'type': 'lyrics',
  'trackId': trackId,
  'synced': lyrics?.isSynchronized ?? false,
  'lines': [
    for (final line in lyrics?.lines ?? <LyricsLine>[])
      {'t': line.timestamp.inMilliseconds / 1000, 'text': line.text},
  ],
};

/// Distinguishes repeated FINISHED reports and late reports from an earlier
/// load of the same recording (repeat-one, manual replay, reconnect).
class CastCompletionGate {
  _CastCompletion? _current;
  _CastCompletion? _previous;
  String? get loadId => _current?.loadId;

  void loaded(String loadId) {
    _previous = null;
    _current = _CastCompletion(loadId);
  }

  void begin(String loadId) {
    _previous = _current;
    _current = _CastCompletion(loadId);
  }

  void commit(String loadId) {
    if (_current?.loadId == loadId) _previous = null;
  }

  bool rollback(String loadId) {
    if (_current?.loadId != loadId) return false;
    _current = _previous;
    _previous = null;
    return true;
  }

  void clear() {
    _current = null;
    _previous = null;
  }

  // Retain a terminal report even when LOAD has not replied or the output
  // handoff has not committed. Android need not repeat its final idle status.
  void observe(Map<String, dynamic> event) {
    if (event['finished'] != true) return;
    for (final state in [_current, _previous]) {
      if (state != null && !state.consumed && event['loadId'] == state.loadId)
        state.pending = Map.of(event);
    }
  }

  Map<String, dynamic>? takePending({required bool ready}) {
    final state = _current;
    if (!ready || state == null || state.consumed || state.pending == null)
      return null;
    state.consumed = true;
    return state.pending;
  }
}

class _CastCompletion {
  _CastCompletion(this.loadId);
  final String loadId;
  Map<String, dynamic>? pending;
  bool consumed = false;
}

Future<String?> castArtwork(
  Song song, {
  bool Function()? stillCurrent,
  bool preferJpeg = false,
}) async {
  bool current() => stillCurrent?.call() ?? true;
  if (!current()) return null;
  final direct = receiverDirectUrl(song.albumArt);
  if (direct != null) return direct;
  String? path = song.albumArt;
  final uri = path == null ? null : Uri.tryParse(path);
  if (uri != null && uri.scheme == 'file') path = uri.toFilePath();
  if (path == null || !await File(path).exists()) {
    path = await AlbumArtService.instance.resolveArtworkPath(
      existingPath: song.albumArt,
      audioSourcePath: song.filePath ?? '',
    );
  }
  if (!current() || path == null || !await File(path).exists()) return null;
  final handle = await File(path).open();
  late final List<int> header;
  try {
    header = await handle.read(12);
  } finally {
    await handle.close();
  }
  if (!current()) return null;
  final extension = switch (header) {
    [0xff, 0xd8, 0xff, ...] => 'jpeg',
    [0x89, 0x50, 0x4e, 0x47, ...] => 'png',
    [0x52, 0x49, 0x46, 0x46, _, _, _, _, 0x57, 0x45, 0x42, 0x50] => 'webp',
    [0x47, 0x49, 0x46, ...] => 'gif',
    [0x42, 0x4d, ...] => 'bmp',
    _ => null,
  };
  if (preferJpeg && extension != 'jpeg') {
    final jpeg = await compute(_encodeCastJpeg, await File(path).readAsBytes());
    if (jpeg == null || !current()) return null;
    return CastContentServer.instance.serveJpeg(jpeg, stillCurrent: current);
  }
  if (extension == null) return null;
  return CastContentServer.instance.serve(
    path,
    filename: extension == 'jpeg' ? 'cover.jpg' : 'cover.$extension',
    contentType: ContentType('image', extension),
    stillCurrent: current,
  );
}

Uint8List? _encodeCastJpeg(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) return null;
  const maxDimension = 640;
  final width = image.width;
  final height = image.height;
  final resized = width >= height && width > maxDimension
      ? img.copyResize(image, width: maxDimension)
      : height > maxDimension
      ? img.copyResize(image, height: maxDimension)
      : image;
  return img.encodeJpg(resized, quality: 85);
}

Future<String?> castMusicVideo(Song song) async {
  final prefs = await SharedPreferences.getInstance();
  Map<dynamic, dynamic> matches = {};
  try {
    matches =
        jsonDecode(prefs.getString('lokal_music_video_matches') ?? '{}') as Map;
  } catch (_) {}
  if (matches[song.id] case final String saved)
    return saved.isEmpty ? null : saved;
  // Called only for the explicitly selected receiver Video view.
  final client = http.Client();
  try {
    return await findMusicVideo(
      YoutubeMusicCatalog(DiscoveryHttp(client)),
      song,
    );
  } finally {
    client.close();
  }
}
