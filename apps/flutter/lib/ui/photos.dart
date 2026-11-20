import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../core/billing.dart';
import '../main.dart';
import '../state/app_state.dart';
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

/// Whether this device can take a photo with its camera (Android phones and tablets).
bool get canUseCamera {
  try {
    return ImagePicker().supportsImageSource(ImageSource.camera) && (kIsWeb ? false : defaultTargetPlatform == TargetPlatform.android);
  } catch (_) {
    return false;
  }
}

/// Takes a photo with the camera and returns it ready to upload (resized JPEG), or null if cancelled.
Future<({Uint8List bytes, int width, int height})?> capturePhoto() async {
  final shot = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400, maxHeight: 2400, imageQuality: 92);
  if (shot == null) return null;
  return preparePhoto(await shot.readAsBytes());
}

/// Photos from the gallery (Android: shrunk by the system first, so big phone photos
/// do not run a tablet out of memory) or from files (Windows, web).
Future<List<({Uint8List bytes, int width, int height})>> pickGalleryPhotos(AppState app) async {
  final result = <({Uint8List bytes, int width, int height})>[];
  if (canUseCamera) {
    for (final file in await ImagePicker().pickMultiImage(maxWidth: 2400, maxHeight: 2400, imageQuality: 92)) {
      final photo = await preparePhoto(await file.readAsBytes());
      if (photo == null) {
        app.toast('${file.name} is not a photo the app can read.');
      } else {
        result.add(photo);
      }
    }
    return result;
  }
  for (final file in await FilePicker.pickFiles(type: FileType.image)) {
    final photo = await preparePhoto(await file.readAsBytes());
    if (photo == null) {
      app.toast('${file.name} is not a photo the app can read.');
    } else {
      result.add(photo);
    }
  }
  return result;
}

/// Uploads prepared photos to a part (used after a new part is saved).
Future<void> uploadPartPhotos(AppState app, String productId, List<({Uint8List bytes, int width, int height})> photos) async {
  for (final photo in photos) {
    await app.api('/products/$productId/images',
        body: {'contentType': 'image/jpeg', 'data': base64Encode(photo.bytes), 'width': photo.width, 'height': photo.height});
  }
}

/// Photo buttons inside the "Add part" form: take with the camera (Android) or choose files.
/// The photos are uploaded once the part is saved.
class PendingPartPhotos extends StatefulWidget {
  const PendingPartPhotos({super.key, required this.photos});
  final List<({Uint8List bytes, int width, int height})> photos;
  @override
  State<PendingPartPhotos> createState() => _PendingPartPhotosState();
}

class _PendingPartPhotosState extends State<PendingPartPhotos> {
  bool busy = false;

  Future<void> _get(bool camera) async {
    final app = context.appRead;
    setState(() => busy = true);
    try {
      if (camera) {
        final photo = await capturePhoto();
        if (photo != null) widget.photos.add(photo);
      } else {
        widget.photos.addAll(await pickGalleryPhotos(app));
      }
    } catch (e) {
      app.toast('The photo could not be taken. ${errorText(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final (i, photo) in widget.photos.indexed)
          Stack(children: [
            ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(photo.bytes, width: 72, height: 72, fit: BoxFit.cover)),
            Positioned(
              right: 0,
              top: 0,
              child: InkWell(
                onTap: () => setState(() => widget.photos.removeAt(i)),
                child: const CircleAvatar(radius: 11, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 14, color: Colors.white)),
              ),
            ),
          ]),
        if (canUseCamera)
          FilledButton.tonalIcon(
            onPressed: busy || widget.photos.length >= 8 ? null : () => _get(true),
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Take photo'),
          ),
        OutlinedButton.icon(
          onPressed: busy || widget.photos.length >= 8 ? null : () => _get(false),
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: Text(canUseCamera ? 'From gallery' : 'Add photos'),
        ),
        if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
    );
  }
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
    await _work('Adding photos…', () async {
      final photos = await pickGalleryPhotos(app);
      if (photos.isEmpty) return;
      await uploadPartPhotos(app, '${widget.product['id']}', photos);
      await app.sync();
      app.toast('${photos.length} photo(s) added.');
    });
  }

  Future<void> _capture() async {
    final app = context.appRead;
    await _work('Adding photo…', () async {
      final photo = await capturePhoto();
      if (photo == null) return;
      await uploadPartPhotos(app, '${widget.product['id']}', [photo]);
      await app.sync();
      app.toast('Photo added.');
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
        if (canEdit && canUseCamera)
          FilledButton.tonalIcon(
            onPressed: busy != null || photos.length >= 8 ? null : _capture,
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: const Text('Take photo'),
          ),
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
