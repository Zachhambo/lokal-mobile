import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/song.dart';

class CopiedTrackClip {
  const CopiedTrackClip({this.videoId, this.uri, this.start, this.end});

  final String? videoId;
  final Uri? uri;
  final double? start;
  final double? end;

  static final revision = ValueNotifier(0);
  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static const _extensions = {'mp4', 'm4v', 'webm', 'mov', 'mkv', 'ogv', 'ogg'};

  static String _key(int serverId, String trackId) =>
      'lokal.link.clip.$serverId.$trackId';

  static Future<Directory> directory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'track_clips'),
  );

  static Future<File?> _localFile(Object? value) async {
    if (value is! String ||
        !RegExp(r'^[a-fA-F0-9-]+\.[a-z0-9]+$').hasMatch(value) ||
        !validExtension(p.extension(value).substring(1))) {
      return null;
    }
    return File(p.join((await directory()).path, value));
  }

  static bool validExtension(String extension) =>
      _extensions.contains(extension);

  static Future<CopiedTrackClip?> forSong(Song song) async {
    final serverId = song.remoteServerId;
    final trackId = song.remoteId;
    if (serverId == null || trackId == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(serverId, trackId));
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final file = await _localFile(data['file']);
      final videoId = data['videoId'];
      final url = data['url'];
      Uri? uri;
      if (file != null && await file.exists()) {
        uri = file.uri;
      } else if (url is String) {
        final parsed = Uri.tryParse(url);
        if (parsed != null &&
            parsed.hasAuthority &&
            (parsed.scheme == 'http' || parsed.scheme == 'https')) {
          uri = parsed;
        }
      }
      final youtube = videoId is String && _videoId.hasMatch(videoId)
          ? videoId
          : null;
      if (uri == null && youtube == null) return null;
      return CopiedTrackClip(
        videoId: youtube,
        uri: uri,
        start: _seconds(data['start']),
        end: _seconds(data['end']),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static double? _seconds(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

  static Future<void> save(
    int serverId,
    String trackId,
    Map<String, dynamic>? data,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(serverId, trackId);
    final previous = prefs.getString(key);
    final next = data == null ? null : jsonEncode(data);
    if (previous == next) return;
    final saved = next == null
        ? await prefs.remove(key)
        : await prefs.setString(key, next);
    if (!saved) {
      throw const FileSystemException('Could not save the copied video clip.');
    }
    revision.value++;
    if (previous == null) return;
    try {
      final old = jsonDecode(previous);
      if (old is Map && old['file'] != data?['file']) {
        final file = await _localFile(old['file']);
        if (file != null && await file.exists()) await file.delete();
      }
    } on Object {
      // The new clip is already committed.
    }
  }

  ({Duration start, Duration end}) range(Duration duration) {
    final length = duration.inMilliseconds / 1000;
    final from = start;
    final to = end;
    final (double low, double high) = switch ((from, to)) {
      (final double a, final double b) when a < b && a < length => (
        a,
        math.min(b, length),
      ),
      (final double a, _) when a < length => (a, math.min(a + 10, length)),
      (final double _, _) => (math.max(0.0, length - 10), length),
      (_, final double b) when b > 0 => (
        math.max(0.0, math.min(b, length) - 10),
        math.min(b, length),
      ),
      _ => (length / 3, length * 2 / 3),
    };
    return (
      start: Duration(milliseconds: (low * 1000).round()),
      end: Duration(milliseconds: (high * 1000).round()),
    );
  }
}
