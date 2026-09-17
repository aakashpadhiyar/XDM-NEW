// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit

enum FileOpeningService {
    static func openDefault(_ fileURL: URL) {
        NSWorkspace.shared.open(fileURL)
    }

    /// Opens media with MPV when available, then common macOS media players,
    /// and finally the user's default application.
    static func playMedia(_ fileURL: URL) {
        let preferredBundleIdentifiers = [
            "io.mpv",
            "com.colliderli.iina",
            "org.videolan.vlc",
            "com.apple.QuickTimePlayerX"
        ]
        for bundleIdentifier in preferredBundleIdentifiers {
            if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                open(fileURL, with: applicationURL)
                return
            }
        }
        if let applicationURL = applications(for: fileURL).first {
            open(fileURL, with: applicationURL)
            return
        }
        openDefault(fileURL)
    }

    static func revealInFinder(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    static func applications(for fileURL: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
    }

    static func open(_ fileURL: URL, with applicationURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: applicationURL, configuration: configuration)
    }
}
