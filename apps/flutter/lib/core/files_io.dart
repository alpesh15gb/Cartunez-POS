import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

/// Saves a text file to Downloads (Windows) or offers to share it (Android).
/// Returns what to tell the user.
Future<String> saveTextFile(String name, String content) async {
  final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(content);
  if (Platform.isAndroid) {
    await Printing.sharePdf(bytes: await file.readAsBytes(), filename: name);
  }
  return 'Saved ${file.path}';
}
