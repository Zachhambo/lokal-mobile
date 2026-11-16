import 'package:flick/core/theme/lokal_tokens.dart';
import 'package:flick/features/search/download_activity.dart';
import 'package:flick/l10n/l10n.dart';

import 'dart:async';

import 'package:flick/features/konnekted/konnekted_data.dart';
import 'package:flick/providers/favorites_provider.dart';
import 'package:flick/features/search/library_download.dart';
import 'package:flick/models/song.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lokal_albums_artists.dart';
import 'lokal_genres.dart';
import 'lokal_library_kit.dart';
import 'lokal_playlists.dart';
import 'lokal_song_browser.dart';

/// Live activity is separate from library state: byte updates do not rescan songs.
final downloadActivityProvider = StreamProvider<List<DownloadActivityEntry>>((ref) {
  final activity = DownloadActivity.instance;
  final events = StreamController<List<DownloadActivityEntry>>();
  void emit() => events.add(activity.entries);
  activity.addListener(emit);
  emit();
  unawaited(activity.load());
  ref.onDispose(() {
    activity.removeListener(emit);
    unawaited(events.close());
  });
  return events.stream;
});

/// Exact saved destinations, plus the legacy fallback folder.
final lokalDownloadsProvider = Provider<AsyncValue<List<Song>>>((ref) {
  final savedPaths = ref.watch(downloadActivityProvider.select(
    (value) => value.value
        ?.where((entry) => entry.path != null)
        .map((entry) => entry.path!)
        .join('\n') ?? '',
  )).split('\n').where((path) => path.isNotEmpty).toSet();
  final folder = RegExp(
    '[/\\\\]${RegExp.escape(LibraryDownloader.folderName)}[/\\\\]',
  );
  return ref
      .watch(konnektedLibraryProvider)
      .whenData(
        (songs) => [
          for (final song in songs)
            if (savedPaths.contains(song.filePath) ||
                folder.hasMatch(song.filePath ?? '')) song,
        ],
      );
});

/// Your history, newest first, each song once.
final lokalRecentlyPlayedProvider = StreamProvider.autoDispose<List<Song>>((
  ref,
) {
  final repository = ref.watch(konnektedHistoryRepositoryProvider);
  final changes = StreamController<void>();
  final subscription = repository.watchHistory().listen(
    changes.add,
    onError: changes.addError,
  );
  changes.add(null);
  ref.onDispose(() {
    unawaited(subscription.cancel());
    unawaited(changes.close());
  });
  return changes.stream.asyncMap((_) async {
    final entries = await repository.getRecentHistory(limit: 300);
    final seen = <String>{};
    return [
      for (final entry in entries)
        if (seen.add(entry.song.id)) entry.song,
    ];
  });
});

/// The Library page for a destination name, or null when it isn't one.
Widget? lokalLibraryPage(String name) => switch (name) {
  'songs' => LokalSongListPage(
    title: lokalText('Library'),
    showTotalDuration: true,
    preferencesKey: 'lokal.library.songs.song_browser_view.v1',
    source: (ref) => ref.watch(konnektedLibraryProvider),
  ),
  'favorites' => LokalSongListPage(
    title: lokalText('Liked'),
    downloadMissing: true,
    source: (ref) => ref.watch(konnektedFavoritesProvider),
    // "Recently added" means added to Likes here, not imported into Library.
    initialSort: LokalSongSort.recentlyAdded,
    recentlyAddedRanks: (ref) =>
        ref.watch(favoritesProvider).value?.likedRanks ?? const <String, int>{},
    preferencesKey: 'lokal.likes.song_browser_view.v1',
    emptyIcon: Icons.favorite_border_rounded,
    emptyTitle: 'No liked songs yet',
    emptyMessage: 'Tap the heart on any song and it shows up here.',
  ),
  'downloads' => const LokalDownloadsPage(),
  'recentlyPlayed' => LokalSongListPage(
    title: lokalText('Recently played'),
    showTotalDuration: true,
    preferencesKey: 'lokal.library.recently_played.song_browser_view.v1',
    source: (ref) => ref.watch(lokalRecentlyPlayedProvider),
    initialSort: LokalSongSort.original,
    originalLabel: 'Most recent',
    emptyIcon: Icons.history_rounded,
    emptyTitle: 'Nothing played yet',
    emptyMessage: 'Songs you play show up here.',
  ),
  'recentlyAdded' => LokalSongListPage(
    title: lokalText('Library'),
    showTotalDuration: true,
    preferencesKey: 'lokal.library.recently_added.song_browser_view.v1',
    source: (ref) => ref.watch(konnektedLibraryProvider),
  ),
  'albums' => const LokalAlbumsPage(),
  'artists' => const LokalArtistsPage(),
  'genres' => const LokalGenresPage(),
  'playlists' => const LokalPlaylistsPage(),
  _ => null,
};

class LokalDownloadsPage extends ConsumerStatefulWidget {
  const LokalDownloadsPage({super.key});

  @override
  ConsumerState<LokalDownloadsPage> createState() => _LokalDownloadsPageState();
}

class _LokalDownloadsPageState extends ConsumerState<LokalDownloadsPage> {
  bool _songs = false;

  @override
  Widget build(BuildContext context) {
    final activity = ref.watch(downloadActivityProvider);
    final downloads = ref.watch(lokalDownloadsProvider);
    final entries = activity.value ?? const <DownloadActivityEntry>[];
    final active = entries.where((entry) => entry.active).toList();
    final history = entries.where((entry) => !entry.active).toList();
    final songs = downloads.value ?? const <Song>[];
    final byPath = {for (final song in songs) song.filePath: song};
    final recorded = entries.map((entry) => entry.path).toSet();
    final legacy = songs.where((song) => !recorded.contains(song.filePath)).toList();
    return LokalLibraryPage(
      title: lokalText('Downloads'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(lokalText('Activity')),
                  selected: !_songs,
                  onSelected: (_) => setState(() => _songs = false),
                ),
                ChoiceChip(
                  label: Text(lokalText('Songs')),
                  selected: _songs,
                  onSelected: (_) => setState(() => _songs = true),
                ),
              ],
            ),
          ),
        ),
        if (_songs && songs.isNotEmpty)
          LokalSongBrowser(
            songs: songs,
            preferencesKey: 'lokal.library.downloads.song_browser_view.v1',
          )
        else if (_songs && downloads.isLoading)
          const SliverToBoxAdapter(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_songs && downloads.hasError)
          SliverToBoxAdapter(
            child: LokalEmptyState(
              icon: Icons.error_outline_rounded,
              title: lokalText('Couldn’t load these songs'),
              message: lokalText('Try again in a moment.'),
              actionLabel: 'Try again',
              onAction: () => ref.invalidate(konnektedLibraryProvider),
            ),
          )
        else if (_songs)
          SliverToBoxAdapter(child: _empty())
        else ...[
          if (active.isNotEmpty) ...[
            SliverToBoxAdapter(child: LokalSectionTitle(title: lokalText('In progress'))),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _activityTile(active[index], null, songs),
                childCount: active.length,
              ),
            ),
          ],
          if (history.isNotEmpty || legacy.isNotEmpty)
            SliverToBoxAdapter(child: LokalSectionTitle(title: lokalText('History'))),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final entry = history[index];
                return _activityTile(entry, byPath[entry.path], songs);
              },
              childCount: history.length,
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final song = legacy[index];
                return ListTile(
                  leading: Icon(Icons.download_done_rounded, color: context.lokal.accent),
                  title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(song.artist),
                  onTap: () => lokalPlay(context, ref, songs, start: song),
                );
              },
              childCount: legacy.length,
            ),
          ),
          if (entries.isEmpty && legacy.isEmpty)
            SliverToBoxAdapter(
              child: activity.isLoading || downloads.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _empty(),
            ),
        ],
      ],
    );
  }

  Widget _empty() => LokalEmptyState(
    icon: Icons.download_rounded,
    title: lokalText('No downloads yet'),
    message: lokalText('Downloads from Search, playlists and albums appear here.'),
  );

  Widget _activityTile(DownloadActivityEntry entry, Song? song, List<Song> songs) {
    final date = MaterialLocalizations.of(context).formatShortDate(entry.started.toLocal());
    final percent = entry.progress == null ? '' : ' · ${(entry.progress! * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              entry.active ? Icons.downloading_rounded :
                  entry.state == 'Completed' ? Icons.download_done_rounded :
                  Icons.info_outline_rounded,
              color: context.lokal.accent,
            ),
            title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${entry.artist}\n${lokalText(entry.state)}$percent · $date'),
            isThreeLine: true,
            trailing: song == null ? null : const Icon(Icons.play_arrow_rounded),
            onTap: song == null ? null : () => lokalPlay(context, ref, songs, start: song),
          ),
          if (entry.active)
            Padding(
              padding: const EdgeInsets.fromLTRB(64, 0, 16, 8),
              child: LinearProgressIndicator(
                value: entry.progress,
                semanticsLabel: entry.title,
              ),
            ),
        ],
      ),
    );
  }
}
