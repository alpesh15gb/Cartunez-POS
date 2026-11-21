// WS-F: optional local ZPL bridge, so the web app can print straight to a
// Zebra without the print dialog.
//
// A browser cannot open a printer port, but it may call a small program on
// the same PC over http://127.0.0.1. Two kinds are supported:
//  * Zebra Browser Print (free from Zebra): URL ending in /write, default
//    http://127.0.0.1:9100/write. The app asks it for its default printer
//    (GET /default?type=printer) and posts {device, data: ZPL}.
//  * Any other bridge (for example a tiny script that forwards to the printer):
//    the ZPL is POSTed as plain text to the URL as given.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const defaultBridgeUrl = 'http://127.0.0.1:9100/write';

/// What to tell the owner when setting the bridge up.
const bridgeSetupHelp =
    'Install Zebra Browser Print on the counter PC (zebra.com > Support > Browser Print), connect the Zebra by USB and set it '
    'as the default device in Browser Print. When this site first prints, allow it in the Browser Print prompt. '
    'Keep the address as http://127.0.0.1:9100/write. Another bridge program works too if it accepts the ZPL posted as text.';

class BridgeError implements Exception {
  BridgeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Only local addresses: the labels never leave this PC.
Uri bridgeUri(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') ||
      !const {'127.0.0.1', 'localhost', '[::1]', '::1'}.contains(uri.host)) {
    throw BridgeError('Enter the bridge address on this computer, for example $defaultBridgeUrl.');
  }
  return uri;
}

bool isBrowserPrint(Uri uri) => uri.path.endsWith('/write');

Future<void> sendZplToBridge(String url, String zpl, {http.Client? client}) async {
  final uri = bridgeUri(url);
  final c = client ?? http.Client();
  try {
    if (isBrowserPrint(uri)) {
      final base = uri.replace(path: uri.path.substring(0, uri.path.length - '/write'.length));
      final found = await c.get(base.replace(path: '${base.path}/default', queryParameters: {'type': 'printer'}))
          .timeout(const Duration(seconds: 5));
      if (found.statusCode != 200 || found.body.trim().isEmpty) {
        throw BridgeError('Zebra Browser Print has no default printer. Open Browser Print and choose the Zebra as the default device.');
      }
      final device = jsonDecode(found.body);
      final sent = await c.post(uri, headers: {'Content-Type': 'text/plain;charset=UTF-8'},
          body: jsonEncode({'device': device, 'data': zpl})).timeout(const Duration(seconds: 10));
      if (sent.statusCode >= 300) throw BridgeError('Zebra Browser Print refused the labels (${sent.statusCode}). ${sent.body}'.trim());
    } else {
      final sent = await c.post(uri, headers: {'Content-Type': 'text/plain;charset=UTF-8'}, body: zpl)
          .timeout(const Duration(seconds: 10));
      if (sent.statusCode >= 300) throw BridgeError('The label bridge refused the labels (${sent.statusCode}).');
    }
  } on TimeoutException {
    throw BridgeError('The label bridge at $url did not answer. Check it is running.');
  } on http.ClientException {
    throw BridgeError('Could not reach the label bridge at $url. Check Zebra Browser Print (or your bridge) is running '
        'and that this site is allowed in it.');
  } on FormatException {
    throw BridgeError('Zebra Browser Print sent an answer the app did not understand. Restart Browser Print and try again.');
  } finally {
    if (client == null) c.close();
  }
}
