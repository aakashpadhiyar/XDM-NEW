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
    private static let browserMonitoringKey = "browserMonitoringEnabled"
    private static let videoCaptureKey = "browserVideoCaptureEnabled"
    private static let videoMinimumMegabytesKey = "browserVideoMinimumMegabytes"
    private static let excludedHostsKey = "browserExcludedHosts"
    private static let fileExtensionsKey = "browserFileExtensions"
    private static let videoExtensionsKey = "browserVideoExtensions"
    private static let clipboardMonitoringKey = "clipboardMonitoringEnabled"
    private static let startAutomaticallyKey = "browserStartAutomatically"
    private static let serverTimestampKey = "browserServerTimestampEnabled"
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

    static var browserMonitoringEnabled: Bool {
        get { bool(for: browserMonitoringKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: browserMonitoringKey) }
    }

    static var videoCaptureEnabled: Bool {
        get { bool(for: videoCaptureKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: videoCaptureKey) }
    }

    static var videoMinimumMegabytes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: videoMinimumMegabytesKey)
            return min(max(value == 0 ? 1 : value, 1), 1_024)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), 1_024), forKey: videoMinimumMegabytesKey) }
    }

    static var excludedHosts: String {
        get { UserDefaults.standard.string(forKey: excludedHostsKey) ?? "update.microsoft.com,windowsupdate.com" }
        set { UserDefaults.standard.set(newValue, forKey: excludedHostsKey) }
    }

    static var fileExtensions: String {
        get { UserDefaults.standard.string(forKey: fileExtensionsKey) ?? "3GP,7Z,AVI,BZ2,DEB,DOC,DOCX,DMG,EXE,GZ,ISO,MSI,PDF,PPT,PPTX,RAR,RPM,XLS,XLSX,TAR,JAR,ZIP,XZ" }
        set { UserDefaults.standard.set(newValue, forKey: fileExtensionsKey) }
    }

    static var videoExtensions: String {
        get { UserDefaults.standard.string(forKey: videoExtensionsKey) ?? "MP4,M3U8,F4M,WEBM,OGG,MP3,AAC,FLV,MKV,DIVX,MOV,MPG,MPEG,OPUS" }
        set { UserDefaults.standard.set(newValue, forKey: videoExtensionsKey) }
    }

    static var clipboardMonitoringEnabled: Bool {
        get { bool(for: clipboardMonitoringKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: clipboardMonitoringKey) }
    }

    static var startDownloadsAutomatically: Bool {
        get { bool(for: startAutomaticallyKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: startAutomaticallyKey) }
    }

    static var serverTimestampEnabled: Bool {
        get { bool(for: serverTimestampKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: serverTimestampKey) }
    }

    static var videoMinimumBytes: Int64 { Int64(videoMinimumMegabytes) * 1_048_576 }

    static func commaSeparatedValues(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func bool(for key: String, default defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}
