# Client builds

All clients are one Flutter app in `apps/flutter`: the web app served at pos.cartunez.in, the
Windows app (Inno Setup installer) and the Android app. They talk to the same API and database.

Build steps, the Windows installer, Android release signing and the web build are described in
[apps/flutter/README.md](../apps/flutter/README.md).

The earlier Next.js web app and its Electron (Windows) and Capacitor (Android) wrappers were
retired in November 2026. Their source remains in Git history before that change.
