import 'package:flutter/widgets.dart';

import 'package:flick/widgets/common/offline_notice.dart';

class ConnectionNoticeHost extends StatelessWidget {
  const ConnectionNoticeHost({
    super.key,
    required this.child,
    this.showNotice = true,
  });

  final Widget child;
  final bool showNotice;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      child,
      if (showNotice) const Positioned(top: 0, child: OfflineNotice()),
    ],
  );
}
