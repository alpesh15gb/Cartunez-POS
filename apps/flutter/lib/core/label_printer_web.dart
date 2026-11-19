bool get canPrintToInstalledPrinter => false;
bool get canPrintToNetworkPrinter => false;

Future<List<String>> installedPrinters() async => [];

Future<void> printRawToInstalled(String printerName, String data, {String? outputFile}) =>
    throw UnsupportedError('Browsers cannot send labels straight to a printer. Use the Windows app.');

Future<void> printRawToNetwork(String host, int port, String data) =>
    throw UnsupportedError('Browsers cannot send labels straight to a printer. Use the Windows app.');
