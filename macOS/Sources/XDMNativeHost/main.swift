// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

private struct DownloadRequest: Decodable {
    let type: String
    let url: String
    let filename: String?
}

private struct HostResponse: Encodable {
    let accepted: Bool
    let message: String
}

private let maximumMessageLength = 1_048_576

private func bundledAppURL() -> URL? {
    let hostURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let resourcesURL = hostURL.deletingLastPathComponent()
    let contentsURL = resourcesURL.deletingLastPathComponent()
    let appURL = contentsURL.deletingLastPathComponent()
    return appURL.pathExtension == "app" ? appURL : nil
}

private func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty else {
            return nil
        }
        data.append(chunk)
    }
    return data
}

private func readMessage() -> Data? {
    let input = FileHandle.standardInput
    guard let header = readExactly(4, from: input) else { return nil }
    let bytes = Array(header)
    let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
    guard length > 0, length <= maximumMessageLength else { return nil }
    return readExactly(length, from: input)
}

private func writeResponse(_ response: HostResponse) {
    guard let payload = try? JSONEncoder().encode(response) else { return }
    let length = UInt32(payload.count)
    let header = Data([
        UInt8(length & 0xff), UInt8((length >> 8) & 0xff),
        UInt8((length >> 16) & 0xff), UInt8((length >> 24) & 0xff)
    ])
    FileHandle.standardOutput.write(header)
    FileHandle.standardOutput.write(payload)
}

private func handOffToXDM(_ request: DownloadRequest) -> HostResponse {
    guard request.type == "download",
          let sourceURL = URL(string: request.url),
          ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") else {
        return HostResponse(accepted: false, message: "Only HTTP and HTTPS download URLs are supported.")
    }

    var components = URLComponents()
    components.scheme = "xdmtest"
    components.host = "download"
    components.queryItems = [URLQueryItem(name: "url", value: sourceURL.absoluteString)]
    if let filename = request.filename, !filename.isEmpty {
        components.queryItems?.append(URLQueryItem(name: "filename", value: filename))
    }

    guard let handoffURL = components.url else {
        return HostResponse(accepted: false, message: "Could not create the XDM handoff URL.")
    }

    do {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bundledAppURL = bundledAppURL() {
            process.arguments = ["-a", bundledAppURL.path, handoffURL.absoluteString]
        } else {
            process.arguments = ["-b", "org.xdm.test", handoffURL.absoluteString]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return HostResponse(accepted: false, message: "XDM Test is not installed or registered with macOS.")
        }
        return HostResponse(accepted: true, message: "Sent download to XDM Test.")
    } catch {
        return HostResponse(accepted: false, message: error.localizedDescription)
    }
}

guard let message = readMessage(), let request = try? JSONDecoder().decode(DownloadRequest.self, from: message) else {
    writeResponse(HostResponse(accepted: false, message: "Invalid native-messaging request."))
    exit(1)
}
writeResponse(handOffToXDM(request))
