import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class IosWidgetCommand {
  const IosWidgetCommand(this.action, {this.id, this.track, this.atMs = 0});
  final String action;
  final String? id, track;
  final int atMs;

  static IosWidgetCommand? parse(String raw) {
    if (raw.length > 2048) return null;
    try {
      return _parse(raw);
    } on FormatException {
      return null;
    }
  }

  static IosWidgetCommand? _parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'konnekted' ||
        uri.host != 'widget' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment ||
        uri.pathSegments.length > 1)
      return null;
    final action = uri.pathSegments.firstOrNull ?? 'open';
    if (!const {
      'open',
      'queue',
      'play',
      'pause',
      'next',
      'previous',
      'flow',
      'radio',
      'recommend',
    }.contains(action))
      return null;
    if (action == 'open' && uri.query.isEmpty)
      return const IosWidgetCommand('open');
    final items = uri.queryParametersAll;
    if (items.keys.any(
          (key) => !const {'command', 'revision', 'at', 'track'}.contains(key),
        ) ||
        items.values.any((values) => values.length != 1))
      return null;
    final id = uri.queryParameters['command'];
    final revision = int.tryParse(uri.queryParameters['revision'] ?? '');
    final at = int.tryParse(uri.queryParameters['at'] ?? '');
    final track = uri.queryParameters['track'];
    if (id == null ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
        ).hasMatch(id) ||
        revision == null ||
        revision < 0 ||
        revision > 9007199254740991 ||
        at == null ||
        at < 0 ||
        at > 4102444800000 ||
        (track != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(track)))
      return null;
    if (const {
          'play',
          'pause',
          'next',
          'previous',
          'radio',
          'recommend',
        }.contains(action) &&
        (track == null || revision < 1))
      return null;
    return IosWidgetCommand(action, id: id, track: track, atMs: at);
  }

  bool freshAt(DateTime now) {
    final delta = now.millisecondsSinceEpoch - atMs;
    return delta >= -300000 && delta <= 900000;
  }
}

/// Commands are serialized in the existing app process. The extension starts
/// no engine and an old control can never skip/pause a different recording.
class IosWidgetActions {
  IosWidgetActions({
    required this.currentAlias,
    required this.execute,
    required this.onStale,
    DateTime Function()? clock,
    MethodChannel? channel,
  }) : _clock = clock ?? DateTime.now,
       _channel = channel ?? const MethodChannel('lokal/widgets/actions');

  final String? Function() currentAlias;
  final Future<void> Function(IosWidgetCommand) execute;
  final Future<void> Function() onStale;
  final DateTime Function() _clock;
  final MethodChannel _channel;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  static const receiptKey = 'lokal.widget.completed-commands.v1';
  static const retryKey = 'lokal.widget.failed-attempts.v1';
  static const maxAttempts = 3;

  Future<void> attach() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'dispatchPending') await drain();
    });
    await drain();
  }

  Future<void> drain() async {
    if (_disposed) return;
    final rows =
        await _channel.invokeListMethod<String>('takePendingActions') ??
        const [];
    for (final raw in rows.take(8)) {
      if (_disposed) break;
      try {
        if (!await dispatch(raw)) break;
      } on Object {
        // Leave this command pending, but let independent taps make progress.
        if (_disposed) break;
        continue;
      }
      await _channel.invokeMethod<void>('acknowledgeAction', raw);
    }
  }

  Future<bool> dispatch(String raw) {
    final next = _tail.then((_) async {
      if (_disposed) return false;
      final command = IosWidgetCommand.parse(raw);
      if (command == null) return true;
      final prefs = await SharedPreferences.getInstance();
      final receipts = prefs.getStringList(receiptKey) ?? const <String>[];
      if (_disposed) return false;
      if (command.id != null && receipts.contains(command.id)) return true;
      final controlsCurrent = const {
        'play',
        'pause',
        'next',
        'previous',
        'radio',
      }.contains(command.action);
      if (!const {'open', 'queue', 'flow'}.contains(command.action) &&
          (!command.freshAt(_clock()) ||
              (controlsCurrent && command.track != currentAlias()))) {
        await onStale();
        return true;
      }
      // Persist failed attempts across attachments so an unavailable provider
      // cannot keep an unexpiring Flow command in the native inbox forever.
      final retryId = command.id ?? raw;
      final failures = prefs.getStringList(retryKey) ?? const <String>[];
      if (failures.where((id) => id == retryId).length >= maxAttempts)
        return true;
      try {
        await execute(command);
      } on Object {
        await prefs.setStringList(
          retryKey,
          [retryId, ...failures].take(64 * maxAttempts).toList(),
        );
        rethrow;
      }
      if (failures.contains(retryId)) {
        await prefs.setStringList(
          retryKey,
          failures.where((id) => id != retryId).toList(),
        );
      }
      if (command.id != null) {
        await prefs.setStringList(
          receiptKey,
          [
            command.id!,
            ...receipts.where((id) => id != command.id),
          ].take(64).toList(),
        );
      }
      return true;
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> dispose() async {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('detach');
    } on Object {
      /* Engine may already be stopping. */
    }
  }
}
