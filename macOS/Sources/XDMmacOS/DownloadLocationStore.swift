// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Combine
import Foundation

/// Persists a user-selected download folder as a security-scoped bookmark.
/// This also works when the packaged app is later sandboxed.
final class DownloadLocationStore: ObservableObject {
    @Published private(set) var folderURL: URL
    @Published private(set) var hasFolderPermission = false

    private let bookmarkKey = "xdm.download-folder-bookmark"

    init() {
        let fallback = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        folderURL = fallback
        restoreBookmarkIfAvailable()
    }

    @discardableResult
    @MainActor
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose download folder"
        panel.prompt = "Use this folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return false }

        do {
            let bookmark = try selectedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            stopAccessingCurrentFolder()
            folderURL = selectedURL
            hasFolderPermission = folderURL.startAccessingSecurityScopedResource()
            return true
        } catch {
            return false
        }
    }

    func withFolderAccess<T>(_ action: (URL) throws -> T) rethrows -> T {
        let startedAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccess { folderURL.stopAccessingSecurityScopedResource() }
        }
        return try action(folderURL)
    }

    private func restoreBookmarkIfAvailable() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        do {
            var stale = false
            let restoredURL = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            folderURL = restoredURL
            hasFolderPermission = folderURL.startAccessingSecurityScopedResource()
            if stale { UserDefaults.standard.removeObject(forKey: bookmarkKey) }
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    private func stopAccessingCurrentFolder() {
        if hasFolderPermission { folderURL.stopAccessingSecurityScopedResource() }
        hasFolderPermission = false
    }

    deinit {
        stopAccessingCurrentFolder()
    }
}
