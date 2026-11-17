import 'package:flick/models/ios_widget_snapshot.dart';
import 'package:flick/services/ios_widget_method_channel_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Exercise the actual installed bridge. Simulator publication is distinct
/// from signed-device App Group and Home Screen acceptance.
Future<void> probeIosWidgetTransport(
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final transport = IosWidgetMethodChannelTransport();
  final capability = await transport.capability().timeout(
    const Duration(seconds: 5),
  );
  if (capability.available) {
    final receipt = await transport.publish(
      IosWidgetSnapshot.fromJson({
        'schemaVersion': 1,
        'revision': capability.committedRevision + 1,
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      }),
      const {},
      reloadTimelines: false,
    ).timeout(const Duration(seconds: 5));
    expect(receipt.revision, greaterThan(capability.committedRevision));
  } else {
    expect(capability.unavailableReason, isNotNull);
  }
  await expectLater(
    const MethodChannel('lokal/widgets')
        .invokeMethod<void>('unsupported-operation'),
    throwsA(
      isA<PlatformException>().having(
        (error) => error.code,
        'code',
        'UNSUPPORTED_WIDGET_METHOD',
      ),
    ),
  );
  binding.reportData!['widget_installation'] = {
    'scope': 'Actual installed native bridge',
    'shared_container_available': capability.available,
    'unsupported_operation_rejected_explicitly': true,
    'signed_group_or_extension_acceptance': false,
  };
}
