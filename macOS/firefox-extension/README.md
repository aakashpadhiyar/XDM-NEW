# XDM New Firefox extension

This extension hands direct HTTP/HTTPS downloads to the local XDM New app through Firefox native messaging. Its toolbar button is off by default; turn it on only when you want XDM New to take over downloads.

For development, use Firefox's `about:debugging#/runtime/this-firefox` page and choose **Load Temporary Add-on**. For public distribution, upload the generated `.xpi` package to Firefox Add-ons (AMO) for signing, then link users to the AMO listing.

Firefox temporary add-ons are removed when Firefox restarts. The extension does not capture protected content.
