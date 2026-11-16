import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/lokal_tokens.dart';
import '../../../core/utils/artist_credits.dart';
import '../../../data/repositories/recently_played_repository.dart';
import '../../../features/konnekted/library/lokal_library_kit.dart';
import '../../../features/konnekted/library/lokal_navigation.dart';
import '../../../features/konnekted/library/lokal_song_browser.dart';
import '../../../l10n/l10n.dart';
import '../../../models/playlist.dart';
import '../../../models/song.dart';
import '../../../providers/playlist_provider.dart';
import '../../../widgets/lokal/lokal_toast.dart';
import '../recap_mix.dart';
import 'replay_artwork.dart';
import 'replay_card_surface.dart';
import 'replay_style.dart';

enum RecapView { overview, songs, artists, albums, explore }

String _label(RecapView view) => lokalText(switch (view) {
  RecapView.overview => 'Overview',
  RecapView.songs => 'Songs',
  RecapView.artists => 'Artists',
  RecapView.albums => 'Albums',
  RecapView.explore => 'Explore',
});

String _mixName(RecapMix mix) => lokalText(switch (mix) {
  RecapMix.favorites => 'Your heavy rotation',
  RecapMix.variety => 'A wider rotation',
  RecapMix.deepCuts => 'The other side',
});

String _mixDetail(RecapMix mix) => lokalText(switch (mix) {
  RecapMix.favorites => 'Your most played, in order.',
  RecapMix.variety => 'One track per artist, then another round.',
  RecapMix.deepCuts => 'Less repeated tracks from this period.',
});

/// A compact landing view; deeper rankings are one tap away instead of
/// consecutive full-height posters. Only the selected view is laid out.
class RecapDashboard extends ConsumerStatefulWidget {
  const RecapDashboard({
    super.key,
    required this.recap,
    required this.failed,
    required this.onRetry,
    required this.onExport,
  });

  final ListeningRecap recap;
  final bool failed;
  final VoidCallback onRetry;
  final VoidCallback onExport;

  @override
  ConsumerState<RecapDashboard> createState() => _RecapDashboardState();
}

class _RecapDashboardState extends ConsumerState<RecapDashboard> {
  RecapView _view = RecapView.overview;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _select(RecapView value) {
    if (_view == value) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _view = value);
  }

  List<Song> get _songs => buildRecapMix(widget.recap, RecapMix.favorites);

  void _play({Song? start}) {
    final songs = widget.recap.topSongs.map((entry) => recapPlayableSong(entry.song)).toList(growable: false);
    unawaited(lokalPlay(context, ref, songs,
      start: start == null ? null : recapPlayableSong(start)));
  }

  void _openMix(RecapMix mix) {
    final recap = widget.recap;
    unawaited(pushLokal(context, RecapMixPage(
      title: _mixName(mix),
      subtitle: ReplayStyle.range(recap),
      detail: _mixDetail(mix),
      songs: buildRecapMix(recap, mix).map(recapPlayableSong).toList(growable: false),
    )));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Column(children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Row(children: [
          for (final view in RecapView.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                key: ValueKey('recap-tab-${view.name}'),
                label: Text(_label(view)),
                selected: view == _view,
                showCheckmark: false,
                selectedColor: t.accentSoft,
                labelStyle: TextStyle(
                  color: view == _view ? t.text : t.muted,
                  fontWeight: view == _view ? FontWeight.w700 : FontWeight.w500,
                ),
                onSelected: (_) => _select(view),
              ),
            ),
        ]),
      ),
      Expanded(child: LayoutBuilder(builder: (context, constraints) {
        final inset = constraints.maxWidth > 760
            ? (constraints.maxWidth - 728) / 2 : 16.0;
        return ListView(
          key: ValueKey('recap-view-${_view.name}'),
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(inset, 0, inset,
            32 + MediaQuery.paddingOf(context).bottom),
          children: [
            if (widget.failed)
              Row(children: [
                Expanded(child: Text(l10n.showingYourLastLoadedReplay,
                  style: TextStyle(color: t.muted))),
                TextButton(onPressed: widget.onRetry, child: Text(l10n.retry)),
              ]),
            ...switch (_view) {
              RecapView.overview => _overview(),
              RecapView.songs => _songRankings(),
              RecapView.artists => _artistRankings(),
              RecapView.albums => _albumRankings(),
              RecapView.explore => _explore(),
            },
          ],
        );
      })),
    ]);
  }

  List<Widget> _overview() {
    final recap = widget.recap;
    final t = context.lokal;
    return [
      _RecapHero(recap: recap, onPlay: _songs.isEmpty ? null : () => _play(),
        onMix: _songs.isEmpty ? null : () => _openMix(RecapMix.favorites)),
      const SizedBox(height: 10),
      _RecapMetrics(recap: recap),
      const SizedBox(height: 18),
      _heading(lokalText('The music that defined it')),
      if (recap.topSong case final song?)
        _RecapRank(
          rank: '01', title: song.song.title,
          subtitle: '${lokalText('Top song')} · ${ReplayStyle.plays(song.plays)}',
          path: song.song.albumArt, progress: 1,
          onTap: () => _play(start: song.song),
          trailing: Icons.play_arrow_rounded,
          onSubtitle: () => openLokalArtist(context, song: song.song),
          subtitleLabel: song.song.artist,
        ),
      if (recap.topArtist case final artist?)
        _RecapRank(
          rank: '01', title: artist.artist,
          subtitle: '${l10n.topArtist} · ${ReplayStyle.plays(artist.plays)}',
          path: _artistCover(artist.artist), progress: 1, circle: true,
          onTap: () => openLokalArtist(context, name: artist.artist),
        ),
      if (recap.topAlbum case final album?)
        _RecapRank(
          rank: '01', title: album.album,
          subtitle: '${l10n.topAlbum} · ${album.artist}',
          path: album.representativeSong.albumArt, progress: 1,
          onTap: () => openLokalAlbumForSong(context, album.representativeSong),
        ),
      const SizedBox(height: 12),
      _RecapSurface(child: Row(children: [
        Icon(Icons.hub_outlined, color: t.accent),
        const SizedBox(width: 12),
        Expanded(child: Text(lokalText(
          '{arg0} artists. {arg1} different songs.',
          args: {'arg0': '${recap.uniqueArtists}', 'arg1': '${recap.uniqueSongs}'}),
          style: TextStyle(color: t.text, fontWeight: FontWeight.w600))),
        IconButton(
          tooltip: lokalText('Explore your listening'),
          onPressed: () => _select(RecapView.explore),
          icon: Icon(Icons.arrow_forward_rounded, color: t.text),
        ),
      ])),
      const SizedBox(height: 12),
      TextButton.icon(onPressed: widget.onExport,
        icon: const Icon(Icons.ios_share_rounded),
        label: Text(l10n.saveCustomizeReplay)),
    ];
  }

  String? _artistCover(String name) {
    final key = name.trim().toLowerCase();
    for (final song in widget.recap.topSongs) {
      if (songArtistNames(song.song).any((n) => n.toLowerCase() == key) &&
          song.song.albumArt?.isNotEmpty == true) {
        return song.song.albumArt;
      }
    }
    return null;
  }

  List<Widget> _songRankings() {
    final recap = widget.recap;
    final max = recap.topSongs.firstOrNull?.plays ?? 1;
    return [
      _heading(l10n.topSongs2, detail: lokalText('Tap a track to play. Tap its artist to explore.')),
      _mixButton(RecapMix.favorites),
      const SizedBox(height: 8),
      for (final (index, entry) in recap.topSongs.indexed)
        _RecapRank(
          rank: '${index + 1}'.padLeft(2, '0'),
          title: entry.song.title, subtitle: ReplayStyle.plays(entry.plays),
          subtitleLabel: entry.song.artist,
          path: entry.song.albumArt, progress: max > 0 ? entry.plays / max : 0,
          onTap: () => _play(start: entry.song),
          trailing: Icons.play_arrow_rounded,
          onSubtitle: () => openLokalArtist(context, song: entry.song),
          onAlbum: entry.song.album?.isNotEmpty == true
              ? () => openLokalAlbumForSong(context, entry.song) : null,
        ),
    ];
  }

  List<Widget> _artistRankings() {
    final recap = widget.recap;
    final max = recap.topArtists.firstOrNull?.plays ?? 1;
    return [
      _heading(l10n.topArtists, detail: lokalText('Open any artist to keep exploring.')),
      for (final (index, entry) in recap.topArtists.indexed)
        _RecapRank(
          rank: '${index + 1}'.padLeft(2, '0'), title: entry.artist,
          subtitle: '${ReplayStyle.plays(entry.plays)} · ${l10n.songsCount(entry.uniqueSongs)}',
          path: _artistCover(entry.artist), circle: true,
          progress: max > 0 ? entry.plays / max : 0,
          onTap: () => openLokalArtist(context, name: entry.artist),
        ),
      _note(lokalText('Artist tiles use artwork from your played tracks.')),
    ];
  }

  List<Widget> _albumRankings() {
    final recap = widget.recap;
    final max = recap.topAlbums.firstOrNull?.plays ?? 1;
    return [
      _heading(lokalText('Top albums'), detail: lokalText('Your listening, one record at a time.')),
      for (final (index, entry) in recap.topAlbums.indexed)
        _RecapRank(
          rank: '${index + 1}'.padLeft(2, '0'), title: entry.album,
          subtitle: '${ReplayStyle.plays(entry.plays)} · ${l10n.songsCount(entry.uniqueSongs)}',
          subtitleLabel: entry.artist,
          path: entry.representativeSong.albumArt,
          progress: max > 0 ? entry.plays / max : 0,
          onTap: () => openLokalAlbumForSong(context, entry.representativeSong),
          onSubtitle: () => openLokalArtist(context, name: entry.artist),
        ),
    ];
  }

  List<Widget> _explore() {
    final recap = widget.recap;
    final t = context.lokal;
    // Extra plays after each song's first appearance, not a discovery score.
    final repeats = recap.totalPlays <= 0 ? 0.0 :
        ((recap.totalPlays - recap.uniqueSongs) / recap.totalPlays).clamp(0.0, 1.0);
    final leadShare = recap.totalPlays <= 0 ? 0.0 :
        ((recap.topArtist?.plays ?? 0) / recap.totalPlays).clamp(0.0, 1.0);
    return [
      _heading(lokalText('Your listening DNA'),
        detail: lokalText('Familiar favorites, different voices, and room to roam.')),
      _RecapSurface(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ratio(lokalText('Repeat listens'), repeats),
          const SizedBox(height: 18),
          _ratio(lokalText('Top artist share'), leadShare),
          const SizedBox(height: 14),
          Text(lokalText('Repeat listens count plays after each track’s first play in this period.'),
            style: TextStyle(color: t.muted, fontSize: 12, height: 1.5)),
        ],
      )),
      const SizedBox(height: 12),
      _RecapSurface(child: Wrap(spacing: 24, runSpacing: 16, children: [
        _fact(lokalText('Active days'), '${recap.activeDays}'),
        _fact(lokalText('Peak hour'), ReplayStyle.peakHour(recap.peakHour)),
        _fact(lokalText('Plays per song'), recap.uniqueSongs == 0 ? '—' :
          (recap.totalPlays / recap.uniqueSongs).toStringAsFixed(1)),
      ])),
      if (recap.topSongs.any((entry) => entry.song.genre?.trim().isNotEmpty == true)) ...[
        const SizedBox(height: 16),
        _heading(lokalText('Genres in rotation')),
        _RecapSurface(child: Wrap(spacing: 8, runSpacing: 8,
          children: _genreChips())),
        _note(lokalText('Genres come from tags on your top tracks. Missing tags are left out.')),
      ],
      _note(lokalText('Listening time uses tracked time where available; older plays use track duration.')),
      const SizedBox(height: 20),
      _heading(lokalText('Turn the numbers into music'),
        detail: lokalText('Preview a mix, play it, or keep it as a playlist.')),
      for (final mix in RecapMix.values) ...[
        _mixButton(mix), const SizedBox(height: 10),
      ],
      _note(lokalText('Mixes use up to 50 tracks from this period’s top 100 songs. The other side starts with the least repeated of those tracks.')),
      const SizedBox(height: 12),
      TextButton.icon(onPressed: widget.onExport,
        icon: const Icon(Icons.ios_share_rounded),
        label: Text(l10n.saveCustomizeReplay)),
    ];
  }

  List<Widget> _genreChips() {
    final counts = <String, int>{};
    final names = <String, String>{};
    for (final entry in widget.recap.topSongs) {
      final genre = entry.song.genre?.trim() ?? '';
      if (genre.isEmpty) continue;
      final key = genre.toLowerCase();
      names.putIfAbsent(key, () => genre);
      counts[key] = (counts[key] ?? 0) + entry.plays;
    }
    final genres = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return [
      for (final genre in genres.take(8))
        ActionChip(
          label: Text(names[genre]!),
          onPressed: () {
            final songs = widget.recap.topSongs.where((entry) =>
              entry.song.genre?.trim().toLowerCase() == genre)
              .map((entry) => recapPlayableSong(entry.song)).toList(growable: false);
            unawaited(pushLokal(context, RecapMixPage(
              title: names[genre]!, subtitle: ReplayStyle.range(widget.recap),
              detail: lokalText('Played tracks with this genre tag.'), songs: songs)));
          },
        ),
    ];
  }

  Widget _ratio(String label, double value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Expanded(child: Text(label, style: TextStyle(color: context.lokal.text))),
        Text('${(value * 100).round()}%', style: TextStyle(
          color: context.lokal.text, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 8),
      ClipRRect(borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(value: value, minHeight: 8,
          color: context.lokal.accent, backgroundColor: context.lokal.surface3)),
    ],
  );

  Widget _fact(String label, String value) => Column(
    mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: TextStyle(color: context.lokal.text,
        fontSize: 24, fontWeight: FontWeight.w700)),
      Text(label, style: TextStyle(color: context.lokal.muted, fontSize: 12)),
    ],
  );

  Widget _heading(String title, {String? detail}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(header: true, child: Text(title, style: TextStyle(
        color: context.lokal.text, fontSize: 22, height: 1.15,
        letterSpacing: -.7, fontWeight: FontWeight.w700))),
      if (detail != null) Padding(padding: const EdgeInsets.only(top: 6),
        child: Text(detail, style: TextStyle(color: context.lokal.muted, height: 1.4))),
    ]),
  );

  Widget _note(String text) => Padding(padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(text, style: TextStyle(color: context.lokal.muted, fontSize: 12, height: 1.5)));

  Widget _mixButton(RecapMix mix) => _RecapSurface(
    onTap: _songs.isEmpty ? null : () => _openMix(mix),
    child: Row(children: [
      Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [context.lokal.accentSoft, context.lokal.surface3]),
          borderRadius: BorderRadius.circular(14)),
        child: Icon(switch (mix) {
          RecapMix.favorites => Icons.repeat_rounded,
          RecapMix.variety => Icons.hub_outlined,
          RecapMix.deepCuts => Icons.explore_outlined,
        }, color: context.lokal.accent),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_mixName(mix), style: TextStyle(color: context.lokal.text,
          fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 4),
        Text(_mixDetail(mix), style: TextStyle(color: context.lokal.muted, fontSize: 12)),
      ])),
      const SizedBox(width: 8),
      Icon(Icons.chevron_right_rounded, color: context.lokal.text),
    ]),
  );
}

class _RecapHero extends StatelessWidget {
  const _RecapHero({required this.recap, this.onPlay, this.onMix});
  final ListeningRecap recap;
  final VoidCallback? onPlay, onMix;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return _RecapSurface(hero: true, child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: ReplayBrand(color: t.text)),
          Icon(Icons.auto_awesome_rounded, color: t.accent, size: 20),
        ]),
        const SizedBox(height: 8),
        Text(ReplayStyle.range(recap), style: TextStyle(color: t.muted, fontSize: 12)),
        const SizedBox(height: 18),
        LayoutBuilder(builder: (context, constraints) {
          final artWidth = constraints.maxWidth < 300 ? 88.0 : 120.0;
          return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(lokalText('Your world,\non repeat.'),
                style: TextStyle(color: t.text, fontSize: 34,
                  height: 1.02, letterSpacing: -1.6, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Text(ReplayStyle.plays(recap.totalPlays),
                style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)),
            ])),
            const SizedBox(width: 8),
            ExcludeSemantics(child: SizedBox(width: artWidth, height: artWidth + 16,
              child: Stack(alignment: Alignment.center, children: [
                for (final (i, song) in recap.topSongs.take(3).toList().reversed.indexed)
                  Transform.translate(offset: Offset((i - 1) * 9, (1 - i) * 5),
                    child: Transform.rotate(angle: (i - 1) * .13,
                      child: DecoratedBox(
                        decoration: BoxDecoration(boxShadow: [
                          BoxShadow(color: t.bg.withValues(alpha: .35),
                            blurRadius: 18, offset: const Offset(0, 8)),
                        ]),
                        child: ReplayArtwork(path: song.song.albumArt, size: artWidth - 16),
                      ))),
              ]),
            )),
          ]);
        }),
        const SizedBox(height: 18),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: t.accent,
              foregroundColor: t.onAccent, minimumSize: const Size(48, 48)),
            onPressed: onPlay, icon: const Icon(Icons.play_arrow_rounded),
            label: Text(lokalText('Play Replay'))),
          OutlinedButton.icon(onPressed: onMix,
            icon: const Icon(Icons.playlist_play_rounded),
            label: Text(lokalText('View playlist'))),
        ]),
      ],
    ));
  }
}

class _RecapMetrics extends StatelessWidget {
  const _RecapMetrics({required this.recap});
  final ListeningRecap recap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final large = MediaQuery.textScalerOf(context).scale(14) > 22;
    final width = large ? constraints.maxWidth : (constraints.maxWidth - 10) / 2;
    final metrics = [
      (ReplayStyle.durationLabel(recap.totalListeningTime), lokalText('Listening time'), Icons.headphones_rounded),
      ('${recap.uniqueSongs}', lokalText('Different songs'), Icons.music_note_rounded),
      ('${recap.uniqueArtists}', lokalText('Artists'), Icons.people_outline_rounded),
      ('${recap.activeDays}', lokalText('Active days'), Icons.calendar_today_rounded),
    ];
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final (value, label, icon) in metrics)
        SizedBox(width: width, child: _RecapSurface(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: context.lokal.accent),
            const SizedBox(height: 8),
            Text(value, style: TextStyle(color: context.lokal.text,
              fontSize: 25, letterSpacing: -.8, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: context.lokal.muted, fontSize: 12)),
          ],
        ))),
    ]);
  });
}

/// One bounded glass layer, clipped to the card. No perpetual tickers.
class _RecapSurface extends StatelessWidget {
  const _RecapSurface({required this.child, this.hero = false, this.onTap});
  final Widget child;
  final bool hero;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return ClipRRect(
      borderRadius: BorderRadius.circular(hero ? 28 : 20),
      child: BackdropFilter(
        enabled: hero,
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: hero
                ? [Color.alphaBlend(t.accent.withValues(alpha: .14), t.surface2), t.surface]
                : [t.surface2.withValues(alpha: .94), t.surface.withValues(alpha: .94)]),
            borderRadius: BorderRadius.circular(hero ? 28 : 20),
            border: Border.all(color: t.text.withValues(alpha: .10)),
          ),
          child: Material(color: Colors.transparent, child: InkWell(
            onTap: onTap, child: Padding(
              padding: EdgeInsets.all(hero ? 20 : 14), child: child))),
        ),
      ),
    );
  }
}

class _RecapRank extends StatelessWidget {
  const _RecapRank({required this.rank, required this.title,
    required this.subtitle, required this.progress, required this.onTap,
    this.path, this.circle = false, this.trailing = Icons.chevron_right_rounded,
    this.onSubtitle, this.subtitleLabel, this.onAlbum});
  final String rank, title, subtitle;
  final String? path, subtitleLabel;
  final double progress;
  final bool circle;
  final IconData trailing;
  final VoidCallback onTap;
  final VoidCallback? onSubtitle, onAlbum;

  @override
  Widget build(BuildContext context) {
    final t = context.lokal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: t.surface2.withValues(alpha: .8),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          InkWell(onTap: onTap, child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
            child: Row(children: [
              Text(rank, style: TextStyle(color: t.accent, fontSize: 12,
                fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              ClipRRect(borderRadius: BorderRadius.circular(circle ? 28 : 8),
                child: ReplayArtwork(path: path, size: 48)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 4),
                Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.muted, fontSize: 12)),
              ])),
              Icon(trailing, color: t.text, size: 20),
            ]),
          )),
          if (onSubtitle != null || onAlbum != null)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                if (onSubtitle != null) Expanded(child: TextButton(
                  onPressed: onSubtitle,
                  child: Align(alignment: Alignment.centerLeft,
                    child: Text(subtitleLabel ?? lokalText('Artist'),
                      maxLines: 1, overflow: TextOverflow.ellipsis)))),
                if (onAlbum != null) IconButton(
                  tooltip: lokalText('Open album'), onPressed: onAlbum,
                  icon: Icon(Icons.album_outlined, color: t.muted, size: 20)),
              ])),
          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: ClipRRect(borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0),
                minHeight: 2, color: t.accent, backgroundColor: t.border))),
        ]),
      ),
    );
  }
}

/// A frozen preview: refreshing history cannot change the playlist being saved.
class RecapMixPage extends ConsumerStatefulWidget {
  const RecapMixPage({super.key, required this.title, required this.subtitle,
    required this.detail, required this.songs});
  final String title, subtitle, detail;
  final List<Song> songs;

  @override
  ConsumerState<RecapMixPage> createState() => _RecapMixPageState();
}

class _RecapMixPageState extends ConsumerState<RecapMixPage> {
  bool _saving = false;
  String? _savedId;

  Future<void> _save() async {
    if (_saving || widget.songs.isEmpty) return;
    if (_savedId case final id?) {
      await openLokalPlaylist(context, id);
      return;
    }
    setState(() => _saving = true);
    final service = ref.read(playlistServiceProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    String? createdId;
    try {
      // New snapshot each time; never overwrite a user's existing playlist.
      final base = '${widget.title} · ${widget.subtitle}';
      final existing = (await service.getPlaylists())
          .map((p) => p.name.trim().toLowerCase()).toSet();
      var name = base;
      for (var suffix = 2; existing.contains(name.toLowerCase()); suffix++) {
        name = '$base ($suffix)';
      }
      final playlist = await service.createPlaylist(name);
      if (playlist == null) throw StateError('Could not create playlist');
      createdId = playlist.id;
      final unique = <String, Song>{for (final s in widget.songs) s.id: s};
      final saved = await service.updatePlaylist(playlist.copyWith(
        songIds: unique.keys.toList(growable: false),
        songSnapshots: {for (final s in unique.values) s.id: PlaylistSongSnapshot.fromSong(s)},
        songAddedAt: {for (final s in unique.values) s.id: DateTime.now()},
      ));
      if (saved == null) throw StateError('Could not save playlist');
      // The app's library can remain mounted after this preview has closed.
      // Keep persistence independent of this route's lifetime.
      try {
        container.invalidate(playlistsProvider);
      } on StateError {
        // The entire app provider scope may have been disposed during saving.
      }
      if (!mounted) return;
      setState(() => _savedId = saved.id);
      LokalToast.show(context, lokalText('Playlist saved'));
    } catch (_) {
      if (createdId != null) await service.deletePlaylist(createdId);
      if (mounted) LokalToast.show(context, lokalText('Couldn’t save playlist. Try again.'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => LokalLibraryPage(
    title: widget.title,
    subtitle: '${widget.subtitle} · ${lokalSongCount(widget.songs.length)}',
    slivers: [
      SliverToBoxAdapter(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.detail, style: TextStyle(color: context.lokal.muted)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: Icon(_savedId == null ? Icons.playlist_add_rounded : Icons.open_in_new_rounded),
            label: Text(lokalText(_saving ? 'Saving…' :
              _savedId == null ? 'Save playlist' : 'Open saved playlist'))),
        ]),
      )),
      LokalSongBrowser(songs: widget.songs, initialSort: LokalSongSort.original,
        originalLabel: lokalText('Recap order')),
    ],
  );
}
