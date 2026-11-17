import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flick/features/search/online_song_save.dart';
import 'package:flick/l10n/l10n.dart';
import 'package:flick/models/song.dart';
import 'package:flick/providers/songs_provider.dart';
import 'package:flick/services/link/lokal_desktop_source.dart';

String _normalize(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Require the same recording, including version text and known album/duration.
/// A playback cache or a desktop catalogue entry is not a phone library copy.
bool fullPlayerLibraryMatch(Song playing, Song local) {
  if (local.isExternal || local.isPending || local.isNetworkSource) return false;
  final path = local.filePath;
  if (path == null || path.isEmpty) return false;
  final uri = Uri.tryParse(path);
  if (uri != null && uri.hasScheme &&
      !{'content', 'file'}.contains(uri.scheme) &&
      !RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) return false;
  if (playing.id == local.id || playing.filePath == path) return true;
  if (_normalize(playing.title).isEmpty ||
      _normalize(playing.artist).isEmpty ||
      _normalize(playing.title) != _normalize(local.title) ||
      _normalize(playing.artist) != _normalize(local.artist)) return false;
  final album = _normalize(playing.album ?? '');
  final localAlbum = _normalize(local.album ?? '');
  if (album.isNotEmpty && localAlbum.isNotEmpty && album != localAlbum) return false;
  return playing.duration == Duration.zero ||
      local.duration == Duration.zero ||
      (playing.duration - local.duration).inMilliseconds.abs() <= 2000;
}

final fullPlayerInLibraryProvider =
    FutureProvider.autoDispose.family<bool, Song>((ref, song) async {
  ref.watch(libraryChangeRevisionProvider);
  final repository = ref.watch(songRepositoryProvider);
  Future<bool> downloaded(Song? candidate) async {
    if (candidate == null || !fullPlayerLibraryMatch(song, candidate)) return false;
    final path = candidate.filePath!;
    if (path.startsWith('content://')) return true;
    final uri = Uri.tryParse(path);
    return (uri?.scheme == 'file' ? File.fromUri(uri!) : File(path)).exists();
  }

  if (await downloaded(await repository.getSongById(song.id))) return true;
  final path = song.filePath;
  if (path != null &&
      await downloaded(await repository.getSongByFilePath(path))) return true;
  // Bounded indexed lookup; never load/sort the complete phone library.
  for (final candidate in await repository.getHistoryMatchCandidates(song.title)) {
    if (await downloaded(candidate)) return true;
  }
  return false;
});

final fullPlayerDownloadProvider = Provider<Future<void> Function(Song)>((ref) {
  return (song) async {
    if (song.sourceType == 'lokal') {
      await LokalDesktopSource.instance.downloadToPhone(song);
    } else {
      await OnlineSongSaveRegistry.instance.save(song);
    }
  };
});

/// Shared action for both player layouts. Its host supplies artwork-aware
/// neutral styling; library membership never turns on the theme accent.
class FullPlayerLibraryAction extends ConsumerStatefulWidget {
  const FullPlayerLibraryAction({
    super.key,
    required this.song,
    required this.builder,
  });

  final Song song;
  final Widget Function(IconData icon, String label, VoidCallback? onTap) builder;

  @override
  ConsumerState<FullPlayerLibraryAction> createState() =>
      _FullPlayerLibraryActionState();
}

class _FullPlayerLibraryActionState extends ConsumerState<FullPlayerLibraryAction> {
  final _downloading = <String>{};

  Future<void> _download() async {
    final song = widget.song;
    if (!_downloading.add(song.id)) return;
    setState(() {});
    final save = ref.read(fullPlayerDownloadProvider);
    try {
      // Recheck after the tap in case another screen just saved this recording.
      ref.invalidate(fullPlayerInLibraryProvider(song));
      if (!await ref.read(fullPlayerInLibraryProvider(song).future)) {
        await save(song);
      }
      if (mounted) ref.invalidate(fullPlayerInLibraryProvider(song));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(lokalText(
            'Could not save {arg0}: {arg1}',
            args: {'arg0': song.title, 'arg1': '$error'},
          ))),
        );
      }
    } finally {
      _downloading.remove(song.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final membership = ref.watch(fullPlayerInLibraryProvider(widget.song));
    final inLibrary = membership.value == true;
    final busy = _downloading.contains(widget.song.id);
    final canDownload = widget.song.sourceType == 'lokal' ||
        OnlineSongSaveRegistry.instance.canSave(widget.song);
    final checking = membership.isLoading;
    return widget.builder(
      inLibrary ? Icons.check_rounded :
          busy ? Icons.downloading_rounded : Icons.download_rounded,
      lokalText(inLibrary ? 'In library' :
          busy ? 'Downloading' :
          checking ? 'Checking library' :
          'Download to library'),
      inLibrary || busy || checking || membership.hasError || !canDownload
          ? null : _download,
    );
  }
}
