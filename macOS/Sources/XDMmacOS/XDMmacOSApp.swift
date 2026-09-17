// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// Copyright (C) 2026
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

@main
struct XDMmacOSApp: App {
    @StateObject private var locationStore = DownloadLocationStore()
    @StateObject private var downloads = DownloadCoordinator()

    var body: some Scene {
        WindowGroup("XDM") {
            ContentView(downloads: downloads, locationStore: locationStore)
                .frame(minWidth: 850, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 680)
    }
}
