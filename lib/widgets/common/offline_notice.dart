import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:flick/l10n/l10n.dart';
import 'package:flick/providers/connectivity_provider.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';

/// Shows brief feedback when connectivity is lost or restored.
class OfflineNotice extends ConsumerStatefulWidget {
  const OfflineNotice({super.key});

  @override
  ConsumerState<OfflineNotice> createState() => _OfflineNoticeState();
}

class _OfflineNoticeState extends ConsumerState<OfflineNotice> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(connectivityProvider, (previous, next) {
      final offline = next == ConnectivityStatus.offline;
      final reconnected =
          previous == ConnectivityStatus.offline &&
          next == ConnectivityStatus.online;
      if (!offline && !reconnected) return;

      // Initial connectivity can be reported while the overlay is building.
      final binding = WidgetsBinding.instance;
      binding.addPostFrameCallback((_) {
        if (!mounted || ref.read(connectivityProvider) != next) return;
        LokalToast.show(
          context,
          offline
              ? '${l10n.youReOffline}${l10n.someOnlineFeaturesMayNotWork}'
              : l10n.backOnline,
          semanticsLabel: offline ? l10n.youReOfflineSomeOnlineFeatures : null,
          duration: Duration(seconds: offline ? 5 : 2),
          leading: Icon(
            offline ? LucideIcons.wifiOff : LucideIcons.check,
            size: 18,
          ),
          owner: this,
        );
      });
      binding.ensureVisualUpdate();
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      LokalToast.dismiss(owner: this);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
