# Client builds

The source tree uses a shared exported Next.js app. Build web assets before creating either native package.

## Windows

Run `npm run build --workspace @motorline/web`. In `apps/desktop`, run `npm install --workspaces=false`, then `npm run package --workspaces=false`. The NSIS installer is written under `release/windows`. The installer supports a per-user installation and preserves the workspace database during uninstall. The release requires an Authenticode certificate to produce a publisher-signed installer. The local build is unsigned.

For an automated installed-client storage check, set `MOTORLINE_TEST_PROFILE` to an isolated test folder and `MOTORLINE_TEST_OUTPUT` to a result JSON path, then launch the installed executable with `--smoke-test`. Launch it a second time using the same profile and verify that `previous` contains the pending test transaction. This hook uses the packaged app and native SQLite bridge and exits after checking the UI. Run the complete counter workflow separately against the API.

Version 1.1.0 pins Electron 45.3.2. A fresh profile defaults to the editable API address `https://pos.cartunez.in/api/v1`; organization and branch codes must be entered for the deployment. Existing connection profiles are preserved. The final 1.1.0 NSIS payload was extracted into a separate directory and passed native storage, offline restart/replay, manager reconciliation and retail operations against the final PostgreSQL API. The installer itself was not executed over the user's running 1.0 installation: NSIS can close the existing app and uninstall the prior version even when a different destination is supplied. The earlier 1.0 installer path was tested; perform the 1.1.0 upgrade after closing counters and reconciling their outboxes.

## Android

Build instructions and the Android toolchain versions are recorded in `apps/android/README.md`. The application must bundle `apps/web/out`, include the native storage bridge, and retain its SQLite database across process restarts. Production APK signing uses a retailer-controlled keystore supplied outside source control. Keep signing credentials outside `.env.example`, source archives, and test reports.
