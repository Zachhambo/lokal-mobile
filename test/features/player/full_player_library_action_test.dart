import 'dart:async';
import 'dart:io';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/providers/songs_provider.dart';

import 'package:flick/features/player/widgets/full_player_library_action.dart';
import 'package:flick/features/search/online_song_save.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const online = Song(
  id: 'online:one', title: 'Song', artist: 'Artist', album: 'Album',
  fileType: 'FLAC', duration: Duration(minutes: 3), isExternal: true,
);

class _Repository extends Fake implements SongRepository {
  final List<Song> songs;
  _Repository(this.songs);
  @override
  Future<Song?> getSongById(String id) async =>
      songs.where((song) => song.id == id).firstOrNull;
  @override
  Future<Song?> getSongByFilePath(String path) async =>
      songs.where((song) => song.filePath == path).firstOrNull;
  @override
  Future<List<Song>> getHistoryMatchCandidates(String title) async => songs;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OnlineSongSaveRegistry.instance.clear();
  });
  tearDown(() => OnlineSongSaveRegistry.instance.clear());

  test('local copy matches online identity, cache and desktop catalogue do not', () {
    final local = online.copyWith(
      id: '1', isExternal: false, filePath: '/Music/song.flac',
    );
    expect(fullPlayerLibraryMatch(online, local), isTrue);
    expect(fullPlayerLibraryMatch(online, online.copyWith(filePath: '/cache/song.flac')), isFalse);
    expect(fullPlayerLibraryMatch(online, local.copyWith(sourceType: 'lokal')), isFalse);
    expect(fullPlayerLibraryMatch(online, local.copyWith(filePath: 'https://host/song.flac')), isFalse);
    expect(fullPlayerLibraryMatch(online, local.copyWith(title: 'Song (Live)')), isFalse);
    expect(fullPlayerLibraryMatch(online, local.copyWith(album: 'Live Album')), isFalse);
    expect(fullPlayerLibraryMatch(online, local.copyWith(duration: const Duration(minutes: 4))), isFalse);
  });

  test('membership requires a persistent local file, not a cache or missing file', () async {
    final directory = await Directory.systemTemp.createTemp('player_library');
    final file = await File('${directory.path}/song.flac').writeAsBytes([1]);
    final local = online.copyWith(id: '1', isExternal: false, filePath: file.path);
    final repository = _Repository([local]);
    final container = ProviderContainer(overrides: [
      songRepositoryProvider.overrideWithValue(repository),
      libraryChangeRevisionProvider.overrideWith((ref) => const Stream<int>.empty()),
    ]);
    final subscription = container.listen(fullPlayerInLibraryProvider(online), (_, __) {});
    try {
      expect(await container.read(fullPlayerInLibraryProvider(online).future), isTrue);
      await file.delete();
      container.invalidate(fullPlayerInLibraryProvider(online));
      expect(await container.read(fullPlayerInLibraryProvider(online).future), isFalse);
      // A cache file exists, but it is not a repository entry.
      await file.writeAsBytes([1]);
      repository.songs.clear();
      container.invalidate(fullPlayerInLibraryProvider(online));
      expect(await container.read(fullPlayerInLibraryProvider(online).future), isFalse);
    } finally {
      subscription.close();
      container.dispose();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('download becomes a neutral check and refuses duplicate taps', (tester) async {
    var saved = false, writes = 0;
    final download = Completer<void>();
    OnlineSongSaveRegistry.instance.register(online, () async => online);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        fullPlayerInLibraryProvider.overrideWith((ref, song) async => saved),
        fullPlayerDownloadProvider.overrideWithValue((song) async {
          writes++;
          await download.future;
          saved = true;
        }),
      ],
      child: MaterialApp(home: Scaffold(body: FullPlayerLibraryAction(
        song: online,
        builder: (icon, label, onTap) => IconButton(
          tooltip: label, onPressed: onTap,
          icon: Icon(icon, color: Colors.white),
        ),
      ))),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.byIcon(Icons.downloading_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.downloading_rounded));
    expect(writes, 1);
    download.complete();
    await tester.pumpAndSettle();
    final check = find.byIcon(Icons.check_rounded);
    expect(check, findsOneWidget);
    expect(tester.widget<Icon>(check).color, Colors.white);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
  });
}
