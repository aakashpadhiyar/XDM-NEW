// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation

final class DownloadCoordinator: NSObject, ObservableObject {
    private static let minimumPartSize: Int64 = 1_048_576

    @Published private(set) var items: [DownloadItem] = []

    private enum TaskKind {
        case single(UUID)
        case segment(UUID, Int)
    }

    private struct SegmentedTransfer {
        let workspaceURL: URL
        let partURLs: [URL]
        let partSizes: [Int64]
        let expectedSize: Int64
        var bytesBySegment: [Int: Int64] = [:]
        var completedSegments = Set<Int>()

        var completedBytes: Int64 {
            completedSegments.reduce(0) { $0 + partSizes[$1] }
        }
    }

    private var taskKinds: [Int: TaskKind] = [:]
    private var singleTasks: [UUID: URLSessionDownloadTask] = [:]
    private var segmentTasks: [UUID: [Int: URLSessionDownloadTask]] = [:]
    private var segmentedTransfers: [UUID: SegmentedTransfer] = [:]
    private var resumeDataByID: [UUID: Data] = [:]
    private var destinationFolders: [UUID: URL] = [:]
    private var preferredFileNames: [UUID: String] = [:]
    private var requestHeadersByID: [UUID: [String: String]] = [:]
    private var pausedSingleTaskIDs = Set<Int>()
    private var resumeRequestedWhilePausing = Set<UUID>()
    private var singlePauseDataReadyIDs = Set<UUID>()
    private var singlePauseCompletionPendingIDs = Set<UUID>()
    private var pausedSegmentedIDs = Set<UUID>()
    private var fallingBackIDs = Set<UUID>()
    private var queuedItemIDs = [UUID]()
    private var activeItemIDs = Set<UUID>()
    private var automaticRetryCounts: [UUID: Int] = [:]
    private var automaticRetryPendingIDs = Set<UUID>()
    private var queueIsPaused = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func start(
        url: URL,
        destinationFolder: URL,
        preferredFileName: String? = nil,
        requestHeaders: [String: String] = [:],
        startImmediately: Bool = true
    ) {
        var item = DownloadItem(
            id: UUID(),
            sourceURL: url,
            destinationFolderURL: destinationFolder,
            requestHeaders: requestHeaders,
            fileName: preferredFileName ?? (url.lastPathComponent.isEmpty ? "Download" : url.lastPathComponent)
        )
        if !startImmediately { item.state = .paused }
        items.insert(item, at: 0)
        automaticRetryCounts[item.id] = 0
        configure(item)
        if startImmediately { enqueue(item.id) }
    }

    func pause(_ item: DownloadItem) {
        if queuedItemIDs.contains(item.id) {
            queuedItemIDs.removeAll { $0 == item.id }
            update(item.id) { $0.state = .paused }
            return
        }
        if let task = singleTasks[item.id] {
            pausedSingleTaskIDs.insert(task.taskIdentifier)
            task.cancel { [weak self] data in
                self?.recordSinglePauseData(item.id, resumeData: data)
            }
            update(item.id) { $0.state = .paused }
            return
        }

        guard segmentTasks[item.id] != nil else { return }
        pausedSegmentedIDs.insert(item.id)
        cancelSegmentedTasks(for: item.id, removeWorkspace: false, preserveTransfer: true)
        if var transfer = segmentedTransfers[item.id] {
            transfer.bytesBySegment = [:]
            segmentedTransfers[item.id] = transfer
        }
        let completedBytes = segmentedTransfers[item.id]?.completedBytes ?? 0
        let expectedBytes = segmentedTransfers[item.id]?.expectedSize ?? 0
        update(item.id) {
            $0.state = .paused
            $0.bytesReceived = completedBytes
            $0.bytesExpected = expectedBytes
        }
        releaseSlot(for: item.id)
    }

    func resume(_ item: DownloadItem) {
        let pauseOperationIsInProgress = singlePauseCompletionPendingIDs.contains(item.id) || pausedSingleTaskIDs.contains { taskID in
            guard case .single(let pausedItemID) = taskKinds[taskID] else { return false }
            return pausedItemID == item.id
        }
        if activeItemIDs.contains(item.id), pauseOperationIsInProgress {
            resumeRequestedWhilePausing.insert(item.id)
            update(item.id) {
                $0.state = .queued
                $0.errorMessage = nil
            }
            return
        }
        pausedSegmentedIDs.remove(item.id)
        update(item.id) {
            $0.state = .queued
            $0.errorMessage = nil
        }
        enqueue(item.id)
    }

    func cancel(_ item: DownloadItem) {
        if let task = singleTasks.removeValue(forKey: item.id) {
            pausedSingleTaskIDs.insert(task.taskIdentifier)
            taskKinds[task.taskIdentifier] = nil
            task.cancel()
        }
        cancelSegmentedTasks(for: item.id, removeWorkspace: true)
        resumeDataByID[item.id] = nil
        destinationFolders[item.id] = nil
        preferredFileNames[item.id] = nil
        requestHeadersByID[item.id] = nil
        automaticRetryPendingIDs.remove(item.id)
        automaticRetryCounts[item.id] = nil
        resumeRequestedWhilePausing.remove(item.id)
        singlePauseDataReadyIDs.remove(item.id)
        singlePauseCompletionPendingIDs.remove(item.id)
        update(item.id) { $0.state = .cancelled }
        queuedItemIDs.removeAll { $0 == item.id }
        releaseSlot(for: item.id)
    }

    func remove(_ item: DownloadItem) {
        cancel(item)
        items.removeAll { $0.id == item.id }
    }

    func retry(_ item: DownloadItem) {
        cancelSegmentedTasks(for: item.id, removeWorkspace: true)
        resumeDataByID[item.id] = nil
        pausedSegmentedIDs.remove(item.id)
        fallingBackIDs.remove(item.id)
        automaticRetryPendingIDs.remove(item.id)
        automaticRetryCounts[item.id] = 0
        configure(item)
        enqueue(item.id)
    }

    func applyQueueSettings() {
        scheduleQueuedTransfers()
    }

    func pauseQueue() {
        queueIsPaused = true
        let active = items.filter { [.queued, .downloading].contains($0.state) }
        active.forEach { pause($0) }
    }

    func resumeQueue() {
        queueIsPaused = false
        items.filter { $0.state == .paused }.forEach { resume($0) }
        scheduleQueuedTransfers()
    }

    func clearFinished() {
        let completed = items.filter { $0.state == .completed }
        completed.forEach { remove($0) }
    }

    func importURLs(from text: String, destinationFolder: URL) -> Int {
        let urls = text.split(whereSeparator: \.isNewline).compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        urls.forEach { start(url: $0, destinationFolder: destinationFolder) }
        return urls.count
    }

    var exportableURLs: String {
        items.map { $0.sourceURL.absoluteString }.joined(separator: "\n")
    }

    func cleanUnusedCache(in destinationFolder: URL) -> Int {
        let cacheRoot = destinationFolder.appendingPathComponent(".XDM", isDirectory: true)
        let activeWorkspaces = Set(segmentedTransfers.values.map(\.workspaceURL))
        guard let workspaces = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removedCount = 0
        for workspace in workspaces where !activeWorkspaces.contains(workspace) {
            if (try? FileManager.default.removeItem(at: workspace)) != nil { removedCount += 1 }
        }
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), remaining.isEmpty {
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        return removedCount
    }

    private func configure(_ item: DownloadItem) {
        destinationFolders[item.id] = item.destinationFolderURL
        preferredFileNames[item.id] = item.fileName
        requestHeadersByID[item.id] = item.requestHeaders
    }

    private func enqueue(_ itemID: UUID) {
        guard destinationFolders[itemID] != nil,
              !activeItemIDs.contains(itemID),
              !queuedItemIDs.contains(itemID) else { return }
        queuedItemIDs.append(itemID)
        scheduleQueuedTransfers()
    }

    private func scheduleQueuedTransfers() {
        guard !queueIsPaused else { return }
        while activeItemIDs.count < ApplicationSettings.simultaneousDownloads, !queuedItemIDs.isEmpty {
            let itemID = queuedItemIDs.removeFirst()
            guard let item = items.first(where: { $0.id == itemID }), destinationFolders[itemID] != nil else { continue }
            activeItemIDs.insert(itemID)
            if let resumeData = resumeDataByID.removeValue(forKey: itemID) {
                let task = session.downloadTask(withResumeData: resumeData)
                singleTasks[itemID] = task
                taskKinds[task.taskIdentifier] = .single(itemID)
                task.resume()
            } else if segmentedTransfers[itemID] != nil {
                resumeSegmentedTransfer(for: itemID)
            } else {
                beginTransfer(for: itemID, from: item.sourceURL)
            }
        }
    }

    private func releaseSlot(for itemID: UUID) {
        activeItemIDs.remove(itemID)
        scheduleQueuedTransfers()
    }

    private func scheduleAutomaticRetry(for itemID: UUID, error: Error) -> Bool {
        guard ApplicationSettings.automaticRetryEnabled,
              destinationFolders[itemID] != nil,
              !automaticRetryPendingIDs.contains(itemID) else { return false }
        let attempt = automaticRetryCounts[itemID, default: 0] + 1
        guard attempt <= ApplicationSettings.automaticRetryLimit else { return false }

        automaticRetryCounts[itemID] = attempt
        automaticRetryPendingIDs.insert(itemID)
        update(itemID) {
            $0.state = .queued
            $0.errorMessage = "Retrying automatically (\(attempt)/\(ApplicationSettings.automaticRetryLimit)): \(error.localizedDescription)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(attempt)) { [weak self] in
            guard let self, self.automaticRetryPendingIDs.remove(itemID) != nil,
                  self.destinationFolders[itemID] != nil else { return }
            self.enqueue(itemID)
        }
        return true
    }

    private func recordSinglePauseData(_ itemID: UUID, resumeData: Data?) {
        guard destinationFolders[itemID] != nil else { return }
        if let resumeData { resumeDataByID[itemID] = resumeData }
        singlePauseDataReadyIDs.insert(itemID)
        finishSinglePauseIfReady(itemID)
    }

    private func finishSinglePauseIfReady(_ itemID: UUID) {
        guard singlePauseDataReadyIDs.contains(itemID), singlePauseCompletionPendingIDs.contains(itemID) else { return }
        singlePauseDataReadyIDs.remove(itemID)
        singlePauseCompletionPendingIDs.remove(itemID)
        releaseSlot(for: itemID)
        if resumeRequestedWhilePausing.remove(itemID) != nil {
            enqueue(itemID)
        }
    }

    private func beginTransfer(for itemID: UUID, from url: URL) {
        update(itemID) {
            $0.state = .queued
            $0.bytesReceived = 0
            $0.bytesExpected = 0
            $0.connectionCount = 1
            $0.errorMessage = nil
        }

        var request = request(for: itemID, url: url)
        request.httpMethod = "HEAD"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            let contentLength = Self.contentLength(from: http)
            let acceptsRanges = http?.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
            DispatchQueue.main.async {
                guard self.destinationFolders[itemID] != nil else { return }
                let resolvedName = self.resolvedFileName(
                    for: itemID,
                    suggestedName: http?.suggestedFilename,
                    mimeType: http?.mimeType
                )
                self.preferredFileNames[itemID] = resolvedName
                self.update(itemID) { $0.fileName = resolvedName }
                if acceptsRanges, let contentLength, contentLength >= Self.minimumPartSize * 2 {
                    self.startSegmentedTransfer(for: itemID, from: url, length: contentLength)
                } else {
                    self.startSingleTransfer(for: itemID, from: url)
                }
            }
        }.resume()
    }

    private func startSingleTransfer(for itemID: UUID, from url: URL) {
        let task = session.downloadTask(with: request(for: itemID, url: url))
        singleTasks[itemID] = task
        taskKinds[task.taskIdentifier] = .single(itemID)
        update(itemID) { $0.connectionCount = 1 }
        task.resume()
    }

    private func startSegmentedTransfer(for itemID: UUID, from url: URL, length: Int64) {
        let partCount = Self.segmentCount(for: length)
        guard partCount > 1 else {
            startSingleTransfer(for: itemID, from: url)
            return
        }

        guard let destinationFolder = destinationFolders[itemID] else {
            startSingleTransfer(for: itemID, from: url)
            return
        }
        let workspace = Self.workspaceURL(
            in: destinationFolder,
            fileName: preferredFileNames[itemID] ?? "Download",
            expectedSize: length,
            itemID: itemID
        )
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            var partURLs = [URL]()
            var partSizes = [Int64]()
            var tasks = [Int: URLSessionDownloadTask]()
            let partFileName = preferredFileNames[itemID] ?? "Download.part"
            for index in 0..<partCount {
                let start = (length * Int64(index)) / Int64(partCount)
                let end = ((length * Int64(index + 1)) / Int64(partCount)) - 1
                let partURL = workspace.appendingPathComponent(String(format: "%02d-", index) + partFileName)
                var rangeRequest = request(for: itemID, url: url)
                rangeRequest.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                rangeRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.downloadTask(with: rangeRequest)
                taskKinds[task.taskIdentifier] = .segment(itemID, index)
                tasks[index] = task
                partURLs.append(partURL)
                partSizes.append(end - start + 1)
            }
            segmentedTransfers[itemID] = SegmentedTransfer(
                workspaceURL: workspace,
                partURLs: partURLs,
                partSizes: partSizes,
                expectedSize: length
            )
            segmentTasks[itemID] = tasks
            update(itemID) {
                $0.temporaryWorkspaceURL = workspace
                $0.connectionCount = partCount
                $0.bytesExpected = length
                $0.state = .downloading
            }
            tasks.values.forEach { $0.resume() }
        } catch {
            startSingleTransfer(for: itemID, from: url)
        }
    }

    private func resumeSegmentedTransfer(for itemID: UUID) {
        guard let transfer = segmentedTransfers[itemID],
              let item = items.first(where: { $0.id == itemID }) else { return }
        var tasks = [Int: URLSessionDownloadTask]()
        for index in transfer.partURLs.indices where !transfer.completedSegments.contains(index) {
            let start = (transfer.expectedSize * Int64(index)) / Int64(transfer.partURLs.count)
            let end = ((transfer.expectedSize * Int64(index + 1)) / Int64(transfer.partURLs.count)) - 1
            var rangeRequest = request(for: itemID, url: item.sourceURL)
            rangeRequest.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            rangeRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let task = session.downloadTask(with: rangeRequest)
            taskKinds[task.taskIdentifier] = .segment(itemID, index)
            tasks[index] = task
        }
        guard !tasks.isEmpty else {
            mergeSegments(for: itemID, transfer: transfer)
            return
        }
        segmentTasks[itemID] = tasks
        update(itemID) {
            $0.state = .downloading
            $0.bytesReceived = transfer.completedBytes
            $0.bytesExpected = transfer.expectedSize
            $0.connectionCount = transfer.partURLs.count
        }
        tasks.values.forEach { $0.resume() }
    }

    private func request(for itemID: UUID, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = requestHeadersByID[itemID] ?? [:]
        return request
    }

    private func cancelSegmentedTasks(for itemID: UUID, removeWorkspace: Bool, preserveTransfer: Bool = false) {
        if let tasks = segmentTasks.removeValue(forKey: itemID) {
            for task in tasks.values {
                taskKinds[task.taskIdentifier] = nil
                task.cancel()
            }
        }
        if !preserveTransfer, let transfer = segmentedTransfers.removeValue(forKey: itemID) {
            if removeWorkspace { Self.removeWorkspace(transfer.workspaceURL) }
            update(itemID) { $0.temporaryWorkspaceURL = nil }
        }
    }

    private func fallbackToSingleTransfer(for itemID: UUID, message: String) {
        guard fallingBackIDs.insert(itemID).inserted, let item = items.first(where: { $0.id == itemID }) else { return }
        cancelSegmentedTasks(for: itemID, removeWorkspace: true)
        update(itemID) {
            $0.connectionCount = 1
            $0.state = .queued
            $0.errorMessage = nil
        }
        startSingleTransfer(for: itemID, from: item.sourceURL)
        fallingBackIDs.remove(itemID)
        _ = message
    }

    private func resolvedFileName(for itemID: UUID, suggestedName: String?, mimeType: String?) -> String {
        let requested = URL(fileURLWithPath: preferredFileNames[itemID] ?? "Download").lastPathComponent
        if !URL(fileURLWithPath: requested).pathExtension.isEmpty { return requested }
        let suggested = suggestedName.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        if !suggested.isEmpty, !URL(fileURLWithPath: suggested).pathExtension.isEmpty {
            let sourceName = items.first(where: { $0.id == itemID })?.sourceURL.lastPathComponent ?? ""
            let extensionForSuggestedName = URL(fileURLWithPath: suggested).pathExtension
            return requested == "Download" || requested == sourceName ? suggested : "\(requested).\(extensionForSuggestedName)"
        }
        if let extensionForMIME = Self.fileExtension(forMIMEType: mimeType) {
            return "\(requested).\(extensionForMIME)"
        }
        return requested
    }

    private func finishSegment(_ index: Int, for itemID: UUID, from location: URL, response: URLResponse?) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              var transfer = segmentedTransfers[itemID],
              transfer.partURLs.indices.contains(index) else {
            fallbackToSingleTransfer(for: itemID, message: "The server did not honor byte-range requests.")
            return
        }
        let partURL = transfer.partURLs[index]
        do {
            try FileManager.default.moveItem(at: location, to: partURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: partURL.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard actualSize == transfer.partSizes[index] else {
                fallbackToSingleTransfer(for: itemID, message: "A download segment had an unexpected size.")
                return
            }
            transfer.bytesBySegment[index] = nil
            transfer.completedSegments.insert(index)
            segmentedTransfers[itemID] = transfer
            if transfer.completedSegments.count == transfer.partURLs.count {
                mergeSegments(for: itemID, transfer: transfer)
            }
        } catch {
            fallbackToSingleTransfer(for: itemID, message: error.localizedDescription)
        }
    }

    private func mergeSegments(for itemID: UUID, transfer: SegmentedTransfer) {
        guard let destinationFolder = destinationFolders[itemID] else { return }
        update(itemID) { $0.state = .merging }
        let fallbackName = "Download-\(itemID.uuidString.prefix(8))"
        let fileName = preferredFileNames[itemID] ?? fallbackName
        let destination = Self.availableDestination(named: fileName, in: destinationFolder)
        let assembled = transfer.workspaceURL.appendingPathComponent("assembled")

        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: assembled.path, contents: nil)
            let output = try FileHandle(forWritingTo: assembled)
            defer { try? output.close() }
            for partURL in transfer.partURLs {
                let input = try FileHandle(forReadingFrom: partURL)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                    try output.write(contentsOf: data)
                }
            }
            try FileManager.default.moveItem(at: assembled, to: destination)
            cancelSegmentedTasks(for: itemID, removeWorkspace: true)
            preferredFileNames[itemID] = nil
            releaseSlot(for: itemID)
            DispatchQueue.main.async {
                guard let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                self.items[index].fileName = destination.lastPathComponent
                self.items[index].finishedFileURL = destination
                self.items[index].bytesReceived = transfer.expectedSize
                self.items[index].bytesExpected = transfer.expectedSize
                self.items[index].state = .completed
            }
        } catch {
            fallbackToSingleTransfer(for: itemID, message: "Could not combine the downloaded parts: \(error.localizedDescription)")
        }
    }

    private func update(_ itemID: UUID, change: @escaping @Sendable (inout DownloadItem) -> Void) {
        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
            change(&self.items[index])
        }
    }

    private static func contentLength(from response: HTTPURLResponse?) -> Int64? {
        guard let response else { return nil }
        if let value = response.value(forHTTPHeaderField: "Content-Length"), let length = Int64(value), length > 0 {
            return length
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    private static func segmentCount(for length: Int64) -> Int {
        let bySize = Int((length + minimumPartSize - 1) / minimumPartSize)
        return min(ApplicationSettings.connectionsPerFile, max(2, bySize))
    }

    private static func workspaceURL(in destinationFolder: URL, fileName: String, expectedSize: Int64, itemID: UUID) -> URL {
        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let safeName = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = itemID.uuidString.prefix(8)
        let directoryName = "\(safeName.isEmpty ? "Download" : safeName)-\(expectedSize)-\(identifier)"
        return destinationFolder
            .appendingPathComponent(".XDM", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func removeWorkspace(_ workspaceURL: URL) {
        try? FileManager.default.removeItem(at: workspaceURL)
        let cacheRoot = workspaceURL.deletingLastPathComponent()
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path), children.isEmpty else { return }
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private static func fileExtension(forMIMEType mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "video/mp4": return "mp4"
        case "video/x-matroska": return "mkv"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "application/pdf": return "pdf"
        case "application/zip": return "zip"
        case "application/x-7z-compressed": return "7z"
        case "application/x-rar-compressed": return "rar"
        case "application/x-apple-diskimage": return "dmg"
        default: return nil
        }
    }

    private static func availableDestination(named name: String, in folder: URL) -> URL {
        let original = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }

        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var number = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }
}

extension DownloadCoordinator: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let kind = taskKinds[downloadTask.taskIdentifier] else { return }
        switch kind {
        case .single(let itemID):
            update(itemID) {
                $0.state = .downloading
                $0.bytesReceived = totalBytesWritten
                $0.bytesExpected = totalBytesExpectedToWrite
            }
        case .segment(let itemID, let index):
            guard var transfer = segmentedTransfers[itemID] else { return }
            transfer.bytesBySegment[index] = totalBytesWritten
            let received = transfer.completedBytes + transfer.bytesBySegment.values.reduce(0, +)
            let expectedSize = transfer.expectedSize
            segmentedTransfers[itemID] = transfer
            update(itemID) {
                $0.state = .downloading
                $0.bytesReceived = received
                $0.bytesExpected = expectedSize
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let kind = taskKinds[downloadTask.taskIdentifier] else { return }
        switch kind {
        case .single(let itemID):
            guard let destinationFolder = destinationFolders[itemID] else { return }
            let suggestedName = resolvedFileName(
                for: itemID,
                suggestedName: downloadTask.response?.suggestedFilename,
                mimeType: downloadTask.response?.mimeType
            )
            let fallbackName = "Download-\(itemID.uuidString.prefix(8))"
            let destination = Self.availableDestination(named: suggestedName.isEmpty ? fallbackName : suggestedName, in: destinationFolder)
            do {
                try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: destination)
                preferredFileNames[itemID] = nil
                DispatchQueue.main.async {
                    guard let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                    self.items[index].fileName = destination.lastPathComponent
                    self.items[index].finishedFileURL = destination
                    self.items[index].state = .completed
                }
            } catch {
                update(itemID) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
        case .segment(let itemID, let index):
            if pausedSegmentedIDs.contains(itemID) { return }
            finishSegment(index, for: itemID, from: location, response: downloadTask.response)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let kind = taskKinds[task.taskIdentifier] else { return }
        switch kind {
        case .single(let itemID):
            singleTasks[itemID] = nil
            taskKinds[task.taskIdentifier] = nil
            let wasPaused = pausedSingleTaskIDs.remove(task.taskIdentifier) != nil
            if wasPaused {
                singlePauseCompletionPendingIDs.insert(itemID)
                finishSinglePauseIfReady(itemID)
                return
            }
            releaseSlot(for: itemID)
            guard let error else { return }
            if scheduleAutomaticRetry(for: itemID, error: error) { return }
            update(itemID) {
                guard $0.state != .completed else { return }
                $0.state = .failed
                $0.errorMessage = error.localizedDescription
            }
        case .segment(let itemID, let index):
            segmentTasks[itemID]?[index] = nil
            guard let error, !pausedSegmentedIDs.contains(itemID), !fallingBackIDs.contains(itemID) else { return }
            fallbackToSingleTransfer(for: itemID, message: error.localizedDescription)
        }
    }
}
