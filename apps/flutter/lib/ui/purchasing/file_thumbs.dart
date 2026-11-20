
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/billing.dart';
import '../../core/files.dart';
import '../../main.dart';
import '../theme.dart';
import '../widgets.dart';

// ---------------------------------------------------------------- photos

/// A small preview of a bill photo (or a PDF icon); tap to open it large.
class FileThumb extends StatelessWidget {
  const FileThumb({super.key, required this.file, this.size = 72});
  final Json file;
  final double size;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final isPdf = file['contentType'] == 'application/pdf';
    return InkWell(
      onTap: () => viewFile(context, file),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: size,
          height: size,
          color: const Color(0xFFEFF3F0),
          child: isPdf
              ? const Icon(Icons.picture_as_pdf_outlined, size: 36, color: Brand.muted)
              : FutureBuilder<Uint8List>(
                  future: app.fileBytes('${file['id']}'),
                  builder: (context, snap) => snap.hasData
                      ? Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
                      : const Icon(Icons.image_outlined, color: Brand.muted),
                ),
        ),
      ),
    );
  }
}

Future<void> viewFile(BuildContext context, Json file) async {
  final app = context.appRead;
  if (file['contentType'] == 'application/pdf') {
    try {
      final bytes = await app.fileBytes('${file['id']}');
      final name = '${file['name'] ?? ''}'.toLowerCase().endsWith('.pdf') ? '${file['name']}' : 'supplier-bill-${file['id']}.pdf';
      app.toast(await saveBytesFile(name, bytes, mimeType: 'application/pdf'));
    } catch (e) {
      app.toast(errorText(e));
    }
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: Stack(children: [
        InteractiveViewer(
          maxScale: 6,
          child: FutureBuilder<Uint8List>(
            future: app.fileBytes('${file['id']}'),
            builder: (context, snap) => snap.hasData
                ? Image.memory(snap.data!, fit: BoxFit.contain)
                : const SizedBox(width: 300, height: 300, child: Center(child: CircularProgressIndicator())),
          ),
        ),
        Positioned(right: 4, top: 4, child: IconButton.filledTonal(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
      ]),
    ),
  );
}
