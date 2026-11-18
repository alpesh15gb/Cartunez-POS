# Cartunez POS app (web, Windows and Android)

The Flutter app for the shop counter. The same code runs in the browser at pos.cartunez.in, as a
Windows program and as an Android app, all talking to the server API in `apps/api`.

## What it does

- Billing: catalog with photos and stock, USB/Bluetooth keyboard-mode scanners with an Enter suffix,
  and camera scanning on Android and supported browsers. Repeat scans add one more. The register also has discounts,
  retail/wholesale, hold and resume, cash/card/UPI and split payments with change, receipts.
- Sales: invoices and credit notes, returns, voids, shifts with cash counts.
- Customers, suppliers, parts (with in-store Code 128 barcodes and support for existing EAN/UPC labels), bins, stock adjust/count/move,
  purchase orders and receiving, label printing (50 × 30 mm), dashboard, reports with CSV export,
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
- Product lookup preserves leading zeroes and punctuation and matches equivalent valid UPC/EAN/GTIN
  representations. New internal codes print as Code 128. Print thermal labels at actual size and test a sample with each counter scanner.
- INR reports use IST business dates. Reports cover the active branch. The tender report reconciles
  recorded invoices, change and refunds. Compare Card and UPI with the provider statement separately.
  CSV amounts are integer minor units, such as paise for INR.

## Build

Requirements: Flutter 3.50+, Visual Studio 2022 C++ build tools (Windows), Android SDK 36 with NDK
28.2 (Android), and Windows Developer Mode.

```
flutter pub get
flutter test                      # billing maths and barcode rules
flutter build apk --release --split-per-abi   # buildpp\outputslutter-apkpp-arm64-v8a-release.apk
flutter build appbundle --release             # buildpp\outputsundle
eleasepp-release.aab (Play Store)
```

`flutter test visual --update-goldens` renders every screen to `visual/out/` against a demo API on
`http://127.0.0.1:4100/api/v1` (start it with `SEED_DEMO=true PORT=4100 npm run dev:api`).

## Web app

```
powershell -ExecutionPolicy Bypass -File tooluild_web.ps1
```

This builds the web app with every resource bundled locally (no Google CDN) and refreshes
`release/web`. **Commit `release/web` with the change**: the VPS release copies it as the site and
does not build Flutter itself. `tool/serve_web.py` serves the build with `/api` forwarded to a local
API, the same way the VPS does. On the web the app reads `/installation.json` to fill in the shop's
organization and branch, and stores the register in the browser's local storage.

`web/sw.js` retires the service worker left by the old Next.js app: on a counter's next visit it
clears the old offline cache, unregisters itself and reloads the tab onto this app.

## Windows installer

Needs Inno Setup 6 (`winget install JRSoftware.InnoSetup`). From `apps/flutter`:

```
powershell -ExecutionPolicy Bypass -File windows\installeruild.ps1
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
Without `key.properties` the build falls back to the debug key.

App icons come from `assets/icon/icon.png`; regenerate them with `dart run flutter_launcher_icons`.
