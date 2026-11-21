// Browsers cannot open a printer port. The web prints labels as exact-size PDFs
// (core/label_sheet_pdf.dart) or through a local ZPL bridge (core/zpl_bridge.dart).
bool get canPrintToInstalledPrinter => false;
bool get canPrintToNetworkPrinter => false;

Future<List<String>> installedPrinters() async => [];

const _useInstead = 'Browsers cannot send labels straight to a printer. '
    'Print a PDF label (roll or A4 sheet), use the Zebra Browser Print bridge, or use the Windows app.';

Future<void> printRawToInstalled(String printerName, String data, {String? outputFile}) =>
    throw UnsupportedError(_useInstead);

Future<void> printRawToNetwork(String host, int port, String data) => throw UnsupportedError(_useInstead);
