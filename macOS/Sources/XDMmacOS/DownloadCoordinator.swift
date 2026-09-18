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

    /// A clear (non-encrypted) HLS media playlist. Segments are written in
    /// playlist order, which produces a playable transport-stream file.
    private struct HLSTransfer {
        let workspaceURL: URL
        let outputURL: URL
        let segmentURLs: [URL]
        var nextSegment = 0
        var bytesReceived: Int64 = 0
    }

    private var taskKinds: [Int: TaskKind] = [:]
    private var singleTasks: [UUID: URLSessionDownloadTask] = [:]
    private var segmentTasks: [UUID: [Int: URLSessionDownloadTask]] = [:]
    private var segmentedTransfers: [UUID: SegmentedTransfer] = [:]
    private var hlsTransfers: [UUID: HLSTransfer] = [:]
    private var hlsTasks: [UUID: URLSessionDataTask] = [:]
    private var pausedHLSIDs = Set<UUID>()
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
        if let task = hlsTasks.removeValue(forKey: item.id) {
            pausedHLSIDs.insert(item.id)
            task.cancel()
            update(item.id) { $0.state = .paused }
            releaseSlot(for: item.id)
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
        pausedHLSIDs.remove(item.id)
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
        cancelHLSTransfer(for: item.id, removeWorkspace: true)
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
        cancelHLSTransfer(for: item.id, removeWorkspace: true)
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
        let activeWorkspaces = Set(segmentedTransfers.values.map(\.workspaceURL) + hlsTransfers.values.map(\.workspaceURL))
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
            } else if hlsTransfers[itemID] != nil {
                resumeHLSTransfer(for: itemID)
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

        if Self.isHLSURL(url) {
            startHLSDownload(for: itemID, manifestURL: url)
            return
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
                if Self.isHLSContentType(http?.mimeType) {
                    self.startHLSDownload(for: itemID, manifestURL: url)
                } else if acceptsRanges, let contentLength, contentLength >= Self.minimumPartSize * 2 {
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

    private func startHLSDownload(for itemID: UUID, manifestURL: URL) {
        guard destinationFolders[itemID] != nil else { return }
        update(itemID) {
            $0.state = .downloading
            $0.connectionCount = 1
            $0.bytesExpected = 0
            $0.errorMessage = nil
        }
        loadHLSPlaylist(for: itemID, at: manifestURL, remainingRedirects: 3)
    }

    private func loadHLSPlaylist(for itemID: UUID, at playlistURL: URL, remainingRedirects: Int) {
        let task = URLSession.shared.dataTask(with: request(for: itemID, url: playlistURL)) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.destinationFolders[itemID] != nil else { return }
                guard error == nil, let data, let playlist = String(data: data, encoding: .utf8) else {
                    self.failHLS(itemID, message: error?.localizedDescription ?? "The streaming playlist could not be read.")
                    return
                }
                let resolvedURL = response?.url ?? playlistURL
                switch Self.parseHLSPlaylist(playlist, baseURL: resolvedURL) {
                case .master(let variantURL):
                    guard remainingRedirects > 0 else {
                        self.failHLS(itemID, message: "The HLS playlist redirected through too many variant playlists.")
                        return
                    }
                    self.loadHLSPlaylist(for: itemID, at: variantURL, remainingRedirects: remainingRedirects - 1)
                case .media(let segments):
                    self.beginHLSSegments(for: itemID, manifestURL: resolvedURL, segments: segments)
                case .failure(let message):
                    self.failHLS(itemID, message: message)
                }
            }
        }
        task.resume()
    }

    private func beginHLSSegments(for itemID: UUID, manifestURL: URL, segments: [URL]) {
        guard let destinationFolder = destinationFolders[itemID], !segments.isEmpty else {
            failHLS(itemID, message: "The HLS playlist has no downloadable media segments.")
            return
        }
        let requestedName = preferredFileNames[itemID] ?? manifestURL.lastPathComponent
        let baseName = URL(fileURLWithPath: requestedName).deletingPathExtension().lastPathComponent
        let fileName = "\(baseName.isEmpty ? "Download" : baseName).ts"
        let workspace = Self.workspaceURL(in: destinationFolder, fileName: fileName, expectedSize: Int64(segments.count), itemID: itemID)
        let outputURL = workspace.appendingPathComponent("stream.ts")
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            hlsTransfers[itemID] = HLSTransfer(workspaceURL: workspace, outputURL: outputURL, segmentURLs: segments)
            preferredFileNames[itemID] = fileName
            update(itemID) {
                $0.fileName = fileName
                $0.temporaryWorkspaceURL = workspace
                $0.state = .downloading
            }
            downloadNextHLSSegment(for: itemID)
        } catch {
            failHLS(itemID, message: "Could not create the streaming workspace: \(error.localizedDescription)")
        }
    }

    private func resumeHLSTransfer(for itemID: UUID) {
        pausedHLSIDs.remove(itemID)
        guard hlsTransfers[itemID] != nil else { return }
        update(itemID) { $0.state = .downloading; $0.errorMessage = nil }
        downloadNextHLSSegment(for: itemID)
    }

    private func downloadNextHLSSegment(for itemID: UUID) {
        guard !pausedHLSIDs.contains(itemID), let transfer = hlsTransfers[itemID] else { return }
        guard transfer.nextSegment < transfer.segmentURLs.count else {
            finishHLS(for: itemID, transfer: transfer)
            return
        }
        let task = URLSession.shared.dataTask(with: request(for: itemID, url: transfer.segmentURLs[transfer.nextSegment])) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, let current = self.hlsTransfers[itemID] else { return }
                self.hlsTasks[itemID] = nil
                guard !self.pausedHLSIDs.contains(itemID) else { return }
                guard error == nil, let data,
                      let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    self.failHLS(itemID, message: error?.localizedDescription ?? "A streaming segment could not be downloaded.")
                    return
                }
                do {
                    let output = try FileHandle(forWritingTo: current.outputURL)
                    try output.seekToEnd()
                    try output.write(contentsOf: data)
                    try output.close()
                    var updated = current
                    updated.nextSegment += 1
                    updated.bytesReceived += Int64(data.count)
                    let received = updated.bytesReceived
                    self.hlsTransfers[itemID] = updated
                    self.update(itemID) {
                        $0.bytesReceived = received
                        $0.bytesExpected = 0
                        $0.state = .downloading
                    }
                    self.downloadNextHLSSegment(for: itemID)
                } catch {
                    self.failHLS(itemID, message: "Could not write a streaming segment: \(error.localizedDescription)")
                }
            }
        }
        hlsTasks[itemID] = task
        task.resume()
    }

    private func finishHLS(for itemID: UUID, transfer: HLSTransfer) {
        guard let destinationFolder = destinationFolders[itemID] else { return }
        let destination = Self.availableDestination(named: preferredFileNames[itemID] ?? "Download.ts", in: destinationFolder)
        update(itemID) { $0.state = .merging }
        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: transfer.outputURL, to: destination)
            hlsTransfers[itemID] = nil
            Self.removeWorkspace(transfer.workspaceURL)
            preferredFileNames[itemID] = nil
            update(itemID) {
                $0.fileName = destination.lastPathComponent
                $0.finishedFileURL = destination
                $0.bytesReceived = transfer.bytesReceived
                $0.state = .completed
                $0.temporaryWorkspaceURL = nil
            }
            releaseSlot(for: itemID)
        } catch {
            failHLS(itemID, message: "Could not finalize the streaming video: \(error.localizedDescription)")
        }
    }

    private func failHLS(_ itemID: UUID, message: String) {
        hlsTasks.removeValue(forKey: itemID)?.cancel()
        if let transfer = hlsTransfers.removeValue(forKey: itemID) { Self.removeWorkspace(transfer.workspaceURL) }
        update(itemID) {
            $0.state = .failed
            $0.errorMessage = message
            $0.temporaryWorkspaceURL = nil
        }
        releaseSlot(for: itemID)
    }

    private func cancelHLSTransfer(for itemID: UUID, removeWorkspace: Bool) {
        hlsTasks.removeValue(forKey: itemID)?.cancel()
        pausedHLSIDs.remove(itemID)
        if let transfer = hlsTransfers.removeValue(forKey: itemID), removeWorkspace {
            Self.removeWorkspace(transfer.workspaceURL)
        }
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

    private enum HLSPlaylistResult {
        case master(URL)
        case media([URL])
        case failure(String)
    }

    private static func isHLSURL(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("m3u8") == .orderedSame
    }

    private static func isHLSContentType(_ contentType: String?) -> Bool {
        let value = contentType?.lowercased() ?? ""
        return value.contains("mpegurl") || value.contains("vnd.apple.mpegurl")
    }

    private static func parseHLSPlaylist(_ text: String, baseURL: URL) -> HLSPlaylistResult {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains(where: { $0 == "#EXTM3U" }) else {
            return .failure("The response is not an HLS M3U8 playlist.")
        }
        var encrypted = false
        var variants = [(bandwidth: Int, url: URL)]()
        var segments = [URL]()
        var nextVariantBandwidth: Int?
        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-KEY:") {
                let upper = line.uppercased()
                if !upper.contains("METHOD=NONE") { encrypted = true }
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let bandwidth = line.split(separator: ",").first { $0.uppercased().hasPrefix("BANDWIDTH=") }
                    .flatMap { Int($0.split(separator: "=").last ?? "0") } ?? 0
                nextVariantBandwidth = bandwidth
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = hlsAttribute("URI", in: line), let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                    segments.append(url)
                }
                continue
            }
            guard !line.hasPrefix("#"), let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
            if let bandwidth = nextVariantBandwidth {
                variants.append((bandwidth, url))
                nextVariantBandwidth = nil
            } else {
                segments.append(url)
            }
        }
        if let selected = variants.max(by: { $0.bandwidth < $1.bandwidth }) { return .master(selected.url) }
        if encrypted { return .failure("This HLS playlist is encrypted or DRM-protected, so XDM New will not download it as clear media.") }
        guard !segments.isEmpty else { return .failure("The HLS playlist did not contain media segments.") }
        return .media(segments)
    }

    private static func hlsAttribute(_ name: String, in line: String) -> String? {
        let pattern = "(?:^|,)\(name)=\\\"?([^,\\\"]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[valueRange])
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
