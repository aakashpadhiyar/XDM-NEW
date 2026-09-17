// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct ContentView: View {
    @ObservedObject var downloads: DownloadCoordinator
    @ObservedObject var locationStore: DownloadLocationStore
    @State private var isShowingAddDownload = false

    var body: some View {
        NavigationSplitView {
            List {
                Label("All downloads", systemImage: "arrow.down.circle")
                Label("Completed", systemImage: "checkmark.circle")
                Label("Settings", systemImage: "gearshape")
            }
            .navigationTitle("XDM")
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                permissionBanner
                if downloads.items.isEmpty {
                    ContentUnavailableView(
                        "No downloads yet",
                        systemImage: "arrow.down.circle",
                        description: Text("Add a direct download URL to begin.")
                    )
                } else {
                    List(downloads.items) { item in
                        DownloadRow(item: item, coordinator: downloads)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Downloads")
        }
        .sheet(isPresented: $isShowingAddDownload) {
            AddDownloadSheet { url in
                downloads.start(url: url, destinationFolder: locationStore.folderURL)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Text("Live downloads")
                .font(.headline)
            Spacer()
            Button("Add download", systemImage: "plus") {
                isShowingAddDownload = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding()
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: locationStore.hasFolderPermission ? "checkmark.shield" : "folder.badge.questionmark")
                .foregroundStyle(locationStore.hasFolderPermission ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Download folder")
                    .font(.subheadline.weight(.medium))
                Text(locationStore.folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Change folder") { _ = locationStore.chooseFolder() }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.quaternary)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var coordinator: DownloadCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading) {
                    Text(item.fileName).lineLimit(1)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                controls
            }
            if let progress = item.progress, item.state == .downloading {
                ProgressView(value: progress)
            } else if item.state == .downloading {
                ProgressView()
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var controls: some View {
        switch item.state {
        case .queued, .downloading:
            Button("Pause", systemImage: "pause.fill") { coordinator.pause(item) }
                .labelStyle(.iconOnly)
            Button("Cancel", systemImage: "xmark") { coordinator.cancel(item) }
                .labelStyle(.iconOnly)
        case .paused:
            Button("Resume", systemImage: "play.fill") { coordinator.resume(item) }
                .labelStyle(.iconOnly)
            Button("Cancel", systemImage: "xmark") { coordinator.cancel(item) }
                .labelStyle(.iconOnly)
        case .completed:
            if let fileURL = item.finishedFileURL {
                Button("Open", systemImage: "arrow.up.forward.app") { FileOpeningService.openDefault(fileURL) }
                    .labelStyle(.iconOnly)
                Menu {
                    Button("Reveal in Finder") { FileOpeningService.revealInFinder(fileURL) }
                    Divider()
                    ForEach(FileOpeningService.applications(for: fileURL), id: \.self) { applicationURL in
                        Button(applicationURL.deletingPathExtension().lastPathComponent) {
                            FileOpeningService.open(fileURL, with: applicationURL)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        case .failed, .cancelled:
            Button("Retry", systemImage: "arrow.clockwise") { coordinator.retry(item) }
                .labelStyle(.iconOnly)
            Button("Remove", systemImage: "trash") { coordinator.remove(item) }
                .labelStyle(.iconOnly)
        }
    }

    private var iconName: String {
        switch item.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused, .cancelled: "pause.circle.fill"
        default: "arrow.down.circle.fill"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .completed: .green
        case .failed: .red
        case .paused, .cancelled: .orange
        default: .accentColor
        }
    }
}

private struct AddDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var showsInvalidURL = false
    let onAdd: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New download").font(.title2.weight(.semibold))
            TextField("https://example.com/file.zip", text: $address)
                .textFieldStyle(.roundedBorder)
            if showsInvalidURL {
                Text("Enter a valid HTTP or HTTPS download URL.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start download") { addDownload() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func addDownload() {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            showsInvalidURL = true
            return
        }
        onAdd(url)
        dismiss()
    }
}
