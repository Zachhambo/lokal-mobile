import 'package:flick/features/search/download_activity.dart';
import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/features/konnekted/konnekted_destination.dart';
import 'package:flick/features/konnekted/konnekted_home.dart';
import 'package:flick/features/konnekted/konnekted_library.dart';
import 'package:flick/features/konnekted/library/lokal_library_kit.dart';
import 'package:flick/features/konnekted/library/lokal_library_pages.dart';
import 'package:flick/features/konnekted/library/lokal_song_browser.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Song _song(String id, {Duration duration = const Duration(minutes: 3)}) => Song(
  id: id,
  title: 'Track $id',
  artist: 'Artist $id',
  duration: duration,
  fileType: 'FLAC',
);

void main() {
  test('Full Library browser is labelled Library and shows total duration', () {
    final page = lokalLibraryPage('songs') as LokalSongListPage;
    expect(page.title, 'Library');
    expect(page.showTotalDuration, isTrue);
    expect(page.preferencesKey, 'lokal.library.songs.song_browser_view.v1');
    final added = lokalLibraryPage('recentlyAdded') as LokalSongListPage;
    expect(added.title, 'Library');
    expect(added.showTotalDuration, isTrue);
    // The You tab's history navigation retains a distinct, truthful page.
    final history = lokalLibraryPage('recentlyPlayed') as LokalSongListPage;
    expect(history.title, 'Recently played');
  });

  testWidgets(
    'Recently Added becomes Library; Recently Played remains intact',
    (tester) async {
      tester.view
        ..physicalSize = const Size(393, 852)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final opened = <KonnektedDestination>[];
      final library = [
        _song('library', duration: const Duration(minutes: 65)),
        _song('library2', duration: const Duration(minutes: 5)),
      ];
      final history = [_song('r1'), _song('r2')];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            konnektedLibraryProvider.overrideWithValue(AsyncData(library)),
            konnektedRecentSongsProvider.overrideWith(
              (ref) => Stream.value(history),
            ),
          ],
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
            home: Scaffold(body: KonnektedLibrary(onNavigate: opened.add)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The More group no longer includes a history row.
      await tester.scrollUntilVisible(
        find.text('More'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(LokalNavRow), findsNWidgets(8));
      expect(find.text('Spotify'), findsOneWidget);
      expect(find.text('Youtube Music'), findsOneWidget);
      expect(find.byIcon(Icons.history_rounded), findsNothing);
      expect(find.text('Songs'), findsOneWidget);
      expect(find.text('Downloads'), findsOneWidget);

      final libraryShelf = find.byWidgetPredicate(
        (widget) => widget is KonnektedSongShelf && widget.title == 'Library',
      );
      await tester.scrollUntilVisible(
        libraryShelf,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: libraryShelf, matching: find.text('Library')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: libraryShelf, matching: find.text('Track library')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: libraryShelf,
          matching: find.text('Track library2'),
        ),
        findsOneWidget,
      );
      final widget = tester.widget<KonnektedSongShelf>(libraryShelf);
      expect(widget.showTotalDuration, isTrue);
      expect(widget.summarySongs?.value?.length, library.length);
      expect(
        find.descendant(of: libraryShelf, matching: find.text('Track r1')),
        findsNothing,
      );
      expect(find.text('2 songs · 1 hr 10 min'), findsOneWidget);
      final horizontalList = tester.widget<ListView>(
        find.descendant(of: libraryShelf, matching: find.byType(ListView)),
      );
      expect(horizontalList.scrollDirection, Axis.horizontal);

      // The shell has already reserved the dock height in MediaQuery. The
      // Library must not add the old 150px spacer on top of that clearance.
      await tester.scrollUntilVisible(
        find.byKey(const Key('library-bottom-clearance')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      final clearance = find.byKey(const Key('library-bottom-clearance'));
      final bottomInsets = MediaQuery.paddingOf(tester.element(clearance))
          .bottom;
      expect(tester.widget<SizedBox>(clearance).height, 12 + bottomInsets);

      await tester.scrollUntilVisible(
        libraryShelf,
        -180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: libraryShelf, matching: find.text('See all')),
      );
      expect(opened, [KonnektedDestination.recentlyAdded]);
      final playedShelf = find.byWidgetPredicate(
        (widget) =>
            widget is KonnektedSongShelf && widget.title == 'Recently played',
      );
      await tester.scrollUntilVisible(
        playedShelf,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final playedWidget = tester.widget<KonnektedSongShelf>(playedShelf);
      expect(playedWidget.showTotalDuration, isFalse);
      expect(playedWidget.summarySongs, isNull);
      expect(
        find.descendant(of: playedShelf, matching: find.text('Track r1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: playedShelf, matching: find.text('Track r2')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: playedShelf, matching: find.text('See all')),
      );
      expect(opened, [
        KonnektedDestination.recentlyAdded,
        KonnektedDestination.recentlyPlayed,
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  test('Downloads includes exact chosen-folder saves and legacy files only', () async {
    final downloaded = _song('saved').copyWith(
      filePath: '/chosen/Artist/Album/track.flac',
    );
    final legacy = _song('legacy').copyWith(
      filePath: '/Music/Lokal Downloads/Artist/track.flac',
    );
    final other = _song('other').copyWith(filePath: '/chosen/other.flac');
    final container = ProviderContainer(overrides: [
      konnektedLibraryProvider.overrideWithValue(AsyncData([downloaded, legacy, other])),
      downloadActivityProvider.overrideWith((ref) => Stream.value([
        DownloadActivityEntry(
          id: 'saved', title: downloaded.title, artist: downloaded.artist,
          started: DateTime(2026), state: 'Completed', path: downloaded.filePath,
        ),
      ])),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(downloadActivityProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(downloadActivityProvider.future);
    expect(container.read(lokalDownloadsProvider).value, [downloaded, legacy]);
  });

  testWidgets('Downloads displays live percentages and completed history', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        konnektedLibraryProvider.overrideWithValue(const AsyncData(<Song>[])),
        downloadActivityProvider.overrideWith((ref) => Stream.value([
          DownloadActivityEntry(
            id: 'active', title: 'Downloading track', artist: 'Artist',
            started: DateTime(2026), progress: .42,
          ),
          DownloadActivityEntry(
            id: 'complete', title: 'Saved track', artist: 'Artist',
            started: DateTime(2026), state: 'Completed',
            path: '/chosen/track.flac',
          ),
        ])),
      ],
      child: MaterialApp(
        theme: LokalTheme.build(LokalTokens.resolve(LokalThemeId.dark)),
        home: lokalLibraryPage('downloads'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Downloading track'), findsOneWidget);
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.text('Saved track'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    ).value, .42);
    expect(tester.takeException(), isNull);
  });
}
