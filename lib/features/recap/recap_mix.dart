import '../../core/utils/artist_credits.dart';
import '../../data/repositories/recently_played_repository.dart';
import '../../models/song.dart';

/// Deterministic, bounded mixes built from this period, with no network work.
enum RecapMix { favorites, variety, deepCuts }

List<Song> buildRecapMix(ListeningRecap recap, RecapMix kind) {
  final seen = <String>{};
  final ranked = recap.topSongs.where((s) => seen.add(s.song.id)).toList();
  if (kind == RecapMix.deepCuts) {
    ranked.sort((a, b) {
      final plays = a.plays.compareTo(b.plays);
      return plays != 0 ? plays : b.lastPlayedAt.compareTo(a.lastPlayedAt);
    });
  }
  if (kind != RecapMix.variety) {
    return ranked.take(50).map((s) => s.song).toList(growable: false);
  }
  final groups = <String, List<Song>>{};
  for (final entry in ranked) {
    final key = primaryArtistCredit(entry.song.artist).trim().toLowerCase();
    (groups[key] ??= []).add(entry.song);
  }
  final result = <Song>[];
  // Round-robin one song per lead artist, preserving rank within each artist.
  for (var round = 0; result.length < ranked.length && result.length < 50; round++) {
    for (final songs in groups.values) {
      if (round < songs.length && result.length < 50) result.add(songs[round]);
    }
  }
  return result;
}

/// Unprojected listening journal entries have metadata but no audio handle.
/// Let the normal queue resolver find a source only after a playback action.
Song recapPlayableSong(Song song) =>
    song.id.startsWith('history:') && (song.filePath?.isEmpty ?? true)
    ? song.copyWith(sourcePackage: Song.pendingSourcePackage)
    : song;
