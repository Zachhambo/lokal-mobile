import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/casting/cast_session_recovery.dart';

void main() {
  test('old receiver events are rejected after mid-song device switch', () {
    expect(
      castEventMatchesReceiver(
        reportedDeviceId: 'receiver-a',
        activeDeviceId: 'receiver-b',
      ),
      isFalse,
    );
    expect(
      castEventMatchesReceiver(
        reportedDeviceId: 'receiver-b',
        activeDeviceId: 'receiver-b',
      ),
      isTrue,
    );
    expect(
      castEventMatchesReceiver(
        reportedDeviceId: 'receiver-a',
        activeDeviceId: null,
      ),
      isFalse,
    );
    expect(
      castEventMatchesReceiver(
        reportedDeviceId: null,
        activeDeviceId: 'receiver-b',
      ),
      isTrue,
    );
  });

  test('lost receiver returns to paused local ownership without auto-play', () async {
    var castActive = true;
    var localPlaying = false;
    var resumedLocal = false;
    var cleaned = false;
    final result = await recoverLostCastSession(
      serialize: (work) => work(),
      stillOwnsSession: () => castActive,
      releaseRemote: () {
        castActive = false;
        localPlaying = false;
      },
      cleanup: () async { cleaned = true; },
    );
    expect(result, isTrue);
    expect(castActive, isFalse);
    expect(localPlaying, isFalse);
    expect(resumedLocal, isFalse);
    expect(cleaned, isTrue);
  });

  test('late session-ended event cannot release replacement receiver', () async {
    final gate = Completer<void>();
    var activeDevice = 'receiver-1';
    var released = false;
    final recovery = recoverLostCastSession(
      serialize: (work) async {
        await gate.future;
        await work();
      },
      stillOwnsSession: () => activeDevice == 'receiver-1',
      releaseRemote: () { released = true; },
      cleanup: () async {},
    );
    activeDevice = 'receiver-2';
    gate.complete();
    expect(await recovery, isFalse);
    expect(released, isFalse);
  });

  test('failed cleanup cannot hold the phone hostage', () async {
    var active = true;
    final result = await recoverLostCastSession(
      serialize: (work) => work(),
      stillOwnsSession: () => active,
      releaseRemote: () { active = false; },
      cleanup: () async { throw StateError('SDK session already gone'); },
    );
    expect(result, isTrue);
    expect(active, isFalse);
  });

  test('serializing waits for an in-flight output transition', () async {
    final gate = Completer<void>();
    var active = true;
    var released = false;
    final recovery = recoverLostCastSession(
      serialize: (work) async {
        await gate.future;
        await work();
      },
      stillOwnsSession: () => active,
      releaseRemote: () {
        released = true;
        active = false;
      },
      cleanup: () async {},
    );
    expect(released, isFalse);
    gate.complete();
    expect(await recovery, isTrue);
    expect(released, isTrue);
  });
}
