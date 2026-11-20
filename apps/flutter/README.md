# Cartunez POS app (web, Windows and Android)

The Flutter app for the shop counter. The same code runs in the browser at pos.cartunez.in, as a
Windows program and as an Android app, all talking to the server API in `apps/api`.

## What it does

- Billing: catalog with photos and stock, USB/Bluetooth keyboard-mode scanners with an Enter suffix,
  and camera scanning on Android and supported browsers. Repeat scans add one more. The register also has discounts,
  retail/wholesale, hold and resume, cash/card/UPI and split payments with change, receipts.
- Sales: invoices and credit notes, returns, voids, shifts with reasoned cash in/out, counts and drawer reconciliation.
- Customers, suppliers, parts (with in-store Code 128 barcodes and support for existing EAN/UPC labels), bins, stock adjust/count/move,
  catalog CSV import, reviewed bin counts, reorder suggestions, purchase orders and receipt-specific label printing, dashboard, reports with CSV export,
  settings, modules, staff, branches, approvals, sync and audit.
- Optional modules (vehicle fitment, branch transfers, warranty & cores) follow Settings › Modules.
- Every sale is saved on the device before it is sent. If the connection drops it is kept and sent
  later with the same transaction ID, so it can never be billed twice.

Not in the app yet: enrolled offline counters with their own invoice ranges, and fitment CSV import
(both were in the retired Next.js app).

## Scanner and report checks

- In Billing, Parts, or Bins, use **Scan barcode** or focus the search field and scan with an Enter
  suffix. Scanner buttons in stock and receiving forms select the matching part or bin. The Windows app
  uses keyboard-mode scanners. For a webcam on Windows, open the HTTPS web app in a browser that allows camera access.
- The web camera loads its pinned ZXing WebAssembly reader from the POS host when scanning starts. The reader and WebAssembly file in `web/scanner/3.1.6` match the version used by `mobile_scanner`. The packaged script adds a local file resolver. [ZXing WebAssembly reader](https://github.com/Sec-ant/zxing-wasm/tree/v3.1.6)
- Product lookup preserves leading zeroes and punctuation and matches equivalent valid UPC/EAN/GTIN
  representations. New internal codes print as Code 128. Print thermal labels at actual size and test a sample with each counter scanner.
- INR reports use IST business dates. Reports cover the active branch. The tender report reconciles
  recorded invoices, change and refunds. Managers can compare a CSV of gross INR Card and UPI captures by reference, amount and date.
  Report CSV headings identify the currency. A ₹500 amount exports as 500.00.

## Label design

Settings › Barcode labels › **Design label** (owner only) sets one design for the whole shop, saved on
the server so every counter prints the same label: label size (presets or a custom width × height),
1-3 labels across the roll and the gap between them, which lines print (shop name, part name, brand,
part number, SKU, bin location, digits under the barcode), price (selling price, MRP including tax,
both, or none), a text size for every line (S, M, L, XL), barcode width and height (Auto fits the
free space; S-XL set bar thickness and height in mm, the same on 203 and 300 dpi printers), and an
optional extra line. Drag any line or
the barcode on the preview to move it; **Put back** / **Reset positions** return to the automatic layout,
and the designer warns when lines overlap. A live preview uses a real
part from the catalog and warns when the barcode would be too short to scan. `lib/core/label_layout.dart`
places everything in millimetres; the Zebra (ZPL), PDF and preview renderers all draw from that plan.

## Zebra label printers

Settings › Barcode labels › **Printer** (saved per device) chooses where barcode labels go:

- **Zebra on this PC (USB), Windows app:** labels are sent as ZPL straight to the installed Zebra driver
  ("ZDesigner …"), with no print dialog. Install Zebra's Windows driver first. On the first label print
  the app picks a Zebra driver automatically if one is installed.
- **Zebra on the network, Windows and Android apps:** ZPL is sent to the printer's IP on port 9100.
- **Print dialog:** a PDF sized to the label, for any printer. This is the only option in the browser,
  because browsers cannot send raw data to a printer.

Labels print at 203 or 300 dpi. The printer draws the
barcode itself (EAN-13, UPC-A, EAN-8, or Code 128 for SKUs and in-store codes), so bars align to the
print head and scan reliably. Prices print as "Rs." because Zebra's built-in fonts have no ₹ sign. Use
**Print test label** after setup to check size and darkness. `lib/core/zpl.dart` builds the labels;
`visual/labels_test.dart` drives the setup against a fake network Zebra.

## Build

Requirements: Flutter 3.50+, Visual Studio 2022 C++ build tools (Windows), Android SDK 36 with NDK
28.2 (Android), and Windows Developer Mode.

```
flutter pub get
flutter test                      # billing maths and barcode rules
flutter build apk --release --split-per-abi   # build/app/outputs/flutter-apk/
flutter build appbundle --release             # build/app/outputs/bundle/release/app-release.aab
```

`flutter test visual --update-goldens` renders every screen to `visual/out/` against a demo API on
`http://127.0.0.1:4100/api/v1` (start it with `SEED_DEMO=true PORT=4100 npm run dev:api`).

## Web app

```
powershell -ExecutionPolicy Bypass -File tool\build_web.ps1
```

This builds the web app with every resource bundled locally (no Google CDN) and refreshes
`release/web`. `tool/build_web.sh` does the same on Linux/macOS and is what CI runs. CI publishes
the bundle for every commit on `main` as the GitHub Release `web-<commit>`. While the VPS still uses
`WEB_BUNDLE=committed` (the default), **commit `release/web` with the change**: the VPS release copies it
as the site and does not build Flutter itself. After the cutover in `docs/CARTUNEZ-DEPLOYMENT.md`,
`release/web` is git-ignored and is only for local testing. `tool/serve_web.py` serves the build with `/api` forwarded to a local
API, the same way the VPS does. On the web the app reads `/installation.json` to fill in the shop's
organization and branch, and stores the register in IndexedDB, migrating older browser-local data on the next visit.

`web/sw.js` retires the service worker left by the old Next.js app: on a counter's next visit it
clears the old offline cache, unregisters itself and reloads the tab onto this app.

## Windows installer

Needs Inno Setup 6 (`winget install JRSoftware.InnoSetup`). From `apps/flutter`:

```
powershell -ExecutionPolicy Bypass -File windows\installer\build.ps1
```

This builds the release and writes `build\installer\CartunezPOS-Setup-<version>.exe` (version from
`pubspec.yaml`). The installer works without admin rights, adds Start menu and optional desktop
shortcuts, bundles the Visual C++ runtime, and upgrades in place. Uninstalling keeps the register's
saved data in `%APPDATA%\in.cartunez\Cartunez POS`, so unsent sales are never lost. Bump `version:`
in `pubspec.yaml` for each release.

The installer is not code-signed, so Windows SmartScreen shows "Windows protected your PC" the first
time (More info → Run anyway). A code-signing certificate removes that.

## Android release key

Release builds are signed with the key named in `android/key.properties` (git-ignored):

```
storePassword=...
keyPassword=...
keyAlias=cartunez
storeFile=C:/Users/<you>/.cartunez-keys/cartunez-pos-release.jks
```

Keep the `.jks` file and its passwords backed up somewhere safe and private. Android only installs an
update if it is signed with the same key, so losing it means every phone must uninstall and reinstall.
A release build requires the configured signing key. Use a debug build for local development.

App icons come from `assets/icon/icon.png`; regenerate them with `dart run flutter_launcher_icons`.
