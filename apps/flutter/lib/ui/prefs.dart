import 'package:flutter/material.dart';

import '../core/store.dart';

/// How the app looks on this device.
enum Appearance {
  light('Light', Icons.light_mode_outlined),
  dark('Dark', Icons.dark_mode_outlined),
  highContrast('High contrast', Icons.contrast);

  const Appearance(this.label, this.icon);
  final String label;
  final IconData icon;

  Appearance get next => Appearance.values[(index + 1) % Appearance.values.length];
}

/// Per-device UI preferences (appearance, rail state). Kept on the device in
/// its own store key, apart from the register workspace.
class UiPrefs extends ChangeNotifier {
  UiPrefs({this.appearance = Appearance.light, this.railExpanded = false});

  static const _key = 'ui-prefs';

  Appearance appearance;

  /// Whether the tablet-width rail shows labels. Desktop always shows them.
  bool railExpanded;

  LocalStore? _store;

  Future<void> load() async {
    try {
      _store = await LocalStore.open();
      final saved = await _store!.read(_key);
      if (saved is Map) {
        appearance = Appearance.values.where((a) => a.name == saved['appearance']).firstOrNull ?? appearance;
        railExpanded = saved['railExpanded'] == true;
        notifyListeners();
      }
    } catch (_) {
      // Preferences are a convenience; the app works with the defaults.
    }
  }

  void setAppearance(Appearance value) {
    if (value == appearance) return;
    appearance = value;
    _save();
  }

  void toggleRail() {
    railExpanded = !railExpanded;
    _save();
  }

  void _save() {
    notifyListeners();
    _store?.write(_key, {'appearance': appearance.name, 'railExpanded': railExpanded}).catchError((_) {});
  }
}

class UiPrefsScope extends InheritedNotifier<UiPrefs> {
  const UiPrefsScope({super.key, required UiPrefs prefs, required super.child}) : super(notifier: prefs);

  static UiPrefs of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<UiPrefsScope>()!.notifier!;

  /// Null outside the app (for example in widget tests of a single screen).
  static UiPrefs? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<UiPrefsScope>()?.notifier;
}
