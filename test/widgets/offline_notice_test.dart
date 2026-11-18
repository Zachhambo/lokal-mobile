import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flick/core/theme/app_theme.dart';
import 'package:flick/providers/connectivity_provider.dart';
import 'package:flick/providers/app_preferences_provider.dart';
import 'package:flick/widgets/common/connection_notice_host.dart';
import 'package:flick/widgets/lokal/lokal_toast.dart';

class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this.results);

  List<ConnectivityResult> results;
  final StreamController<List<ConnectivityResult>> _controller =
      StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => results;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  void emit(List<ConnectivityResult> value) {
    results = value;
    _controller.add(value);
  }

  Future<void> close() => _controller.close();
}

Finder get _offline => find.textContaining("You're offline");
Finder get _online => find.text('Back online');

Widget _host(
  _FakeConnectivity connectivity, {
  Widget? home,
  MediaQueryData? mediaQuery,
}) => ProviderScope(
  overrides: [connectivityClientProvider.overrideWithValue(connectivity)],
  child: MaterialApp(
    theme: AppTheme.darkTheme,
    builder: (context, navigator) => MediaQuery(
      data: mediaQuery ?? MediaQuery.of(context),
      child: Overlay.wrap(
        child: Consumer(
          builder: (context, ref, _) => ConnectionNoticeHost(
            showNotice: ref.watch(
              appPreferencesProvider.select(
                (preferences) => preferences.connectionNoticesEnabled,
              ),
            ),
            child: navigator ?? const SizedBox.shrink(),
          ),
        ),
      ),
    ),
    home: home ?? const Scaffold(body: SizedBox.expand()),
  ),
);

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(ConnectionNoticeHost)),
);

Future<void> _goOffline(
  WidgetTester tester,
  _FakeConnectivity connectivity,
) async {
  connectivity.emit([ConnectivityResult.none]);
  await tester.pump();
  await tester.pump(ConnectivityNotifier.offlineDebounce);
  await tester.pumpAndSettle();
}

void main() {
  late _FakeConnectivity connectivity;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    connectivity = _FakeConnectivity([ConnectivityResult.wifi]);
  });

  tearDown(() async {
    LokalToast.dismiss();
    await connectivity.close();
  });

  testWidgets('online startup is quiet and offline feedback expires', (
    tester,
  ) async {
    await tester.pumpWidget(_host(connectivity));
    await tester.pumpAndSettle();
    expect(_offline, findsNothing);
    expect(_online, findsNothing);

    connectivity.emit([ConnectivityResult.none]);
    await tester.pump();
    expect(_offline, findsNothing);
    await tester.pump(ConnectivityNotifier.offlineDebounce);
    await tester.pumpAndSettle();
    expect(_offline, findsOneWidget);
    expect(
      find.textContaining('Some online features may not work'),
      findsOneWidget,
    );
    expect(find.byIcon(LucideIcons.wifiOff), findsOneWidget);
    expect(
      find.bySemanticsLabel("You're offline. Some online features may not work."),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 5));
    expect(_offline, findsNothing);
    expect(
      _container(tester).read(connectivityProvider),
      ConnectivityStatus.offline,
    );

    connectivity.emit([ConnectivityResult.wifi]);
    await tester.pumpAndSettle();
    expect(_online, findsOneWidget);
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(_online, findsNothing);
  });

  testWidgets('offline startup shows the pill', (tester) async {
    connectivity.results = [ConnectivityResult.none];
    await tester.pumpWidget(_host(connectivity));
    await tester.pumpAndSettle();
    expect(_offline, findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'the pill leaves the viewport and insets intact and passes taps through',
    (tester) async {
      tester.view.physicalSize = const Size(360, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const media = MediaQueryData(
        size: Size(360, 540),
        padding: EdgeInsets.only(top: 24),
        viewPadding: EdgeInsets.only(top: 24, bottom: 48),
        viewInsets: EdgeInsets.only(bottom: 192),
        textScaler: TextScaler.linear(2),
      );
      late MediaQueryData pageMedia;
      var taps = 0;
      await tester.pumpWidget(
        _host(
          connectivity,
          mediaQuery: media,
          home: Builder(
            builder: (context) {
              pageMedia = MediaQuery.of(context);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox.expand(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _goOffline(tester, connectivity);
      final pill = find.ancestor(
        of: _offline,
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.shape is StadiumBorder,
        ),
      );
      expect(pill, findsOneWidget);
      expect(tester.getSize(pill).width, lessThan(360));
      expect(tester.getTopLeft(pill).dy, greaterThanOrEqualTo(24));
      expect(tester.getCenter(pill).dy, lessThan(135));
      expect(pageMedia, media);
      await tester.tapAt(tester.getCenter(pill));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('disabled notices stay hidden without disabling connectivity', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'app_connection_notices_enabled': false,
    });
    await tester.pumpWidget(_host(connectivity));
    await tester.pumpAndSettle();
    final container = _container(tester);
    container.read(connectivityProvider);
    await tester.pumpAndSettle();
    await _goOffline(tester, connectivity);
    expect(container.read(connectivityProvider), ConnectivityStatus.offline);
    expect(_offline, findsNothing);

    connectivity.emit([ConnectivityResult.wifi]);
    await tester.pumpAndSettle();
    expect(container.read(connectivityProvider), ConnectivityStatus.online);
    expect(_online, findsNothing);
  });

  testWidgets(
    'toggling notices off clears their pill and on shows current status',
    (tester) async {
      await tester.pumpWidget(_host(connectivity));
      await tester.pumpAndSettle();
      await _goOffline(tester, connectivity);
      expect(_offline, findsOneWidget);

      final preferences = _container(tester)
          .read(appPreferencesProvider.notifier);
      await preferences.setConnectionNoticesEnabled(false);
      await tester.pumpAndSettle();
      expect(_offline, findsNothing);

      await preferences.setConnectionNoticesEnabled(true);
      await tester.pumpAndSettle();
      expect(_offline, findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('disabling connectivity notices leaves a newer pill visible', (
    tester,
  ) async {
    await tester.pumpWidget(_host(connectivity));
    await tester.pumpAndSettle();
    await _goOffline(tester, connectivity);
    LokalToast.show(tester.element(find.byType(Scaffold)), 'Saved');

    final preferences = _container(tester)
        .read(appPreferencesProvider.notifier);
    await preferences.setConnectionNoticesEnabled(false);
    await tester.pumpAndSettle();
    expect(_offline, findsNothing);
    expect(find.text('Saved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'a new offline transition replaces the back-online pill and timer',
    (tester) async {
      await tester.pumpWidget(_host(connectivity));
      await tester.pumpAndSettle();
      await _goOffline(tester, connectivity);
      connectivity.emit([ConnectivityResult.wifi]);
      await tester.pumpAndSettle();
      expect(_online, findsOneWidget);

      await _goOffline(tester, connectivity);
      await tester.pump(const Duration(seconds: 3));
      expect(_online, findsNothing);
      expect(_offline, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    },
  );
}
