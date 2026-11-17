import '../../models/song.dart';
import 'link_protocol.dart';

/// Build a portable Lokal Sync identity for a favorite whose playable entry
/// only exists in SharedPreferences (for example an online-only favorite).
/// Never export source URLs, credentials or phone-local file paths.
Map<String, dynamic>? linkFavoriteSnapshotWire(Object? raw) {
  if (raw is! Map) return null;
  final title = raw['title'];
  final artist = raw['artist'];
  if (title is! String ||
      artist is! String ||
      title.trim().isEmpty ||
      artist.trim().isEmpty) {
    return null;
  }
  final rawDuration = raw['durationMs'];
  if (rawDuration is! num ||
      !rawDuration.isFinite ||
      rawDuration < 0 ||
      rawDuration > const Duration(hours: 24).inMilliseconds) {
    return null;
  }
  final duration = Duration(milliseconds: rawDuration.round());
  final key = linkTrackKey(artist, title, duration);
  final album = raw['album'];
  final albumArtist = raw['albumArtist'];
  final cover = raw['albumArt'];
  final remoteId = raw['remoteId'];
  final source = remoteId is String &&
          (RegExp(r'^yt:[A-Za-z0-9_-]{11}$').hasMatch(remoteId) ||
           RegExp(r'^sc:[0-9]+$').hasMatch(remoteId))
      ? remoteId
      : null;
  return {
    'id': raw['id'] is String ? raw['id'] : '',
    'title': title,
    'artist': artist,
    'album': album is String ? album : '',
    'album_artist': albumArtist is String ? albumArtist : '',
    'duration': duration.inMilliseconds / 1000,
    'track_key': key,
    if (source != null) 'online_ref': true,
    if (source != null) 'source_ref': source,
    if (cover is String && cover.startsWith('https://') && !cover.contains('?'))
      'artwork_url': cover,
  };
}

/// Prefer the current library record and its stable desktop alias. Saved
/// metadata is an intentionally narrow fallback for online-only favorites.
Future<Map<String, dynamic>?> linkFavoriteWire(
  String id, {
  required Map<String, Song> library,
  required Map<String, dynamic> snapshots,
  required Future<String> Function(Song) trackKeyFor,
  required Map<String, dynamic> Function(Song) songWire,
}) async {
  final song = library[id];
  if (song != null) {
    return {...songWire(song), 'track_key': await trackKeyFor(song)};
  }
  return linkFavoriteSnapshotWire(snapshots[id]);
}
