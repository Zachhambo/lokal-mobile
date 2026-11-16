import 'dart:async';
import 'dart:convert';

import 'package:flick/features/search/download_activity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('records preparation progress and exact destination as one job', () async {
    final activity = DownloadActivity();
    final release = Completer<void>();
    final started = Completer<void>();
    final download = activity.run(
      title: 'Track',
      artist: 'Artist',
      task: () async {
        activity.status('Downloading from source… 42%');
        started.complete();
        await release.future;
        return activity.run(
          title: 'Prepared track',
          artist: 'Artist',
          task: () async {
            activity.status('Saving');
            activity.saved('/chosen/Music/Artist/Album/Track.flac');
            return 'saved';
          },
        );
      },
    );
    await started.future;
    expect(activity.entries, hasLength(1));
    expect(activity.entries.single.progress, .42);
    expect(activity.entries.single.active, isTrue);
    release.complete();
    expect(await download, 'saved');
    await activity.flushed;
    expect(activity.entries.single.state, 'Completed');
    final restored = DownloadActivity();
    await restored.load();
    expect(restored.entries.single.path, '/chosen/Music/Artist/Album/Track.flac');
    expect(restored.entries.single.state, 'Completed');
    expect(restored.entries.single.active, isFalse);
  });

  test('concurrent transfers keep their own progress and outcomes', () async {
    final activity = DownloadActivity();
    final release = Completer<void>();
    final started = Completer<void>();
    final first = activity.run(
      title: 'First', artist: 'Artist',
      task: () async {
        activity.status('Downloading… 25%');
        started.complete();
        await release.future;
        activity.saved('/first.flac');
      },
    );
    await started.future;
    await expectLater(
      activity.run<void>(
        title: 'Second', artist: 'Artist',
        task: () async => throw StateError('Source unavailable'),
      ),
      throwsStateError,
    );
    expect(activity.entries.first.state, 'Failed');
    expect(activity.entries.last.progress, .25);
    release.complete();
    await first;
    expect(activity.entries.last.path, '/first.flac');
    expect(activity.entries.last.state, 'Completed');
  });

  test('restart marks unfinished transfers interrupted and tolerates bad rows', () async {
    SharedPreferences.setMockInitialValues({
      DownloadActivity.storageKey: [
        'invalid',
        jsonEncode({
          'id': 'old', 'title': 'Track', 'artist': 'Artist',
          'started': '2026-01-01T00:00:00Z', 'state': 'Downloading',
        }),
      ],
    });
    final activity = DownloadActivity();
    await activity.load();
    expect(activity.entries, hasLength(1));
    expect(activity.entries.single.state, 'Interrupted');
    expect(activity.entries.single.active, isFalse);
  });

  test('Soulseek bytes are not completed before library import', () async {
    final activity = DownloadActivity();
    await activity.transfer(
      id: 'peer-job', title: 'Track', artist: 'Soulseek',
      state: 'Downloading', progress: .7,
    );
    expect(activity.entries.single.progress, .7);
    await activity.transfer(
      id: 'peer-job', title: 'Track', artist: 'Soulseek',
      state: 'Saving', progress: 1,
    );
    expect(activity.entries.single.active, isTrue);
    await activity.run(
      id: 'peer-job', title: 'Track', artist: 'Artist',
      task: () async => activity.saved('/music/track.flac'),
    );
    await activity.transfer(
      id: 'peer-job', title: 'Track', artist: 'Soulseek',
      state: 'Saving', progress: 1,
    );
    expect(activity.entries, hasLength(1));
    expect(activity.entries.single.state, 'Completed');
  });
}
