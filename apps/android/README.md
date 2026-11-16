# Android client

This Capacitor client bundles the Next.js export from `../web/out`. `MotorlineNative` stores each scoped workspace and durable outbox in Android SQLite with a transaction for every write. The application backup setting is disabled to keep organization data on the enrolled device.

The native bridge supports camera barcode scanning using embedded ZXing and printing through Android PrintManager. An installed Android print service handles supported network, USB or Bluetooth thermal printers. The system print panel also exposes Save as PDF. A physical printer requires separate validation.

Build the web export, then run `npm run sync -w @motorline/android` followed by `android/gradlew.bat -p android assembleDebug` from this directory. JDK 21, Android SDK Platform 36 and Build Tools 36.0.0 are required. Set `JAVA_HOME` and `ANDROID_HOME` to the installed tool locations.

Debug APKs use an Android debug certificate for installation testing. Production distribution requires a retailer-owned release keystore. Set `MOTORLINE_ANDROID_KEYSTORE`, `MOTORLINE_ANDROID_STORE_PASSWORD`, `MOTORLINE_ANDROID_KEY_ALIAS`, and `MOTORLINE_ANDROID_KEY_PASSWORD`, then run `android/gradlew.bat -p android assembleRelease`. Partial signing configuration fails immediately. Keep keystore credentials outside source control. A release build with all signing variables absent produces an unsigned artifact that requires signing before installation.

Set the API URL to the HTTPS address of the shop server. Its certificate must be trusted by Android. The emulator reaches a host server through `10.0.2.2`. Initial enrollment requires connectivity. Subsequent offline sessions use the configured device policy and cached workspace.

Debug builds enable WebView inspection and local HTTP for emulator testing. Release builds retain the HTTPS policy and disable WebView inspection. The delivered `release/android/Motorline-1.0.0-test.apk` is signed with an Android debug certificate. It is for installation and acceptance testing, not production distribution.

The current `release/android/Motorline-1.1.0-release.apk` uses the stable private application release key generated for this installation. See `docs/ANDROID-RELEASE-SIGNING.md` for secure key custody and the development-emulator WebView debugging limitation. `docs/test-results/android-release-package.json` records its version, signature, asset comparison and manifest policy; `android-release-smoke.json` records actual installed behavior and remaining live-server/hardware checks.

Automated device tests live in `tests/android-bridge.cjs`, `tests/android-acceptance.cjs`, and `tests/android-operations.cjs`. Run them sequentially from the project root with Node.js 22+, passing the absolute `adb` executable path and an evidence output directory. They target a running API 36 emulator on `emulator-5558` and use the actual installed app, native SQLite, and shared PostgreSQL API. The workflow tests require the seeded demo tenant and mutate its fictional stock and invoices. See `docs/RELEASE-VERIFICATION.md` and `docs/test-results/android-final-package.json` in the project root for measured results and remaining hardware checks.

`tests/android-reconciliation.cjs` creates an isolated fictional part and two enrolled counters through the API, submits concurrent offline sales for the last unit, and resolves the resulting conflict through the installed Android manager screen. It checks the visible status, removal of Resolve, latest audit event, exact stock variance, one invoice per transaction, and replay idempotency. It requires the installed app already signed into the seeded owner in Pune with an open shift.
