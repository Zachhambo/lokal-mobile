import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models/song.dart';
import '../../services/link/copied_track_clip.dart';
import 'music_video_surface.dart';

Future<void> openCopiedTrackClip(
  BuildContext context,
  Song song,
  CopiedTrackClip clip,
) => Navigator.of(context, rootNavigator: true).push<void>(
  MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(title: Text(song.title)),
      body: SafeArea(
        child: clip.videoId != null
            ? MusicVideoSurface(videoId: clip.videoId!, clip: clip)
            : _FileClip(clip: clip),
      ),
    ),
  ),
);

class _FileClip extends StatefulWidget {
  const _FileClip({required this.clip});

  final CopiedTrackClip clip;

  @override
  State<_FileClip> createState() => _FileClipState();
}

class _FileClipState extends State<_FileClip> {
  late final VideoPlayerController _controller;
  var _seeking = false;
  var _failed = false;
  var _ready = false;
  Duration _start = Duration.zero;
  Duration _end = Duration.zero;

  @override
  void initState() {
    super.initState();
    final uri = widget.clip.uri!;
    final options = VideoPlayerOptions(mixWithOthers: true);
    _controller = uri.scheme == 'file'
        ? VideoPlayerController.file(
            File.fromUri(uri),
            videoPlayerOptions: options,
          )
        : VideoPlayerController.networkUrl(uri, videoPlayerOptions: options);
    _controller.addListener(_update);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      if (!mounted) return;
      final range = widget.clip.range(_controller.value.duration);
      _start = range.start;
      _end = range.end;
      await _controller.setVolume(0);
      if (!mounted) return;
      await _controller.seekTo(_start);
      if (!mounted) return;
      await _controller.play();
      if (mounted) setState(() => _ready = true);
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _update() {
    final value = _controller.value;
    if (value.hasError && mounted && !_failed) {
      setState(() => _failed = true);
    } else if (_ready &&
        !_seeking &&
        _end > _start &&
        ((value.isPlaying && value.position >= _end) || value.isCompleted)) {
      unawaited(_rewind());
    }
  }

  Future<void> _rewind() async {
    _seeking = true;
    try {
      await _controller.seekTo(_start);
      if (mounted) await _controller.play();
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      _seeking = false;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_update);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Center(child: Text('Could not play this video clip.'));
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return Center(
      child: AspectRatio(
        aspectRatio: _controller.value.aspectRatio,
        child: VideoPlayer(_controller),
      ),
    );
  }
}
