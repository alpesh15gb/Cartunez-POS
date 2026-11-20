import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';

import 'state/app_state.dart';
import 'ui/login.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    MobileScannerPlatform.instance
      ..setWebBarcodeReader(WebBarcodeReader.zxingWasm)
      ..setBarcodeLibraryScriptUrl('scanner/3.1.6/reader.js');
  }
  final state = AppState();
  runApp(CartunezApp(state: state));
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

class CartunezApp extends StatelessWidget {
  const CartunezApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    return AppScope(
      state: state,
      child: ListenableBuilder(listenable: state, builder: (context, _) => MaterialApp(
        key: ObjectKey(state.session),
        title: 'Cartunez POS',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const _Root(),
      )),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final Widget child;
    if (app.startupProblem != null) {
      child = Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(app.startupProblem!, textAlign: TextAlign.center),
        TextButton(onPressed: app.init, child: const Text('Retry')),
      ])));
    } else if (!app.ready) {
      child = const Scaffold(key: ValueKey('loading'), body: Center(child: CircularProgressIndicator()));
    } else if (app.session == null) {
      child = const LoginScreen(key: ValueKey('login'));
    } else {
      child = const Shell(key: ValueKey('shell'));
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: child);
  }
}
