// WS-A: receipt printing and sharing after a counter sale.
//
// Windows: silent direct print to the receipt printer chosen on this device
// (or the Windows default printer). Web and Android: the normal print dialog.
// The per-device choice is kept in local storage, never on the server.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import 'store.dart';
import 'receipt_print_io.dart' if (dart.library.js_interop) 'receipt_print_web.dart' as platform;

export 'receipt_print_io.dart' if (dart.library.js_interop) 'receipt_print_web.dart' show canPrintSilently;

/// This device's receipt printer settings.
class ReceiptPrinterPrefs extends ChangeNotifier {
  ReceiptPrinterPrefs._();
  static final instance = ReceiptPrinterPrefs._();
  static const _key = 'receipt-printer';

  /// Printer name for silent printing (Windows). Empty: the Windows default printer.
  String printer = '';

  /// Print the receipt as soon as a sale completes.
  bool autoPrint = false;

  LocalStore? _store;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _store = await LocalStore.open();
      final saved = await _store!.read(_key);
      if (saved is Map) {
        printer = '${saved['printer'] ?? ''}';
        autoPrint = saved['autoPrint'] == true;
        notifyListeners();
      }
    } catch (_) {
      // A convenience: printing still works through the dialog.
    }
  }

  Future<void> save({String? printer, bool? autoPrint}) async {
    if (printer != null) this.printer = printer;
    if (autoPrint != null) this.autoPrint = autoPrint;
    notifyListeners();
    try {
      await _store?.write(_key, {'printer': this.printer, 'autoPrint': this.autoPrint});
    } catch (_) {}
  }

  /// Tests: skip storage and start from the defaults.
  @visibleForTesting
  void reset() {
    printer = '';
    autoPrint = false;
    _loaded = true;
  }
}

/// Installed printers this device can print to silently (Windows only).
Future<List<Printer>> receiptPrinters() => platform.receiptPrinters();

/// Prints a receipt PDF: silently to the chosen printer on Windows, otherwise
/// through the system print dialog. Returns a message when printed silently.
Future<String> sendReceiptPdf(Uint8List bytes, String name) async {
  final prefs = ReceiptPrinterPrefs.instance;
  await prefs.load();
  if (platform.canPrintSilently) {
    final printers = await platform.receiptPrinters();
    final chosen = printers.where((p) => p.name == prefs.printer || p.url == prefs.printer).firstOrNull ??
        printers.where((p) => p.isDefault).firstOrNull;
    if (chosen != null) {
      final ok = await Printing.directPrintPdf(printer: chosen, name: name, onLayout: (_) async => bytes);
      if (ok) return 'Receipt sent to ${chosen.name}.';
    }
  }
  if (kIsWeb) {
    // In browsers, Printing.layoutPdf mounts a hidden iframe next to the app
    // whose window.print() dialog blocks Chrome / Flutter pointer events until
    // dismissed. Guard with a timeout and remove any stray print iframe after.
    try {
      await Printing.layoutPdf(name: name, onLayout: (_) async => bytes).timeout(const Duration(seconds: 15));
    } catch (_) {}
    platform.cleanupPrintFrame();
    return '';
  }
  await Printing.layoutPdf(name: name, onLayout: (_) async => bytes);
  return '';
}

/// Shares the receipt PDF through the system share sheet (Android, web, Windows).
Future<void> shareReceiptPdf(Uint8List bytes, String fileName) =>
    Printing.sharePdf(bytes: bytes, filename: fileName);

/// wa.me link with the receipt summary. Indian 10-digit mobiles get +91.
/// Without a number WhatsApp asks whom to send it to.
Uri whatsappUri(String? phone, String text) {
  var digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('0')) digits = digits.substring(1);
  if (digits.length == 10) digits = '91$digits';
  return Uri.parse('https://wa.me/${digits.length >= 11 ? digits : ''}?text=${Uri.encodeComponent(text)}');
}

/// The one way the app opens WhatsApp (receipts, collection reminders, estimates):
/// the wa.me link goes to the WhatsApp app on Android, a new tab on web and the
/// default browser on Windows. Only if that fails is the link copied, and
/// [toast] says so.
Future<void> openWhatsApp(Uri uri, void Function(String message) toast,
    {String copied = 'Could not open WhatsApp, so the link was copied. Paste it in a browser or chat.'}) async {
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (opened) return;
  await Clipboard.setData(ClipboardData(text: uri.toString()));
  toast(copied);
}

/// UPI payment link for a static QR: the shop's UPI ID, payee name and amount.
String upiPayUri({required String vpa, String payee = '', required int amountMinor, String note = ''}) {
  final amount = (amountMinor / 100).toStringAsFixed(2);
  final params = [
    'pa=${Uri.encodeComponent(vpa)}',
    if (payee.isNotEmpty) 'pn=${Uri.encodeComponent(payee)}',
    'am=$amount',
    'cu=INR',
    if (note.isNotEmpty) 'tn=${Uri.encodeComponent(note)}',
  ];
  return 'upi://pay?${params.join('&')}';
}
