import 'package:web/web.dart' as web;

/// Opens [url] in a new tab. Returns false when it could not be opened.
Future<bool> openLink(String url) async {
  try {
    web.window.open(url, '_blank');
    return true;
  } catch (_) {
    return false;
  }
}
