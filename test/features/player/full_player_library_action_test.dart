import 'dart:async';

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
