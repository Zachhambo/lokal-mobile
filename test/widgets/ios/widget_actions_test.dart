import 'dart:async';
import 'package:flick/services/ios_widget_actions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 17);
  final alias = List.filled(64, 'a').join();
  String link(String action, {String? track, String? id, int? at}) =>
    Uri(scheme: 'konnekted', host: 'widget', path: '/$action',
      queryParameters: {
        'command': id ?? '12345678-1234-1234-1234-123456789abc',
        'revision': '12', 'at': '${at ?? now.millisecondsSinceEpoch}',
        if (track != null) 'track': track,
      }).toString();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('command parser rejects foreign, ambiguous and unbound actions', () {
    expect(IosWidgetCommand.parse('konnekted://widget')!.action, 'open');
    expect(IosWidgetCommand.parse(link('pause', track: alias))!.track, alias);
    for (final raw in [
      'https://widget/play', 'konnekted://user@widget/open',
      'konnekted://widget:42/open', 'konnekted://widget/open#fragment',
      link('next'), link('toggle', track: alias), link('play', track: '/music/file'),
      link('next', track: alias) + '&track=$alias',
      link('pause', track: alias) + '&source=https://example.com',
    ]) {
      expect(IosWidgetCommand.parse(raw), isNull, reason: raw);
    }
  });

  test('old controls cannot affect a newer recording and receipts stop duplicate skips', () async {
    var current = alias;
    final executed = <String>[];
    var stale = 0;
    final handler = IosWidgetActions(currentAlias: () => current, clock: () => now,
      execute: (command) async { executed.add(command.action); },
      onStale: () async { stale++; });
    final next = link('next', track: alias);
    await handler.dispatch(next);
    await handler.dispatch(next);
    expect(executed, ['next']);
    current = List.filled(64, 'b').join();
    await handler.dispatch(link('pause', track: alias, id: '22345678-1234-1234-1234-123456789abc'));
    await handler.dispatch(link('flow', at: now.subtract(const Duration(minutes: 16)).millisecondsSinceEpoch));
    expect(executed, ['next']);
    expect(stale, 2);
  });

  test('queued commands serialize; failed work has no completion receipt', () async {
    final gate = Completer<void>();
    final events = <String>[];
    final handler = IosWidgetActions(currentAlias: () => alias, clock: () => now,
      execute: (command) async {
        events.add(command.action);
        if (command.action == 'play') await gate.future;
        else { throw StateError('Playback unavailable'); }
      }, onStale: () async {});
    final first = handler.dispatch(link('play', track: alias));
    final second = handler.dispatch(link('pause', track: alias,
      id: '22345678-1234-1234-1234-123456789abc'));
    final failure = expectLater(second, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['play']);
    gate.complete();
    await first;
    await failure;
    final receipts = (await SharedPreferences.getInstance())
        .getStringList(IosWidgetActions.receiptKey)!;
    expect(receipts, ['12345678-1234-1234-1234-123456789abc']);
  });

  test('native inbox is acknowledged only after successful dispatch', () async {
    const channel = MethodChannel('test/widget-actions');
    final calls = <String>[];
    final raw = link('play', track: alias);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'takePendingActions') return [raw];
        return null;
      });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
    final handler = IosWidgetActions(channel: channel,
      currentAlias: () => alias, clock: () => now,
      execute: (_) async { calls.add('played'); },
      onStale: () async {});
    await handler.attach();
    expect(calls, ['takePendingActions', 'played', 'acknowledgeAction']);
    await handler.dispose();
  });
}
