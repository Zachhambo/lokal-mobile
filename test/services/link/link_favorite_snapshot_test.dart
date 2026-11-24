import 'package:flick/models/song.dart';
import 'package:flick/services/link/link_favorite_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const online = {
    'id': 'discovery:sample',
    'title': 'Streamed track',
    'artist': 'Artist One',
    'album': 'Album',
    'albumArtist': 'Various Artists',
    'durationMs': 183500,
    'isExternal': true,
    'filePath': 'lokal-morneye-live://signed/session?token=private',
    'albumArt': 'https://cdn.example.org/artwork.jpg',
    'remoteId': 'yt:AbCdEfGhI12',
  };

  test('online-only favorite has a portable desktop like identity', () {
    final wire = linkFavoriteSnapshotWire(online)!;
    expect(wire['track_key'], 'artist one|streamed track|184');
    expect(wire['duration'], 183.5);
    expect(wire['album_artist'], 'Various Artists');
    expect(wire['source_ref'], 'yt:AbCdEfGhI12');
    expect(wire['online_ref'], isTrue);
    expect(wire['artwork_url'], 'https://cdn.example.org/artwork.jpg');
    expect(wire.toString(), isNot(contains('signed/session')));
    expect(wire.toString(), isNot(contains('private')));
  });

  test('never export a signed artwork URL or an unvalidated source ID', () {
    final wire = linkFavoriteSnapshotWire({
      ...online,
      'albumArt': 'https://cdn.example.org/cover.jpg?token=secret',
      'remoteId': 'https://stream.example.org/audio?token=secret',
    })!;
    expect(wire, isNot(contains('artwork_url')));
    expect(wire, isNot(contains('online_ref')));
    expect(wire, isNot(contains('source_ref')));
  });

  test('reject snapshots without sufficient track identity', () {
    expect(linkFavoriteSnapshotWire({'title': 'No artist'}), isNull);
    expect(linkFavoriteSnapshotWire({...online, 'durationMs': -1}), isNull);
    expect(linkFavoriteSnapshotWire({...online, 'durationMs': '183500'}), isNull);
    expect(linkFavoriteSnapshotWire({...online, 'artist': ''}), isNull);
  });

  test('use local track alias in preference to saved online metadata', () async {
    const local = Song(
      id: '7',
      title: 'Local song',
      artist: 'Artist',
      duration: Duration(minutes: 2),
      fileType: 'FLAC',
      isExternal: false,
    );
    final actual = await linkFavoriteWire(
      local.id,
      library: {local.id: local},
      snapshots: {local.id: online},
      trackKeyFor: (song) async => 'desktop-linked-identity',
      songWire: (song) => {'title': song.title, 'track_key': 'local'},
    );
    expect(actual?['track_key'], 'desktop-linked-identity');
    expect(actual?['title'], 'Local song');
    final onlyOnline = await linkFavoriteWire(
      'discovery:sample',
      library: {},
      snapshots: {'discovery:sample': online},
      trackKeyFor: (_) async => throw StateError('No local song'),
      songWire: (_) => throw StateError('No local song'),
    );
    expect(onlyOnline?['track_key'], 'artist one|streamed track|184');
  });

  test('one-time backfill preserves existing local likes and pending unlikes',
      () {
    final baseline = linkFavoriteBaselineAfterUpgrade(
      {'online', 'local', 'old-unlike'},
      likedIds: {'online', 'local'},
      catalogIds: {'local'},
      migrate: true,
    );
    expect(baseline, {'local', 'old-unlike'});
    expect(
      linkFavoriteBaselineAfterUpgrade(
        {'online', 'local'},
        likedIds: {'online', 'local'},
        catalogIds: {'local'},
        migrate: false,
      ),
      {'online', 'local'},
    );
  });
}
