import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../main.dart';
import '../state/app_state.dart';
import 'login.dart';
import 'shell.dart';

// Address-based navigation (go_router). Every workspace tab has a clean path
// (see `workspaces` in shell.dart); browser refresh, back and forward work on
// the web, and links survive sign-in (/login?from=...).

/// Changes only when something that decides where a user may be changes:
/// startup, who is signed in, their role and the switched-on modules. The
/// router re-runs its redirect then, and not on every sync.
class RouteGuard extends ValueNotifier<String> {
  RouteGuard(this.app) : super(_signature(app)) {
    app.addListener(_update);
  }
  final AppState app;

  static String _signature(AppState app) => [
        app.ready,
        app.startupProblem != null,
        app.session == null ? '' : identityHashCode(app.session),
        app.role,
        for (final f in allFeatures) app.feature(f),
      ].join('|');

  void _update() => value = _signature(app);

  @override
  void dispose() {
    app.removeListener(_update);
    super.dispose();
  }
}

String? _safeFrom(String? from) {
  if (from == null || !from.startsWith('/') || from.startsWith('//') || from.startsWith('/login')) return null;
  return from;
}

String _purchasingSupplierPath(Uri uri) => uri.replace(path: uri.path.replaceFirst('/people/', '/purchasing/')).toString();

/// Where [uri] should go instead, or null to stay.
String? redirectFor(AppState app, Uri uri) {
  if (!app.ready || app.startupProblem != null) return null;
  final path = uri.path;
  if (app.session == null) {
    if (path == '/login') return null;
    final from = path == '/' ? null : uri.toString();
    return Uri(path: '/login', queryParameters: from == null ? null : {'from': from}).toString();
  }
  if (path == '/login') return _safeFrom(uri.queryParameters['from']) ?? homePath(app);
  if (path == '/people/suppliers' || path.startsWith('/people/suppliers/')) {
    return _purchasingSupplierPath(uri);
  }
  final match = matchPath(path);
  if (match != null) {
    if (match.tab.visibleTo(app)) return null;
    final ws = workspaceOf(match.tab);
    final tabs = ws.visibleTabs(app);
    return path == ws.root && tabs.isNotEmpty ? tabs.first.path : homePath(app);
  }
  for (final ws in workspaces) {
    if (path == ws.root || path == '${ws.root}/') {
      final tabs = ws.visibleTabs(app);
      return tabs.isEmpty ? homePath(app) : tabs.first.path;
    }
  }
  return homePath(app);
}

final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final _shellNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'workspace');

GoRouter buildRouter(AppState app, {required Listenable refresh, String initialLocation = '/'}) {
  Page<void> page(TabDef tab, GoRouterState state) =>
      NoTransitionPage(key: ValueKey(tab.id), child: WorkspacePage(tab: tab, arg: state.pathParameters['arg']));
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    refreshListenable: refresh,
    redirect: (context, state) => redirectFor(app, state.uri),
    // An address that matches nothing goes to the user's home tab.
    onException: (context, state, router) => router.go(app.session == null ? '/login' : homePath(app)),
    routes: [
      GoRoute(path: '/', redirect: (_, _) => app.session == null ? '/login' : homePath(app)),
      GoRoute(path: '/login', builder: (_, _) => const AppGate(child: LoginScreen())),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppGate(child: Shell(location: state.uri.path, child: child)),
        routes: [
          // Bookmarks from People now open the single supplier workspace.
          for (final path in ['/people/suppliers', '/people/suppliers/:arg'])
            GoRoute(path: path, redirect: (_, state) => _purchasingSupplierPath(state.uri)),
          for (final ws in workspaces)
            for (final tab in ws.tabs) ...[
              GoRoute(path: tab.path, pageBuilder: (_, state) => page(tab, state)),
              if (tab.hasArg) GoRoute(path: '${tab.path}/:arg', pageBuilder: (_, state) => page(tab, state)),
            ],
          // Workspace addresses (/orders, /catalog, ...) open their first tab.
          for (final ws in workspaces)
            if (!ws.tabs.any((t) => t.path == ws.root))
              GoRoute(path: ws.root, redirect: (_, state) => redirectFor(app, state.uri)),
        ],
      ),
    ],
  );
}

/// Startup, failure and loading states shown in place of any page.
class AppGate extends StatelessWidget {
  const AppGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (app.startupProblem != null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(app.startupProblem!, textAlign: TextAlign.center),
            TextButton(onPressed: app.init, child: const Text('Retry')),
          ]),
        ),
      );
    }
    // Not ready yet, or signed out and about to move to /login.
    if (!app.ready || (app.session == null && child is! LoginScreen)) {
      return const Scaffold(key: ValueKey('loading'), body: Center(child: CircularProgressIndicator()));
    }
    return child;
  }
}
