import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Coalesces download progress independently of playback, sync and metadata jobs.
class DownloadProgressNotification {
  DownloadProgressNotification({TargetPlatform Function()? platform})
      : _platform = platform ?? (() => defaultTargetPlatform);
  final TargetPlatform Function() _platform;
  static const channel = MethodChannel('lokal/library_sync_notification');
  Timer? _timer;
  Map<String, Object?>? _pending;
  DateTime? _sentAt;
  Future<void> _tail = Future.value();

  Future<void> get flushed => _tail;

  void update({
    required String title,
    required String message,
    required bool busy,
    double? progress,
    bool begin = false,
  }) {
    if (kIsWeb || !{TargetPlatform.android, TargetPlatform.iOS}.contains(_platform())) return;
    _pending = {
      'kind': 'download',
      'title': title,
      'message': message,
      'busy': busy,
      'processed': progress == null ? 0 : (progress.clamp(0, 1) * 1000).round(),
      'total': progress == null ? null : 1000,
      'begin': begin,
    };
    if (begin || !busy || _sentAt == null ||
        DateTime.now().difference(_sentAt!) >= const Duration(milliseconds: 500)) {
      _timer?.cancel();
      _timer = null;
      _flush();
    } else {
      _timer ??= Timer(const Duration(milliseconds: 500), () {
        _timer = null;
        _flush();
      });
    }
  }

  void _flush() {
    final payload = _pending;
    if (payload == null) return;
    _pending = null;
    _sentAt = DateTime.now();
    _tail = _tail.then((_) async {
      try {
        if (payload['begin'] == true && _platform() == TargetPlatform.android) {
          // Ask only in response to a requested download, never on app launch.
          await Permission.notification.request();
        }
        await channel.invokeMethod<bool>('update', payload);
      } on PlatformException {
        // Denied permission cannot prevent a download.
      } on MissingPluginException {
        // Non-device hosts.
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    _pending = null;
  }
}
