# XDM New for macOS

XDM New is an open-source, macOS-focused download manager modernization built from the historical Xtreme Download Manager source tree. It keeps the useful download-manager behavior while providing a native Mac interface and a clean local browser handoff. The current macOS test release is `0.0.1`.

## What is included

- Native macOS AppKit application with system, light, and dark appearance choices.
- Direct HTTP/HTTPS downloads, pause/resume, queue control, history, file properties, reveal, open, and **Open With**.
- Range-based segmented downloads: 1–20 connections per supported file and 1–10 concurrent downloads.
- Persistent partial-download cache in `.XDM` under the selected download folder, automatic segment merge, and cleanup after completion.
- Media-aware browser handoff and a compact video-detected notification.
- Open source Chrome and Firefox integration sources under `macOS/chrome-extension` and `macOS/firefox-extension`.

## Build and test on macOS

```sh
cd macOS
swift build -c release
./scripts/package-test-app.sh
./scripts/install-test-app.command "$PWD/test-applications"
```

The packaged test application is ad-hoc signed for local use. It is not notarized; macOS may require you to explicitly allow it in Privacy & Security.

See [macOS/README.md](macOS/README.md) for browser-extension setup and local testing details.

## Browser integration

XDM New’s Chrome extension uses a local loopback handoff to the app at `127.0.0.1:9614`; it is intentionally separate from the legacy XDM native-messaging helper. The Firefox adapter also supports the legacy XDM handoff protocol for use with the original extension.

## Licensing and credits

The historical XDM base is GPL-2.0. New macOS code is GPL-2.0-or-later. Read [NOTICE.md](NOTICE.md) before redistributing modified extension code: the upstream Chrome helper is GPL-3.0, while the included Chrome extension was newly written and does not include that helper’s code.
