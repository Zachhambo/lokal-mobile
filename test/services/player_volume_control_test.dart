import 'package:flick/models/audio_engine_type.dart';
import 'package:flick/services/casting/casting_service.dart';
import 'package:flick/models/audio_output_diagnostics.dart';
import 'package:flick/services/android_audio_processing_service.dart';
import 'package:flick/services/player_service.dart';
import 'package:flick/services/player_volume_control.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Player extends Fake implements PlayerService {
  @override
  final audioOutputDiagnosticsNotifier =
      ValueNotifier<AudioOutputDiagnostics?>(null);
  @override
  final extendedVolumeEnabledNotifier = ValueNotifier(false);
  @override
  AudioEngineType currentEngineType = AudioEngineType.normalAndroid;
  @override
  bool isCasting = false;
  @override
  bool isVolumeAvailable = true;
  @override
  double currentVolume = 1.0;
  final writes = <double>[];

  @override
  double get maxVolume =>
      extendedVolumeEnabledNotifier.value && !isCasting &&
              currentEngineType != AudioEngineType.usbDacExperimental &&
              currentEngineType != AudioEngineType.dapInternalHighRes
          ? 2.0
          : 1.0;

  @override
  Future<void> setVolume(double value) async {
    writes.add(value);
    currentVolume = value.clamp(0.0, maxVolume).toDouble();
  }

  void dispose() {
    audioOutputDiagnosticsNotifier.dispose();
    extendedVolumeEnabledNotifier.dispose();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lokal/system_volume');
  const events = MethodChannel('lokal/system_volume/events');
  late _Player player;
  late PlayerVolumeControl control;
  late double systemVolume;
  late List<double> systemWrites;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    systemVolume = 0.5;
    systemWrites = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'set') {
        systemVolume = (call.arguments['volume'] as num).toDouble();
        systemWrites.add(systemVolume);
      }
      return systemVolume;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, (_) async {});
    player = _Player();
    control = PlayerVolumeControl(player);
    await control.refresh();
  });

  tearDown(() async {
    control.dispose();
    await Future<void>.delayed(Duration.zero);
    player.dispose();
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(events, null);
  });

  test('toggle exposes 200 percent and notifies an already open slider', () {
    var changes = 0;
    control.addListener(() => changes++);
    expect(control.max, 1.0);
    player.extendedVolumeEnabledNotifier.value = true;
    expect(changes, 1);
    expect(control.max, 2.0);
  });

  test('150/200 percent reaches engine gain with Android at 100 percent', () async {
    player.extendedVolumeEnabledNotifier.value = true;
    await control.set(1.5);
    expect(player.writes, [1.5]);
    expect(systemWrites, [1.0]);
    expect(control.value, 1.5);
    await control.set(2.0);
    expect(player.currentVolume, 2.0);
    expect(control.value, 2.0);
    expect(AndroidJustAudioProcessingService.volumeToBoostMb(2.0), 602);
  });

  test('lowering below 100 percent removes boost and uses media volume', () async {
    player.extendedVolumeEnabledNotifier.value = true;
    await control.set(2.0);
    await control.set(0.4);
    expect(player.writes, [2.0, 1.0]);
    expect(systemWrites, [1.0, 0.4]);
    expect(control.value, 0.4);
    await control.set(0.0);
    expect(control.value, 0.0);
  });

  test('hardware-key media volume changes remain reflected while boosted', () async {
    player.extendedVolumeEnabledNotifier.value = true;
    await control.set(2.0);
    systemVolume = 0.4;
    await control.refresh();
    expect(control.value, closeTo(0.8, 0.00001));
  });

  test('disabled setting caps requests at 100 percent', () async {
    await control.set(2.0);
    expect(player.writes, [1.0]);
    expect(systemWrites, [1.0]);
    expect(control.value, 1.0);
  });

  test('Cast, direct USB and DAP retain their own volume authority', () async {
    player.extendedVolumeEnabledNotifier.value = true;
    for (final engine in [
      AudioEngineType.usbDacExperimental,
      AudioEngineType.dapInternalHighRes,
      AudioEngineType.normalAndroid,
    ]) {
      player.currentEngineType = engine;
      player.isCasting = engine == AudioEngineType.normalAndroid;
      expect(control.usesSystemVolume, isFalse);
      expect(control.max, 1.0);
      await control.set(0.3);
      expect(control.value, 0.3);
    }
    expect(player.writes, [0.3, 0.3, 0.3]);
    expect(systemWrites, isEmpty);
  });

  test('receiver volume ticks refresh the open Cast slider without phone writes', () {
    player.isCasting = true;
    var changes = 0;
    control.addListener(() => changes++);
    player.currentVolume = .42;
    CastingService.instance.remoteVolumeNotifier.value = .42;
    expect(changes, 1);
    expect(control.value, .42);
    expect(control.usesSystemVolume, isFalse);
    expect(systemWrites, isEmpty);
    expect(player.writes, isEmpty);
    CastingService.instance.remoteVolumeNotifier.value = null;
  });

  test('protected bit-perfect routes reject system and engine writes', () async {
    player.isVolumeAvailable = false;
    expect(control.available, isFalse);
    await control.set(0.5);
    expect(player.writes, isEmpty);
    expect(systemWrites, isEmpty);
  });
}
