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
}
