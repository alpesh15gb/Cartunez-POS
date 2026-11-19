import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../core/billing.dart';
import '../main.dart';
import 'theme.dart';
import 'widgets.dart';

/// A part's main photo (uploaded), its built-in picture, or an icon.
class PartPhoto extends StatelessWidget {
  const PartPhoto({super.key, required this.product, this.imageId, this.fit = BoxFit.cover, this.iconSize = 44});
  final Json product;

  /// A specific photo; defaults to the part's main photo.
  final String? imageId;
  final BoxFit fit;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final placeholder = Icon(Icons.settings_outlined, size: iconSize, color: const Color(0xFF8FA99B));
    final id = imageId ?? app.photosOf('${product['id']}').firstOrNull?['id'] as String?;
    if (id != null) {
      return FutureBuilder<Uint8List>(
        future: app.photoBytes(id),
        builder: (context, snap) => snap.hasData
            ? Image.memory(snap.data!, fit: fit, gaplessPlayback: true, errorBuilder: (_, _, _) => placeholder)
            // A still placeholder while loading: no spinners flickering through long lists.
            : Center(child: snap.hasError ? placeholder : Icon(Icons.image_outlined, size: iconSize * 0.7, color: const Color(0xFFB9C9BF))),
      );
    }
    final icon = '${product['icon'] ?? ''}';
    return icon.isEmpty ? placeholder : Image.asset('assets/parts/$icon.jpg', fit: fit, errorBuilder: (_, _, _) => placeholder);
  }
}

/// Shrinks a photo to at most 1600 px on its longest side as an 85% JPEG.
/// Runs in the background on Windows and Android.
Future<({Uint8List bytes, int width, int height})?> preparePhoto(Uint8List original) =>
    kIsWeb ? Future.value(_prepare(original)) : compute(_prepare, original);

({Uint8List bytes, int width, int height})? _prepare(Uint8List original) {
  final decoded = img.decodeImage(original);
  if (decoded == null) return null;
  final oriented = img.bakeOrientation(decoded);
  const max = 1600;
  final resized = oriented.width > max || oriented.height > max
      ? img.copyResize(oriented, width: oriented.width >= oriented.height ? max : null, height: oriented.height > oriented.width ? max : null, interpolation: img.Interpolation.average)
      : oriented;
  return (bytes: Uint8List.fromList(img.encodeJpg(resized, quality: 85)), width: resized.width, height: resized.height);
}

/// Add, order and remove a part's photos. The first photo is the main one.
Future<void> editPhotos(BuildContext context, Json product) =>
    showDialog<void>(context: context, builder: (_) => _PhotosDialog(product: product));

class _PhotosDialog extends StatefulWidget {
  const _PhotosDialog({required this.product});
  final Json product;
  @override
  State<_PhotosDialog> createState() => _PhotosDialogState();
}

class _PhotosDialogState extends State<_PhotosDialog> {
  String? busy;

  Future<void> _work(String label, Future<void> Function() action) async {
    setState(() => busy = label);
    try {
      await action();
    } catch (e) {
      if (mounted) context.appRead.toast(errorText(e));
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  Future<void> _add() async {
    final app = context.appRead;
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty) return;
    await _work('Adding photos…', () async {
      var added = 0;
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        final photo = await preparePhoto(bytes);
        if (photo == null) {
          app.toast('${file.name} is not a photo the app can read.');
          continue;
        }
        await app.api('/products/${widget.product['id']}/images',
            body: {'contentType': 'image/jpeg', 'data': base64Encode(photo.bytes), 'width': photo.width, 'height': photo.height});
        added++;
      }
      await app.sync();
      if (added > 0) app.toast('$added photo(s) added.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final photos = app.photosOf('${widget.product['id']}');
    final canEdit = app.canStock;
    return AlertDialog(
      title: Text('Photos · ${widget.product['name']}'),
      content: SizedBox(
        width: 640,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            photos.isEmpty
                ? 'No photos yet. Add clear photos of the part on a plain background.'
                : 'The first photo is the main one, shown at the counter and on the website.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (final (i, photo) in photos.indexed)
              SizedBox(
                width: 140,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      height: 120,
                      color: const Color(0xFFEFF3F0),
                      child: Stack(fit: StackFit.expand, children: [
                        PartPhoto(product: widget.product, imageId: '${photo['id']}'),
                        if (i == 0) const Positioned(left: 6, top: 6, child: StatusChip('Main')),
                      ]),
                    ),
                  ),
                  if (canEdit)
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      TextButton(
                        onPressed: i == 0 || busy != null
                            ? null
                            : () => _work('Saving…', () async {
                                  final order = [photo['id'], ...photos.where((p) => p['id'] != photo['id']).map((p) => p['id'])];
                                  await app.api('/products/${widget.product['id']}/images/order', body: {'imageIds': order});
                                  await app.sync();
                                }),
                        child: const Text('Make main'),
                      ),
                      IconButton(
                        tooltip: 'Remove photo',
                        onPressed: busy != null
                            ? null
                            : () => _work('Removing…', () async {
                                  if (!await confirm(context, 'Remove this photo?', 'It is also removed from the website.', action: 'Remove')) return;
                                  await app.api('/products/${widget.product['id']}/images/${photo['id']}', method: 'DELETE');
                                  await app.sync();
                                }),
                        icon: const Icon(Icons.delete_outline, color: Brand.danger),
                      ),
                    ]),
                ]),
              ),
          ]),
          if (busy != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(busy!),
              ]),
            ),
        ]),
      ),
      actions: [
        if (canEdit)
          FilledButton.icon(
            onPressed: busy != null || photos.length >= 8 ? null : _add,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: Text(photos.length >= 8 ? '8 photos at most' : 'Add photos'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}
