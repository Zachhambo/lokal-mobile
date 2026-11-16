import 'package:flick/services/download_progress_notification.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-requested library transfers only; playback buffering is not a download.
class DownloadActivityEntry {
  DownloadActivityEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.started,
    this.state = 'Downloading',
    this.progress,
    this.path,
  });

  final String id, title, artist;
  final DateTime started;
  String state;
  double? progress;
  String? path;
  bool get active => !{'Completed', 'Failed', 'Interrupted', 'Cancelled'}.contains(state);

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'artist': artist,
    'started': started.toIso8601String(), 'state': state, 'path': path,
  };

  static DownloadActivityEntry fromJson(Map<String, dynamic> json) {
    final state = json['state'] as String;
    return DownloadActivityEntry(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      started: DateTime.parse(json['started'] as String),
      state: {'Completed', 'Failed', 'Interrupted', 'Cancelled'}.contains(state)
          ? state : 'Interrupted',
      path: json['path'] as String?,
    );
  }
}

/// A zone joins preparation, download and library save into one history row,
/// including nested playlist/player save calls and concurrent requests.
class DownloadActivity extends ChangeNotifier {
  DownloadActivity({DownloadProgressNotification? notifications})
      : _notifications = notifications ?? DownloadProgressNotification();
  final DownloadProgressNotification _notifications;
  static final instance = DownloadActivity();
  static final _zoneKey = Object();
  static const storageKey = 'lokal.download_activity.v1';
  static const historyLimit = 1000;
  final _entries = <DownloadActivityEntry>[];
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  int _sequence = 0;
  DateTime _lastProgressNotice = DateTime.fromMillisecondsSinceEpoch(0);

  List<DownloadActivityEntry> get entries => List.unmodifiable(_entries);
  DownloadActivityEntry? get current => Zone.current[_zoneKey] as DownloadActivityEntry?;

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final row in prefs.getStringList(storageKey) ?? <String>[]) {
        try {
          final entry = DownloadActivityEntry.fromJson(
            Map<String, dynamic>.from(jsonDecode(row) as Map),
          );
          if (!_entries.any((item) => item.id == entry.id)) _entries.add(entry);
        } catch (_) { /* A damaged row must not hide the other downloads. */ }
      }
      _entries.sort((a, b) => b.started.compareTo(a.started));
      _trim();
      notifyListeners();
    } catch (_) { /* History storage must not block a music download. */ }
  }

  void _trim() {
    var finished = 0;
    _entries.removeWhere((entry) => !entry.active && ++finished > historyLimit);
  }

  void _persist() {
    _trim();
    final rows = _entries.map((entry) => jsonEncode(entry.toJson())).toList();
    _writes = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(storageKey, rows);
      } catch (_) { /* Keep live progress usable if storage is unavailable. */ }
    });
  }

  /// Exposed for deterministic persistence tests and app lifecycle callers.
  Future<void> get flushed => _writes;

  Future<T> run<T>({
    required String title,
    required String artist,
    required Future<T> Function() task,
    String? id,
  }) async {
    if (current != null) return task();
    await load();
    final entry = id == null ? null :
        _entries.where((row) => row.id == id).firstOrNull;
    final job = entry ?? DownloadActivityEntry(
      id: id ?? '${DateTime.now().microsecondsSinceEpoch}:${_sequence++}',
      title: title, artist: artist, started: DateTime.now(),
    );
    if (entry == null) _entries.insert(0, job);
    job.state = 'Downloading';
    job.progress = null;
    notifyListeners();
    _publish(job, begin: true);
    _persist();
    return runZoned(() async {
      try {
        final result = await task();
        job.state = 'Completed';
        job.progress = 1;
        return result;
      } catch (_) {
        job.state = 'Failed';
        job.progress = null;
        rethrow;
      } finally {
        notifyListeners();
        _publish(job);
        _persist();
      }
    }, zoneValues: {_zoneKey: job});
  }

  Future<void> transfer({
    required String id,
    required String title,
    required String artist,
    required String state,
    required double progress,
  }) async {
    await load();
    var entry = _entries.where((row) => row.id == id).firstOrNull;
    if (entry?.state == 'Completed') return;
    final changed = entry == null || entry.state != state;
    if (entry == null) {
      entry = DownloadActivityEntry(
        id: id, title: title, artist: artist, started: DateTime.now(),
      );
      _entries.insert(0, entry);
    }
    // Completed network bytes still have to be imported into the library.
    if (state == 'Saving' && entry.state == 'Failed') return;
    entry.state = state;
    entry.progress = state == 'Downloading' ? progress.clamp(0.0, 1.0) : null;
    notifyListeners();
    _publish(entry, begin: changed && entry.state == 'Queued');
    if (changed) _persist();
  }

  void status(String message) {
    final entry = current;
    if (entry == null) return;
    // Persist states only at boundaries, never write storage for every byte.
    final previousState = entry.state;
    final match = RegExp(r'(\d+(?:\.\d+)?)\s*%').firstMatch(message);
    entry.progress = match == null ? null :
        (double.parse(match[1]!) / 100).clamp(0.0, 1.0);
    entry.state = message.startsWith('Saving') ? 'Saving' :
        message.startsWith('Searching') ? 'Searching' : 'Downloading';
    final now = DateTime.now();
    if (entry.state != previousState || entry.progress == 1 ||
        now.difference(_lastProgressNotice).inMilliseconds >= 100) {
      _lastProgressNotice = now;
      notifyListeners();
      _publish(entry);
    }
  }

  void _publish(DownloadActivityEntry changed, {bool begin = false}) {
    final active = _entries.where((entry) => entry.active).toList();
    final primary = active.isEmpty ? changed : active.first;
    final percent = primary.progress == null ? '' :
        ' · ${(primary.progress! * 100).round()}%';
    final others = active.length <= 1 ? '' : ' · ${active.length} active downloads';
    _notifications.update(
      title: active.isNotEmpty ? 'Downloading music' :
          changed.state == 'Completed' ? 'Download complete' : 'Download failed',
      message: '${primary.title} · ${primary.state}$percent$others',
      busy: active.isNotEmpty,
      progress: primary.progress,
      begin: begin,
    );
  }

  @override
  void dispose() {
    _notifications.dispose();
    super.dispose();
  }

  void saved(String path) {
    final entry = current;
    if (entry != null) entry.path = path;
  }
}
