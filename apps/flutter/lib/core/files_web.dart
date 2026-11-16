import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Downloads a text file through the browser. Returns what to tell the user.
Future<String> saveTextFile(String name, String content) async {
  final bytes = utf8.encode(content);
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: 'text/csv;charset=utf-8'));
  final url = web.URL.createObjectURL(blob);
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body!.append(link);
  link.click();
  link.remove();
  web.URL.revokeObjectURL(url);
  return 'Downloaded $name';
}
