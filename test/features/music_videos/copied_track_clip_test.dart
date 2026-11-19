import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flick/data/database.dart';
import 'package:flick/services/link/link_journal.dart';
import 'package:flutter/services.dart';
import 'package:isar_community/isar.dart';
import 'package:flick/features/music_videos/music_video_surface.dart';
import 'package:flick/models/song.dart';
import 'package:flick/services/link/copied_track_clip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const song = Song(
    id: '42',
    title: 'Song',
    artist: 'Artist',
    duration: Duration(minutes: 3),
    fileType: 'flac',
    remoteId: 'desktop-track',
    remoteServerId: 3,
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a copied YouTube clip retains its identity and trim after reopening',
    () async {
      await CopiedTrackClip.save(3, 'desktop-track', {
        'videoId': 'abcdefghijk',
        'start': 75,
        'end': 85.5,
      });
      final clip = (await CopiedTrackClip.forSong(song))!;
      expect(clip.videoId, 'abcdefghijk');
      expect(clip.range(song.duration), (
        start: const Duration(seconds: 75),
        end: const Duration(seconds: 85, milliseconds: 500),
      ));
      final html = musicVideoEmbedHtml(clip.videoId!, clip: clip);
      expect(html, contains('const lokalClipStart = 75.0;'));
      expect(html, contains('const lokalClipEnd = 85.5;'));
      expect(html, contains('lokalPlayer.mute()'));
      expect(html, contains('lokalPlayer.seekTo(from, true)'));

      await CopiedTrackClip.save(3, 'desktop-track', null);
      expect(await CopiedTrackClip.forSong(song), isNull);
    },
  );

  test('a selected range never exceeds a local file duration', () {
    const clip = CopiedTrackClip(start: 5, end: 90);
    expect(clip.range(const Duration(seconds: 7)), (
      start: const Duration(seconds: 5),
      end: const Duration(seconds: 7),
    ));
  });
  test(
    'accepts YouTube and Music links and parses seconds and clock times',
    () {
      for (final link in [
        'https://www.youtube.com/watch?v=abcdefghijk&t=75',
        'https://music.youtube.com/watch?v=abcdefghijk',
        'https://youtu.be/abcdefghijk',
        'https://www.youtube.com/shorts/abcdefghijk',
      ]) {
        expect(CopiedTrackClip.youtubeIdFromLink(link), 'abcdefghijk');
      }
      for (final link in [
        'file:///a.mp4',
        'https://www.youtube.com.evil.example/watch?v=abcdefghijk',
        'https://www.youtube.com/playlist?list=PLtest',
        'https://youtu.be/abcdefghijkl',
      ]) {
        expect(CopiedTrackClip.youtubeIdFromLink(link), isNull);
      }
      expect(CopiedTrackClip.parseTime(''), isNull);
      expect(CopiedTrackClip.parseTime('1:02:03'), 3723);
      expect(CopiedTrackClip.parseTime('1:15.5'), 75.5);
      expect(CopiedTrackClip.parseTime('0'), 0);
      expect(CopiedTrackClip.parseTime('-1'), isNaN);
      expect(CopiedTrackClip.parseTime('1:99'), isNaN);
    },
  );

  test(
    'editing a phone-only song saves one durable operation and reveals a clip',
    () async {
      final config = File('.dart_tool/package_config.json').absolute.uri;
      final packages =
          (jsonDecode(File.fromUri(config).readAsStringSync())
                  as Map)['packages']
              as List;
      final library = packages.cast<Map>().singleWhere(
        (entry) => entry['name'] == 'isar_community_flutter_libs',
      );
      final root = config.resolve('${library['rootUri']}/');
      final binary = Platform.isMacOS
          ? 'macos/libisar.dylib'
          : Platform.isWindows
          ? 'windows/isar.dll'
          : 'linux/libisar.so';
      Isar.initializeIsarCore(
        libraries: {Abi.current(): root.resolve(binary).toFilePath()},
      );
      final directory = await Directory.systemTemp.createTemp(
        'lokal-video-clip-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      addTearDown(() async {
        await Database.close();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      });
      await Database.init();
      const local = Song(
        id: '99',
        title: 'Phone song',
        artist: 'Artist',
        duration: Duration(minutes: 3),
        fileType: 'flac',
      );
      expect(await CopiedTrackClip.forSong(local), isNull);
      final revision = CopiedTrackClip.revision.value;
      await CopiedTrackClip.edit(
        local,
        videoId: 'abcdefghijk',
        start: 13,
        end: 20.5,
      );
      expect(CopiedTrackClip.revision.value, revision + 1);
      var clip = await CopiedTrackClip.forSong(local);
      expect(clip?.videoId, 'abcdefghijk');
      expect(clip?.start, 13);
      expect(clip?.end, 20.5);
      var journal = await LinkJournal.instance.libraryAfter(0);
      final first = (journal['items'] as List).single as Map;
      expect(first['op'], 'track.edit');
      expect(first['fields']['video_clip'], {
        'videoId': 'abcdefghijk',
        'start': 13,
        'end': 20.5,
      });
      await CopiedTrackClip.edit(local, videoId: null);
      clip = await CopiedTrackClip.forSong(local);
      expect(clip, isNull);
      journal = await LinkJournal.instance.libraryAfter(
        journal['cursor'] as int,
      );
      final removal = (journal['items'] as List).single as Map;
      expect((removal['fields'] as Map).containsKey('video_clip'), isTrue);
      expect(removal['fields']['video_clip'], isNull);
    },
  );
}
