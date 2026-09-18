// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Network

struct BrowserMonitorPayload: Sendable {
    var id: String?
    let url: URL
    let fileName: String?
    let requestHeaders: [String: String]
    let contentType: String?
    let contentLength: Int64?
    let contentRangeTotal: Int64?
    let contentDisposition: String?
    let referrer: String?
    let tabID: String?
    let acceptsByteRanges: Bool

    var reportedSize: Int64? {
        contentRangeTotal ?? contentLength
    }

    var mediaKind: String {
        let type = contentType?.lowercased() ?? ""
        let extensionName = url.pathExtension.lowercased()
        if type.hasPrefix("video/") || ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv"].contains(extensionName) { return "Video" }
        if type.hasPrefix("audio/") || ["mp3", "m4a", "aac", "flac", "wav", "ogg"].contains(extensionName) { return "Audio" }
        if type.contains("mpegurl") || type.contains("m3u8") || type.contains("f4m") || ["m3u8", "f4m"].contains(extensionName) { return "Stream manifest" }
        return "Unknown media"
    }
}

/// Compatibility endpoint for the legacy XDM Browser Monitor Firefox add-on.
/// The add-on uses simple HTTP requests to 127.0.0.1:9614 rather than native messaging.
final class BrowserMonitorServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.xdm.test.browser-monitor")
    private var videos: [String: BrowserMonitorPayload] = [:]

    var onDownload: (@MainActor @Sendable (BrowserMonitorPayload) -> Void)?
    var onVideoDetected: (@MainActor @Sendable (BrowserMonitorPayload) -> Void)?
    var onAvailabilityChanged: (@MainActor @Sendable (String) -> Void)?

    init(port: UInt16 = 9614) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "XDMTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid browser-monitor port."])
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: endpointPort
        )
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.receiveRequest(on: connection, buffered: Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.notifyAvailability("Legacy XDM browser monitor: listening on 127.0.0.1:9614")
            case .failed(let error):
                let description = error.localizedDescription
                if description.localizedCaseInsensitiveContains("Address already in use") {
                    self.notifyAvailability("Legacy XDM extension unavailable: port 9614 is used by another XDM app. Quit the old XDM app, or use the bundled XDM New extension.")
                } else {
                    self.notifyAvailability("Legacy XDM extension unavailable: \(description)")
                }
            case .cancelled:
                self.notifyAvailability("Original extension monitoring stopped")
            default:
                break
            }
        }
    }

    func start() {
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    func removeVideo(id: String) {
        queue.async { [weak self] in self?.videos[id] = nil }
    }

    private func notifyAvailability(_ message: String) {
        guard let callback = onAvailabilityChanged else { return }
        Task { @MainActor in callback(message) }
    }

    private func receiveRequest(on connection: NWConnection, buffered: Data) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var requestData = buffered
            if let data { requestData.append(data) }

            guard error == nil else {
                connection.cancel()
                return
            }

            if let request = Self.parseRequest(requestData) {
                self.handle(request, on: connection)
                return
            }

            if requestData.count >= 65_536 || isComplete {
                self.respond(status: 400, body: "Bad Request", on: connection)
            } else {
                self.receiveMore(on: connection, buffered: requestData)
            }
        }
    }

    private func receiveMore(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536 - buffered.count) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var requestData = buffered
            if let data { requestData.append(data) }
            guard error == nil else {
                connection.cancel()
                return
            }
            if let request = Self.parseRequest(requestData) {
                self.handle(request, on: connection)
            } else if requestData.count >= 65_536 || isComplete {
                self.respond(status: 400, body: "Bad Request", on: connection)
            } else {
                self.receiveMore(on: connection, buffered: requestData)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/sync"):
            let videoList = videos.values.map { payload in
                [
                    "id": payload.id ?? "",
                    "text": payload.fileName ?? payload.url.lastPathComponent,
                    "info": Self.videoInfo(for: payload)
                ]
            }
            let response: [String: Any] = [
                "enabled": ApplicationSettings.browserMonitoringEnabled,
                "blockedHosts": ApplicationSettings.commaSeparatedValues(ApplicationSettings.excludedHosts),
                "videoUrls": [],
                "fileExts": ApplicationSettings.commaSeparatedValues(ApplicationSettings.fileExtensions),
                "vidExts": ApplicationSettings.commaSeparatedValues(ApplicationSettings.videoExtensions),
                "vidList": videoList,
                "mimeList": ["video/", "audio/", "mpegurl", "f4m", "m3u8"]
            ]
            let body = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
            respond(status: 200, body: body, contentType: "application/json", on: connection)

        case ("POST", "/download"):
            guard ApplicationSettings.browserMonitoringEnabled else {
                respond(status: 204, body: Data(), on: connection)
                return
            }
            guard let payload = Self.payload(from: request.body) else {
                respond(status: 400, body: "Missing download URL", on: connection)
                return
            }
            if let callback = onDownload {
                Task { @MainActor in callback(payload) }
            }
            respond(status: 200, body: Data(), on: connection)

        case ("POST", "/video"):
            guard ApplicationSettings.browserMonitoringEnabled, ApplicationSettings.videoCaptureEnabled else {
                respond(status: 204, body: Data(), on: connection)
                return
            }
            guard var payload = Self.payload(from: request.body) else {
                respond(status: 400, body: "Missing video URL", on: connection)
                return
            }
            let id = UUID().uuidString
            payload.id = id
            guard Self.shouldOfferMedia(payload) else {
                respond(status: 204, body: Data(), on: connection)
                return
            }
            guard !videos.values.contains(where: { Self.isSameVideoVariant($0, payload) }) else {
                respond(status: 200, body: Data(), on: connection)
                return
            }
            videos[id] = payload
            if let callback = onVideoDetected {
                Task { @MainActor in callback(payload) }
            }
            respond(status: 200, body: Data(), on: connection)

        case ("POST", "/item"):
            let id = String(data: request.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let payload = videos.removeValue(forKey: id) else {
                respond(status: 404, body: "Video is no longer available", on: connection)
                return
            }
            if let callback = onDownload {
                Task { @MainActor in callback(payload) }
            }
            respond(status: 200, body: Data(), on: connection)

        case ("GET", "/clear"), ("GET", "/204"):
            if request.path == "/clear" { videos.removeAll() }
            respond(status: request.path == "/204" ? 204 : 200, body: Data(), on: connection)

        default:
            respond(status: 404, body: "Not Found", on: connection)
        }
    }

    private func respond(status: Int, body: String, on connection: NWConnection) {
        respond(status: status, body: Data(body.utf8), on: connection)
    }

    private func respond(status: Int, body: Data, contentType: String = "text/plain; charset=utf-8", on connection: NWConnection) {
        let reason = status == 200 ? "OK" : status == 204 ? "No Content" : status == 400 ? "Bad Request" : "Not Found"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: \(contentType)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func videoInfo(for payload: BrowserMonitorPayload) -> String {
        var values = [String]()
        if let reportedSize = payload.reportedSize, reportedSize > 0 {
            values.append(ByteCountFormatter.string(fromByteCount: reportedSize, countStyle: .file))
        }
        if let contentType = payload.contentType, !contentType.isEmpty {
            values.append(contentType)
        }
        return values.joined(separator: " · ")
    }

    private static func isSameVideoVariant(_ first: BrowserMonitorPayload, _ second: BrowserMonitorPayload) -> Bool {
        if first.url == second.url { return true }
        let firstName = (first.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? first.fileName : first.url.lastPathComponent) ?? first.url.lastPathComponent
        let secondName = (second.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? second.fileName : second.url.lastPathComponent) ?? second.url.lastPathComponent
        guard let firstSize = first.reportedSize, firstSize > 0,
              let secondSize = second.reportedSize, secondSize > 0 else { return false }
        return firstName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            == secondName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            && firstSize == secondSize
    }

    private static func shouldOfferMedia(_ payload: BrowserMonitorPayload) -> Bool {
        let type = payload.contentType?.lowercased() ?? ""
        guard !type.hasPrefix("image/") else { return false }
        let manifest = payload.mediaKind == "Stream manifest"
        guard payload.mediaKind != "Unknown media" else { return false }
        guard !manifest else { return true }
        guard !isExcludedHost(payload.url.host) else { return false }
        return payload.reportedSize == nil || payload.reportedSize! >= ApplicationSettings.videoMinimumBytes
    }

    private static func isExcludedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return ApplicationSettings.commaSeparatedValues(ApplicationSettings.excludedHosts).contains { excluded in
            let normalized = excluded.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return host == normalized || host.hasSuffix(".\(normalized)")
        }
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return HTTPRequest(method: String(parts[0]).uppercased(), path: String(parts[1]), body: Data(data[bodyStart..<(bodyStart + length)]))
    }

    private static func payload(from body: Data) -> BrowserMonitorPayload? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var url: URL?
        var fileName: String?
        var requestHeaders = [String: String]()
        var responseHeaders = [String: String]()
        var cookies = [String]()

        for rawLine in text.components(separatedBy: .newlines) where !rawLine.isEmpty {
            guard let equals = rawLine.firstIndex(of: "=") else { continue }
            let key = String(rawLine[..<equals])
            let value = String(rawLine[rawLine.index(after: equals)...])
            switch key {
            case "url": url = URL(string: value)
            case "file": fileName = URL(fileURLWithPath: value).lastPathComponent
            case "req": appendHeader(value, to: &requestHeaders)
            case "res": appendHeader(value, to: &responseHeaders)
            case "cookie": appendCookie(value, to: &cookies)
            default: break
            }
        }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if !cookies.isEmpty { requestHeaders["Cookie"] = cookies.joined(separator: "; ") }
        requestHeaders.removeValue(forKey: "Host")
        requestHeaders.removeValue(forKey: "Content-Length")
        requestHeaders.removeValue(forKey: "Range")
        let contentLength = Int64(headerValue("Content-Length", in: responseHeaders) ?? "")
        let contentRangeTotal = contentRangeTotal(from: headerValue("Content-Range", in: responseHeaders))
        let contentType = headerValue("Content-Type", in: responseHeaders)
        let contentDisposition = headerValue("Content-Disposition", in: responseHeaders)
        let referrer = headerValue("Referer", in: requestHeaders) ?? headerValue("Referrer", in: requestHeaders)
        let tabID = headerValue("tabId", in: responseHeaders)
        let acceptsRanges = headerValue("Accept-Ranges", in: responseHeaders)?.lowercased().contains("bytes") == true
        return BrowserMonitorPayload(
            id: nil,
            url: url,
            fileName: fileName,
            requestHeaders: requestHeaders,
            contentType: contentType,
            contentLength: contentLength,
            contentRangeTotal: contentRangeTotal,
            contentDisposition: contentDisposition,
            referrer: referrer,
            tabID: tabID,
            acceptsByteRanges: acceptsRanges
        )
    }

    private static func appendHeader(_ input: String, to headers: inout [String: String]) {
        guard let colon = input.firstIndex(of: ":") else { return }
        let name = String(input[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(input[input.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        headers[name] = value
    }

    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private static func contentRangeTotal(from header: String?) -> Int64? {
        guard let total = header?.split(separator: "/").last, total != "*" else { return nil }
        return Int64(total)
    }

    private static func appendCookie(_ input: String, to cookies: inout [String]) {
        guard let colon = input.firstIndex(of: ":") else { return }
        let name = input[..<colon].trimmingCharacters(in: .whitespaces)
        let value = input[input.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        cookies.append("\(name)=\(value)")
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
}
