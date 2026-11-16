import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/casting/casting_service.dart';
import 'package:flick/services/uac2_service.dart';

/// The phone's slider controls STREAM_MUSIC; direct output and casting retain
/// their existing gain/hardware controls. Never mirror phone volume into USB.
class PlayerVolumeControl extends ChangeNotifier with WidgetsBindingObserver {
  PlayerVolumeControl(this.player) {
    WidgetsBinding.instance.addObserver(this);
    player.audioOutputDiagnosticsNotifier.addListener(_changed);
    player.extendedVolumeEnabledNotifier.addListener(_changed);
    CastingService.instance.remoteVolumeNotifier.addListener(_changed);
    Uac2Service.instance.addStatusListener(_routeChanged);
    if (_isAndroid) {
      _subscription = _events.listen((value) {
        if (_disposed) return;
        _systemVolume = (value as num).toDouble();
        notifyListeners();
      }, onError: (Object _) {});
      unawaited(refresh());
    }
  }

  static const _channel = MethodChannel('lokal/system_volume');
  static final _events = const EventChannel('lokal/system_volume/events')
      .receiveBroadcastStream();
  final PlayerService player;
  StreamSubscription<dynamic>? _subscription;
  double? _systemVolume;
  bool _disposed = false;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  bool get usesSystemVolume =>
      _isAndroid &&
      !player.isCasting &&
      player.currentEngineType != AudioEngineType.usbDacExperimental &&
      player.currentEngineType != AudioEngineType.dapInternalHighRes;
  bool get available =>
      player.isVolumeAvailable && (!usesSystemVolume || _systemVolume != null);
  double get max => player.maxVolume;
  double get value =>
      (usesSystemVolume
              ? (_systemVolume ?? 0) * math.max(1.0, player.currentVolume)
              : player.currentVolume)
          .clamp(0.0, max)
          .toDouble();

  void _routeChanged(Uac2DeviceStatus? _) => _changed();

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    try {
      final volume = await _channel.invokeMethod<num>('get');
      if (_disposed || volume == null) return;
      _systemVolume = volume.toDouble();
      notifyListeners();
    } on PlatformException {
      /* Keep the slider unavailable until Android responds. */
    } on MissingPluginException {
      /* Unsupported host. */
    }
  }

  Future<void> set(double volume) async {
    if (!volume.isFinite || !available) return;
    if (!usesSystemVolume) {
      await player.setVolume(volume);
      _changed();
      return;
    }
    try {
      // 0–100 % remains Android media volume. Above that, keep Android at
      // unity and apply the extra gain through the active playback engine.
      // Reset engine gain below 100 % so lowering the slider removes boost.
      final target = volume.clamp(0.0, max).toDouble();
      await player.setVolume(math.max(1.0, target));
      final applied = await _channel.invokeMethod<num>('set', {
        'volume': math.min(1.0, target),
      });
      if (_disposed || applied == null) return;
      _systemVolume = applied.toDouble();
      notifyListeners();
    } on PlatformException {
      await refresh();
    } on MissingPluginException {
      /* Unsupported host. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAndroid) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    player.audioOutputDiagnosticsNotifier.removeListener(_changed);
    player.extendedVolumeEnabledNotifier.removeListener(_changed);
    CastingService.instance.remoteVolumeNotifier.removeListener(_changed);
    Uac2Service.instance.removeStatusListener(_routeChanged);
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
