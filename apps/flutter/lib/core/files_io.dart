import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';

/// Saves to Downloads on Windows or to the selected document location on Android.
/// Returns what to tell the user.
Future<String> saveTextFile(String name, String content) async {
  if (Platform.isAndroid) {
    final uri = await FilePicker.saveFile(fileName: name, bytes: Uint8List.fromList(utf8.encode(content)),
        mimeType: name.endsWith('.csv') ? 'text/csv' : 'text/plain');
    return uri == null ? 'Export cancelled.' : 'Saved $name.';
  }
  final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(content);
  return 'Saved ${file.path}';
}

/// Saves a binary file (for example a supplier's PDF bill) the same way.
Future<String> saveBytesFile(String name, Uint8List bytes, {String mimeType = 'application/octet-stream'}) async {
  if (Platform.isAndroid) {
    final uri = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mimeType);
    return uri == null ? 'Cancelled.' : 'Saved $name.';
  }
  final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes);
  return 'Saved ${file.path}';
}
