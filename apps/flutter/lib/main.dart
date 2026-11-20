import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';

import 'state/app_state.dart';
import 'ui/prefs.dart';
import 'ui/router.dart';
import 'ui/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Clean addresses (pos.cartunez.in/orders/invoices) instead of /#/...
  usePathUrlStrategy();
  if (kIsWeb) {
    MobileScannerPlatform.instance
      ..setWebBarcodeReader(WebBarcodeReader.zxingWasm)
      ..setBarcodeLibraryScriptUrl('scanner/3.1.6/reader.js');
  }
  final state = AppState();
  final prefs = UiPrefs();
  unawaited(prefs.load());
  runApp(CartunezApp(state: state, prefs: prefs));
  await state.init();
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);
  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

extension AppContext on BuildContext {
  AppState get app => AppScope.of(this);
  AppState get appRead => AppScope.read(this);
}

class CartunezApp extends StatefulWidget {
  const CartunezApp({super.key, required this.state, this.prefs, this.initialLocation = '/'});
  final AppState state;

  /// This device's UI preferences; tests pass their own.
  final UiPrefs? prefs;

  /// Where to start when the platform gives no address (desktop, Android, tests).
  final String initialLocation;

  @override
  State<CartunezApp> createState() => _CartunezAppState();
}

class _CartunezAppState extends State<CartunezApp> {
  late final UiPrefs prefs = widget.prefs ?? UiPrefs();
  late final RouteGuard guard = RouteGuard(widget.state);
  late final GoRouter router = buildRouter(widget.state, refresh: guard, initialLocation: widget.initialLocation);
  Object? _session;

  @override
  void initState() {
    super.initState();
    _session = widget.state.session;
    widget.state.addListener(_onState);
  }

  /// A different person (or nobody) is signed in: close any open dialogs
  /// from the previous session, as the old app did by rebuilding everything.
  void _onState() {
    final session = widget.state.session;
    if (identical(session, _session)) return;
    _session = session;
    rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    router.dispose();
    guard.dispose();
    if (widget.prefs == null) prefs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    return AppScope(
      state: widget.state,
      child: UiPrefsScope(
        prefs: prefs,
        child: ListenableBuilder(
          listenable: prefs,
          builder: (context, _) => MaterialApp.router(
            title: 'Cartunez POS',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(prefs.appearance),
            // The operating system's high-contrast setting also gets the high-contrast theme.
            highContrastTheme: buildTheme(prefs.appearance == Appearance.dark ? Appearance.dark : Appearance.highContrast),
            routerConfig: router,
          ),
        ),
      ),
    );
  }
}
