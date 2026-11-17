import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/song.dart';
import '../player_service.dart';
import '../remote_source_service.dart';
import '../sources/local_network_access.dart';
import 'cast_content_server.dart';
import 'cast_device.dart';
import 'dlna_backend.dart';
import 'chromecast_backend.dart';
import 'cast_handoff.dart';
import 'cast_session_recovery.dart';
import 'cast_source.dart';
import 'cast_local_file.dart';
import 'cast_receiver_presentation.dart';
import 'cast_receiver_transport.dart';
import '../lyrics_service.dart';

// ponytail: orchestrates DLNA + Chromecast backends; drives PlayerService notifiers
// so the UI works unchanged while casting. Mutual import with PlayerService is fine
// in Dart (no constructor-time cycle; both are lazy singletons).
//
// System integration: while casting, the media notification switches the
// MediaSession to remote volume (setPlaybackToRemote) so the system volume
// panel shows the cast target and hardware keys drive it. DLNA targets are
// additionally published as MediaRouter routes (native DlnaRouteProvider) so
// One UI / output switchers see a real remote output.
class CastingService {
  CastingService._() {
    _listenChromecastEvents();
  }
  static final CastingService instance = CastingService._();

  static const _dlnaRouteChannel = MethodChannel(
    'com.mossapps.flick/dlna_route',
  );

  final DlnaBackend _dlna = DlnaBackend();
  final ChromecastBackend _chromecast = ChromecastBackend();

  final ValueNotifier<List<CastDevice>> devicesNotifier =
      ValueNotifier<List<CastDevice>>(const []);
  final ValueNotifier<CastDevice?> activeDeviceNotifier =
      ValueNotifier<CastDevice?>(null);
  final ValueNotifier<bool> isActiveNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isDiscoveringNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isChangingOutputNotifier = ValueNotifier<bool>(
    false,
  );
  final ValueNotifier<String?> errorNotifier = ValueNotifier<String?>(null);

  /// Remote volume 0..1 while casting; null when local. Mirrors the TV-side
  /// value so the system VolumeProvider and in-app slider stay in sync.
  final ValueNotifier<double?> remoteVolumeNotifier = ValueNotifier<double?>(
    null,
  );

  final receiverViewNotifier = ValueNotifier<String>('nowplaying');
  final _completion = CastCompletionGate();
  String? currentCastLoadId;
  int _loadRevision = 0;
  int _sourceRevision = 0;
  int _sourcePreparations = 0;
  final isPreparingNotifier = ValueNotifier<bool>(false);

  void _syncPreparationState() {
    isPreparingNotifier.value =
        _sourcePreparations > 0 || _pendingCastLoadId != null;
  }
  String? _pendingCastLoadId;
  Map<String, dynamic>? _lastCcStatus;
  int _presentationRevision = 0;

  CastDevice? _activeDevice;
  Song? _currentSong;
  Timer? _pollTimer;
  Timer? _discoverCooldown;
  Timer? _ccSuspensionTimer;
  int _ccSessionRevision = 0;
  StreamSubscription<Map<String, dynamic>>? _ccEventsSub;
  bool _wasPlayingBeforeCast = false;
  bool _tearingDown = false;
  bool _receiverSkipInFlight = false;

  bool get isActive => _activeDevice != null;
  CastDevice? get activeDevice => _activeDevice;
  Song? get currentSong => _currentSong;

  Future<void> discover({Duration timeout = const Duration(seconds: 4)}) async {
    if (isDiscoveringNotifier.value) return;
    isDiscoveringNotifier.value = true;
    try {
      final failures = <Object>[];
      Future<List<CastDevice>> scan(
        Future<List<CastDevice>> Function() run,
      ) async {
        try {
          return await run();
        } catch (error) {
          if (!Platform.isIOS) rethrow;
          failures.add(error);
          return const [];
        }
      }

      final results = await Future.wait<dynamic>([
        scan(() => _dlna.discover(timeout: timeout)),
        scan(_chromecast.discover),
      ]);
      final dlna = results[0] as List<CastDevice>;
      final cc = results[1] as List<CastDevice>;
      devicesNotifier.value = [...dlna, ...cc];
      _publishDlnaRoutes(dlna);
      if (failures.isNotEmpty) {
        throw PlatformException(
          code: 'CAST_DISCOVERY',
          message: 'Some receivers could not be scanned. Check Local Network access in Settings, then scan again.',
        );
      }
    } finally {
      isDiscoveringNotifier.value = false;
    }
  }

  void startContinuousDiscovery() {
    if (_discoverCooldown != null) return;
    discover();
    _discoverCooldown = Timer.periodic(
      const Duration(seconds: 10),
      (_) => discover(),
    );
  }

  void stopContinuousDiscovery() {
    _discoverCooldown?.cancel();
    _discoverCooldown = null;
  }

  Future<void> connect(CastDevice device) async {
    if ((Platform.isIOS || Platform.isAndroid) &&
        device.backend == CastBackend.chromecast) {
      return _connectChromecast(device);
    }
    if (_activeDevice?.id == device.id) return;
    final ps = PlayerService();
    final wasPlaying = ps.isPlayingNotifier.value;
    final resumeSong = ps.currentSongNotifier.value;
    final resumePosition = ps.positionNotifier.value;
    final previousWasChromecast =
        _activeDevice?.backend == CastBackend.chromecast;
    if (previousWasChromecast && isChangingOutputNotifier.value) {
      throw PlatformException(
        code: 'CAST_BUSY',
        message: 'Wait for the current Cast output change.',
      );
    }
    if (previousWasChromecast) isChangingOutputNotifier.value = true;
    try {
      // Chromecast can disappear while still playing. A DLNA switch may
      // proceed, but only a confirmed STOP can auto-start the new receiver.
      final previousReceiverStopped = previousWasChromecast
          ? await ps.runOutputTransition((_) =>
              _disconnectChromecast(allowUnconfirmedDetach: true))
          : true;
      if (!previousWasChromecast) {
        await disconnect(resumeLocal: false);
      }
      _wasPlayingBeforeCast = wasPlaying;

    // Pause while the local transport still owns playback. Once _activeDevice
    // is set, PlayerService.pause() delegates to the cast receiver instead,
    // leaving the phone's audio engine playing during the handoff (#434).
    // Do this even if the UI reports paused: it also settles a stale engine.
    await ps.pause();

    _activeDevice = device;
    activeDeviceNotifier.value = device;
    isActiveNotifier.value = true;
    remoteVolumeNotifier.value = null;

    if (device.backend == CastBackend.chromecast) {
      await _chromecast.connect(device);
      final v = await _chromecast.getVolume();
      if (v != null && v >= 0) remoteVolumeNotifier.value = v.clamp(0.0, 1.0);
    } else {
      _selectDlnaRoute(device);
    }

    if (wasPlaying && resumeSong != null) {
      await delegatePlay(
        resumeSong,
        autoplay: previousReceiverStopped,
      );
      if (resumePosition.inSeconds > 3) {
        await delegateSeek(resumePosition);
      }
    }
    if (!previousReceiverStopped) {
      errorNotifier.value =
          'The previous receiver did not confirm Stop. This output is paused to avoid simultaneous playback.';
    }

    unawaited(ps.refreshNotificationState());
    } finally {
      if (previousWasChromecast) isChangingOutputNotifier.value = false;
    }
  }

  /// Select a phone-local output without leaving a phantom Cast owner behind.
  /// An unconfirmed remote STOP never triggers automatic local playback.
  Future<bool> selectLocalOutputRoute(String routeId) async {
    if (_activeDevice?.backend != CastBackend.chromecast) {
      if (_activeDevice?.backend == CastBackend.dlna) {
        await disconnect(resumeLocal: false);
      }
      return _chromecast.selectOutputRoute(routeId);
    }
    if (isChangingOutputNotifier.value) {
      throw PlatformException(code: 'CAST_BUSY',
          message: 'Wait for the current output change.');
    }
    isChangingOutputNotifier.value = true;
    try {
      return await PlayerService().runOutputTransition((local) async {
        final stoppedReceiver = await _disconnectChromecast(
          allowUnconfirmedDetach: true,
        );
        final selected = await _chromecast.selectOutputRoute(routeId);
        if (selected && stoppedReceiver && local.wasPlaying &&
            local.isCurrent()) {
          // The local engine may still be parked at the pre-Cast playhead.
          // Seek before resuming so it cannot briefly play the old position.
          await PlayerService().seek(local.position);
          if (local.isCurrent()) await local.resumeLocal();
        } else if (!stoppedReceiver) {
          errorNotifier.value =
              'Returned to local output paused. The previous receiver may still be playing.';
        }
        return selected;
      });
    } finally {
      isChangingOutputNotifier.value = false;
      unawaited(PlayerService().refreshNotificationState());
    }
  }

  Future<void> disconnect({bool resumeLocal = true, bool leaveReceiver = false}) async {
    if ((Platform.isIOS || Platform.isAndroid) &&
        _activeDevice?.backend == CastBackend.chromecast) {
      if (isChangingOutputNotifier.value) {
        throw PlatformException(
          code: 'CAST_BUSY',
          message: 'Wait for the current Cast connection change.',
        );
      }
      isChangingOutputNotifier.value = true;
      try {
        await PlayerService().runOutputTransition((local) async {
          final stoppedReceiver = await _disconnectChromecast(
            leaveReceiver: leaveReceiver,
          );
          // A lost/abandoned receiver may continue playing independently.
          // Never auto-start the phone unless STOP was acknowledged.
          if (resumeLocal && stoppedReceiver && local.wasPlaying && local.isCurrent()) {
            await local.resumeLocal();
            // A paused attached engine can resume the same recording at its
            // pre-Cast position. Restore the receiver's captured position too.
            if (local.isCurrent()) await PlayerService().seek(local.position);
          }
        });
      } catch (_) {
        errorNotifier.value = 'Receiver shutdown is unconfirmed. Retry Stop casting when the receiver is reachable.';
        rethrow;
      } finally {
        isChangingOutputNotifier.value = false;
        _drainCastCompletion();
      }
      return;
    }
    if (_activeDevice == null) return;
    _tearingDown = true;
    _pollTimer?.cancel();
    _pollTimer = null;

    final wasPlaying = _wasPlayingBeforeCast;
    _wasPlayingBeforeCast = false;
    final dev = _activeDevice!;
    currentCastLoadId = null;
    _sourceRevision++;
    _completion.clear();
    _pendingCastLoadId = null;
    _lastCcStatus = null;
    _presentationRevision++;
    _activeDevice = null;
    _currentSong = null;
    _receiverSkipInFlight = false;
    activeDeviceNotifier.value = null;
    isActiveNotifier.value = false;
    remoteVolumeNotifier.value = null;

    try {
      if (dev.backend == CastBackend.chromecast) {
        await _chromecast.disconnect();
      } else {
        if (dev.controlUrl != null) {
          try {
            await _dlna.stop(dev.controlUrl!);
          } catch (_) {}
        }
        _unselectDlnaRoute();
      }
      await CastContentServer.instance.stop();
    } finally {
      _tearingDown = false;
    }

    final ps = PlayerService();
    if (resumeLocal && wasPlaying && ps.currentSongNotifier.value != null) {
      // Local engine may hold a stale track after remote-side song changes;
      // replay the current song so resume lands on what the UI shows.
      final song = ps.currentSongNotifier.value!;
      final pos = ps.positionNotifier.value;
      unawaited(ps.play(song));
      if (pos.inSeconds > 3) {
        unawaited(ps.seek(pos).then((_) => ps.resume()).catchError((_) {}));
      }
    }
    unawaited(ps.refreshNotificationState());
  }

  void _claimCastRemote(
    CastDevice device,
    Song? song,
    Duration position,
    bool playing,
  ) {
    _activeDevice = device;
    _currentSong = song;
    activeDeviceNotifier.value = device;
    isActiveNotifier.value = true;
    remoteVolumeNotifier.value = null;
    final ps = PlayerService();
    ps.isPlayingNotifier.value = playing;
    ps.positionNotifier.value = position;
  }

  void _releaseCastRemote() {
    currentCastLoadId = null;
    _sourceRevision++;
    _completion.clear();
    _pendingCastLoadId = null;
    _lastCcStatus = null;
    _presentationRevision++;
    _activeDevice = null;
    _currentSong = null;
    _wasPlayingBeforeCast = false;
    _receiverSkipInFlight = false;
    _cancelCcSuspension();
    activeDeviceNotifier.value = null;
    isActiveNotifier.value = false;
    remoteVolumeNotifier.value = null;
    PlayerService().isBufferingNotifier.value = false;
    PlayerService().isPlayingNotifier.value = false;
  }

  Future<void> _connectChromecast(CastDevice device) async {
    if (_activeDevice?.id == device.id) return;
    if (isChangingOutputNotifier.value) {
      throw PlatformException(
        code: 'CAST_BUSY',
        message: 'Wait for the current Cast connection change.',
      );
    }
    isChangingOutputNotifier.value = true;
    errorNotifier.value = null;
    final ps = PlayerService();
    var selectedDevice = device;
    var previousReceiverStopped = true;
    try {
      await ps.runOutputTransition((local) async {
        if (_activeDevice?.backend == CastBackend.chromecast) {
          // The user explicitly requested a different receiver. If the old
          // receiver cannot acknowledge STOP, detach its sender rather than
          // blocking all further output changes. The new receiver must start
          // paused until the user explicitly plays it.
          previousReceiverStopped = await _disconnectChromecast(
            allowUnconfirmedDetach: true,
          );
        } else {
          await disconnect(resumeLocal: false);
        }
        await handoffToCast(
          local: local,
          allowAutoPlay: previousReceiverStopped,
          connect: () async {
            await _chromecast.connect(device);
            try {
              final name = (await _chromecast.sessionInfo())['name'] as String?;
              if (name != null && name.trim().isNotEmpty)
                selectedDevice = CastDevice(
                  id: device.id,
                  name: name.trim(),
                  backend: device.backend,
                );
            } catch (_) {}
          },
          preparePaused: () async {
            final song = local.song!;
            final url = await _receiverCastUrl(song);
            if (url == null) {
              throw PlatformException(
                code: 'CAST_SOURCE',
                message: 'This track has no receiver-accessible audio source.',
              );
            }
            await _loadCastSong(
              song,
              url,
              autoplay: false,
              position: local.position,
            );
          },
          play: _chromecast.play,
          disconnect: () async {
            await _chromecast.disconnect();
            await CastContentServer.instance.stop();
          },
          claimRemote: () => _claimCastRemote(
            selectedDevice,
            local.song,
            local.position,
            false,
          ),
          releaseRemote: _releaseCastRemote,
        );
        ps.isPlayingNotifier.value =
            previousReceiverStopped && local.wasPlaying && local.song != null;
        errorNotifier.value = previousReceiverStopped
            ? null
            : 'The previous receiver did not confirm Stop. This receiver is paused to avoid playing on both. Stop the previous receiver separately if necessary.';
        if (local.song != null) unawaited(_presentReceiverSong(local.song!));
        // A volume query is ancillary; its failure cannot undo a confirmed load.
        try {
          final volume = await _chromecast.getVolume();
          if (volume != null) {
            remoteVolumeNotifier.value = volume.clamp(0.0, 1.0);
          }
        } catch (_) {}
      });
    } on CastHandoffCancelled {
      throw PlatformException(
        code: 'CAST_CANCELLED',
        message:
            'Playback changed while connecting. Select the receiver again.',
      );
    } on CastHandoffUncertain {
      errorNotifier.value = 'Receiver shutdown is unconfirmed. Retry Stop casting before switching to local audio.';
      throw PlatformException(
        code: 'CAST_UNCERTAIN',
        message: errorNotifier.value,
      );
    } finally {
      isChangingOutputNotifier.value = false;
      _drainCastCompletion();
      unawaited(ps.refreshNotificationState());
    }
  }

  Future<bool> _nativeCastConnected() async {
    try {
      // A missing or failed probe is not proof that the receiver stopped.
      final status = await _chromecast.sessionInfo().timeout(
        const Duration(seconds: 3),
      );
      return status['connected'] != false;
    } catch (_) {
      return true;
    }
  }

  void _cancelCcSuspension() {
    _ccSuspensionTimer?.cancel();
    _ccSuspensionTimer = null;
    _ccSessionRevision++;
  }

  void _scheduleCcSuspensionCheck() {
    _cancelCcSuspension();
    if (!Platform.isAndroid ||
        _activeDevice?.backend != CastBackend.chromecast ||
        _tearingDown ||
        isChangingOutputNotifier.value) {
      return;
    }
    final device = _activeDevice;
    final revision = _ccSessionRevision;
    // Temporary SDK suspension must not immediately steal remote ownership.
    _ccSuspensionTimer = Timer(const Duration(seconds: 10), () {
      unawaited(() async {
        if (revision != _ccSessionRevision ||
            !identical(_activeDevice, device)) return;
        if (!(await _nativeCastConnected()) &&
            revision == _ccSessionRevision &&
            identical(_activeDevice, device)) {
          _recoverLostChromecast(shutdownConfirmed: false);
        }
      }());
    });
  }

  void _recoverLostChromecast({
    required bool shutdownConfirmed,
    int retryAttempt = 0,
  }) {
    final device = _activeDevice;
    final sessionRevision = _ccSessionRevision;
    if (device?.backend != CastBackend.chromecast ||
        _tearingDown ||
        isChangingOutputNotifier.value) return;
    // Release in PlayerService's queue, *not* the native event callback, so a
    // delayed end event cannot release a replacement receiver or selection.
    unawaited(
      recoverLostCastSession(
        serialize: (work) =>
            PlayerService().runOutputTransition((_) => work()),
        stillOwnsSession: () =>
            identical(_activeDevice, device) &&
            sessionRevision == _ccSessionRevision &&
            !_tearingDown &&
            !isChangingOutputNotifier.value,
        releaseRemote: () {
          _releaseCastRemote();
          errorNotifier.value = shutdownConfirmed
              ? null
              : 'Cast connection lost. Playback on the receiver may continue; stop it there if needed.';
        },
        cleanup: () async {
          try {
            if (!shutdownConfirmed) await _chromecast.abandon();
            await CastContentServer.instance.stop();
          } finally {
            unawaited(PlayerService().refreshNotificationState());
          }
        },
      ).then<void>((_) {}).catchError((Object error) {
        // runOutputTransition can reject before running its callback if an
        // external output lease cannot be released. Do not silently abandon
        // this recovery: retry while this exact receiver still owns playback.
        if (!identical(_activeDevice, device) ||
            sessionRevision != _ccSessionRevision ||
            _tearingDown ||
            isChangingOutputNotifier.value) return;
        debugPrint('[Cast] Lost-session recovery failed: $error');
        errorNotifier.value =
            'Cast disconnected. Retrying return to this device; playback may still continue on the receiver.';
        if (retryAttempt < 3) {
          Timer(Duration(seconds: 1 << retryAttempt), () {
            if (identical(_activeDevice, device) &&
                sessionRevision == _ccSessionRevision &&
                !isChangingOutputNotifier.value) {
              _recoverLostChromecast(
                shutdownConfirmed: shutdownConfirmed,
                retryAttempt: retryAttempt + 1,
              );
            }
          });
        }
      }),
    );
  }

  /// True only when the native sender confirmed receiver shutdown. When the
  /// device has vanished, detach the sender and return control to the phone
  /// *paused*. Explicit Leave Cast uses the same safe local-only fallback.
  Future<bool> _disconnectChromecast({
    bool leaveReceiver = false,
    bool allowUnconfirmedDetach = false,
  }) async {
    _tearingDown = true;
    _cancelCcSuspension();
    try {
      var stoppedReceiver = false;
      if (!leaveReceiver && await _nativeCastConnected()) {
        try {
          final disconnect = _chromecast.disconnectConfirmed();
          // The channel may report success after an already-lost session:
          // only the SDK's explicit STOP confirmation authorizes autoplay.
          if (allowUnconfirmedDetach) {
            stoppedReceiver = await disconnect.timeout(
              const Duration(seconds: 8),
            );
          } else {
            stoppedReceiver = await disconnect;
          }
        } catch (_) {
          // A normal Stop request must still refuse automatic dual playback.
          // A deliberate receiver switch is allowed to detach the old sender,
          // but the destination stays paused until the user resumes.
          if (!allowUnconfirmedDetach && await _nativeCastConnected()) rethrow;
        }
      }
      if (!stoppedReceiver) {
        try {
          await _chromecast.abandon();
        } catch (_) {
          // Local ownership must remain recoverable even after SDK teardown
          // errors; abandon never claims that the receiver was stopped.
        }
      }
      _releaseCastRemote();
      try {
        await CastContentServer.instance.stop();
      } catch (_) {}
      errorNotifier.value = stoppedReceiver
          ? null
          : 'Returned to this device. The Cast receiver may still be playing.';
      return stoppedReceiver;
    } finally {
      _tearingDown = false;
    }
  }

  // Called by PlayerService._playInternal hook. Returns true if handled.
  Future<bool> delegatePlay(Song song, {bool autoplay = true}) async {
    if (_activeDevice == null) return false;
    final ps = PlayerService();
    final String? url;
    if ((Platform.isIOS || Platform.isAndroid) &&
        _activeDevice?.backend == CastBackend.chromecast) {
      url = await _receiverCastUrl(song);
    } else {
      final resolved = await RemoteSourceService.instance.resolveHttpPlayback(
        song,
      );
      url = resolved?.url ?? await _serveFromPhone(song);
    }
    if (url == null) {
      if ((Platform.isIOS || Platform.isAndroid) &&
          _activeDevice?.backend == CastBackend.chromecast) {
        throw PlatformException(
          code: 'CAST_SOURCE',
          message: 'This track cannot be sent to the receiver. Stop casting to play it on this device.',
        );
      }
      // Content-URI locals and unresolvable sources stay local-only.
      return false;
    }
    final dev = _activeDevice!;
    if (dev.backend == CastBackend.dlna) {
      final control = dev.controlUrl;
      if (control == null) return false;
      await _dlna.setUri(control, url, title: song.title);
      // A new receiver must remain paused when the previous Chromecast
      // cannot confirm STOP; media URI staging alone is safe.
      if (autoplay) await _dlna.play(control);
      _startDlnaPolling(control, dev.renderingControlUrl);
    } else {
      await _loadCastSong(song, url, autoplay: autoplay);
    }
    errorNotifier.value = null;
    _currentSong = song;
    ps.currentSongNotifier.value = song;
    ps.durationNotifier.value = song.duration;
    ps.positionNotifier.value = Duration.zero;
    ps.isPlayingNotifier.value = autoplay;
    _drainCastCompletion();
    if (dev.backend == CastBackend.chromecast)
      unawaited(_presentReceiverSong(song));
    return true;
  }

  Future<void> _loadCastSong(
    Song song,
    String url, {
    bool autoplay = true,
    Duration position = Duration.zero,
  }) async {
    final loadId =
        '${DateTime.now().microsecondsSinceEpoch}:${++_loadRevision}';
    final device = _activeDevice;
    final previousLoadId = currentCastLoadId;
    final previousSong = _currentSong;
    final previousStatus = _lastCcStatus;
    currentCastLoadId = loadId;
    _pendingCastLoadId = loadId;
    _syncPreparationState();
    _lastCcStatus = null;
    _completion.begin(loadId);
    try {
      String? art;
      try {
        art = await castArtwork(
          song,
          stillCurrent: () => currentCastLoadId == loadId,
        ).timeout(const Duration(seconds: 5));
      } catch (_) {}
      if (currentCastLoadId != loadId) throw const CastHandoffCancelled();
      await _chromecast.load(
        url,
        title: song.title,
        artist: song.artist,
        album: song.album,
        trackId: song.id,
        loadId: loadId,
        artworkUrl: art,
        autoplay: autoplay,
        position: position,
        contentType: castAudioContentType(url, song.fileType),
      );
      _completion.commit(loadId);
    } catch (_) {
      // A failed/late reply does not establish what is actually on the TV.
      // Reconcile against native SDK media status, without reviving an old
      // session or overwriting a more recent load.
      Map<String, dynamic> status = {};
      try {
        status = await _chromecast.sessionInfo();
      } catch (_) {}
      if (identical(device, _activeDevice) && currentCastLoadId == loadId) {
        if (status['loadId'] == loadId &&
            status['trackId'] == song.id &&
            status['sourceError'] != true) {
          _completion.commit(loadId);
          _lastCcStatus = status;
          _completion.observe(status);
          return; // Receiver confirms the requested media despite the lost reply.
        }
        if (previousLoadId != null &&
            status['loadId'] == previousLoadId &&
            status['trackId'] == previousSong?.id) {
          _completion.rollback(loadId);
          currentCastLoadId = previousLoadId;
          _currentSong = previousSong;
          _lastCcStatus = {...?previousStatus, ...status};
          _completion.observe(status);
        } else {
          currentCastLoadId = null;
          _completion.clear();
          _currentSong = null;
          _lastCcStatus = null;
          PlayerService().isBufferingNotifier.value = false;
        }
      }
      rethrow;
    } finally {
      if (_pendingCastLoadId == loadId) _pendingCastLoadId = null;
      _syncPreparationState();
    }
  }

  Future<void> setReceiverView(String view) async {
    if (!const ['nowplaying', 'lyrics', 'video'].contains(view) ||
        _activeDevice?.backend != CastBackend.chromecast)
      return;
    final device = _activeDevice;
    final revision = ++_presentationRevision;
    await _chromecast.sendCustom({'type': 'view', 'view': view});
    if (!identical(device, _activeDevice) || revision != _presentationRevision)
      return;
    receiverViewNotifier.value = view;
    final song = _currentSong;
    if (song != null)
      await _presentReceiverSong(song, reportError: true, sendView: false);
  }

  Future<void> _presentReceiverSong(
    Song song, {
    bool reportError = false,
    bool sendView = true,
  }) async {
    final revision = ++_presentationRevision;
    final device = _activeDevice;
    bool current() =>
        revision == _presentationRevision &&
        identical(device, _activeDevice) &&
        _currentSong?.id == song.id;
    try {
      final view = receiverViewNotifier.value;
      if (sendView)
        await _chromecast.sendCustom({'type': 'view', 'view': view});
      if (!current()) return;
      if (view == 'lyrics') {
        final lyrics = await LyricsService().loadLyricsForSong(
          song,
          fetchOnline: true,
          stillCurrent: current,
        );
        if (current())
          await _chromecast.sendCustom(castLyrics(song.id, lyrics));
      } else if (view == 'video') {
        final id = await castMusicVideo(song);
        if (!current()) return;
        await _chromecast.sendCustom({
          'type': 'video',
          'trackId': song.id,
          if (id != null) 'videoId': id,
        });
        if (id == null && reportError)
          throw PlatformException(
            code: 'CAST_VIDEO',
            message: 'No matching music video was found for this song.',
          );
      }
    } catch (error) {
      if (current()) {
        errorNotifier.value =
            'The receiver could not display this view. Try again.';
        if (reportError) rethrow;
      }
    }
  }

  Future<void> delegatePause() async {
    if (_activeDevice == null) return;
    if (_activeDevice!.backend == CastBackend.dlna) {
      await _dlna.pause(_activeDevice!.controlUrl!);
    } else if (_lastCcStatus?['finished'] != true) {
      await _chromecast.pause();
    }
    PlayerService().isBufferingNotifier.value = false;
    PlayerService().isPlayingNotifier.value = false;
  }

  Future<void> delegateResume() async {
    if (_activeDevice == null) return;
    if (_activeDevice!.backend == CastBackend.dlna) {
      await _dlna.play(_activeDevice!.controlUrl!);
    } else {
      await _chromecast.resume();
    }
    PlayerService().isPlayingNotifier.value = true;
  }

  Future<void> delegateSeek(Duration position) async {
    if (_activeDevice == null) return;
    // The displayed recording is changing. In particular, reloading a finished
    // previous track here would invalidate the pending replacement source.
    if (_sourcePreparations > 0 || _pendingCastLoadId != null) return;
    if (_activeDevice!.backend == CastBackend.dlna) {
      await _dlna.seek(_activeDevice!.controlUrl!, position);
    } else if (_lastCcStatus?['finished'] == true && _currentSong != null) {
      final song = _currentSong!;
      final url = await _receiverCastUrl(song);
      if (url == null) throw StateError('The Cast source is unavailable.');
      await _loadCastSong(song, url, autoplay: false, position: position);
    } else {
      await _chromecast.seek(position);
    }
    PlayerService().positionNotifier.value = position;
  }

  Future<void> delegateStop() async {
    if (_activeDevice == null) return;
    if (_activeDevice!.backend == CastBackend.dlna) {
      await _dlna.stop(_activeDevice!.controlUrl!);
    } else {
      await _disconnectChromecast();
    }
  }

  Future<void> delegateSetVolume(double volume) async {
    if (_activeDevice == null) return;
    final v = volume.clamp(0.0, 1.0);
    if (_activeDevice!.backend == CastBackend.dlna) {
      final rc = _activeDevice!.renderingControlUrl;
      if (rc == null) return;
      await _dlna.setVolume(rc, (v * 100).round().clamp(0, 100));
    } else {
      await _chromecast.setVolume(v);
    }
    remoteVolumeNotifier.value = v;
  }

  // ==================== native route bridge ====================

  void _publishDlnaRoutes(List<CastDevice> dlnaDevices) {
    _invokeDlnaRoute('publishRoutes', {
      'routes': [
        for (final d in dlnaDevices) {'id': d.id, 'name': d.name},
      ],
    });
  }

  void _selectDlnaRoute(CastDevice d) =>
      _invokeDlnaRoute('selectRoute', {'id': d.id});

  void _unselectDlnaRoute() => _invokeDlnaRoute('unselectRoute', {});

  void _invokeDlnaRoute(String method, Map<String, dynamic> args) {
    // ignore: unawaited_futures
    _dlnaRouteChannel.invokeMethod<void>(method, args).catchError((_) {});
  }

  // ==================== chromecast native events ====================

  void _listenChromecastEvents() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (_ccEventsSub != null) return;
    _ccEventsSub = _chromecast.events.listen(
      (e) {
        final event = e['event'] as String?;
        final reportedDeviceId = e['deviceId'] as String?;
        // SDK callbacks and queued EventChannel messages may arrive after a
        // mid-play switch. Never let receiver A's status/end overwrite B.
        if (!castEventMatchesReceiver(
          reportedDeviceId: reportedDeviceId,
          activeDeviceId: _activeDevice?.backend == CastBackend.chromecast
              ? _activeDevice?.id
              : null,
        )) return;
        switch (event) {
          case 'sessionStarted':
          case 'sessionResumed':
            _cancelCcSuspension();
            break;
          case 'sessionSuspended':
            // Android may recover a brief Wi-Fi interruption. Give the SDK a
            // bounded reconnect window before returning control to the phone.
            // iOS suspends Cast normally in the background: never infer that
            // its receiver powered off solely from a suspension callback.
            _scheduleCcSuspensionCheck();
            break;
          case 'sessionEnded':
            _cancelCcSuspension();
            if (Platform.isIOS || Platform.isAndroid) {
              _recoverLostChromecast(
                shutdownConfirmed: e['shutdownConfirmed'] == true,
              );
              break;
            }
            if (!_tearingDown && isActive) unawaited(disconnect());
            break;
          case 'receiverMessage':
            try {
              final data = e['data'] is String
                  ? jsonDecode(e['data'] as String)
                  : e['data'];
              if (data is Map &&
                  data['type'] == 'hello' &&
                  _currentSong != null)
                unawaited(_presentReceiverSong(_currentSong!));
              if (data is Map && data['type'] == 'transport') {
                _onReceiverTransport(data);
              }
              if (data is Map &&
                  data['type'] == 'view' &&
                  const [
                    'nowplaying',
                    'lyrics',
                    'video',
                  ].contains(data['view'])) {
                receiverViewNotifier.value = data['view'] as String;
                if (_currentSong != null)
                  unawaited(_presentReceiverSong(_currentSong!));
              }
            } catch (_) {}
            break;
          case 'status':
            _handleCcStatus(e);
            break;
          case 'volume':
            if ((Platform.isIOS || Platform.isAndroid) &&
                _activeDevice?.backend != CastBackend.chromecast) {
              break;
            }
            final v = (e['volume'] as num?)?.toDouble();
            if (v != null) {
              remoteVolumeNotifier.value = v.clamp(0.0, 1.0);
            }
            break;
          case 'dlnaRouteSelected':
            _handleDlnaRouteSelected(e);
            break;
          case 'dlnaRouteUnselected':
            if (!_tearingDown && _activeDevice?.backend == CastBackend.dlna) {
              unawaited(disconnect());
            }
            break;
          case 'dlnaVolume':
            final v = (e['volume'] as num?)?.toDouble();
            if (v != null && _activeDevice != null) {
              unawaited(PlayerService().setVolume(v));
            }
            break;
        }
      },
      onError: (_) {},
      onDone: () => _ccEventsSub = null,
    );
  }

  /// Native Android and iOS share this receiver namespace and queue owner.
  /// CAF has only the active recording on mobile; next/previous must travel
  /// back to PlayerService instead of seeking the current media item to zero.
  void _onReceiverTransport(Map<dynamic, dynamic> message) {
    if (_activeDevice?.backend != CastBackend.chromecast ||
        _tearingDown ||
        isChangingOutputNotifier.value ||
        _pendingCastLoadId != null ||
        _receiverSkipInFlight) {
      return;
    }
    final action = castReceiverTransport(
      message,
      currentTrackId: _currentSong?.id,
      currentLoadId: currentCastLoadId,
    );
    if (action == null ||
        PlayerService().currentSongNotifier.value?.id != _currentSong?.id) {
      return;
    }
    _receiverSkipInFlight = true;
    final device = _activeDevice;
    unawaited(() async {
      try {
        if (action == CastReceiverTransport.next) {
          await PlayerService().next();
        } else {
          // Receiver Previous is a track-navigation command, unlike the
          // phone's Previous button which intentionally restarts after 3s.
          await PlayerService().previous(allowRestart: false);
        }
      } catch (error) {
        if (identical(device, _activeDevice)) {
          errorNotifier.value = 'Could not change songs on the receiver. Try again.';
        }
      } finally {
        _receiverSkipInFlight = false;
      }
    }());
  }

  void _handleCcStatus(Map<String, dynamic> e) {
    if (_activeDevice?.backend != CastBackend.chromecast) return;
    // Record both the in-flight and prior load before checking presentation:
    // a short track can finish before LOAD replies and the song UI commits.
    _completion.observe(e);
    final ps = PlayerService();
    if (e['loadId'] is String && e['loadId'] != currentCastLoadId) return;
    if (_pendingCastLoadId != null) return;
    if (e['trackId'] is String &&
        e['trackId'] != ps.currentSongNotifier.value?.id)
      return;
    _lastCcStatus = Map.of(e);
    _drainCastCompletion();
    if (e['finished'] == true) {
      ps.isBufferingNotifier.value = false;
      return;
    }
    if (e['sourceError'] == true) {
      errorNotifier.value =
          'The receiver could not play this audio format or reach its source.';
      ps.isBufferingNotifier.value = false;
      ps.isPlayingNotifier.value = false;
      return;
    }
    ps.isBufferingNotifier.value = e['buffering'] == true;
    final position = (e['position'] as num?)?.toInt();
    final duration = (e['duration'] as num?)?.toInt();
    final playing = e['playing'] as bool?;
    if (playing != null) ps.isPlayingNotifier.value = playing;
    if (position != null) {
      ps.positionNotifier.value = Duration(milliseconds: position);
    }
    if (duration != null && duration > 0) {
      ps.durationNotifier.value = Duration(milliseconds: duration);
    }
  }

  void _drainCastCompletion() {
    final song = _currentSong;
    final ps = PlayerService();
    final event = _completion.takePending(
      ready:
          _activeDevice?.backend == CastBackend.chromecast &&
          !isChangingOutputNotifier.value &&
          _pendingCastLoadId == null &&
          song != null &&
          ps.currentSongNotifier.value?.id == song.id,
    );
    if (event == null || event['trackId'] != song?.id) return;
    _lastCcStatus = event;
    unawaited(ps.castTrackFinished(song!.id, event['loadId'] as String));
  }

  /// Replay only a receiver-confirmed prior load after PlayerService restores
  /// the selected queue occurrence following a failed track replacement.
  void replayConfirmedStatus() {
    final status = _lastCcStatus;
    if (status != null) _handleCcStatus(status);
    _drainCastCompletion();
  }

  void _handleDlnaRouteSelected(Map<String, dynamic> e) {
    if (_tearingDown || isActive) return;
    final id = e['id'] as String?;
    if (id == null) return;
    final match = devicesNotifier.value.where((d) => d.id == id).firstOrNull;
    if (match != null && match.backend == CastBackend.dlna) {
      unawaited(connect(match));
    }
  }

  Future<String?> _receiverCastUrl(Song song) async {
    final revision = ++_sourceRevision;
    _sourcePreparations++;
    _syncPreparationState();
    bool current() => revision == _sourceRevision && !_tearingDown;
    try {
      final source = _resolveReceiverCastUrl(song, current);
      if (song.sourceType != 'lokal') return await source;
      return await source.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      if (revision == _sourceRevision) _sourceRevision++;
      throw TimeoutException(
        'The Cast source did not become available. Retry this song.',
      );
    } finally {
      _sourcePreparations--;
      _syncPreparationState();
    }
  }

  Future<String?> _resolveReceiverCastUrl(
    Song song,
    bool Function() current,
  ) async {
    final resolved = await RemoteSourceService.instance.resolveHttpPlayback(
      song,
    );
    if (!current()) throw const CastHandoffCancelled();
    if (resolved != null) {
      final direct = receiverDirectUrl(resolved.url, headers: resolved.headers);
      if (direct != null) return direct;
      if (song.sourceType != 'lokal')
        return _serveFromPhone(song, stillCurrent: current);
      // Relay authenticated HTTP without waiting for a complete PC download.
      // Account headers stay on the phone and never enter receiver metadata.
      return CastContentServer.instance.relay(
        resolved.url,
        filename: 'track.${song.fileType.toLowerCase()}',
        headers: resolved.headers,
        stillCurrent: current,
      );
    }
    return receiverDirectUrl(song.filePath) ??
        await _serveFromPhone(song, stillCurrent: current);
  }

  /// Last-resort cast source: serve the bytes from this phone via the
  /// embedded HTTP server. Covers local files, SMB, and cached network songs
  /// (including formats the local engine can't decode — the renderer decodes).
  Future<String?> _serveFromPhone(
    Song song, {
    bool Function()? stillCurrent,
  }) async {
    try {
      String? path;
      if (song.isNetworkSource) {
        path = await RemoteSourceService.instance.ensureLocal(song);
      } else {
        path = await castLocalFile(song.filePath, extension: song.fileType);
      }
      if (path == null || !(stillCurrent?.call() ?? true)) return null;
      final ext = song.fileType.toLowerCase();
      final title = song.title.replaceAll(RegExp(r'[^A-Za-z0-9._\- ]'), '');
      return await CastContentServer.instance.serve(
        path,
        filename: '${title.isEmpty ? 'track' : title}.$ext',
        stillCurrent: stillCurrent,
      );
    } on NetworkAccessDenied catch (error) {
      throw PlatformException(
        code: 'CAST_NETWORK_PERMISSION',
        message: error.message,
      );
    } catch (_) {
      return null;
    }
  }

  void _startDlnaPolling(String controlUrl, String? renderingControlUrl) {
    _pollTimer?.cancel();
    var tick = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_activeDevice == null) return;
      final info = await _dlna.getPosition(controlUrl);
      if (info == null) return;
      final ps = PlayerService();
      ps.positionNotifier.value = info.position;
      if (info.duration.inMilliseconds > 0) {
        ps.durationNotifier.value = info.duration;
      }
      ps.isPlayingNotifier.value = info.playing;
      // Volume poll is half-rate; each tick is already 2 SOAP calls.
      if (renderingControlUrl != null && tick++ % 2 == 0) {
        final v = await _dlna.getVolume(renderingControlUrl);
        if (v != null) remoteVolumeNotifier.value = v / 100.0;
      }
    });
  }
}
