import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Raw (ZPL) printing is available on Windows (installed printer) and on any
/// platform with a network printer.
bool get canPrintToInstalledPrinter => Platform.isWindows;
bool get canPrintToNetworkPrinter => true;

/// Names of printers installed in Windows, default first. Empty elsewhere.
Future<List<String>> installedPrinters() async {
  if (!Platform.isWindows) return [];
  return Isolate.run(_enumPrinters);
}

/// Sends ZPL straight to a Windows printer (the Zebra driver passes RAW data
/// through untouched), bypassing the print dialog.
Future<void> printRawToInstalled(String printerName, String data, {String? outputFile}) async {
  if (!Platform.isWindows) throw UnsupportedError('Installed-printer printing needs Windows.');
  final error = await Isolate.run(() => _writeRaw(printerName, utf8.encode(data), outputFile));
  if (error != null) throw Exception(error);
}

/// Sends ZPL to a network printer on its raw port (9100 on Zebra printers).
Future<void> printRawToNetwork(String host, int port, String data) async {
  final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
  try {
    socket.add(utf8.encode(data));
    await socket.flush();
  } finally {
    await socket.close();
  }
}

// ---------- Windows print spooler (winspool.drv) ----------

final class _DocInfo1 extends Struct {
  external Pointer<Utf16> docName;
  external Pointer<Utf16> outputFile;
  external Pointer<Utf16> datatype;
}

final class _PrinterInfo4 extends Struct {
  external Pointer<Utf16> printerName;
  external Pointer<Utf16> serverName;
  @Uint32()
  external int attributes;
}

typedef _OpenNative = Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>);
typedef _Open = int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>);
typedef _HandleNative = Int32 Function(IntPtr);
typedef _Handle = int Function(int);
typedef _StartDocNative = Uint32 Function(IntPtr, Uint32, Pointer<_DocInfo1>);
typedef _StartDoc = int Function(int, int, Pointer<_DocInfo1>);
typedef _WriteNative = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _Write = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>);
typedef _EnumNative = Int32 Function(Uint32, Pointer<Utf16>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint32>);
typedef _Enum = int Function(int, Pointer<Utf16>, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>);
typedef _DefaultNative = Int32 Function(Pointer<Utf16>, Pointer<Uint32>);
typedef _Default = int Function(Pointer<Utf16>, Pointer<Uint32>);
typedef _LastErrorNative = Uint32 Function();
typedef _LastError = int Function();

const _enumLocal = 0x2, _enumConnections = 0x4;

List<String> _enumPrinters() {
  final ws = DynamicLibrary.open('winspool.drv');
  final enumPrinters = ws.lookupFunction<_EnumNative, _Enum>('EnumPrintersW');
  final getDefault = ws.lookupFunction<_DefaultNative, _Default>('GetDefaultPrinterW');
  return using((arena) {
    final needed = arena<Uint32>(), count = arena<Uint32>();
    enumPrinters(_enumLocal | _enumConnections, nullptr, 4, nullptr, 0, needed, count);
    if (needed.value == 0) return <String>[];
    final buffer = arena<Uint8>(needed.value);
    if (enumPrinters(_enumLocal | _enumConnections, nullptr, 4, buffer, needed.value, needed, count) == 0) return <String>[];
    final infos = buffer.cast<_PrinterInfo4>();
    final names = [for (var i = 0; i < count.value; i++) infos[i].printerName.toDartString()];
    final size = arena<Uint32>()..value = 512;
    final name = arena<Uint16>(512).cast<Utf16>();
    if (getDefault(name, size) != 0) {
      final preferred = name.toDartString();
      if (names.remove(preferred)) names.insert(0, preferred);
    }
    return names;
  });
}

/// Returns an error message, or null when the job was handed to the spooler.
String? _writeRaw(String printerName, List<int> bytes, String? outputFile) {
  final ws = DynamicLibrary.open('winspool.drv');
  final lastError = DynamicLibrary.open('kernel32.dll').lookupFunction<_LastErrorNative, _LastError>('GetLastError');
  final open = ws.lookupFunction<_OpenNative, _Open>('OpenPrinterW');
  final close = ws.lookupFunction<_HandleNative, _Handle>('ClosePrinter');
  final startDoc = ws.lookupFunction<_StartDocNative, _StartDoc>('StartDocPrinterW');
  final endDoc = ws.lookupFunction<_HandleNative, _Handle>('EndDocPrinter');
  final startPage = ws.lookupFunction<_HandleNative, _Handle>('StartPagePrinter');
  final endPage = ws.lookupFunction<_HandleNative, _Handle>('EndPagePrinter');
  final write = ws.lookupFunction<_WriteNative, _Write>('WritePrinter');

  return using((arena) {
    final handle = arena<IntPtr>();
    if (open(printerName.toNativeUtf16(allocator: arena), handle, nullptr) == 0) {
      return 'Could not open the printer "$printerName" (Windows error ${lastError()}). Check it is installed and switched on.';
    }
    final printer = handle.value;
    try {
      final doc = arena<_DocInfo1>()
        ..ref.docName = 'Cartunez labels'.toNativeUtf16(allocator: arena)
        ..ref.outputFile = outputFile == null ? nullptr : outputFile.toNativeUtf16(allocator: arena)
        ..ref.datatype = 'RAW'.toNativeUtf16(allocator: arena);
      if (startDoc(printer, 1, doc) == 0) {
        return 'The printer "$printerName" did not accept the label job (Windows error ${lastError()}). '
            'Choose the Zebra printer itself, not a PDF or Office printer.';
      }
      try {
        startPage(printer);
        final data = arena<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
        final written = arena<Uint32>();
        final ok = write(printer, data, bytes.length, written) != 0 && written.value == bytes.length;
        endPage(printer);
        if (!ok) return 'Sending the labels to "$printerName" failed (Windows error ${lastError()}).';
      } finally {
        endDoc(printer);
      }
      return null;
    } finally {
      close(printer);
    }
  });
}
