# XDM New for macOS

This is the native macOS foundation for a GPL-2.0-or-later XDM derivative. It uses the XDM 7.2.8 source tree as a behaviour reference, but does not reuse its Java/Swing interface. The first test package is AppKit-based so it can compile with the macOS Command Line Tools; the SwiftUI prototype remains in the source tree for the later full-Xcode build.

Current first slice:

- direct HTTP/HTTPS downloads with visible live progress;
- smart byte-range downloads using 1–20 concurrent connections (10 by default) when the server advertises and honors range requests, with ordered on-disk merging and a safe one-connection fallback;
- pause, resume, retry, cancel, and removal controls;
- a user-selected download folder stored as a security-scoped bookmark;
- completed or partial video preview; completed-file actions that use the macOS default application or a user-selected installed app, plus Finder reveal;
- saved history, properties, context menus, queue limits (1–10 simultaneous downloads), and a `.XDM` partial-download cache that is cleaned after a successful merge;
- system, light, and dark appearance choices, plus application, connection, queue, and browser-integration settings;
- a Firefox development extension and native-messaging host for explicit browser-download handoff.
- compatibility with the installed legacy **XDM Browser Monitor** Firefox extension: direct downloads are handed to XDM Test, while detected media opens a native **Download now / Later** prompt.

## Build a test app

```sh
cd macOS
./scripts/build-macos.command
open "dist/XDM New.app"
```

The command compiles the release build, makes a clean ad-hoc-signed staging app, verifies its signature, creates and validates `dist/XDM-New-macOS-<version>-test.zip`, and prints its SHA-256 checksum. Only after those checks succeed, it replaces the known generated test apps, test ZIPs, and `.DS_Store` in `macOS/dist`; source files, the GitHub release, and your Downloads folder are never touched. Pass `--keep-old` to preserve earlier local test artifacts.

To copy the test app to an empty folder without administrator access:

```sh
open scripts/install-test-app.command --args "$PWD/test-applications"
```

The installer deliberately refuses to overwrite an existing test app. It does not use administrator privileges, change Gatekeeper settings, or alter the original XDM install.

## Firefox handoff test

Build the test app first, then install the user-level native-messaging manifest:

```sh
cd macOS
./scripts/install-firefox-test-integration.command
```

In Firefox, open `about:debugging#/runtime/this-firefox`, select **Load Temporary Add-on**, and choose `firefox-extension/manifest.json`. The extension's toolbar button is off by default. When turned on, it passes direct HTTP/HTTPS downloads to XDM Test and cancels Firefox's duplicate download after XDM confirms the handoff.

This integration is intentionally a local, development-only setup. It is not signed for public Firefox distribution.

## Chrome handoff test

Open Chrome's `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select `chrome-extension`. When XDM New is running, intercepted direct HTTP/HTTPS downloads are offered to the local app over `127.0.0.1:9614`.

The Chrome extension is open source and separate from the historical native-messaging helper. It must be loaded manually for development; it is not in the Chrome Web Store.

## Use the original XDM Firefox extension

XDM Test now implements the original extension's local HTTP protocol on `127.0.0.1:9614`. This allows the existing Firefox extension identified as `browser-mon@xdman.sourceforge.net` to work without replacing it.

The old `/Applications/xdm.app` uses the same port. Quit that old XDM app before opening XDM New; the window will say **Original XDM Firefox extension: connected** once it owns the port. Keep only one of the two apps running at a time. Direct downloads are handed to XDM New with the browser's request headers and cookies when Firefox supplies them. Media detection shows a compact native **Download video** prompt; choosing Later keeps the entry available in the extension's own menu.

The app is ad-hoc signed for local testing, but not notarized or ready for public distribution. HLS/DASH merging, notarization, and a signed installer are future milestones.

## Licensing

Any public distribution of this derivative must comply with XDM's GPL-2.0 license: retain notices, state material changes, and provide complete corresponding source.
