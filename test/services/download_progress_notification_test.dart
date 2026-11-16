import 'package:flick/services/download_progress_notification.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadProgressNotification.channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadProgressNotification.channel, null);
  });

  testWidgets('coalesces percentages and completion retires pending progress', (tester) async {
    final notification = DownloadProgressNotification();
    addTearDown(notification.dispose);
    notification.update(title: 'Downloading music', message: 'Track', busy: true, begin: true);
    await notification.flushed;
    expect(calls.single.arguments['kind'], 'download');
    expect(calls.single.arguments['begin'], isTrue);
    notification.update(title: 'Downloading music', message: 'Track · 42%', busy: true, progress: .42);
    notification.update(title: 'Downloading music', message: 'Track · 50%', busy: true, progress: .5);
    expect(calls, hasLength(1));
    await tester.pump(const Duration(milliseconds: 501));
    await notification.flushed;
    expect(calls.last.arguments['processed'], 500);
    expect(calls.last.arguments['total'], 1000);
    notification.update(title: 'Downloading music', message: 'Track · 90%', busy: true, progress: .9);
    notification.update(title: 'Download complete', message: 'Track', busy: false, progress: 1);
    await notification.flushed;
    await tester.pump(const Duration(seconds: 1));
    expect(calls.last.arguments['busy'], isFalse);
    expect(calls.last.arguments['title'], 'Download complete');
    expect(calls.where((call) => call.arguments['processed'] == 900), isEmpty);
  });

  test('notification permission failure does not fail downloads', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DownloadProgressNotification.channel,
            (_) async => throw PlatformException(code: 'DENIED'));
    final notification = DownloadProgressNotification();
    addTearDown(notification.dispose);
    notification.update(title: 'Downloading music', message: 'Track', busy: true);
    await notification.flushed;
  });

  test('unknown-length transfers remain indeterminate', () async {
    final notification = DownloadProgressNotification();
    addTearDown(notification.dispose);
    notification.update(title: 'Downloading music', message: 'Track', busy: true);
    await notification.flushed;
    expect(calls.single.arguments['total'], isNull);
  });
}
