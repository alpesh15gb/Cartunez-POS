import 'dart:io';

/// Opens [url] with the system's handler on desktop. Returns false where that is
/// not possible (Android without a plugin): the caller then offers to copy it.
Future<bool> openLink(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [url]);
      return true;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [url]);
      return true;
    }
  } catch (_) {}
  return false;
}
