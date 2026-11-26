
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
    builder: (context) => _FileViewer(file: file),
  );
}

class _FileViewer extends StatefulWidget {
  const _FileViewer({required this.file});
  final Json file;
  @override
  State<_FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<_FileViewer> {
  late Future<Uint8List> bytes;

  @override
  void initState() {
    super.initState();
    bytes = context.appRead.fileBytes('${widget.file['id']}');
  }

  void _retry() => setState(() {
    bytes = context.appRead.fileBytes('${widget.file['id']}');
  });

  @override
  Widget build(BuildContext context) => Dialog(
        child: Stack(children: [
          InteractiveViewer(
            maxScale: 6,
            child: FutureBuilder<Uint8List>(
              future: bytes,
              builder: (context, snap) {
                if (snap.hasError) {
                  return SizedBox(
                    width: 300,
                    height: 300,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.broken_image_outlined, color: Brand.danger),
                          const SizedBox(height: 12),
                          const Text('Could not load this file.', textAlign: TextAlign.center),
                          const SizedBox(height: 4),
                          Text(errorText(snap.error!), textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(onPressed: _retry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
                        ]),
                      ),
                    ),
                  );
                }
                if (snap.hasData) return Image.memory(snap.data!, fit: BoxFit.contain);
                return const SizedBox(width: 300, height: 300, child: Center(child: CircularProgressIndicator()));
              },
            ),
          ),
          Positioned(right: 4, top: 4, child: IconButton.filledTonal(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))),
        ]),
      );
}
