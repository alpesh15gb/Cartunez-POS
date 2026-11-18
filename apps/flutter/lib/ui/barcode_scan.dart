import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

bool get supportsBarcodeCamera => kIsWeb || const {
  TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.macOS,
}.contains(defaultTargetPlatform);

Future<String?> requestBarcode(BuildContext context) {
  return Navigator.of(context).push<String>(MaterialPageRoute(
    builder: (_) => const _BarcodePage(),
  ));
}

class _BarcodePage extends StatefulWidget {
  const _BarcodePage();

  @override
  State<_BarcodePage> createState() => _BarcodePageState();
}

class _BarcodePageState extends State<_BarcodePage> {
  final input = TextEditingController();
  bool camera = false;
  bool submitted = false;

  void submit(String value) {
    if (submitted || value.trim().isEmpty) return;
    submitted = true;
    Navigator.pop(context, value.trim());
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan barcode')),
    body: camera
        ? Column(children: [
            Expanded(child: MobileScanner(
              errorBuilder: (context, error) => const Center(child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Camera unavailable. Check browser or device permissions, or use a scanner or keyboard.', textAlign: TextAlign.center),
              )),
              onDetect: (capture) {
                final codes = capture.barcodes.map((b) => b.rawValue?.trim()).whereType<String>().where((code) => code.isNotEmpty).toSet();
                if (codes.length == 1) submit(codes.single);
              },
            )),
            const Padding(padding: EdgeInsets.all(12), child: Text('Point the camera at one barcode.')),
            SafeArea(child: TextButton.icon(
              onPressed: () => setState(() => camera = false),
              icon: const Icon(Icons.keyboard), label: const Text('Use scanner or keyboard'),
            )),
          ])
        : Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
              TextField(
                autofocus: true,
                controller: input,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: submit,
                decoration: const InputDecoration(labelText: 'Barcode', helperText: 'Use a USB or Bluetooth scanner, or enter the code.'),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => submit(input.text), child: const Text('Use barcode')),
              if (supportsBarcodeCamera)
                TextButton.icon(onPressed: () => setState(() => camera = true), icon: const Icon(Icons.camera_alt_outlined), label: const Text('Use camera')),
            ]),
          )),
  );
}
