import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/recently_played_repository.dart';
import '../../../providers/app_preferences_provider.dart';
import '../../../widgets/common/display_mode_wrapper.dart';
import '../../../widgets/common/flick_artwork_placeholder.dart';
import '../widgets/replay_card_options.dart';
import '../widgets/recap_dashboard.dart';
import '../../../core/theme/lokal_tokens.dart';
import '../widgets/replay_style.dart';
import 'replay_studio_screen.dart';

import 'package:flick/l10n/l10n.dart';

/// An artwork-led retrospective; poster-making lives in Replay Studio.
class ListeningRecapScreen extends ConsumerStatefulWidget {
  final RecentlyPlayedRepository? repository;

  /// The period the story opens at.
  final ListeningRecapPeriod initialPeriod;

  const ListeningRecapScreen({
    super.key,
    this.repository,
    this.initialPeriod = ListeningRecapPeriod.daily,
  });

  @override
  ConsumerState<ListeningRecapScreen> createState() =>
      _ListeningRecapScreenState();
}

class _ListeningRecapScreenState extends ConsumerState<ListeningRecapScreen>
    with WidgetsBindingObserver {
  late final _repository = widget.repository ?? RecentlyPlayedRepository();
  late ListeningRecapPeriod _period = widget.initialPeriod;
  Map<ListeningRecapPeriod, ListeningRecap> _recaps = {};
  StreamSubscription<void>? _history;
  Timer? _refreshDebounce;
  int _loadGeneration = 0;
  int _direction = 1;
  bool _loading = true;
  bool _failed = false;
  bool _active = true;
  bool _editing = false;
  ReplayCardOptions _options = const ReplayCardOptions();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadRecaps();
    _history = _repository.watchHistory().listen(
      (_) {
        _refreshDebounce?.cancel();
        _refreshDebounce = Timer(
          const Duration(milliseconds: 200),
          () => _loadRecaps(refresh: true),
        );
      },
      onError: (Object error) {
        if (mounted) setState(() => _failed = true);
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _active = state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadGeneration++;
    _history?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadRecaps({bool refresh = false}) async {
    final generation = ++_loadGeneration;
    if (!refresh) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final recaps = await _repository.getListeningRecaps();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _recaps = recaps;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  ListeningRecap get _recap =>
      _recaps[_period] ??
      ListeningRecap.empty(_period, _period.rangeFor(DateTime.now()));

  void _selectPeriod(ListeningRecapPeriod period) {
    if (_period == period) return;
    setState(() {
      _direction = period.index > _period.index ? 1 : -1;
      _period = period;
    });
  }

  Future<void> _openExport() async {
    final snapshot = _recap;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        !ref.read(appPreferencesProvider).animationsEnabled;
    if (_editing) return;
    setState(() => _editing = true);
    final options = await Navigator.of(context).push<ReplayCardOptions>(
      PageRouteBuilder(
        settings: const RouteSettings(name: '/replay/studio'),
        transitionDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 300),
        reverseTransitionDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 250),
        pageBuilder: (context, animation, secondaryAnimation) =>
            ReplayStudioScreen(
              recap: snapshot,
              initialOptions: _options,
              onOptionsChanged: (options) {
                if (mounted) setState(() => _options = options);
              },
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.015), end: Offset.zero)
                    .animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    ),
                child: child,
              ),
            ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _editing = false;
      if (options != null) _options = options;
    });
  }

  @override
  Widget build(BuildContext context) {
    final animations = ref.watch(
      appPreferencesProvider.select((p) => p.animationsEnabled),
    );
    return DisplayModeWrapper(
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations:
              MediaQuery.disableAnimationsOf(context) || !animations,
        ),
        child: TickerMode(
          enabled: _active && !_editing,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _header(),
                  ReplayPeriodPicker(
                    selected: _period,
                    onSelected: _selectPeriod,
                  ),
                  const SizedBox(height: 4),
                  Expanded(child: Builder(builder: _body)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: l10n.back,
            onPressed: () => Navigator.maybePop(context),
            icon: Icon(
              Icons.arrow_back_rounded,
              color: context.lokal.text,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              l10n.flickReplay,
              style: TextStyle(
                fontSize: 22,
                letterSpacing: -0.5,
                fontWeight: FontWeight.w700,
                color: context.lokal.text,
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.saveCustomizeReplay,
            onPressed: _loading || !_recap.hasData ? null : _openExport,
            icon: const Icon(Icons.ios_share_rounded),
            color: context.lokal.muted,
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return Center(
        child: Semantics(
          label: l10n.loadingReplay,
          child: SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.lokal.muted,
            ),
          ),
        ),
      );
    }
    if (_failed && _recaps.isEmpty) {
      return _message(
        title: l10n.replayCouldnTLoad,
        detail: l10n.yourListeningHistoryIsStillYours,
        action: TextButton.icon(
          onPressed: () => _loadRecaps(),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(l10n.tryAgain),
        ),
      );
    }
    return AnimatedSwitcher(
      duration: ReplayStyle.duration(context),
      reverseDuration: ReplayStyle.duration(context),
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.topCenter,
        children: [
          ...previous.map(
            (child) => ExcludeSemantics(child: IgnorePointer(child: child)),
          ),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position:
              Tween(
                begin: Offset(0.035 * _direction, 0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        ),
      ),
      child: _recap.hasData
          ? RecapDashboard(
              key: ValueKey(_period),
              recap: _recap,
              failed: _failed,
              onRetry: () => _loadRecaps(refresh: true),
              onExport: _openExport,
            )
          : KeyedSubtree(
              key: ValueKey(_period),
              child: _message(
                title: l10n.yourNextFavoriteNisWaiting,
                detail: _period.emptyMessage,
              ),
            ),
    );
  }

  Widget _message({
    required String title,
    required String detail,
    Widget? action,
  }) {
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          28,
          56,
          28,
          40 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FlickArtworkPlaceholder(size: 72, opacity: 0.8),
            const SizedBox(height: 40),
            Text(
              title,
              style: TextStyle(
                fontSize: 36,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: context.lokal.text,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              detail,
              style: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: context.lokal.muted,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 20), action],
          ],
        ),
      ),
    );
  }
}

class ReplayPeriodPicker extends StatelessWidget {
  final ListeningRecapPeriod selected;
  final ValueChanged<ListeningRecapPeriod> onSelected;

  const ReplayPeriodPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
          final width = largeText ? 440.0 : constraints.maxWidth;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.lokal.surface2,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Stack(
                  children: [
                    AnimatedPositioned(
                      duration: ReplayStyle.duration(context),
                      curve: Curves.easeOutCubic,
                      left: selected.index * width / 4,
                      width: width / 4,
                      top: 4,
                      bottom: 4,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: context.lokal.accent,
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (final period in ListeningRecapPeriod.values)
                          Expanded(
                            child: Semantics(
                              selected: selected == period,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: selected == period
                                      ? context.lokal.onAccent
                                      : context.lokal.muted,
                                  minimumSize: const Size(48, 52),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 12,
                                  ),
                                  shape: const StadiumBorder(),
                                ),
                                onPressed: () => onSelected(period),
                                child: Text(
                                  period.label,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: selected == period
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
