// Raw label printing: Windows installed printers and network printers on
// native builds; the browser cannot send raw data, so the web prints PDFs.
export 'label_printer_io.dart' if (dart.library.js_interop) 'label_printer_web.dart';
