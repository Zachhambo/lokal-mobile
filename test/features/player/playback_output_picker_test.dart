import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flick/features/player/widgets/playback_output_picker.dart';
import 'package:flick/providers/cast_provider.dart';
import 'package:flick/services/casting/cast_device.dart';

const livingRoom = CastDevice(
  id: 'living-room',
  name: 'Living room',
  backend: CastBackend.chromecast,
);
const kitchen = CastDevice(
  id: 'kitchen',
  name: 'Kitchen DLNA',
  backend: CastBackend.dlna,
);

class FakeOutputNotifier extends CastNotifier {
  static int connects = 0;
  static int disconnects = 0;

  @override
  CastState build() => const CastState(devices: [livingRoom, kitchen]);

  @override
  Future<void> discover() async {}

  @override
  Future<void> connect(CastDevice device) async {
    connects++;
    state = CastState(
      devices: const [livingRoom, kitchen],
      activeDevice: device,
      isActive: true,
    );
  }

  @override
  Future<void> disconnect({
    bool resumeLocal = true,
    bool leaveReceiver = false,
  }) async {
    disconnects++;
    state = const CastState(devices: [livingRoom, kitchen]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FakeOutputNotifier.connects = 0;
    FakeOutputNotifier.disconnects = 0;
  });

  Widget app() => ProviderScope(
    overrides: [
      castProvider.overrideWith(FakeOutputNotifier.new),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => PlaybackOutputPicker.show(context),
            child: const Text('Output'),
          ),
        ),
      ),
    ),
  );

  testWidgets('header output menu enumerates Cast and DLNA devices', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('output-picker-phone')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('output-picker-cast-chromecast-living-room')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('output-picker-cast-dlna-kitchen')),
      findsOneWidget,
    );
  });

  testWidgets('selecting receiver uses Cast provider handoff and closes sheet', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Living room'));
    await tester.pumpAndSettle();
    expect(FakeOutputNotifier.connects, 1);
    expect(find.byType(PlaybackOutputPicker), findsNothing);
  });

  testWidgets('refresh keeps output options discoverable', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('Output'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Living room'), findsOneWidget);
    expect(find.text('Kitchen DLNA'), findsOneWidget);
  });
}
