/// Reclaims the phone after the native Cast session ends. This never resumes
/// local audio: a disconnected receiver might still be playing over the network.
///
/// Serialize with PlayerService so an older session event cannot steal a newer
/// connection or override a track change while an output handoff is running.
Future<bool> recoverLostCastSession({
  required Future<void> Function(Future<void> Function()) serialize,
  required bool Function() stillOwnsSession,
  required void Function() releaseRemote,
  required Future<void> Function() cleanup,
}) async {
  var released = false;
  await serialize(() async {
    if (!stillOwnsSession()) return;
    releaseRemote();
    released = true;
    // Cleanup failure must never restore the dead session's ownership.
    try {
      await cleanup();
    } catch (_) {}
  });
  return released;
}

/// Reject delayed native callbacks from a replaced Cast receiver. A missing
/// identity is accepted only for legacy sender events without the new field.
bool castEventMatchesReceiver({
  required String? reportedDeviceId,
  required String? activeDeviceId,
}) => reportedDeviceId == null ||
    (activeDeviceId != null && reportedDeviceId == activeDeviceId);
