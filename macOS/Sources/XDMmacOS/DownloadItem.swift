// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum DownloadState: String, Equatable, Sendable {
    case queued = "Queued"
    case downloading = "Downloading"
    case merging = "Merging parts"
    case paused = "Paused"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

struct DownloadItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceURL: URL
    let destinationFolderURL: URL
    let requestHeaders: [String: String]
    let createdAt: Date = Date()
    var fileName: String
    var state: DownloadState = .queued
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0
    var bytesPerSecond: Double = 0
    var speedSampleBytes: Int64 = 0
    var speedSampleDate = Date()
    var connectionCount = 1
    var errorMessage: String?
    var finishedFileURL: URL?
    var temporaryWorkspaceURL: URL?

    var fileExtension: String {
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension
        return pathExtension.isEmpty ? "No extension supplied" : pathExtension.uppercased()
    }

    var progress: Double? {
        guard bytesExpected > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(bytesExpected))
    }

    var detail: String {
        switch state {
        case .failed:
            return errorMessage ?? "The download failed."
        case .completed:
            return "Saved to \(finishedFileURL?.deletingLastPathComponent().path ?? "Downloads")"
        case .merging:
            return "Combining \(connectionCount) downloaded parts…"
        default:
            let speed = bytesPerSecond > 0 ? " · \(Self.byteCount(Int64(bytesPerSecond)))/s" : ""
            guard bytesExpected > 0 else {
                return bytesReceived > 0 ? "\(Self.byteCount(bytesReceived))\(speed)" : state.rawValue
            }
            let connections = connectionCount > 1 ? " · \(connectionCount) connections" : ""
            return "\(Self.byteCount(bytesReceived)) of \(Self.byteCount(bytesExpected))\(speed)\(connections)"
        }
    }

    static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
