import 'package:flick/data/repositories/recently_played_repository.dart';
import 'package:flick/features/recap/recap_mix.dart';
import 'package:flick/models/song.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ListeningRecap> fixture() async {
  final now = DateTime(2026, 11, 16, 12);
  final entries = <RecentlyPlayedEntry>[];
  for (var i = 0; i < 130; i++) {
    final song = Song(id: '$i', title: 'Song $i',
      artist: 'Artist ${i % 40}', album: 'Album ${i % 40}',
      duration: const Duration(minutes: 3), fileType: 'FLAC');
    for (var play = 0; play < 131 - i; play++) {
      entries.add(RecentlyPlayedEntry(song: song, playedAt: now));
    }
  }
  final recaps = await aggregateListeningRecapsFromEntries(
    entries: entries,
    ranges: {ListeningRecapPeriod.daily: ListeningRecapPeriod.daily.rangeFor(now)},
    unknownArtist: 'Unknown', unknownAlbum: 'Unknown', forceWorker: true);
  return recaps[ListeningRecapPeriod.daily]!;
}

void main() {
  test('bounded rankings keep full totals and useful mix depth', () async {
    final recap = await fixture();
    expect(recap.uniqueSongs, 130);
    expect(recap.topSongs.length, 100);
    expect(recap.topArtists.length, 30);
    expect(recap.topAlbums.length, 30);
    final favorites = buildRecapMix(recap, RecapMix.favorites);
    expect(favorites.length, 50);
    expect(favorites.first.id, '0');
    final deep = buildRecapMix(recap, RecapMix.deepCuts);
    expect(deep.first.id, '99');
    final variety = buildRecapMix(recap, RecapMix.variety);
    expect(variety.take(40).map((s) => s.artist).toSet().length, 40);
    expect(variety.map((s) => s.id).toSet().length, variety.length);
    expect(buildRecapMix(recap, RecapMix.variety).map((s) => s.id),
      variety.map((s) => s.id));
    expect(recap.topSongs.first.song.id, '0');
  });

  test('empty history has empty mixes and journal metadata becomes resolvable', () {
    final recap = ListeningRecap.empty(ListeningRecapPeriod.daily,
      ListeningRecapPeriod.daily.rangeFor(DateTime(2026, 11, 16)));
    for (final kind in RecapMix.values) {
      expect(buildRecapMix(recap, kind), isEmpty);
    }
    const journal = Song(id: 'history:abc', title: 'Track', artist: 'Artist',
      duration: Duration(minutes: 3), fileType: 'history');
    expect(recapPlayableSong(journal).isPending, isTrue);
    expect(journal.isPending, isFalse);
    final local = journal.copyWith(id: '1', filePath: '/music/song.flac');
    expect(identical(recapPlayableSong(local), local), isTrue);
  });
}
