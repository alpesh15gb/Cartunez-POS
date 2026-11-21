import 'package:web/web.dart' as web;

/// Opens the link in a new browser tab (wa.me hands over to WhatsApp).
Future<bool> openExternalLink(String url) async {
  web.window.open(url, '_blank');
  return true;
}
