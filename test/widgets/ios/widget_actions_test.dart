import 'dart:async';

import 'package:flick/services/ios_widget_actions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 17);
  final alias = List.filled(64, 'a').join();
  String link(String action, {String? track, String? id, int? at}) => Uri(
    scheme: 'konnekted',
    host: 'widget',
    path: '/$action',
    queryParameters: {
      'command': id ?? '12345678-1234-1234-1234-123456789abc',
      'revision': '12',
      'at': '${at ?? now.millisecondsSinceEpoch}',
      if (track != null) 'track': track,
    },
  ).toString();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('command parser rejects foreign, ambiguous and unbound actions', () {
    expect(IosWidgetCommand.parse('konnekted://widget')!.action, 'open');
    expect(IosWidgetCommand.parse(link('pause', track: alias))!.track, alias);
    for (final raw in [
      'konnekted://widget/open?command=%FF',
      'konnekted://widget/%FF',
      'https://widget/play',
      'konnekted://user@widget/open',
      'konnekted://widget:42/open',
      'konnekted://widget/open#fragment',
      link('next'),
      link('toggle', track: alias),
      link('play', track: '/music/file'),
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
    final handler = IosWidgetActions(
      currentAlias: () => current,
      clock: () => now,
      execute: (command) async {
        executed.add(command.action);
      },
      onStale: () async {
        stale++;
      },
    );
    final next = link('next', track: alias);
    await handler.dispatch(next);
    await handler.dispatch(next);
    expect(executed, ['next']);
    current = List.filled(64, 'b').join();
    await handler.dispatch(
      link('pause', track: alias, id: '22345678-1234-1234-1234-123456789abc'),
    );
    await handler.dispatch(
      link(
        'pause',
        track: current,
        id: '32345678-1234-1234-1234-123456789abc',
        at: now.subtract(const Duration(minutes: 16)).millisecondsSinceEpoch,
      ),
    );
    expect(executed, ['next']);
    expect(stale, 2);
    await handler.dispatch(
      link('flow', id: '42345678-1234-1234-1234-123456789abc', at: 0),
    );
    expect(executed, ['next', 'flow']);
  });

  test(
    'queued commands serialize; failed work has no completion receipt',
    () async {
      final gate = Completer<void>();
      final events = <String>[];
      final handler = IosWidgetActions(
        currentAlias: () => alias,
        clock: () => now,
        execute: (command) async {
          events.add(command.action);
          if (command.action == 'play')
            await gate.future;
          else {
            throw StateError('Playback unavailable');
          }
        },
        onStale: () async {},
      );
      final first = handler.dispatch(link('play', track: alias));
      final second = handler.dispatch(
        link('pause', track: alias, id: '22345678-1234-1234-1234-123456789abc'),
      );
      final failure = expectLater(second, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['play']);
      gate.complete();
      await first;
      await failure;
      final receipts = (await SharedPreferences.getInstance()).getStringList(
        IosWidgetActions.receiptKey,
      )!;
      expect(receipts, ['12345678-1234-1234-1234-123456789abc']);
    },
  );

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
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final handler = IosWidgetActions(
      channel: channel,
      currentAlias: () => alias,
      clock: () => now,
      execute: (_) async {
        calls.add('played');
      },
      onStale: () async {},
    );
    await handler.attach();
    expect(calls, ['takePendingActions', 'played', 'acknowledgeAction']);
    await handler.dispose();
  });
  test('disposal preserves commands that have not executed', () async {
    const channel = MethodChannel('test/disposed-widget-actions');
    final first = link('play', track: alias);
    final second = link('queue', id: '22345678-1234-1234-1234-123456789abc');
    final gate = Completer<void>();
    final started = Completer<void>();
    final executed = <String>[];
    final acknowledged = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takePendingActions') return [first, second];
      if (call.method == 'acknowledgeAction')
        acknowledged.add(call.arguments as String);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final handler = IosWidgetActions(
      channel: channel,
      currentAlias: () => alias,
      clock: () => now,
      onStale: () async {},
      execute: (command) async {
        executed.add(command.action);
        started.complete();
        await gate.future;
      },
    );
    final draining = handler.drain();
    await started.future;
    await handler.dispose();
    gate.complete();
    await draining;
    expect(executed, ['play']);
    expect(acknowledged, [first]);
  });

  test(
    'malformed UTF-8 is acknowledged without blocking a valid later action',
    () async {
      const channel = MethodChannel('test/malformed-widget-actions');
      final valid = link('queue');
      final acknowledged = <String>[];
      final executed = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takePendingActions')
          return ['konnekted://widget/open?command=%FF', valid];
        if (call.method == 'acknowledgeAction')
          acknowledged.add(call.arguments as String);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final handler = IosWidgetActions(
        channel: channel,
        currentAlias: () => alias,
        clock: () => now,
        onStale: () async {},
        execute: (command) async {
          executed.add(command.action);
        },
      );
      await handler.drain();
      expect(executed, ['queue']);
      expect(acknowledged.length, 2);
      await handler.dispose();
    },
  );

  test(
    'failed Flow does not block queue and retries stop across attachments',
    () async {
      const channel = MethodChannel('test/retry-widget-actions');
      final flow = link('flow');
      final queue = link('queue', id: '22345678-1234-1234-1234-123456789abc');
      final pending = <String>[flow, queue];
      final executed = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takePendingActions')
          return List<String>.of(pending);
        if (call.method == 'acknowledgeAction') pending.remove(call.arguments);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      IosWidgetActions createHandler() => IosWidgetActions(
        channel: channel,
        currentAlias: () => alias,
        clock: () => now,
        onStale: () async {},
        execute: (command) async {
          executed.add(command.action);
          if (command.action == 'flow')
            throw StateError('Provider unavailable');
        },
      );
      final first = createHandler();
      await first.drain();
      expect(executed, ['flow', 'queue']);
      expect(pending, [flow]);
      await first.dispose();
      final resumed = createHandler();
      for (var attempt = 0; attempt < IosWidgetActions.maxAttempts; attempt++) {
        await resumed.drain();
      }
      expect(
        executed.where((action) => action == 'flow').length,
        IosWidgetActions.maxAttempts,
      );
      expect(pending, isEmpty);
      await resumed.dispose();
    },
  );

  test(
    'transient failure can recover and its successful receipt deduplicates',
    () async {
      var attempts = 0;
      final handler = IosWidgetActions(
        currentAlias: () => alias,
        clock: () => now,
        onStale: () async {},
        execute: (_) async {
          if (++attempts == 1) throw StateError('Temporary failure');
        },
      );
      final raw = link('flow');
      await expectLater(handler.dispatch(raw), throwsStateError);
      expect(await handler.dispatch(raw), isTrue);
      expect(await handler.dispatch(raw), isTrue);
      expect(attempts, 2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(IosWidgetActions.retryKey), isEmpty);
      expect(prefs.getStringList(IosWidgetActions.receiptKey), [
        '12345678-1234-1234-1234-123456789abc',
      ]);
    },
  );

  test(
    'disposal during a failed command preserves later pending work',
    () async {
      const channel = MethodChannel('test/disposed-failed-widget-actions');
      final gate = Completer<void>();
      final started = Completer<void>();
      final acknowledged = <String>[];
      final executed = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takePendingActions')
          return [
            link('flow'),
            link('queue', id: '22345678-1234-1234-1234-123456789abc'),
          ];
        if (call.method == 'acknowledgeAction')
          acknowledged.add(call.arguments as String);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final handler = IosWidgetActions(
        channel: channel,
        currentAlias: () => alias,
        clock: () => now,
        onStale: () async {},
        execute: (command) async {
          executed.add(command.action);
          started.complete();
          await gate.future;
          throw StateError('Provider unavailable');
        },
      );
      final draining = handler.drain();
      await started.future;
      await handler.dispose();
      gate.complete();
      await draining;
      expect(executed, ['flow']);
      expect(acknowledged, isEmpty);
    },
  );
  test(
    'newer Pause retires failed Play even across a later attachment',
    () async {
      const channel = MethodChannel('test/superseded-widget-actions');
      final play = link('play', track: alias);
      final pause = link(
        'pause',
        track: alias,
        id: '22345678-1234-1234-1234-123456789abc',
      );
      final pending = <String>[play, pause];
      final executed = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takePendingActions')
          return List<String>.of(pending);
        if (call.method == 'acknowledgeAction') pending.remove(call.arguments);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      IosWidgetActions createHandler() => IosWidgetActions(
        channel: channel,
        currentAlias: () => alias,
        clock: () => now,
        onStale: () async {},
        execute: (command) async {
          executed.add(command.action);
          if (command.action == 'play') throw StateError('Play unavailable');
        },
      );
      final first = createHandler();
      await first.drain();
      expect(executed, ['play', 'pause']);
      expect(pending, [play]);
      await first.dispose();
      final resumed = createHandler();
      await resumed.drain();
      expect(executed, ['play', 'pause']);
      expect(pending, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getStringList(
          IosWidgetActions.retryKey,
        ),
        isEmpty,
      );
      await resumed.dispose();
    },
  );
}
