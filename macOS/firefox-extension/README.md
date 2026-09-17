# Firefox test extension

This development-only extension hands direct HTTP/HTTPS downloads to `XDM Test` through Firefox native messaging. Its toolbar button is off by default; turn it on only when you want XDM to take over downloads.

After running the integration setup script, open `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on**, and select this directory's `manifest.json`.

Firefox temporary add-ons are removed when Firefox restarts. Do not publish this test extension or use it to capture protected content.
