import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'data/controller.dart';
import 'data/background_scan.dart';
import 'data/store.dart';
import 'data/app_logger.dart';
import 'domain/market.dart';
import 'ui/common.dart';
import 'ui/prices_page.dart';
import 'ui/chart_page.dart';
import 'ui/calculator_page.dart';
import 'ui/info_page.dart';
import 'ui/range_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Vazirmatn font / Iran city data'],
        await rootBundle.loadString('assets/THIRD_PARTY_NOTICES.txt'));
  });
  AppLogger.instance.installErrorHandlers();
  await BackgroundScanScheduler.initialize();
  runApp(const IronPinApp());
}

class IronPinApp extends StatelessWidget {
  final MarketController? controller;
  const IronPinApp({super.key, this.controller});
  @override
  Widget build(BuildContext context) => MaterialApp(
      title: 'IronPin | آیرون‌پین',
      debugShowCheckedModeBanner: false,
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Vazirmatn',
          colorScheme: ColorScheme.fromSeed(
              seedColor: teal, primary: teal, secondary: ink),
          scaffoldBackgroundColor: const Color(0xfff3f6f8),
          textTheme: ThemeData.light().textTheme.apply(
              fontFamily: 'Vazirmatn', bodyColor: ink, displayColor: ink),
          appBarTheme: const AppBarTheme(
              backgroundColor: ink,
              foregroundColor: Colors.white,
              elevation: 0),
          cardTheme: CardTheme(
              color: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Color(0xffe2e9ed)))),
          inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xffdce4e9))),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xffdce4e9))),
              labelStyle: const TextStyle(fontSize: 12)),
          navigationBarTheme: const NavigationBarThemeData(
              backgroundColor: Colors.white,
              indicatorColor: Color(0xffd8f1ed),
              labelTextStyle: WidgetStatePropertyAll(
                  TextStyle(fontSize: 11, fontFamily: 'Vazirmatn')))),
      home:
          controller == null ? const Bootstrap() : MarketHome(c: controller!));
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  MarketController? controller;
  String? error;
  @override
  void initState() {
    super.initState();
    start();
  }

  Future<void> start() async {
    try {
      final store = await MarketStore.open();
      final c = MarketController(store);
      await c.init();
      if (!mounted) {
        c.dispose();
        await store.close();
        return;
      }
      setState(() => controller = c);
    } catch (e, stack) {
      AppLogger.instance.capture(e, stack, section: 'startup');
      if (mounted) {
        setState(() => error =
            'پایگاه داده یا فایل‌های برنامه باز نشد. فضای خالی دستگاه را بررسی کنید.');
      }
    }
  }

  @override
  void dispose() {
    final c = controller;
    c?.dispose();
    if (c != null) unawaited(c.store.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => controller != null
      ? MarketHome(c: controller!)
      : Scaffold(
          body: Center(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.factory_outlined, size: 64, color: teal),
                    const SizedBox(height: 20),
                    const Text('IronPin',
                        style: TextStyle(
                            fontSize: 30, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    if (error == null)
                      const CircularProgressIndicator()
                    else
                      Text(error!, textAlign: TextAlign.center)
                  ]))));
}

class MarketHome extends StatefulWidget {
  final MarketController c;
  const MarketHome({super.key, required this.c});
  @override
  State<MarketHome> createState() => _MarketHomeState();
}

class _MarketHomeState extends State<MarketHome> with WidgetsBindingObserver {
  int tab = 0;
  String? chartId;
  final List<Widget?> _pages = List.filled(5, null);
  bool _retentionOpen = false;
  String? _observedMonth;
  Future<void> _checkRetention() async {
    if (_retentionOpen || !widget.c.ready) return;
    _retentionOpen = true;
    try {
      final store = widget.c.store;
      final now = DateTime.now();
      if (!await store.retentionDue(now) || !mounted) return;
      if (await store.historyCount() == 0) {
        await store.decideRetention(clearOld: false, now: now);
        return;
      }
      if (!mounted) return;
      await AppLogger.instance.record('retention', 'monthly_prompt');
      if (!mounted) return;
      final clear = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
                  title: const Text('تاریخچه ماه‌های قبل را نگه داریم؟'),
                  content: Text(
                      'این پرسش هر ماه شمسی، هنگام استفاده از برنامه نمایش داده می‌شود.\n\nپاک‌سازی فقط ثبت‌های پیش از ${dateLabel(MarketStore.retentionCutoff(now), time: false)} را حذف می‌کند؛ آخرین قیمت‌ها، تنظیمات و لاگ‌ها باقی می‌مانند.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('پاک‌سازی تاریخچه قدیمی')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('نگه‌داشتن اطلاعات'))
                  ]));
      if (clear != null) {
        await store.decideRetention(clearOld: clear, now: now);
        if (clear) widget.c.historyChanged();
      }
    } catch (e, stack) {
      AppLogger.instance.capture(e, stack, section: 'retention');
    } finally {
      _retentionOpen = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkRetention());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.c.foreground = state == AppLifecycleState.resumed;
    unawaited(
        AppLogger.instance.record('lifecycle', 'state', {'state': state.name}));
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkRetention());
      unawaited(widget.c.refreshBackgroundState());
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.c,
      builder: (context, _) {
        final c = widget.c;
        final month = MarketStore.retentionMonth(DateTime.now());
        if (c.ready && _observedMonth != month) {
          _observedMonth = month;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _checkRetention());
        }
        // Reuse the exact widget instance for inactive tabs: no eager chart/info builds.
        _pages[tab] = switch (tab) {
          0 => PricesPage(
              c: c,
              onChart: (q) => setState(() {
                    chartId = q.id;
                    tab = 1;
                  })),
          1 => ChartPage(c: c, selectedId: chartId),
          2 => RangePage(c: c),
          3 => CalculatorPage(city: c.selectedCity),
          _ => InfoPage(c: c),
        };
        return Scaffold(
          appBar: AppBar(
              title: Row(children: [
                Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                        color: teal, borderRadius: BorderRadius.circular(9)),
                    child: const Icon(Icons.view_in_ar, size: 23)),
                const SizedBox(width: 12),
                const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('آیرون‌پین',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 19)),
                      Text('بازار آهن، با منبع روشن',
                          style: TextStyle(fontSize: 10, color: Colors.white70),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)
                    ]))
              ]),
              actions: [
                IconButton(
                    tooltip: 'نوسازی قیمت‌ها',
                    onPressed: c.busy || c.transferring ? null : c.refresh,
                    icon: c.busy
                        ? const SizedBox(
                            height: 21,
                            width: 21,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white70))
                        : const Icon(Icons.sync)),
                const SizedBox(width: 8)
              ],
              bottom: PreferredSize(
                  preferredSize: Size.fromHeight(c.busy ? 32 : 26),
                  child: Column(children: [
                    Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Row(children: [
                          Icon(c.busy ? Icons.downloading : Icons.storage,
                              size: 12, color: const Color(0xff7bddca)),
                          const SizedBox(width: 7),
                          Expanded(
                              child: Text(
                                  c.busy
                                      ? 'دریافت منابع ${fmt(c.finished)} / ${fmt(c.enabled.length)}'
                                      : '${fmt(c.quotes.length)} ردیف ذخیره‌شده روی دستگاه',
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 10),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)),
                          const Text('بدون سرور',
                              style: TextStyle(
                                  fontSize: 10, color: Colors.white54))
                        ])),
                    if (c.busy)
                      const LinearProgressIndicator(
                          minHeight: 2,
                          backgroundColor: ink,
                          color: Color(0xff7bddca))
                  ]))),
          body: SafeArea(
              child: IndexedStack(index: tab, children: [
            for (final page in _pages) page ?? const SizedBox.shrink()
          ])),
          bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) {
                unawaited(AppLogger.instance
                    .record('navigation', 'tab', {'index': i}));
                setState(() => tab = i);
              },
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.storefront_outlined),
                    selectedIcon: Icon(Icons.storefront),
                    label: 'قیمت‌ها'),
                NavigationDestination(
                    icon: Icon(Icons.show_chart), label: 'نمودار'),
                NavigationDestination(
                    icon: Icon(Icons.price_change_outlined), label: 'رنج‌گیری'),
                NavigationDestination(
                    icon: Icon(Icons.calculate_outlined),
                    selectedIcon: Icon(Icons.calculate),
                    label: 'محاسبات'),
                NavigationDestination(
                    icon: Icon(Icons.info_outline),
                    selectedIcon: Icon(Icons.info),
                    label: 'اطلاعات')
              ]),
        );
      });
}
