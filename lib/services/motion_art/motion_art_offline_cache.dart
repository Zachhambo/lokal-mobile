import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flick/core/utils/dev_log.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'animated_artwork_service.dart';
import 'local_motion_hls_server.dart';

/// Persistent, completed video clips (not merely cached motion-art URLs).
///
/// Downloads happen after network playback starts, never on the critical path
/// to the first frame. Files live in application support rather than the OS's
/// evictable temporary cache. HLS playlists and their segments are committed
/// together; interrupted downloads can never masquerade as offline clips.
class MotionArtOfflineCache {
  MotionArtOfflineCache._({http.Client? client, Directory? directory})
    : _client = client ?? http.Client(),
      _directoryOverride = directory;

  static final instance = MotionArtOfflineCache._();

  @visibleForTesting
  static MotionArtOfflineCache create({
    http.Client? client,
    Directory? directory,
  }) => MotionArtOfflineCache._(client: client, directory: directory);

  static const int maxClipBytes = 35 * 1024 * 1024;
  static const int maxCacheBytes = 250 * 1024 * 1024;
  static const Duration _timeout = Duration(seconds: 20);

  final http.Client _client;
  final Directory? _directoryOverride;
  final Map<String, Future<File?>> _downloads = {};
  final Map<String, int> _inUse = {};

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static bool _secureUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  Future<Directory> _root() async {
    final base = _directoryOverride ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/motion_art_offline');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _lookupFile(String key) async =>
      File('${(await _root()).path}/lookup-${_hash(key)}.json');

  Future<Directory> _clipDir(String url) async =>
      Directory('${(await _root()).path}/clip-${_hash(url)}');

  /// Only return a saved lookup if at least one of its videos is fully cached.
  /// This lets offline playback bypass provider search after an app restart.
  Future<AnimatedArtwork?> find(String key) async {
    try {
      final file = await _lookupFile(key);
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic> ||
          data['artwork'] is! Map<String, dynamic>) {
        return null;
      }
      final artwork = AnimatedArtwork.fromJson(
        data['artwork'] as Map<String, dynamic>,
      );
      for (final url in _urls(artwork, preferVertical: false)) {
        if (await localFile(url) != null) return artwork;
      }
    } catch (error) {
      devLog('[MotionArt] offline lookup ignored: $error');
    }
    return null;
  }

  Set<String> _urls(AnimatedArtwork artwork, {required bool preferVertical}) {
    return {
      if (preferVertical) ...[
        artwork.verticalPlaybackUrl,
        artwork.videoUrlVertical,
      ],
      artwork.playbackUrl,
      artwork.videoUrl,
      artwork.verticalPlaybackUrl,
      artwork.videoUrlVertical,
    }.nonNulls.toSet();
  }

  /// Prefer an already downloaded video (including a square fallback when a
  /// portrait variant was never cached). Otherwise preserve online quality.
  Future<({String url, String? cachedSource})?> playable(
    AnimatedArtwork artwork, {
    required bool preferVertical,
  }) async {
    final urls = _urls(artwork, preferVertical: preferVertical);
    for (final source in urls) {
      final file = await localFile(source);
      if (file != null) {
        try {
          // AVPlayer needs an HTTP HLS source even when every segment is on
          // disk. The loopback-only server serves these files without data.
          final url = file.path.endsWith('.m3u8')
              ? (await LocalMotionHlsServer.serve(file)).toString()
              : file.uri.toString();
          return (url: url, cachedSource: source);
        } catch (error) {
          devLog('[MotionArt] local HLS playback unavailable: $error');
        }
      }
    }
    final preferred = urls.firstOrNull;
    if (preferred == null) return null;
    return (url: preferred, cachedSource: null);
  }

  /// Check the completed marker, not just a playlist or partial segment.
  Future<File?> localFile(String source) async {
    if (!_secureUrl(source)) return null;
    try {
      final dir = await _clipDir(source);
      final marker = File('${dir.path}/complete.json');
      if (!await marker.exists()) return null;
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map || decoded['url'] != source) return null;
      final name = decoded['entry'];
      if (name != 'clip.mp4' &&
          name != 'clip.webm' &&
          name != 'clip.mov' &&
          name != 'playlist.m3u8') {
        return null;
      }
      final file = File('${dir.path}/$name');
      if (!await file.exists() || await file.length() == 0) return null;
      if (name == 'playlist.m3u8' && !await _hasCompleteHlsAssets(file)) {
        return null;
      }
      await file.setLastModified(DateTime.now());
      return file;
    } catch (_) {
      return null;
    }
  }

  /// HLS requires every local media segment and initialization map.
  /// Reject incomplete caches before a native decoder opens them offline.
  Future<bool> _hasCompleteHlsAssets(File playlist) async {
    final body = await playlist.readAsString();
    if (!body.contains('#EXT-X-ENDLIST')) return false;
    final names = <String>{};
    for (final raw in body.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-MAP:')) {
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match == null) return false;
        names.add(match[1]!);
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        names.add(line);
      }
    }
    if (names.isEmpty || names.length > 150) return false;
    final allowed = RegExp(r'^asset_[0-9]+\.(?:mp4|m4s|ts|aac|bin)$');
    for (final name in names) {
      if (!allowed.hasMatch(name)) return false;
      final segment = File('${playlist.parent.path}/$name');
      if (!await segment.exists() || await segment.length() == 0) {
        return false;
      }
    }
    return true;
  }

  /// Invalidate a video that a native decoder could not open. Future plays
  /// fall back to the network instead of repeatedly using a broken local file.
  Future<void> discard(String source) async {
    if (!_secureUrl(source) || _inUse.containsKey(source)) return;
    try {
      final dir = await _clipDir(source);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (error) {
      devLog('[MotionArt] offline clip discard failed: $error');
    }
  }

  void retain(String source) {
    _inUse[source] = (_inUse[source] ?? 0) + 1;
  }

  void release(String source) {
    final count = _inUse[source] ?? 0;
    if (count <= 1) {
      _inUse.remove(source);
    } else {
      _inUse[source] = count - 1;
    }
  }

  /// Called only after playback has successfully initialized. A failed or
  /// interrupted download is ignored, with normal streamed playback intact.
  Future<void> remember(
    String lookupKey,
    AnimatedArtwork artwork, {
    required bool preferVertical,
    Future<bool> Function()? canDownload,
  }) async {
    if (canDownload != null && !await canDownload()) return;
    try {
      final urls = _urls(artwork, preferVertical: preferVertical);
      for (final url in urls.where(_secureUrl)) {
        final clip = await _ensureClip(url, canDownload: canDownload);
        if (clip == null) continue;
        await index(lookupKey, artwork);
        break;
      }
    } catch (error) {
      devLog('[MotionArt] offline cache write failed: $error');
    }
  }

  /// Index a completed clip independently of the preference that selected it.
  Future<void> index(String key, AnimatedArtwork artwork) async {
    try {
      final file = await _lookupFile(key);
      final temp = await file.parent.createTemp('lookup-');
      try {
        final entry = File('${temp.path}/entry.json');
        await entry.writeAsString(
          jsonEncode({'artwork': artwork.toJson()}),
          flush: true,
        );
        await entry.rename(file.path);
      } finally {
        await temp.delete(recursive: true);
      }
    } catch (error) {
      devLog('[MotionArt] offline index write failed: $error');
    }
  }

  /// Reindex an already downloaded clip without making a request.
  Future<void> indexExisting(String key, AnimatedArtwork artwork) async {
    for (final source in _urls(artwork, preferVertical: false)) {
      if (await localFile(source) != null) {
        await index(key, artwork);
        return;
      }
    }
  }

  Future<File?> _ensureClip(
    String url, {
    Future<bool> Function()? canDownload,
  }) => _downloads.putIfAbsent(url, () async {
    try {
      return await localFile(url) ??
          await _download(url, canDownload: canDownload);
    } finally {
      _downloads.remove(url);
    }
  });

  Future<File?> _download(
    String url, {
    Future<bool> Function()? canDownload,
  }) async {
    final target = await _clipDir(url);
    final temp = Directory('${target.path}.partial');
    try {
      if (canDownload != null && !await canDownload()) return null;
      if (await temp.exists()) await temp.delete(recursive: true);
      await temp.create(recursive: true);
      final entry = Uri.parse(url).path.toLowerCase().endsWith('.m3u8')
          ? await _downloadHls(url, temp, canDownload: canDownload)
          : await _downloadProgressive(url, temp, canDownload: canDownload);
      if (entry == null || (canDownload != null && !await canDownload())) {
        return null;
      }
      await File('${temp.path}/complete.json')
          .writeAsString(jsonEncode({'url': url, 'entry': entry}), flush: true);
      if (await target.exists()) await target.delete(recursive: true);
      await temp.rename(target.path);
      final result = File('${target.path}/$entry');
      // Protect this new clip, and any clips currently opened by a player.
      await _trim(exclude: url);
      devLog('[MotionArt] saved offline clip: ${Uri.parse(url).host}');
      return await result.exists() ? result : null;
    } catch (error) {
      devLog('[MotionArt] video not cached ($url): $error');
      return null;
    } finally {
      if (await temp.exists()) {
        try {
          await temp.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<({List<int> bytes, Uri url})?> _getBytes(
    String url,
    int remaining, {
    Future<bool> Function()? canDownload,
    ({int start, int end})? range,
  }) async {
    if (!_secureUrl(url) ||
        remaining <= 0 ||
        (canDownload != null && !await canDownload())) {
      return null;
    }
    if (range != null && range.end - range.start + 1 > remaining) return null;

    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      Uri.parse(url),
      abortTrigger: abort.future,
    );
    if (range != null) {
      request.headers['Range'] = 'bytes=${range.start}-${range.end}';
      request.headers['Accept-Encoding'] = 'identity';
    }
    final timer = Timer(_timeout, abort.complete);
    try {
      final response = await _client.send(request).timeout(_timeout);
      final effectiveUrl = switch (response) {
        http.BaseResponseWithUrl(:final url) => url,
        _ => request.url,
      };
      if (!_secureUrl(effectiveUrl.toString())) return null;
      final partial = response.statusCode == HttpStatus.partialContent;
      if (partial && range != null) {
        final contentRange = response.headers['content-range'] ?? '';
        if (!contentRange.startsWith('bytes ${range.start}-${range.end}/')) {
          return null;
        }
      } else if (response.statusCode != HttpStatus.ok) {
        return null;
      }
      if (response.contentLength case final int length when length > remaining) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(_timeout)) {
        if (canDownload != null && !await canDownload()) return null;
        if (bytes.length + chunk.length > remaining) return null;
        bytes.addAll(chunk);
      }
      if (range == null) return (bytes: bytes, url: effectiveUrl);
      if (partial) {
        return bytes.length == range.end - range.start + 1
            ? (bytes: bytes, url: effectiveUrl)
            : null;
      }
      // Some CDNs ignore Range and serve the whole (still bounded) asset.
      return bytes.length > range.end
          ? (bytes: bytes.sublist(range.start, range.end + 1), url: effectiveUrl)
          : null;
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<String?> _downloadProgressive(
    String url,
    Directory temp, {
    Future<bool> Function()? canDownload,
  }) async {
    final response = await _getBytes(url, maxClipBytes, canDownload: canDownload);
    if (response == null || response.bytes.isEmpty) return null;
    // Preserve the container extension even when the CDN redirects to an
    // opaque URL. An MP4's file type box also identifies extensionless clips.
    String? extension =
        [response.url, Uri.parse(url)]
            .map((uri) => uri.path.split('.').last.toLowerCase())
            .where(const {'mp4', 'm4v', 'mov', 'webm'}.contains)
            .firstOrNull;
    final bytes = response.bytes;
    if (extension == null &&
        bytes.length >= 12 &&
        String.fromCharCodes(bytes.getRange(4, 8)) == 'ftyp') {
      extension = 'mp4';
    }
    final fileName = switch (extension) {
      'webm' => 'clip.webm',
      'mov' => 'clip.mov',
      'mp4' || 'm4v' => 'clip.mp4',
      _ => null,
    };
    if (fileName == null) return null;
    await File('${temp.path}/$fileName').writeAsBytes(response.bytes, flush: true);
    return fileName;
  }

  Future<String?> _downloadHls(
    String url,
    Directory temp, {
    Future<bool> Function()? canDownload,
  }) async {
    var body = await _getBytes(
      url,
      256 * 1024,
      canDownload: canDownload,
    );
    if (body == null) return null;
    var playlistUrl = body.url;
    var playlist = utf8.decode(body.bytes, allowMalformed: true);
    if (!playlist.trimLeft().startsWith('#EXTM3U')) return null;

    // The service usually selects a bounded rendition already; handle a
    // remaining master playlist without downloading every quality variant.
    if (playlist.contains('#EXT-X-STREAM-INF:')) {
      final rows = playlist.split(RegExp(r'\r?\n'));
      final variants = <(int, String)>[];
      for (var i = 0; i < rows.length - 1; i++) {
        if (!rows[i].startsWith('#EXT-X-STREAM-INF:')) continue;
        final resolution = RegExp(r'RESOLUTION=(\d+)x(\d+)')
            .firstMatch(rows[i]);
        final link = rows
            .skip(i + 1)
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty && !s.startsWith('#'))
            .firstOrNull;
        if (link == null) continue;
        final pixels = resolution == null
            ? 0
            : int.parse(resolution[1]!) * int.parse(resolution[2]!);
        variants.add((pixels, playlistUrl.resolve(link).toString()));
      }
      variants.sort((a, b) => a.$1.compareTo(b.$1));
      final selected =
          variants
              .where((v) => v.$1 >= 480 * 480 && v.$1 <= 960 * 960)
              .lastOrNull ??
          variants.firstOrNull;
      if (selected == null || !_secureUrl(selected.$2)) return null;
      body = await _getBytes(selected.$2, 256 * 1024, canDownload: canDownload);
      if (body == null) return null;
      playlistUrl = body.url;
      playlist = utf8.decode(body.bytes, allowMalformed: true);
    }

    // Offline HLS must be finite, clear, and self-contained.
    if (!playlist.contains('#EXT-X-ENDLIST') ||
        playlist.contains('#EXT-X-I-FRAMES-ONLY') ||
        playlist.contains('#EXT-X-PART:') ||
        playlist.contains('#EXT-X-PRELOAD-HINT:') ||
        playlist.contains('#EXT-X-SESSION-KEY:') ||
        RegExp(r'#EXT-X-KEY:(?!METHOD=NONE)').hasMatch(playlist) ||
        RegExp(r'#EXT-X-(?!MAP:)[^\r\n]*URI=').hasMatch(playlist)) {
      return null;
    }
    final rows = playlist.split(RegExp(r'\r?\n'));
    var totalBytes = 0;
    var assets = 0;
    final rewritten = <String>[];
    final assetNames = <(String, ({int start, int end})?), String>{};

    String? previousSegment;
    int? previousEnd;
    String? segmentRange;
    var segments = 0;

    ({int start, int end})? parseRange(String value, int? nextOffset) {
      final match = RegExp(r'^(\d+)(?:@(\d+))?$').firstMatch(value);
      if (match == null) return null;
      final length = int.tryParse(match[1]!);
      final start = match[2] == null ? nextOffset : int.tryParse(match[2]!);
      if (length == null ||
          length <= 0 ||
          length > maxClipBytes ||
          start == null ||
          start < 0 ||
          start > 0x7fffffffffffffff - length) {
        return null;
      }
      return (start: start, end: start + length - 1);
    }

    Future<String?> copyAsset(
      String remote,
      ({int start, int end})? range,
    ) async {
      if (!_secureUrl(remote)) return null;
      final key = (remote, range);
      final existing = assetNames[key];
      if (existing != null) return existing;
      if (assets >= 150) return null;
      final extension = Uri.parse(remote).path.toLowerCase();
      final suffix = extension.endsWith('.m4s')
          ? '.m4s'
          : extension.endsWith('.mp4')
          ? '.mp4'
          : extension.endsWith('.ts')
          ? '.ts'
          : extension.endsWith('.aac')
          ? '.aac'
          : '.bin';
      final local = 'asset_${assets++}$suffix';
      final response = await _getBytes(
        remote,
        maxClipBytes - totalBytes,
        canDownload: canDownload,
        range: range,
      );
      if (response == null || response.bytes.isEmpty) return null;
      final bytes = response.bytes;
      totalBytes += bytes.length;
      await File('${temp.path}/$local').writeAsBytes(bytes, flush: true);
      assetNames[key] = local;
      return local;
    }

    for (final raw in rows) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-MAP:')) {
        final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (match == null) return null;
        final byteRange = RegExp(r',?BYTERANGE="([^"]+)",?').firstMatch(line);
        if (line.contains('BYTERANGE=') && byteRange == null) return null;
        final remote = playlistUrl.resolve(match[1]!).toString();
        final range = byteRange == null ? null : parseRange(byteRange[1]!, 0);
        if (byteRange != null && range == null) return null;
        final local = await copyAsset(remote, range);
        if (local == null) return null;
        rewritten.add('#EXT-X-MAP:URI="$local"');
      } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
        if (segmentRange != null) return null;
        segmentRange = line.substring('#EXT-X-BYTERANGE:'.length);
      } else if (line.isEmpty || line.startsWith('#')) {
        rewritten.add(raw);
      } else {
        final remote = playlistUrl.resolve(line).toString();
        final offset = remote == previousSegment ? previousEnd : null;
        final range = segmentRange == null
            ? null
            : parseRange(segmentRange, offset);
        if (segmentRange != null && range == null) return null;
        final local = await copyAsset(remote, range);
        if (local == null) return null;
        previousEnd = range == null ? null : range.end + 1;
        segmentRange = null;
        previousSegment = remote;
        segments++;
        rewritten.add(local);
      }
    }
    if (segments == 0 || segmentRange != null) return null;
    await File('${temp.path}/playlist.m3u8')
        .writeAsString(rewritten.join('\n'), flush: true);
    return 'playlist.m3u8';
  }

  Future<void> _trim({required String exclude}) async {
    final root = await _root();
    final dirs = await root.list().where((e) =>
        e is Directory && e.path.split(Platform.pathSeparator).last
            .startsWith('clip-') && !e.path.endsWith('.partial')).cast<Directory>().toList();
    final entries = <({Directory dir, File file, int bytes, DateTime used})>[];
    var total = 0;
    for (final dir in dirs) {
      final marker = File('${dir.path}/complete.json');
      if (!await marker.exists()) continue;
      try {
        final data = jsonDecode(await marker.readAsString()) as Map;
        final file = File('${dir.path}/${data['entry']}');
        var bytes = 0;
        await for (final item in dir.list()) {
          if (item is File) bytes += await item.length();
        }
        total += bytes;
        entries.add((dir: dir, file: file, bytes: bytes,
            used: (await file.stat()).modified));
      } catch (_) {}
    }
    entries.sort((a, b) => a.used.compareTo(b.used));
    for (final item in entries) {
      if (total <= maxCacheBytes) break;
      try {
        final marker = jsonDecode(await File(
          '${item.dir.path}/complete.json',
        ).readAsString()) as Map;
        final source = marker['url'];
        if (source == exclude || _inUse.containsKey(source) ||
            _downloads.containsKey(source)) continue;
        await item.dir.delete(recursive: true);
        total -= item.bytes;
      } catch (_) {}
    }
  }
}
