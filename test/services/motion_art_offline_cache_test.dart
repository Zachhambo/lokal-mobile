import 'dart:convert';
import 'dart:io';

import 'package:flick/services/motion_art/animated_artwork_service.dart';
import 'package:flick/services/motion_art/motion_art_offline_cache.dart';
import 'package:flick/services/motion_art/local_motion_hls_server.dart';
import 'package:flick/services/motion_art/moving_cover_service.dart';
import 'package:flick/services/motion_art/moving_cover_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Flutter's widget-test HttpOverrides normally rejects every HTTP request.
  // The loopback player server needs a real localhost client.
  final previousHttp = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() async {
    await LocalMotionHlsServer.closeForTesting();
    HttpOverrides.global = previousHttp;
  });

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lokal_motion_offline_');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  const mp4 = AnimatedArtwork(
    name: 'Album',
    artist: 'Artist',
    albumId: 'spotify:track',
    animatedUrl: 'https://video.example.com/canvas.mp4',
  );

  test('persists the real video, then resolves completely offline after restart',
      () async {
    var requests = 0;
    final downloader = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((request) async {
        requests++;
        expect(request.url.toString(), mp4.playbackUrl);
        return http.Response('video bytes', 200);
      }),
    );

    expect(await downloader.find('song|artist|apple'), isNull);
    await downloader.remember('song|artist|apple', mp4, preferVertical: false);
    expect(requests, 1);

    final restarted = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((request) async =>
          throw StateError('Offline playback must not request $request')),
    );
    final art = await restarted.find('song|artist|apple');
    expect(art?.albumId, 'spotify:track');
    final playable = await restarted.playable(art!, preferVertical: false);
    expect(playable?.cachedSource, mp4.playbackUrl);
    final uri = Uri.parse(playable!.url);
    expect(uri.scheme, 'file');
    expect(await File.fromUri(uri).readAsString(), 'video bytes');
    // Spotify Canvas is a progressive MP4 and must stay an ordinary local
    // file even when full-bleed playback requests a portrait variant.
    final portrait = await restarted.playable(art!, preferVertical: true);
    expect(Uri.parse(portrait!.url).scheme, 'file');
    expect(portrait.cachedSource, mp4.playbackUrl);
  });

  test('moving-cover resolver finds offline video without any provider requests',
      () async {
    SharedPreferences.setMockInitialValues({
      'lokal.motion.sources': ['spotify'],
    });
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async => http.Response('clip', 200)),
    );
    final first = MovingCoverService(
      offlineCache: cache,
      client: MockClient((request) async =>
          throw StateError('Provider must not be queried: $request')),
    );
    await first.cachePlayedClip(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      artwork: mp4,
      preferVertical: false,
    );

    final restarted = MovingCoverService(
      offlineCache: MotionArtOfflineCache.create(
        directory: directory,
        client: MockClient((request) async =>
            throw StateError('Offline request: $request')),
      ),
      client: MockClient((request) async =>
          throw StateError('Provider request: $request')),
    );
    final result = await restarted.lookup(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      settings: const MovingCoverSettings(sources: {'spotify'}),
    );
    expect(result.artwork?.playbackUrl, mp4.playbackUrl);
    expect(result.transient, isFalse);
  });

  test('album and track artist identities find one cached Spotify Canvas',
      () async {
    SharedPreferences.setMockInitialValues({
      'lokal.motion.sources': ['spotify'],
    });
    var downloads = 0;
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async {
        downloads++;
        return http.Response('canvas bytes', 200);
      }),
    );
    final service = MovingCoverService(
      offlineCache: cache,
      client: MockClient((request) async =>
          throw StateError('Unexpected online lookup: $request')),
    );
    await service.cachePlayedClip(
      title: 'Track',
      artist: 'Album Artist',
      alternateArtist: 'Track Artist',
      album: 'Album',
      artwork: mp4,
      preferVertical: false,
    );
    expect(downloads, 1);

    final restarted = MovingCoverService(
      offlineCache: MotionArtOfflineCache.create(
        directory: directory,
        client: MockClient((request) async =>
            throw StateError('No offline download: $request')),
      ),
      client: MockClient((request) async =>
          throw StateError('No offline provider: $request')),
    );
    final fullPlayer = await restarted.lookup(
      title: 'Track',
      artist: 'Track Artist',
      album: 'Album',
      settings: const MovingCoverSettings(sources: {'spotify'}),
    );
    expect(fullPlayer.artwork?.albumId, 'spotify:track');

    final miniPlayer = await restarted.lookup(
      title: 'Track',
      artist: 'Album Artist',
      alternateArtist: 'Track Artist',
      album: 'Album',
      settings: const MovingCoverSettings(sources: {'spotify'}),
    );
    expect(miniPlayer.artwork?.albumId, 'spotify:track');
    expect(downloads, 1);
  });

  test('Eco on cellular plays a previously cached cover without provider access',
      () async {
    var requests = 0;
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async {
        requests++;
        return http.Response('saved video', 200);
      }),
    );
    var eco = false;
    final service = MovingCoverService(
      offlineCache: cache,
      ecoActive: () async => eco,
      client: MockClient((request) async =>
          throw StateError('Provider request forbidden: $request')),
    );
    await service.cachePlayedClip(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      artwork: mp4,
      preferVertical: false,
    );
    expect(requests, 1);
    eco = true;

    final result = await service.lookup(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      settings: const MovingCoverSettings(sources: {'spotify'}),
    );
    expect(result.artwork?.animatedUrl, mp4.animatedUrl);
    final playable = await cache.playable(result.artwork!, preferVertical: false);
    expect(Uri.parse(playable!.url).scheme, 'file');
    expect(requests, 1);
  });

  test('Eco on cellular refuses uncached motion art and never downloads it',
      () async {
    var requests = 0;
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((request) async {
        requests++;
        return http.Response('unexpected', 200);
      }),
    );
    final service = MovingCoverService(
      offlineCache: cache,
      ecoActive: () async => true,
      client: MockClient((request) async {
        requests++;
        throw StateError('Provider must not be contacted: $request');
      }),
    );
    await service.cachePlayedClip(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      artwork: mp4,
      preferVertical: false,
    );
    final result = await service.lookup(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      settings: const MovingCoverSettings(),
    );
    expect(result.artwork, isNull);
    expect(result.transient, isFalse);
    expect(requests, 0);
  });

  test('Eco activated during download prevents committing a partial clip',
      () async {
    var downloadAllowed = true;
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async {
        downloadAllowed = false;
        return http.Response('partial video', 200);
      }),
    );
    await cache.remember(
      'track',
      mp4,
      preferVertical: false,
      canDownload: () async => downloadAllowed,
    );
    expect(await cache.find('track'), isNull);
    expect(await cache.localFile(mp4.playbackUrl!), isNull);
  });

  test('stores finite HLS segments and rewrites manifest to local assets',
      () async {
    const artwork = AnimatedArtwork(
      name: 'Album',
      artist: 'Artist',
      albumId: 'apple:album',
      animatedUrl: 'https://cdn.example.com/playlist.m3u8',
    );
    final urls = <String>[];
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((request) async {
        urls.add(request.url.toString());
        return switch (request.url.path) {
          '/playlist.m3u8' => http.Response(
              '#EXTM3U\n'
              '#EXT-X-VERSION:7\n'
              '#EXT-X-TARGETDURATION:3\n'
              '#EXT-X-MAP:URI="init.mp4"\n'
              '#EXTINF:2.5,\n'
              'segment1.m4s\n'
              '#EXTINF:2.5,\n'
              'segment2.m4s\n'
              '#EXT-X-ENDLIST\n',
              200,
            ),
          '/init.mp4' => http.Response('init', 200),
          '/segment1.m4s' => http.Response('segment1', 200),
          '/segment2.m4s' => http.Response('segment2', 200),
          _ => http.Response('not found', 404),
        };
      }),
    );

    await cache.remember('hls', artwork, preferVertical: false);
    final playable = await cache.playable(artwork, preferVertical: false);
    // AVPlayer/ExoPlayer must consume a real local HLS HTTP source, never a
    // file:// manifest or a CDN request. Media and range requests remain local.
    final uri = Uri.parse(playable!.url);
    expect(uri.scheme, 'http');
    expect(uri.host, '127.0.0.1');
    final nativeClient = HttpClient();
    addTearDown(nativeClient.close);
    final response = await (await nativeClient.getUrl(uri)).close();
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, 'application/vnd.apple.mpegurl');
    final playlist = await utf8.decoder.bind(response).join();
    expect(playable.cachedSource, artwork.playbackUrl);
    final segmentRequest = await nativeClient.getUrl(uri.resolve('asset_1.m4s'));
    segmentRequest.headers.set('range', 'bytes=1-3');
    final segment = await segmentRequest.close();
    expect(segment.statusCode, 206);
    expect(segment.headers.value('content-range'), 'bytes 1-3/8');
    expect(await utf8.decoder.bind(segment).join(), 'egm');
    final traversal = await (await nativeClient.getUrl(
      uri.resolve('%2e%2e/complete.json'),
    )).close();
    expect(traversal.statusCode, 404);
    expect(playlist, contains('URI="asset_0.mp4"'));
    expect(playlist, contains('asset_1.m4s'));
    expect(playlist, contains('asset_2.m4s'));
    expect(playlist, isNot(contains('https://')));
    expect(urls.length, 4);
    expect(await cache.find('hls'), isNotNull);
  });

  test(
    'normalizes HLS byte ranges into self-contained offline segments',
    () async {
      const artwork = AnimatedArtwork(
        name: 'Album',
        artist: 'Artist',
        albumId: 'apple:album',
        animatedUrl: 'https://cdn.example.com/playlist.m3u8',
      );
      final ranges = <String>[];
      final cache = MotionArtOfflineCache.create(
        directory: directory,
        client: MockClient((request) async {
          if (request.url.path == '/playlist.m3u8') {
            return http.Response(
              '#EXTM3U\n'
              '#EXT-X-VERSION:7\n'
              '#EXT-X-TARGETDURATION:3\n'
              '#EXT-X-MAP:URI="cover.mp4",BYTERANGE="4@2"\n'
              '#EXTINF:2.5,\n'
              '#EXT-X-BYTERANGE:4@6\n'
              'cover.mp4\n'
              '#EXTINF:2.5,\n'
              '#EXT-X-BYTERANGE:4\n'
              'cover.mp4\n'
              '#EXT-X-ENDLIST\n',
              200,
            );
          }
          final range = request.headers['range']!;
          ranges.add(range);
          if (range == 'bytes=10-13') {
            // An origin that ignores Range still works for a bounded response.
            return http.Response('xxinitone!two!', 200);
          }
          return http.Response(
            range == 'bytes=2-5' ? 'init' : 'one!',
            206,
            headers: {'content-range': 'bytes ${range.substring(6)}/14'},
          );
        }),
      );

      await cache.remember('ranges', artwork, preferVertical: false);
      final manifest = (await cache.localFile(artwork.playbackUrl!))!;
      final playlist = await manifest.readAsString();
      expect(ranges, ['bytes=2-5', 'bytes=6-9', 'bytes=10-13']);
      expect(playlist, contains('URI="asset_0.mp4"'));
      expect(playlist, isNot(contains('BYTERANGE')));
      for (final (index, content) in ['init', 'one!', 'two!'].indexed) {
        expect(
          await File('${manifest.parent.path}/asset_$index.mp4').readAsString(),
          content,
        );
      }
    },
  );

  test('prepares motion art while Canvas is selected and switches after restart', () async {
    SharedPreferences.setMockInitialValues({
      'lokal.motion.sources': ['tidal', 'spotify'],
      'lokal.motion.spotify_first': true,
    });
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async => http.Response('saved video', 200)),
    );
    final online = MovingCoverService(
      offlineCache: cache,
      offline: () async => false,
      client: MockClient((request) async {
        expect(request.url.host, 'api.tidal.com');
        return http.Response(
          '{"tracks":{"items":[{"title":"Track","artists":[{"name":"Artist"}],'
          '"album":{"title":"Album","videoCover":"12345678-1234-1234-1234-123456789abc"}}]}}',
          200,
        );
      }),
    );
    await online.cachePlayedClip(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      artwork: mp4,
      preferVertical: true,
    );

    var networkCalls = 0;
    final noNetwork = MockClient((_) async {
      networkCalls++;
      throw StateError('offline');
    });
    final restartedCache = MotionArtOfflineCache.create(
      directory: directory,
      client: noNetwork,
    );
    final restarted = MovingCoverService(
      offlineCache: restartedCache,
      offline: () async => true,
      client: noNetwork,
    );

    Future<String?> selected({
      required bool spotifyFirst,
      Set<String> sources = const {'tidal', 'spotify'},
    }) async {
      final clip = await restarted.lookup(
        title: 'Track',
        artist: 'Artist',
        album: 'Album',
        settings: MovingCoverSettings(
          sources: sources,
          spotifyFirst: spotifyFirst,
        ),
      );
      final artwork = clip.artwork;
      if (artwork == null) return null;
      final local = await restartedCache.playable(
        artwork,
        preferVertical: true,
      );
      expect(Uri.parse(local!.url).scheme, 'file');
      return artwork.albumId.split(':').first;
    }

    expect(await selected(spotifyFirst: true), 'spotify');
    expect(await selected(spotifyFirst: false), 'tidal');
    expect(await selected(spotifyFirst: true, sources: {'tidal'}), 'tidal');
    expect(await selected(spotifyFirst: true, sources: {}), isNull);
    expect(networkCalls, 0);
  });

  test('missing HLS segments invalidate an otherwise complete marker', () async {
    const artwork = AnimatedArtwork(
      name: 'Album',
      artist: 'Artist',
      albumId: 'apple:album',
      animatedUrl: 'https://cdn.example.com/media.m3u8',
    );
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((request) async => switch (request.url.path) {
        '/media.m3u8' => http.Response(
            '#EXTM3U\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n', 200),
        '/segment.ts' => http.Response('segment bytes', 200),
        _ => http.Response('not found', 404),
      }),
    );
    await cache.remember('hls', artwork, preferVertical: false);
    expect(await cache.find('hls'), isNotNull);
    final root = Directory('${directory.path}/motion_art_offline');
    final clip = (await root.list().where((e) => e is Directory).toList())
        .whereType<Directory>().single;
    await File('${clip.path}/asset_0.ts').delete();
    expect(await cache.find('hls'), isNull);
  });

  test('never marks incomplete or encrypted HLS as offline playable', () async {
    const artwork = AnimatedArtwork(
      name: 'Album',
      artist: 'Artist',
      albumId: 'apple:album',
      animatedUrl: 'https://cdn.example.com/encrypted.m3u8',
    );
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async => http.Response(
            '#EXTM3U\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="key"\n'
            '#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n',
            200,
          )),
    );
    await cache.remember('encrypted', artwork, preferVertical: false);
    expect(await cache.find('encrypted'), isNull);
    final playable = await cache.playable(artwork, preferVertical: false);
    expect(playable?.cachedSource, isNull);
    expect(playable?.url, artwork.playbackUrl);
  });

  test('falls back to a saved square clip when portrait is unavailable',
      () async {
    const artwork = AnimatedArtwork(
      name: 'Album',
      artist: 'Artist',
      albumId: 'apple:album',
      animatedUrl: 'https://cdn.example.com/square.mp4',
      animatedVerticalUrl: 'https://cdn.example.com/portrait.mp4',
    );
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((request) async {
        expect(request.url.path, '/square.mp4');
        return http.Response('square clip', 200);
      }),
    );
    await cache.remember('square', artwork, preferVertical: false);
    final offline = await cache.playable(artwork, preferVertical: true);
    expect(offline?.cachedSource, artwork.playbackUrl);
    expect(Uri.parse(offline!.url).scheme, 'file');
  });
  test('airplane mode bypasses memoized streaming lookup after clip eviction',
      () async {
    SharedPreferences.setMockInitialValues({
      'lokal.motion.sources': ['spotify'],
    });
    var offline = false;
    var providerRequests = 0;
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async => http.Response('canvas bytes', 200)),
    );
    final service = MovingCoverService(
      offlineCache: cache,
      offline: () async => offline,
      ecoActive: () async => false,
      client: MockClient((request) async {
        providerRequests++;
        throw StateError('No provider HTTP is permitted offline: $request');
      }),
    );
    await service.cachePlayedClip(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      artwork: mp4,
      preferVertical: false,
    );
    const spotifyOnly = MovingCoverSettings(sources: {'spotify'});
    expect(
      (await service.lookup(
        title: 'Track', artist: 'Artist', album: 'Album',
        settings: spotifyOnly,
      )).artwork,
      isNotNull,
    );
    await cache.discard(mp4.playbackUrl!);
    offline = true;
    final disconnected = await service.lookup(
      title: 'Track', artist: 'Artist', album: 'Album',
      settings: spotifyOnly,
    );
    expect(disconnected.artwork, isNull,
        reason: 'A memoized remote Canvas URL is not an offline video');
    expect(disconnected.transient, isFalse);
    expect(providerRequests, 0);
  });

  test('saved Spotify Canvas survives provider reorder but not source disable',
      () async {
    var offline = false;
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async => http.Response('canvas bytes', 200)),
    );
    final service = MovingCoverService(
      offlineCache: cache,
      ecoActive: () async => false,
      offline: () async => offline,
      client: MockClient((request) async =>
          throw StateError('Provider must not be called: $request')),
    );
    await service.cachePlayedClip(
      title: 'Track', artist: 'Artist', album: 'Album',
      artwork: mp4, preferVertical: false,
    );
    offline = true;
    final changedPriority = await service.lookup(
      title: 'Track', artist: 'Artist', album: 'Album',
      settings: const MovingCoverSettings(
        sources: {'spotify', 'apple'},
        spotifyFirst: true,
      ),
    );
    expect(changedPriority.artwork?.albumId, 'spotify:track');
    final playable = await cache.playable(
      changedPriority.artwork!, preferVertical: false,
    );
    expect(Uri.parse(playable!.url).scheme, 'file');
    expect(playable.cachedSource, mp4.playbackUrl);

    final disabled = await service.lookup(
      title: 'Track', artist: 'Artist', album: 'Album',
      settings: const MovingCoverSettings(sources: {'apple'}),
    );
    expect(disabled.artwork, isNull,
        reason: 'An explicitly disabled Canvas source stays disabled');
  });

  test('legacy order-dependent offline clips migrate with no network', () async {
    final cache = MotionArtOfflineCache.create(
      directory: directory,
      client: MockClient((_) async => http.Response('old canvas', 200)),
    );
    await cache.remember(
      'v1|track|artist|album|apple,spotify',
      mp4,
      preferVertical: false,
    );
    expect(await cache.find('v2|track|artist|album|spotify'), isNull);

    final service = MovingCoverService(
      offlineCache: cache,
      ecoActive: () async => false,
      offline: () async => true,
      client: MockClient((request) async =>
          throw StateError('No provider request allowed: $request')),
    );
    final oldCanvas = await service.lookup(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      settings: const MovingCoverSettings(
        sources: {'apple', 'spotify'},
        spotifyFirst: true,
      ),
    );
    expect(oldCanvas.artwork?.albumId, 'spotify:track');
    expect(await cache.find('v2|track|artist|album|spotify'), isNotNull);
  });

}
