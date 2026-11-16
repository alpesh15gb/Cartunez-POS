# Cartunez POS — native app (Windows and Android)

A native Flutter app for the shop counter. It talks to the same server API as the web app
(`apps/api`), so no server change is needed to use it.

## What it does

- Billing: catalog with photos and stock, barcode scanning (USB/Bluetooth scanners anywhere in the
  app, camera on Android), repeat scans add one more, cart with quantity steppers, discounts,
  retail/wholesale, hold and resume, cash/card/UPI and split payments with change, receipts.
- Sales: invoices and credit notes, returns, voids, shifts with cash counts.
- Customers, suppliers, parts (with in-store EAN-13 barcodes), bins, stock adjust/count/move,
  purchase orders and receiving, label printing (50 × 30 mm), dashboard, reports with CSV export,
  settings, modules, staff, branches, approvals, sync and audit.
- Optional modules (vehicle fitment, branch transfers, warranty & cores) follow Settings › Modules.
- Every sale is saved on the device before it is sent. If the connection drops it is kept and sent
  later with the same transaction ID, so it can never be billed twice.

Not yet in the native app: enrolled offline counters with their own invoice ranges, and fitment CSV
import. Use the web app for those.

## Build

Requirements: Flutter 3.50+, Visual Studio 2022 C++ build tools (Windows), Android SDK 36 with NDK
28.2 (Android), and Windows Developer Mode.

```
flutter pub get
flutter test                      # billing maths and barcode rules
flutter build apk --release --split-per-abi   # buildpp\outputslutter-apkpp-arm64-v8a-release.apk
flutter build appbundle --release             # buildpp\outputsundleeleasepp-release.aab (Play Store)
```

`flutter test visual --update-goldens` renders every screen to `visual/out/` against a demo API on
`http://127.0.0.1:4100/api/v1` (start it with `SEED_DEMO=true PORT=4100 npm run dev:api`).

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
