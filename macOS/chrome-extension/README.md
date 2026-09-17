# XDM New Chrome extension

This local development extension hands direct HTTP/HTTPS downloads to the running XDM New test app.

1. In Chrome, open `chrome://extensions`.
2. Turn on **Developer mode**.
3. Choose **Load unpacked** and select this folder.
4. Click the XDM New extension icon to turn monitoring on.

It deliberately does not intercept protected content, and if XDM cannot accept a handoff Chrome keeps its own download. This is a local development extension, not a signed Chrome Web Store package.
