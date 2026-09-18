// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum ApplicationSettings {
    private static let connectionsKey = "downloadConnectionsPerFile"
    private static let simultaneousDownloadsKey = "simultaneousDownloads"
    static let maximumConnectionsPerFile = 20
    static let maximumSimultaneousDownloads = 10
    private static let appearanceKey = "appearanceMode"
    private static let automaticRetryKey = "automaticRetryEnabled"
    static let automaticRetryLimit = 3

    enum AppearanceMode: String, CaseIterable {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    static var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey) }
    }

    static var connectionsPerFile: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: connectionsKey)
            return value == 0 ? 10 : min(max(value, 1), maximumConnectionsPerFile)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), maximumConnectionsPerFile), forKey: connectionsKey) }
    }

    static var simultaneousDownloads: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: simultaneousDownloadsKey)
            return value == 0 ? 3 : min(max(value, 1), maximumSimultaneousDownloads)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), maximumSimultaneousDownloads), forKey: simultaneousDownloadsKey) }
    }

    /// Network transfers occasionally fail because a server closes an idle connection.
    /// Keep retries conservative: the user can still retry manually after this limit.
    static var automaticRetryEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: automaticRetryKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: automaticRetryKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: automaticRetryKey) }
    }
}
