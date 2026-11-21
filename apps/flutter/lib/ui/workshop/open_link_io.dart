import 'dart:io';

/// Windows opens the default browser; elsewhere the caller copies the link instead.
Future<bool> openExternalLink(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
      return true;
    }
  } catch (_) {}
  return false;
}
