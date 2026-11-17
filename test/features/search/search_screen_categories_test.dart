import 'package:flick/core/theme/lokal_theme.dart';
import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/data/repositories/song_repository.dart';
import 'package:flick/features/search/models/global_search_results.dart';
import 'package:flick/features/search/models/search_category.dart';
import 'package:flick/features/search/providers/global_search_provider.dart';
import 'package:flick/features/search/providers/search_filter_provider.dart';
import 'package:flick/features/search/screens/search_screen.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/songs_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _song = Song(
  id: 'song-1',
  title: 'Search song',
  artist: 'Search artist',
  album: 'Search album',
  duration: Duration(minutes: 3),
  fileType: 'FLAC',
);

const _album = AlbumGroup(
  key: 'search-album',
  albumName: 'Search album',
  albumArtist: 'Search artist',
  songs: [_song],
);

String _categoryLabel(SearchCategory category) => switch (category) {
  SearchCategory.songs => 'Songs',
  SearchCategory.artists => 'Artists',
  SearchCategory.albums => 'Albums',
  SearchCategory.folders => 'Folders',
  _ => throw StateError('Unexpected search category: $category'),
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final category in [
    SearchCategory.songs,
    SearchCategory.artists,
    SearchCategory.albums,
    SearchCategory.folders,
  ]) {
    final label = _categoryLabel(category);
    testWidgets('auto-selects the only result category: $category', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          globalSearchResultsProvider.overrideWith((ref, query) async {
            return switch (category) {
              SearchCategory.songs => GlobalSearchResults(
                query: query,
                songs: const [_song],
              ),
              SearchCategory.artists => GlobalSearchResults(
                query: query,
                artists: const [
                  MapEntry('Search artist', [_song]),
                ],
              ),
              SearchCategory.albums => GlobalSearchResults(
                query: query,
                albums: const [_album],
              ),
              SearchCategory.folders => GlobalSearchResults(
                query: query,
                folders: const [
                  FolderGroup(
                    name: 'Search folder',
                    key: 'search-folder',
                    songs: [_song],
                  ),
                ],
              ),
              _ => throw StateError('Unexpected search category: $category'),
            };
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
            home: const SearchScreen(),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Search');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, label),
      );
      expect(chip.selected, isTrue);
      expect(container.read(searchFilterProvider), {category});
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shows compact sections for up to five mixed results', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        globalSearchResultsProvider.overrideWith((ref, query) async {
          return GlobalSearchResults(
            query: query,
            songs: const [_song, _song],
            artists: const [
              MapEntry('Search artist', [_song]),
            ],
            albums: const [_album],
            folders: const [
              FolderGroup(
                name: 'Search folder',
                key: 'search-folder',
                songs: [_song],
              ),
            ],
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: LokalTheme.build(LokalTokens.themes[LokalThemeId.dark]!),
          home: const SearchScreen(),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Search');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('Search song'), findsNWidgets(2));
    expect(find.text('Search artist'), findsOneWidget);
    expect(find.text('Search album'), findsOneWidget);
    expect(find.text('Search folder'), findsOneWidget);
    for (final category in [
      SearchCategory.songs,
      SearchCategory.artists,
      SearchCategory.albums,
      SearchCategory.folders,
    ]) {
      expect(
        tester
            .widget<ChoiceChip>(
              find.widgetWithText(ChoiceChip, _categoryLabel(category)),
            )
            .selected,
        isTrue,
      );
    }
    final compactSongsHeading = tester.widget<Text>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.text('Songs'),
          )
          .first,
    );
    expect(compactSongsHeading.style?.fontSize, 11);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Songs'));
    await tester.pumpAndSettle();
    expect(find.text('Search artist'), findsNothing);
    expect(find.text('Search album'), findsNothing);
    expect(find.text('Search folder'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
