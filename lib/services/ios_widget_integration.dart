import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/lokal_appearance.dart';
import '../features/flow/flow_controller.dart';
import '../features/flow/flow_library.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import 'ios_widget_actions.dart';
import 'ios_widget_runtime.dart';
import 'ios_widget_snapshot_builder.dart';
import 'online_playlist_reference.dart';
import 'online_radio_recommendations.dart';

/// Mount once alongside the existing player; never in a widget extension.
class IosWidgetIntegration {
  IosWidgetIntegration(this.ref, {
    required this.openPlayer, required this.openQueue, required this.showMessage,
  });
  final WidgetRef ref;
  final void Function() openPlayer, openQueue;
  final void Function(String) showMessage;
  late final IosWidgetRuntime runtime;
  late final IosWidgetActions actions;
  final List<ProviderSubscription<dynamic>> _subscriptions = [];
  List<Song> _recommendations = const [];
  bool _disposed = false;

  Future<void> attach() async {
    runtime = IosWidgetRuntime.system(
      accentArgb: ref.read(lokalAppearanceProvider).tokens.accent.toARGB32());
    actions = IosWidgetActions(
      currentAlias: () {
        final song = ref.read(playerProvider).currentSong;
        return song == null ? null : iosWidgetTrackAlias(song.id);
      },
      execute: (command) async {
        try {
          await _execute(command);
        } catch (_) {
          if (!_disposed) showMessage('Could not start playback. Open Lokal to retry.');
          rethrow;
        }
      },
      onStale: () async {
        await runtime.retry();
        if (!_disposed) {
          showMessage('Your music changed. The widget is refreshing; tap again.');
        }
      },
    );
    _subscriptions.add(ref.listenManual(playerProvider, (_, next) => runtime.observe(next),
      fireImmediately: true));
    _subscriptions.add(ref.listenManual(lokalAppearanceProvider,
      (_, next) => runtime.setAccent(next.tokens.accent.toARGB32())));
    _subscriptions.add(ref.listenManual(flowControllerProvider,
      (_, _) => _recommendationsChanged(), fireImmediately: true));
    _subscriptions.add(ref.listenManual(flowLibraryProvider,
      (_, _) => _recommendationsChanged(), fireImmediately: true));
    await actions.attach();
  }

  void _recommendationsChanged() {
    if (_disposed) return;
    final data = ref.read(flowControllerProvider).value;
    final library = ref.read(flowLibraryProvider).value;
    if (data == null || library == null) return;
    _recommendations = library.mix(data, DateTime.now()).take(12).toList(growable: false);
    runtime.sampler.setRecommendations(_recommendations,
      kind: _recommendations.isEmpty ? IosWidgetFlowKind.none : IosWidgetFlowKind.flow,
      status: 'Your Flow');
  }

  Future<void> _execute(IosWidgetCommand command) async {
    if (_disposed) return;
    final player = ref.read(playerProvider.notifier);
    final revision = ref.read(playerServiceProvider).playbackRequestRevision;
    bool currentRequest() => !_disposed &&
      ref.read(playerServiceProvider).playbackRequestRevision == revision;
    switch (command.action) {
      case 'open':
        openPlayer();
      case 'queue':
        openQueue();
      case 'play':
      case 'pause':
        final wantPlaying = command.action == 'play';
        if (ref.read(playerProvider).isPlaying != wantPlaying) {
          await player.togglePlayPause();
        }
      case 'next':
        await player.next();
      case 'previous':
        await player.previous();
      case 'flow':
        final library = await ref.read(flowLibraryProvider.future);
        if (!library.unlocked) {
          showMessage('Like more library songs to unlock Flow.');
          return;
        }
        await ref.read(flowControllerProvider.future);
        if (!currentRequest()) return;
        await ref.read(flowControllerProvider.notifier).play();
      case 'radio':
        final seed = ref.read(playerProvider).currentSong;
        if (seed == null) return;
        final recommendations = await const OnlineRadioRecommendations().recommend(
          seed, count: 8, existing: [seed]).timeout(const Duration(seconds: 17));
        if (!currentRequest() ||
            iosWidgetTrackAlias(ref.read(playerProvider).currentSong?.id ?? '') != command.track) return;
        if (recommendations.isEmpty) {
          showMessage('No radio matches yet. Try another song.');
          return;
        }
        final songs = [seed, ...recommendations.map(stableOnlinePlaylistSong)];
        await player.play(songs.first, playlist: songs);
      case 'recommend':
        await ref.read(flowControllerProvider.future);
        await ref.read(flowLibraryProvider.future);
        if (!currentRequest()) return;
        _recommendationsChanged();
        final song = _recommendations.where((song) =>
          iosWidgetTrackAlias(song.id) == command.track).firstOrNull;
        if (song == null) {
          showMessage('This mix changed. Open Flow to choose a track.');
          return;
        }
        await ref.read(flowControllerProvider.future);
        await ref.read(flowControllerProvider.notifier).play(songId: song.id);
    }
    if (!_disposed) {
      runtime.observe(ref.read(playerProvider));
      await runtime.flush();
    }
  }

  Future<void> refresh() async {
    if (_disposed) return;
    await runtime.retry();
    await actions.drain();
  }

  Future<void> flush() => runtime.flush();

  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) { subscription.close(); }
    unawaited(actions.dispose());
    runtime.dispose();
  }
}
