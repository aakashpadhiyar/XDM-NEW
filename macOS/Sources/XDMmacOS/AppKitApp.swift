// XDMmacOS is a derivative work of Xtreme Download Manager (XDM).
// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Combine
import Quartz
import ServiceManagement

private final class DownloadTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

private final class PreviewDataSource: NSObject, QLPreviewPanelDataSource {
    var url: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private enum StateFilter: Int { case all, active, completed }

    private let downloads = DownloadCoordinator()
    private let locationStore = DownloadLocationStore()
    private let tableView = DownloadTableView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let categoryMenu = NSPopUpButton()
    private let stateControl = NSSegmentedControl(labels: ["All", "Active", "Completed"], trackingMode: .selectOne, target: nil, action: nil)
    private let browserStatusLabel = NSTextField(labelWithString: "Browser integration: starting…")
    private let detectedVideosButton = NSButton(title: "Download video", target: nil, action: nil)
    private let browserMonitoringToggle = NSButton(checkboxWithTitle: "Browser monitoring", target: nil, action: nil)
    private var detectedVideosMenuItem: NSMenuItem?
    private var stateFilter = StateFilter.all
    private var itemsObservation: AnyCancellable?
    private var browserMonitor: BrowserMonitorServer?
    private var detectedVideos = [BrowserMonitorPayload]()
    private var videoToast: NSPanel?
    private let previewDataSource = PreviewDataSource()
    private var settingsWindow: NSPanel?
    private var settingsConnectionsSlider: NSSlider?
    private var settingsConnectionsLabel: NSTextField?
    private var settingsSimultaneousControl: NSPopUpButton?
    private var settingsLaunchAtLoginCheck: NSButton?
    private var settingsFolderLabel: NSTextField?
    private var settingsAppearanceControl: NSPopUpButton?
    private var settingsAutomaticRetryCheck: NSButton?
    private weak var mainWindow: NSWindow?
    private var propertiesWindow: NSPanel?
    private var propertiesItemID: UUID?
    private var aboutWindow: NSPanel?
    private var videoListWindow: NSPanel?
    private let detectedVideosTable = NSTableView()
    private var visibleVideoOptions = [BrowserMonitorPayload]()
    private var browserMonitoringWindow: NSPanel?
    private var browserFileExtensionsField: NSTextField?
    private var browserVideoExtensionsField: NSTextField?
    private var browserExcludedHostsField: NSTextField?
    private var browserMinimumSizeControl: NSPopUpButton?
    private var browserVideoCaptureCheck: NSButton?
    private var browserClipboardCheck: NSButton?
    private var browserAutomaticStartCheck: NSButton?
    private var browserTimestampCheck: NSButton?
    private var clipboardTimer: Timer?
    private var lastClipboardChangeCount = NSPasteboard.general.changeCount

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearanceSetting()
        installMainMenu()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "XDM New"
        mainWindow = window
        window.center()
        window.contentView = makeContentView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        refreshFolderLabel()
        startOriginalFirefoxExtensionBridge()
        startClipboardMonitoring()
        itemsObservation = downloads.$items.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.reloadTablePreservingSelection()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        itemsObservation?.cancel()
        browserMonitor?.stop()
        clipboardTimer?.invalidate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { acceptBrowserHandoff(url) }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "XDM New")
        appMenu.addItem(menuItem("About XDM New", action: #selector(showAbout)))
        appMenu.addItem(menuItem("Settings…", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(responderMenuItem("Hide XDM New", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(responderMenuItem("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h", modifiers: [.command, .option]))
        appMenu.addItem(responderMenuItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(responderMenuItem("Quit XDM New", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        addTopLevelMenu(appMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("New Download…", action: #selector(addDownload), keyEquivalent: "n"))
        fileMenu.addItem(menuItem("Download Video…", action: #selector(showDetectedVideos)))
        fileMenu.addItem(menuItem("Add from Clipboard", action: #selector(addFromClipboard)))
        fileMenu.addItem(menuItem("Batch Download…", action: #selector(batchDownload)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem("Delete Selected Download", action: #selector(removeSelectedFromHistory)))
        fileMenu.addItem(menuItem("Clear Finished", action: #selector(clearFinishedDownloads)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem("Export URLs…", action: #selector(exportDownloads)))
        fileMenu.addItem(menuItem("Import URLs…", action: #selector(importDownloads)))
        addTopLevelMenu(fileMenu, to: mainMenu)

        let downloadsMenu = NSMenu(title: "Downloads")
        let videosItem = menuItem("Detected Videos", action: #selector(showDetectedVideos))
        downloadsMenu.addItem(videosItem)
        detectedVideosMenuItem = videosItem
        downloadsMenu.addItem(.separator())
        downloadsMenu.addItem(menuItem("Pause", action: #selector(pauseSelected)))
        downloadsMenu.addItem(menuItem("Resume", action: #selector(resumeSelected)))
        downloadsMenu.addItem(menuItem("Cancel", action: #selector(cancelSelected)))
        downloadsMenu.addItem(menuItem("Retry", action: #selector(retrySelected)))
        downloadsMenu.addItem(menuItem("Restart", action: #selector(restartSelected)))
        downloadsMenu.addItem(.separator())
        downloadsMenu.addItem(menuItem("Pause Queue", action: #selector(pauseQueue)))
        downloadsMenu.addItem(menuItem("Start Queue", action: #selector(resumeQueue)))
        downloadsMenu.addItem(.separator())
        downloadsMenu.addItem(menuItem("Properties…", action: #selector(showSelectedProperties)))
        downloadsMenu.addItem(menuItem("Preview Video", action: #selector(previewSelectedVideo)))
        downloadsMenu.addItem(menuItem("Reveal in Finder", action: #selector(revealSelectedFile)))
        addTopLevelMenu(downloadsMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(menuItem("All Downloads", action: #selector(showAllDownloads), keyEquivalent: "1"))
        viewMenu.addItem(menuItem("Active Downloads", action: #selector(showActiveDownloads), keyEquivalent: "2"))
        viewMenu.addItem(menuItem("Completed Downloads", action: #selector(showCompletedDownloads), keyEquivalent: "3"))
        addTopLevelMenu(viewMenu, to: mainMenu)

        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(menuItem("Options…", action: #selector(showSettings), keyEquivalent: ","))
        toolsMenu.addItem(menuItem("Refresh Link", action: #selector(refreshSelectedLink)))
        toolsMenu.addItem(menuItem("Properties", action: #selector(showSelectedProperties)))
        toolsMenu.addItem(menuItem("Network Optimization", action: #selector(showSettings)))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(menuItem("Browser Monitoring…", action: #selector(showBrowserMonitoring)))
        addTopLevelMenu(toolsMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(responderMenuItem("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(responderMenuItem("Zoom", action: #selector(NSWindow.performZoom(_:))))
        NSApp.windowsMenu = windowMenu
        addTopLevelMenu(windowMenu, to: mainMenu)

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(menuItem("Firefox Extension Setup…", action: #selector(showFirefoxSetup)))
        helpMenu.addItem(menuItem("Show Chrome Extension", action: #selector(revealChromeExtension)))
        addTopLevelMenu(helpMenu, to: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    private func addTopLevelMenu(_ submenu: NSMenu, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        mainMenu.addItem(item)
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if !keyEquivalent.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private func responderMenuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if !keyEquivalent.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private func acceptBrowserHandoff(_ handoffURL: URL) {
        guard handoffURL.scheme == "xdmtest", handoffURL.host == "download",
              let components = URLComponents(url: handoffURL, resolvingAgainstBaseURL: false),
              let source = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let downloadURL = URL(string: source),
              ["http", "https"].contains(downloadURL.scheme?.lowercased() ?? "") else {
            return
        }
        let browserFilename = components.queryItems?.first(where: { $0.name == "filename" })?.value
            .flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        downloads.start(
            url: downloadURL,
            destinationFolder: locationStore.folderURL,
            preferredFileName: browserFilename,
            startImmediately: ApplicationSettings.startDownloadsAutomatically
        )
        reloadTablePreservingSelection()
    }

    private func startOriginalFirefoxExtensionBridge() {
        do {
            let testPort = UInt16(ProcessInfo.processInfo.environment["XDM_TEST_MONITOR_PORT"] ?? "")
            let server = try BrowserMonitorServer(port: testPort ?? 9614)
            server.onAvailabilityChanged = { [weak self] status in
                self?.browserStatusLabel.stringValue = status
            }
            server.onDownload = { [weak self] payload in
                self?.startBrowserDownload(payload)
            }
            server.onVideoDetected = { [weak self] payload in
                self?.offerVideoDownload(payload)
            }
            browserMonitor = server
            server.start()
        } catch {
            browserStatusLabel.stringValue = "Legacy XDM extension unavailable: \(error.localizedDescription)"
        }
    }

    private func startBrowserDownload(_ payload: BrowserMonitorPayload) {
        downloads.start(
            url: payload.url,
            destinationFolder: locationStore.folderURL,
            preferredFileName: payload.fileName,
            requestHeaders: payload.requestHeaders,
            startImmediately: ApplicationSettings.startDownloadsAutomatically
        )
        if let id = payload.id { removeDetectedVideo(id: id) }
        reloadTablePreservingSelection()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startClipboardMonitoring() {
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollClipboard() }
        }
    }

    private func pollClipboard() {
        guard ApplicationSettings.clipboardMonitoringEnabled else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !downloads.items.contains(where: { $0.sourceURL == url }) else { return }
        downloads.start(url: url, destinationFolder: locationStore.folderURL)
    }

    private func offerVideoDownload(_ payload: BrowserMonitorPayload) {
        guard !detectedVideos.contains(where: { isSameVideoVariant($0, payload) }) else { return }
        detectedVideos.insert(payload, at: 0)
        updateDetectedVideosButton()
        showVideoToast()
    }

    private func makeContentView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)

        let heading = NSTextField(labelWithString: "XDM New — Download manager")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        root.addArrangedSubview(heading)

        let topControls = NSStackView(views: [
            button("Add URL", action: #selector(addDownload)),
            button("Download video", action: #selector(showDetectedVideos)),
            button("Add from clipboard", action: #selector(addFromClipboard)),
            button("Batch download", action: #selector(batchDownload))
        ])
        topControls.spacing = 8
        root.addArrangedSubview(topControls)
        detectedVideosButton.target = self
        detectedVideosButton.action = #selector(showDetectedVideos)
        detectedVideosButton.bezelStyle = .rounded
        updateDetectedVideosButton()

        folderLabel.stringValue = "Download location and category folders are managed in Settings."
        folderLabel.font = .systemFont(ofSize: 12)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(folderLabel)

        browserStatusLabel.font = .systemFont(ofSize: 12)
        browserStatusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(browserStatusLabel)
        browserMonitoringToggle.target = self
        browserMonitoringToggle.action = #selector(toggleBrowserMonitoring(_:))
        browserMonitoringToggle.state = ApplicationSettings.browserMonitoringEnabled ? .on : .off
        root.addArrangedSubview(browserMonitoringToggle)

        let filters = NSStackView()
        filters.spacing = 10
        stateControl.target = self
        stateControl.action = #selector(changeStateFilter(_:))
        stateControl.selectedSegment = StateFilter.all.rawValue
        filters.addArrangedSubview(stateControl)
        searchField.placeholderString = "Search downloads"
        searchField.target = self
        searchField.action = #selector(refreshList)
        searchField.frame.size.width = 230
        filters.addArrangedSubview(searchField)
        root.addArrangedSubview(filters)

        let developer = NSTextField(labelWithString: "Developed by Aakash Padhiyar  •  github.com/aakashpadhiyar/XDM-NEW")
        developer.font = .systemFont(ofSize: 11)
        developer.textColor = .secondaryLabelColor
        root.addArrangedSubview(developer)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("download"))
        column.title = "Downloads"
        column.width = 820
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 62
        tableView.target = self
        tableView.doubleAction = #selector(showSelectedProperties)
        tableView.menu = makeDownloadContextMenu()

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        return root
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.bezelStyle = .rounded
        return control
    }

    private func refreshFolderLabel() {
        folderLabel.stringValue = "Downloads save to: \(locationStore.folderURL.path)"
    }

    @objc private func addDownload() {
        let alert = NSAlert()
        alert.messageText = "New download"
        alert.informativeText = "Enter a direct HTTP or HTTPS URL."
        alert.addButton(withTitle: "Start download")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(string: "")
        input.placeholderString = "https://example.com/file.zip"
        input.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: input.stringValue),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }
        downloads.start(url: url, destinationFolder: locationStore.folderURL)
        reloadTablePreservingSelection()
    }

    @objc private func changeFolder() {
        if locationStore.chooseFolder() { refreshFolderLabel() }
    }

    @objc private func toggleBrowserMonitoring(_ sender: NSButton) {
        ApplicationSettings.browserMonitoringEnabled = sender.state == .on
        browserStatusLabel.stringValue = ApplicationSettings.browserMonitoringEnabled
            ? "Browser monitoring is on. Extensions can hand downloads to XDM New."
            : "Browser monitoring is off. Extensions will leave browser downloads untouched."
    }

    @objc private func addFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            presentInformation("No download link in clipboard", message: "Copy a direct HTTP or HTTPS URL, then choose Add from Clipboard.")
            return
        }
        downloads.start(url: url, destinationFolder: locationStore.folderURL)
    }

    @objc private func batchDownload() {
        let alert = NSAlert()
        alert.messageText = "Batch download"
        alert.informativeText = "Paste one direct HTTP or HTTPS download URL per line."
        alert.addButton(withTitle: "Add downloads")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 160))
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView(frame: input.frame)
        scroll.documentView = input
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let count = downloads.importURLs(from: input.string, destinationFolder: locationStore.folderURL)
        if count == 0 { presentInformation("No valid URLs", message: "Add one direct HTTP or HTTPS URL per line.") }
    }

    @objc private func clearFinishedDownloads() {
        downloads.clearFinished()
        reloadTablePreservingSelection()
    }

    @objc private func exportDownloads() {
        let panel = NSSavePanel()
        panel.title = "Export XDM download URLs"
        panel.nameFieldStringValue = "XDM-New-downloads.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try downloads.exportableURLs.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentInformation("Could not export downloads", message: error.localizedDescription)
        }
    }

    @objc private func importDownloads() {
        let panel = NSOpenPanel()
        panel.title = "Import XDM download URLs"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = downloads.importURLs(from: try String(contentsOf: url), destinationFolder: locationStore.folderURL)
            presentInformation("Import complete", message: count == 1 ? "Added 1 download." : "Added \(count) downloads.")
        } catch {
            presentInformation("Could not import downloads", message: error.localizedDescription)
        }
    }

    @objc private func restartSelected() {
        guard let item = selectedItem else { return }
        downloads.cancel(item)
        downloads.start(url: item.sourceURL, destinationFolder: item.destinationFolderURL, preferredFileName: item.fileName, requestHeaders: item.requestHeaders)
    }

    @objc private func pauseQueue() { downloads.pauseQueue() }

    @objc private func resumeQueue() { downloads.resumeQueue() }

    @objc private func refreshSelectedLink() {
        guard let item = selectedItem else { return }
        presentInformation("Refresh link", message: "XDM New will use the saved browser headers and the original URL when this download is restarted. For an expired signed URL, replay the download from the browser extension.")
        _ = item
    }

    @objc private func showSettings() {
        if let settingsWindow {
            updateSettingsControls()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "XDM Settings"
        panel.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)

        let heading = NSTextField(labelWithString: "Downloads")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        root.addArrangedSubview(heading)

        let connectionsRow = NSStackView()
        connectionsRow.spacing = 12
        let connectionsTitle = NSTextField(labelWithString: "Connections per supported file")
        connectionsTitle.frame.size.width = 190
        let connectionsSlider = NSSlider(value: Double(ApplicationSettings.connectionsPerFile), minValue: 1, maxValue: Double(ApplicationSettings.maximumConnectionsPerFile), target: self, action: #selector(changeConnectionsSetting(_:)))
        connectionsSlider.numberOfTickMarks = ApplicationSettings.maximumConnectionsPerFile
        connectionsSlider.allowsTickMarkValuesOnly = true
        connectionsSlider.frame.size.width = 160
        let connectionsValue = NSTextField(labelWithString: "")
        connectionsValue.frame.size.width = 50
        connectionsRow.addArrangedSubview(connectionsTitle)
        connectionsRow.addArrangedSubview(connectionsSlider)
        connectionsRow.addArrangedSubview(connectionsValue)
        root.addArrangedSubview(connectionsRow)
        settingsConnectionsSlider = connectionsSlider
        settingsConnectionsLabel = connectionsValue

        let explanation = NSTextField(wrappingLabelWithString: "Uses byte-range splitting when the server supports it. Unsupported servers automatically use one connection.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 450
        root.addArrangedSubview(explanation)

        let simultaneousRow = NSStackView()
        simultaneousRow.spacing = 12
        let simultaneousTitle = NSTextField(labelWithString: "Downloads at the same time")
        simultaneousTitle.frame.size.width = 190
        let simultaneousControl = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 26), pullsDown: false)
        simultaneousControl.addItems(withTitles: (1...ApplicationSettings.maximumSimultaneousDownloads).map(String.init))
        simultaneousRow.addArrangedSubview(simultaneousTitle)
        simultaneousRow.addArrangedSubview(simultaneousControl)
        root.addArrangedSubview(simultaneousRow)
        settingsSimultaneousControl = simultaneousControl

        let automaticRetry = NSButton(
            checkboxWithTitle: "Retry network failures automatically (up to \(ApplicationSettings.automaticRetryLimit) times)",
            target: nil,
            action: nil
        )
        root.addArrangedSubview(automaticRetry)
        settingsAutomaticRetryCheck = automaticRetry

        let appearanceRow = NSStackView()
        appearanceRow.spacing = 12
        let appearanceTitle = NSTextField(labelWithString: "Appearance")
        appearanceTitle.frame.size.width = 190
        let appearanceControl = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 26), pullsDown: false)
        appearanceControl.addItems(withTitles: ApplicationSettings.AppearanceMode.allCases.map(\.title))
        appearanceRow.addArrangedSubview(appearanceTitle)
        appearanceRow.addArrangedSubview(appearanceControl)
        root.addArrangedSubview(appearanceRow)
        settingsAppearanceControl = appearanceControl

        let folderHeading = NSTextField(labelWithString: "Save location")
        folderHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        root.addArrangedSubview(folderHeading)
        let folderRow = NSStackView()
        folderRow.spacing = 10
        let settingsFolder = NSTextField(labelWithString: "")
        settingsFolder.lineBreakMode = .byTruncatingMiddle
        settingsFolder.frame.size.width = 360
        folderRow.addArrangedSubview(settingsFolder)
        folderRow.addArrangedSubview(button("Change…", action: #selector(changeSettingsFolder)))
        folderRow.addArrangedSubview(button("Clean cache…", action: #selector(cleanUnusedCache)))
        root.addArrangedSubview(folderRow)
        settingsFolderLabel = settingsFolder

        let categoryHeading = NSTextField(labelWithString: "Categories")
        categoryHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        root.addArrangedSubview(categoryHeading)
        let categoryHelp = NSTextField(wrappingLabelWithString: "Documents, compressed files, music, video, and programs are shown as categories in the download table. New downloads use the location above so all .XDM resume data stays together.")
        categoryHelp.font = .systemFont(ofSize: 12)
        categoryHelp.textColor = .secondaryLabelColor
        categoryHelp.preferredMaxLayoutWidth = 470
        root.addArrangedSubview(categoryHelp)

        let launchAtLogin = NSButton(checkboxWithTitle: "Open XDM Test when I log in", target: nil, action: nil)
        root.addArrangedSubview(launchAtLogin)
        settingsLaunchAtLoginCheck = launchAtLogin

        let browserHeading = NSTextField(labelWithString: "Browser integration")
        browserHeading.font = .systemFont(ofSize: 14, weight: .semibold)
        root.addArrangedSubview(browserHeading)
        let browserStatus = NSTextField(wrappingLabelWithString: "\(browserStatusLabel.stringValue)\n\nUse XDM New’s bundled browser extensions. Firefox and Chrome use native messaging, so neither needs the legacy port.")
        browserStatus.font = .systemFont(ofSize: 12)
        browserStatus.textColor = .secondaryLabelColor
        browserStatus.preferredMaxLayoutWidth = 480
        root.addArrangedSubview(browserStatus)
        let browserActions = NSStackView()
        browserActions.spacing = 8
        browserActions.addArrangedSubview(button("Install / repair browser bridge", action: #selector(installFirefoxBridge)))
        browserActions.addArrangedSubview(button("Firefox extension…", action: #selector(showFirefoxSetup)))
        browserActions.addArrangedSubview(button("Chrome extension…", action: #selector(revealChromeExtension)))
        root.addArrangedSubview(browserActions)

        let project = NSButton(title: "Developer: Aakash Padhiyar  •  Open GitHub repository", target: self, action: #selector(openProjectRepository))
        project.bezelStyle = .inline
        root.addArrangedSubview(project)

        let actions = NSStackView()
        actions.spacing = 8
        actions.addArrangedSubview(button("Save", action: #selector(saveSettings)))
        actions.addArrangedSubview(button("Cancel", action: #selector(closeSettings)))
        root.addArrangedSubview(actions)

        panel.contentView = root
        panel.center()
        settingsWindow = panel
        updateSettingsControls()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateSettingsControls() {
        settingsConnectionsSlider?.integerValue = ApplicationSettings.connectionsPerFile
        settingsConnectionsLabel?.stringValue = "\(ApplicationSettings.connectionsPerFile) / \(ApplicationSettings.maximumConnectionsPerFile)"
        settingsSimultaneousControl?.selectItem(at: ApplicationSettings.simultaneousDownloads - 1)
        settingsAppearanceControl?.selectItem(at: ApplicationSettings.AppearanceMode.allCases.firstIndex(of: ApplicationSettings.appearanceMode) ?? 0)
        settingsAutomaticRetryCheck?.state = ApplicationSettings.automaticRetryEnabled ? .on : .off
        settingsFolderLabel?.stringValue = locationStore.folderURL.path
        settingsLaunchAtLoginCheck?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func showBrowserMonitoring() {
        if let browserMonitoringWindow {
            updateBrowserMonitoringControls()
            browserMonitoringWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 670, height: 650),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Browser Monitoring"
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 22, right: 22)

        let heading = NSTextField(labelWithString: "Browser Monitoring")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(heading)
        let status = NSTextField(wrappingLabelWithString: "\(browserStatusLabel.stringValue)\nSelect the browsers you use, install the bundled add-on, and keep it enabled. XDM New’s Firefox and Chrome bridges use native messaging and are separate from the original XDM extension.")
        status.preferredMaxLayoutWidth = 610
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        root.addArrangedSubview(status)

        let browserGrid = NSStackView()
        browserGrid.orientation = .vertical
        browserGrid.alignment = .leading
        browserGrid.spacing = 7
        [
            ("Mozilla Firefox", #selector(showFirefoxSetup)),
            ("Google Chrome", #selector(revealChromeExtension)),
            ("Chromium / Vivaldi / Opera", #selector(revealChromeExtension)),
            ("Microsoft Edge", #selector(revealChromeExtension))
        ].forEach { title, action in
            let row = NSStackView()
            row.spacing = 12
            let label = NSTextField(labelWithString: title)
            label.frame.size.width = 220
            row.addArrangedSubview(label)
            row.addArrangedSubview(button(title == "Mozilla Firefox" ? "Install add-on…" : "Show add-on…", action: action))
            browserGrid.addArrangedSubview(row)
        }
        root.addArrangedSubview(browserGrid)
        root.addArrangedSubview(button("Install / repair native browser bridge", action: #selector(installFirefoxBridge)))

        let capture = NSButton(checkboxWithTitle: "Show a download option for streaming video", target: nil, action: nil)
        root.addArrangedSubview(capture)
        browserVideoCaptureCheck = capture
        let videoTypes = settingField(title: "Video formats to detect", width: 570)
        root.addArrangedSubview(videoTypes.row)
        browserVideoExtensionsField = videoTypes.field
        let fileTypes = settingField(title: "File types to capture automatically", width: 570)
        root.addArrangedSubview(fileTypes.row)
        browserFileExtensionsField = fileTypes.field

        let sizeRow = NSStackView()
        sizeRow.spacing = 12
        sizeRow.addArrangedSubview(NSTextField(labelWithString: "Download video larger than"))
        let sizeControl = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 100, height: 26), pullsDown: false)
        sizeControl.addItems(withTitles: ["1 MB", "5 MB", "10 MB", "25 MB", "50 MB", "100 MB"])
        sizeRow.addArrangedSubview(sizeControl)
        root.addArrangedSubview(sizeRow)
        browserMinimumSizeControl = sizeControl

        let excluded = settingField(title: "Do not automatically capture downloads from these sites", width: 570)
        root.addArrangedSubview(excluded.row)
        browserExcludedHostsField = excluded.field
        let clipboard = NSButton(checkboxWithTitle: "Monitor clipboard for direct download links", target: nil, action: nil)
        let automaticStart = NSButton(checkboxWithTitle: "Start downloads automatically", target: nil, action: nil)
        let timestamp = NSButton(checkboxWithTitle: "Use server timestamp when supplied", target: nil, action: nil)
        root.addArrangedSubview(clipboard)
        root.addArrangedSubview(automaticStart)
        root.addArrangedSubview(timestamp)
        browserClipboardCheck = clipboard
        browserAutomaticStartCheck = automaticStart
        browserTimestampCheck = timestamp

        let actions = NSStackView()
        actions.spacing = 8
        actions.addArrangedSubview(button("Save", action: #selector(saveBrowserMonitoring)))
        actions.addArrangedSubview(button("Close", action: #selector(closeBrowserMonitoring)))
        root.addArrangedSubview(actions)
        scroll.documentView = root
        panel.contentView = scroll
        browserMonitoringWindow = panel
        updateBrowserMonitoringControls()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func settingField(title: String, width: CGFloat) -> (row: NSStackView, field: NSTextField) {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let field = NSTextField(string: "")
        field.frame.size.width = width
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        return (row, field)
    }

    private func updateBrowserMonitoringControls() {
        browserVideoCaptureCheck?.state = ApplicationSettings.videoCaptureEnabled ? .on : .off
        browserFileExtensionsField?.stringValue = ApplicationSettings.fileExtensions
        browserVideoExtensionsField?.stringValue = ApplicationSettings.videoExtensions
        browserExcludedHostsField?.stringValue = ApplicationSettings.excludedHosts
        browserClipboardCheck?.state = ApplicationSettings.clipboardMonitoringEnabled ? .on : .off
        browserAutomaticStartCheck?.state = ApplicationSettings.startDownloadsAutomatically ? .on : .off
        browserTimestampCheck?.state = ApplicationSettings.serverTimestampEnabled ? .on : .off
        let values = [1, 5, 10, 25, 50, 100]
        browserMinimumSizeControl?.selectItem(at: values.firstIndex(of: ApplicationSettings.videoMinimumMegabytes) ?? 0)
    }

    @objc private func saveBrowserMonitoring() {
        ApplicationSettings.videoCaptureEnabled = browserVideoCaptureCheck?.state == .on
        ApplicationSettings.fileExtensions = browserFileExtensionsField?.stringValue ?? ApplicationSettings.fileExtensions
        ApplicationSettings.videoExtensions = browserVideoExtensionsField?.stringValue ?? ApplicationSettings.videoExtensions
        ApplicationSettings.excludedHosts = browserExcludedHostsField?.stringValue ?? ApplicationSettings.excludedHosts
        ApplicationSettings.clipboardMonitoringEnabled = browserClipboardCheck?.state == .on
        ApplicationSettings.startDownloadsAutomatically = browserAutomaticStartCheck?.state == .on
        ApplicationSettings.serverTimestampEnabled = browserTimestampCheck?.state == .on
        let values = [1, 5, 10, 25, 50, 100]
        if let index = browserMinimumSizeControl?.indexOfSelectedItem, values.indices.contains(index) {
            ApplicationSettings.videoMinimumMegabytes = values[index]
        }
        presentInformation("Browser Monitoring saved", message: "Reload your browser extension so it receives the updated capture rules.")
    }

    @objc private func closeBrowserMonitoring() {
        browserMonitoringWindow?.orderOut(nil)
        browserMonitoringWindow = nil
        browserFileExtensionsField = nil
        browserVideoExtensionsField = nil
        browserExcludedHostsField = nil
        browserMinimumSizeControl = nil
        browserVideoCaptureCheck = nil
        browserClipboardCheck = nil
        browserAutomaticStartCheck = nil
        browserTimestampCheck = nil
    }

    @objc private func changeConnectionsSetting(_ sender: NSSlider) {
        settingsConnectionsLabel?.stringValue = "\(sender.integerValue) / \(ApplicationSettings.maximumConnectionsPerFile)"
    }

    @objc private func changeSettingsFolder() {
        guard locationStore.chooseFolder() else { return }
        refreshFolderLabel()
        settingsFolderLabel?.stringValue = locationStore.folderURL.path
    }

    @objc private func cleanUnusedCache() {
        let removedCount = downloads.cleanUnusedCache(in: locationStore.folderURL)
        let alert = NSAlert()
        alert.messageText = "Cache cleaned"
        alert.informativeText = removedCount == 1
            ? "Removed 1 unused .XDM workspace. Active and paused downloads were kept."
            : "Removed \(removedCount) unused .XDM workspaces. Active and paused downloads were kept."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func saveSettings() {
        if let connections = settingsConnectionsSlider?.integerValue {
            ApplicationSettings.connectionsPerFile = connections
        }
        if let simultaneous = settingsSimultaneousControl?.indexOfSelectedItem, simultaneous >= 0 {
            ApplicationSettings.simultaneousDownloads = simultaneous + 1
        }
        if let appearanceIndex = settingsAppearanceControl?.indexOfSelectedItem,
           ApplicationSettings.AppearanceMode.allCases.indices.contains(appearanceIndex) {
            ApplicationSettings.appearanceMode = ApplicationSettings.AppearanceMode.allCases[appearanceIndex]
            applyAppearanceSetting()
        }
        ApplicationSettings.automaticRetryEnabled = settingsAutomaticRetryCheck?.state == .on
        downloads.applyQueueSettings()

        guard let launchAtLogin = settingsLaunchAtLoginCheck else {
            closeSettings()
            return
        }
        let shouldLaunchAtLogin = launchAtLogin.state == .on
        let isEnabled = SMAppService.mainApp.status == .enabled
        guard shouldLaunchAtLogin != isEnabled else {
            closeSettings()
            return
        }
        do {
            if shouldLaunchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            closeSettings()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not update the login setting"
            alert.informativeText = "The download settings were saved. macOS did not accept the launch-at-login change: \(error.localizedDescription)"
            alert.runModal()
            updateSettingsControls()
        }
    }

    @objc private func closeSettings() {
        settingsWindow?.orderOut(nil)
        settingsWindow = nil
        settingsConnectionsSlider = nil
        settingsConnectionsLabel = nil
        settingsSimultaneousControl = nil
        settingsLaunchAtLoginCheck = nil
        settingsFolderLabel = nil
        settingsAppearanceControl = nil
        settingsAutomaticRetryCheck = nil
    }

    private func applyAppearanceSetting() {
        switch ApplicationSettings.appearanceMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc private func showFirefoxSetup() {
        let alert = NSAlert()
        alert.messageText = "Firefox browser integration"
        alert.informativeText = "First choose Install / repair Firefox bridge in Settings. Then open about:debugging in Firefox → This Firefox → Load Temporary Add-on, and select manifest.json from the bundled folder. The original legacy XDM extension can only connect when port 9614 is free; the bundled XDM New extension does not have that limitation."
        alert.addButton(withTitle: "Show Firefox extension")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn { revealFirefoxExtension() }
    }

    @objc private func revealFirefoxExtension() {
        revealBundledResource(named: "firefox-extension", message: "In Firefox, open about:debugging → This Firefox → Load Temporary Add-on, then choose manifest.json in this folder.")
    }

    @objc private func revealChromeExtension() {
        revealBundledResource(named: "chrome-extension", message: "In Chrome, open chrome://extensions, enable Developer mode, choose Load unpacked, then select this folder.")
    }

    @objc private func installFirefoxBridge() {
        guard let hostURL = Bundle.main.resourceURL?.appendingPathComponent("XDMNativeHost"),
              FileManager.default.isExecutableFile(atPath: hostURL.path) else {
            presentInformation("Browser bridge is unavailable", message: "Reinstall XDM New so its native host is included.")
            return
        }
        let firefoxDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts", isDirectory: true)
        let firefoxManifest: [String: Any] = [
            "name": "org.xdm.test",
            "description": "XDM New native messaging host",
            "path": hostURL.path,
            "type": "stdio",
            "allowed_extensions": ["xdm-new@aakashpadhiyar.github.io", "xdm-test@local"]
        ]
        let chromeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        let chromeManifest: [String: Any] = [
            "name": "org.xdm.test",
            "description": "XDM New native messaging host",
            "path": hostURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://hognoibbenpcpakhkpajhhnflnfcpgah/"]
        ]
        do {
            try FileManager.default.createDirectory(at: firefoxDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chromeDirectory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: firefoxManifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: firefoxDirectory.appendingPathComponent("org.xdm.test.json"), options: .atomic)
            try JSONSerialization.data(withJSONObject: chromeManifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: chromeDirectory.appendingPathComponent("org.xdm.test.json"), options: .atomic)
            presentInformation("Browser bridge installed", message: "Firefox and Chrome can now send downloads to XDM New. Reload the bundled extension after installing it from Settings.")
        } catch {
            presentInformation("Could not install browser bridge", message: error.localizedDescription)
        }
    }

    @objc private func openProjectRepository() {
        NSWorkspace.shared.open(URL(string: "https://github.com/aakashpadhiyar/XDM-NEW")!)
    }

    private func revealBundledResource(named name: String, message: String) {
        let folderURL = Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true)
        if let folderURL, FileManager.default.fileExists(atPath: folderURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        }
        presentInformation("Browser extension setup", message: message)
    }

    @objc private func showAbout() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 510),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "About XDM New"
        panel.isReleasedWhenClosed = false
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)
        if let logoURL = Bundle.main.url(forResource: "xdm-new-logo", withExtension: "png"),
           let logo = NSImage(contentsOf: logoURL) {
            let imageView = NSImageView(image: logo)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            root.addArrangedSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 76),
                imageView.heightAnchor.constraint(equalToConstant: 76)
            ])
        }
        let name = NSTextField(labelWithString: "XDM New for macOS")
        name.font = .systemFont(ofSize: 21, weight: .semibold)
        root.addArrangedSubview(name)
        let developer = NSTextField(labelWithString: "Developer: Aakash Padhiyar")
        developer.font = .systemFont(ofSize: 13, weight: .medium)
        root.addArrangedSubview(developer)
        let description = NSTextField(wrappingLabelWithString: """
        A new macOS-focused download-manager implementation. It supports browser handoff, multi-connection downloads, pause/resume, segment merging, local video preview, and macOS file handling.

        This is not an official XDM release and is currently for macOS only—not Windows. It is a new implementation inspired by the historical open-source Xtreme Download Manager (XDM) 7.2.8 source code by Subhra74, licensed GPL-2.0-or-later.
        """)
        description.alignment = .center
        description.font = .systemFont(ofSize: 13)
        description.textColor = .secondaryLabelColor
        description.preferredMaxLayoutWidth = 430
        description.frame.size = NSSize(width: 430, height: 160)
        root.addArrangedSubview(description)
        root.addArrangedSubview(button("Close", action: #selector(closeAbout)))
        panel.contentView = root
        panel.center()
        aboutWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func closeAbout() {
        aboutWindow?.orderOut(nil)
        aboutWindow = nil
    }

    private func makeDownloadContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Download actions")
        menu.addItem(NSMenuItem(title: "Properties…", action: #selector(showSelectedProperties), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preview video", action: #selector(previewSelectedVideo), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Play completed media", action: #selector(playSelectedMedia), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Preview", action: #selector(previewSelectedFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open", action: #selector(openSelectedFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open with…", action: #selector(openWithApplication), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelectedFile), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Pause", action: #selector(pauseSelected), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Resume", action: #selector(resumeSelected), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Cancel", action: #selector(cancelSelected), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Retry", action: #selector(retrySelected), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Remove from history", action: #selector(removeSelectedFromHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Move file to Trash and remove history…", action: #selector(deleteSelectedFileAndHistory), keyEquivalent: ""))
        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    private func reloadTablePreservingSelection() {
        let selectedID = selectedItem?.id
        tableView.reloadData()
        guard let selectedID, let row = visibleItems.firstIndex(where: { $0.id == selectedID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func changeStateFilter(_ sender: NSSegmentedControl) {
        stateFilter = StateFilter(rawValue: sender.selectedSegment) ?? .all
        refreshList()
    }

    @objc private func showAllDownloads() {
        stateFilter = .all
        stateControl.selectedSegment = StateFilter.all.rawValue
        refreshList()
    }

    @objc private func showActiveDownloads() {
        stateFilter = .active
        stateControl.selectedSegment = StateFilter.active.rawValue
        refreshList()
    }

    @objc private func showCompletedDownloads() {
        stateFilter = .completed
        stateControl.selectedSegment = StateFilter.completed.rawValue
        refreshList()
    }

    @objc private func refreshList() {
        reloadTablePreservingSelection()
    }

    @objc private func pauseSelected() {
        withSelectedItem { downloads.pause($0) }
    }

    @objc private func resumeSelected() {
        withSelectedItem { downloads.resume($0) }
    }

    @objc private func cancelSelected() {
        withSelectedItem { downloads.cancel($0) }
    }

    @objc private func retrySelected() {
        withSelectedItem { downloads.retry($0) }
    }

    @objc private func showSelectedProperties() {
        guard let item = selectedItem else { return }
        propertiesItemID = item.id
        propertiesWindow?.orderOut(nil)
        let properties = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        properties.title = "Download Properties"
        properties.isReleasedWhenClosed = false
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        let title = NSTextField(labelWithString: item.fileName)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(title)
        let expectedSize = item.bytesExpected > 0 ? DownloadItem.byteCount(item.bytesExpected) : "Not supplied"
        let receivedSize = DownloadItem.byteCount(item.bytesReceived)
        let savedFile = item.finishedFileURL?.path ?? "Not completed"
        let cacheFolder = item.temporaryWorkspaceURL?.path ?? "Not in use (removed after completion or cancellation)"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let details = NSTextField(wrappingLabelWithString: """
        Status: \(item.state.rawValue)
        File extension: \(item.fileExtension)
        Downloaded: \(receivedSize)
        Expected size: \(expectedSize)
        Connections: \(item.connectionCount)
        Website: \(item.sourceURL.host ?? "Unknown host")
        Source URL: \(item.sourceURL.absoluteString)
        Download folder: \(item.destinationFolderURL.path)
        Final file: \(savedFile)
        Segment cache: \(cacheFolder)
        Added: \(formatter.string(from: item.createdAt))
        """)
        details.font = .systemFont(ofSize: 12)
        details.preferredMaxLayoutWidth = 570
        details.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(details)
        let actions = NSStackView()
        actions.spacing = 8
        let preview = button("Preview video", action: #selector(previewPropertiesVideo))
        preview.isEnabled = videoPreviewURL(for: item) != nil
        actions.addArrangedSubview(preview)
        actions.addArrangedSubview(button("Remove from history", action: #selector(removePropertiesFromHistory)))
        let delete = button("Move file to Trash + remove", action: #selector(deletePropertiesFileAndHistory))
        delete.isEnabled = item.finishedFileURL != nil
        actions.addArrangedSubview(delete)
        actions.addArrangedSubview(button("Close", action: #selector(closeProperties)))
        root.addArrangedSubview(actions)
        properties.contentView = root
        properties.center()
        propertiesWindow = properties
        properties.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func previewSelectedFile() {
        guard let fileURL = selectedItem?.finishedFileURL, let panel = QLPreviewPanel.shared() else { return }
        previewDataSource.url = fileURL
        panel.dataSource = previewDataSource
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func previewSelectedVideo() {
        guard let item = selectedItem, let fileURL = videoPreviewURL(for: item) else {
            presentInformation("Video preview is not ready", message: "For an incomplete multi-part video, XDM can preview it after the first segment has completed.")
            return
        }
        FileOpeningService.playMedia(fileURL)
    }

    @objc private func previewPropertiesVideo() {
        guard let item = propertiesItem, let fileURL = videoPreviewURL(for: item) else { return }
        FileOpeningService.playMedia(fileURL)
    }

    @objc private func playSelectedMedia() {
        withSelectedFile { FileOpeningService.playMedia($0) }
    }

    @objc private func removeSelectedFromHistory() {
        withSelectedItem { item in
            downloads.remove(item)
            if propertiesItemID == item.id { closeProperties() }
        }
    }

    @objc private func removePropertiesFromHistory() {
        guard let item = propertiesItem else { return }
        downloads.remove(item)
        closeProperties()
    }

    @objc private func deleteSelectedFileAndHistory() {
        guard let item = selectedItem else { return }
        confirmDeleteFileAndHistory(item)
    }

    @objc private func deletePropertiesFileAndHistory() {
        guard let item = propertiesItem else { return }
        confirmDeleteFileAndHistory(item)
    }

    @objc private func closeProperties() {
        propertiesWindow?.orderOut(nil)
        propertiesWindow = nil
        propertiesItemID = nil
    }

    private func confirmDeleteFileAndHistory(_ item: DownloadItem) {
        guard let fileURL = item.finishedFileURL else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "Move \(item.fileName) to Trash?"
        confirmation.informativeText = "This removes the download from XDM history and moves the completed file to the macOS Trash."
        confirmation.addButton(withTitle: "Move to Trash")
        confirmation.addButton(withTitle: "Cancel")
        guard let mainWindow else { return }
        confirmation.beginSheetModal(for: mainWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                self.downloads.remove(item)
                if self.propertiesItemID == item.id { self.closeProperties() }
            } catch {
                self.presentInformation("Could not move file to Trash", message: error.localizedDescription)
            }
        }
    }

    private func presentInformation(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let mainWindow {
            alert.beginSheetModal(for: mainWindow)
        }
    }

    @objc private func openSelectedFile() {
        withSelectedFile { FileOpeningService.openDefault($0) }
    }

    @objc private func revealSelectedFile() {
        withSelectedFile { FileOpeningService.revealInFinder($0) }
    }

    @objc private func openWithApplication() {
        guard let fileURL = selectedItem?.finishedFileURL else { return }
        let applications = FileOpeningService.applications(for: fileURL)
        guard !applications.isEmpty else { return }

        let menu = NSMenu()
        for applicationURL in applications {
            let item = NSMenuItem(title: applicationURL.deletingPathExtension().lastPathComponent, action: #selector(openFileWithSelectedApplication(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = applicationURL
            menu.addItem(item)
        }
        let point = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc private func openFileWithSelectedApplication(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL, let fileURL = selectedItem?.finishedFileURL else { return }
        FileOpeningService.open(fileURL, with: appURL)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showAbout), #selector(showSettings), #selector(addDownload), #selector(changeFolder),
             #selector(showFirefoxSetup), #selector(revealFirefoxExtension), #selector(revealChromeExtension),
             #selector(showAllDownloads), #selector(showActiveDownloads), #selector(showCompletedDownloads):
            return true
        case #selector(showDetectedVideos):
            return !detectedVideos.isEmpty
        default:
            break
        }
        guard let item = selectedItem else { return false }
        switch menuItem.action {
        case #selector(playSelectedMedia), #selector(previewSelectedFile), #selector(openSelectedFile), #selector(openWithApplication), #selector(revealSelectedFile):
            return item.finishedFileURL != nil
        case #selector(previewSelectedVideo):
            return videoPreviewURL(for: item) != nil
        case #selector(pauseSelected):
            return [.queued, .downloading].contains(item.state)
        case #selector(resumeSelected):
            return item.state == .paused
        case #selector(cancelSelected):
            return [.queued, .downloading, .merging, .paused].contains(item.state)
        case #selector(retrySelected):
            return [.failed, .cancelled].contains(item.state)
        default:
            return true
        }
    }

    private func updateDetectedVideosButton() {
        let count = detectedVideos.count
        detectedVideosButton.title = count == 0 ? "Videos" : "Videos (\(count))"
        detectedVideosMenuItem?.title = count == 0 ? "Detected Videos" : "Detected Videos (\(count))"
        detectedVideosMenuItem?.isEnabled = count > 0
    }

    private func removeDetectedVideo(id: String) {
        detectedVideos.removeAll { $0.id == id }
        browserMonitor?.removeVideo(id: id)
        updateDetectedVideosButton()
        if videoListWindow?.isVisible == true {
            visibleVideoOptions = orderedVideoOptions
            detectedVideosTable.reloadData()
        }
        if detectedVideos.isEmpty { videoToast?.orderOut(nil) }
    }

    private func videoDescription(_ payload: BrowserMonitorPayload) -> String {
        let size = payload.reportedSize.map { DownloadItem.byteCount($0) } ?? "Size unavailable"
        let best = isBestVariant(payload) ? "Best · " : ""
        let resolution = videoResolution(payload)
        return "\(best)\(resolution) · \(size) · \(payload.mediaKind)"
    }

    private func videoResolution(_ payload: BrowserMonitorPayload) -> String {
        let value = payload.resolution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Not supplied" : value
    }

    private func videoName(_ payload: BrowserMonitorPayload) -> String {
        let suppliedName = payload.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return suppliedName.isEmpty ? payload.url.lastPathComponent : suppliedName
    }

    private func normalizedVideoName(_ payload: BrowserMonitorPayload) -> String {
        videoName(payload).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func isSameVideoVariant(_ first: BrowserMonitorPayload, _ second: BrowserMonitorPayload) -> Bool {
        if first.url == second.url { return true }
        guard let firstSize = first.reportedSize, firstSize > 0,
              let secondSize = second.reportedSize, secondSize > 0 else { return false }
        return normalizedVideoName(first) == normalizedVideoName(second) && firstSize == secondSize
    }

    private func isBestVariant(_ payload: BrowserMonitorPayload) -> Bool {
        let variants = detectedVideos.filter { normalizedVideoName($0) == normalizedVideoName(payload) }
        guard variants.count > 1,
              let size = payload.reportedSize,
              let largest = variants.compactMap(\.reportedSize).max() else { return false }
        return size == largest
    }

    private var orderedVideoOptions: [BrowserMonitorPayload] {
        detectedVideos.sorted { first, second in
            let firstBest = isBestVariant(first)
            let secondBest = isBestVariant(second)
            if firstBest != secondBest { return firstBest }
            let firstName = normalizedVideoName(first)
            let secondName = normalizedVideoName(second)
            if firstName == secondName {
                return (first.reportedSize ?? -1) > (second.reportedSize ?? -1)
            }
            return firstName.localizedStandardCompare(secondName) == .orderedAscending
        }
    }

    private func showVideoToast() {
        let panel: NSPanel
        if let videoToast {
            panel = videoToast
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 330, height: 72),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.hasShadow = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 330, height: 72))
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 14
            material.layer?.masksToBounds = true
            let content = NSStackView()
            content.orientation = .horizontal
            content.alignment = .centerY
            content.spacing = 10
            content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            content.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView(image: NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "Video") ?? NSImage())
            icon.contentTintColor = .controlAccentColor
            icon.frame.size = NSSize(width: 24, height: 24)
            let textStack = NSStackView()
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 2
            let title = NSTextField(labelWithString: "Video detected")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let label = NSTextField(labelWithString: "")
            label.tag = 100
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let button = NSButton(title: "Download video", target: self, action: #selector(showDetectedVideos))
            button.bezelStyle = .rounded
            button.controlSize = .small
            textStack.addArrangedSubview(title)
            textStack.addArrangedSubview(label)
            content.addArrangedSubview(icon)
            content.addArrangedSubview(textStack)
            content.addArrangedSubview(button)
            material.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                content.topAnchor.constraint(equalTo: material.topAnchor),
                content.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
            panel.contentView = material
            videoToast = panel
        }
        let count = detectedVideos.count
        (panel.contentView?.viewWithTag(100) as? NSTextField)?.stringValue = count == 1 ? "Ready to download" : "\(count) choices ready"
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - frame.width - 18, y: screen.visibleFrame.minY + 18))
        }
        panel.orderFrontRegardless()
    }

    @objc private func showDetectedVideos() {
        guard !detectedVideos.isEmpty else { return }
        videoToast?.orderOut(nil)
        visibleVideoOptions = orderedVideoOptions
        if videoListWindow == nil { makeDetectedVideosPanel() }
        detectedVideosTable.reloadData()
        let bestIndex = visibleVideoOptions.firstIndex(where: { isBestVariant($0) }) ?? 0
        detectedVideosTable.selectRowIndexes(IndexSet(integer: bestIndex), byExtendingSelection: false)
        positionVideoListPanel()
        videoListWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeDetectedVideosPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Download video"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let heading = NSTextField(labelWithString: "Detected video downloads")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(heading)
        let hint = NSTextField(labelWithString: "Unique variants only. “Best” is the largest reported version of the same media.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        root.addArrangedSubview(hint)

        let columns = [("Name", 260.0), ("Resolution", 105.0), ("Size", 90.0), ("Type", 120.0)]
        for (identifier, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("video-\(identifier)"))
            column.title = identifier
            column.width = width
            detectedVideosTable.addTableColumn(column)
        }
        detectedVideosTable.delegate = self
        detectedVideosTable.dataSource = self
        detectedVideosTable.usesAlternatingRowBackgroundColors = true
        detectedVideosTable.rowHeight = 30
        let scroll = NSScrollView()
        scroll.documentView = detectedVideosTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 586),
            scroll.heightAnchor.constraint(equalToConstant: 150)
        ])
        let actions = NSStackView()
        actions.spacing = 8
        actions.addArrangedSubview(button("Details", action: #selector(showSelectedVideoDetails)))
        actions.addArrangedSubview(button("Download now", action: #selector(downloadSelectedVideo)))
        let closeButton = button("×", action: #selector(closeDetectedVideos))
        closeButton.bezelStyle = .inline
        closeButton.font = .systemFont(ofSize: 18, weight: .medium)
        closeButton.toolTip = "Minimize to Download video"
        actions.addArrangedSubview(closeButton)
        root.addArrangedSubview(actions)
        panel.contentView = root
        videoListWindow = panel
    }

    private func positionVideoListPanel() {
        guard let panel = videoListWindow, let screen = mainWindow?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 18, y: visible.minY + 18))
    }

    @objc private func downloadSelectedVideo() {
        let row = detectedVideosTable.selectedRow
        guard visibleVideoOptions.indices.contains(row) else { return }
        startBrowserDownload(visibleVideoOptions[row])
        visibleVideoOptions = orderedVideoOptions
        detectedVideosTable.reloadData()
        if visibleVideoOptions.isEmpty { closeDetectedVideos() }
    }

    @objc private func showSelectedVideoDetails() {
        let row = detectedVideosTable.selectedRow
        guard visibleVideoOptions.indices.contains(row) else { return }
        showMediaDetails(visibleVideoOptions[row])
    }

    @objc private func closeDetectedVideos() {
        videoListWindow?.orderOut(nil)
        if !detectedVideos.isEmpty { showVideoToast() }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === videoListWindow else { return }
        if !detectedVideos.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.showVideoToast() }
        }
    }

    private func showMediaDetails(_ payload: BrowserMonitorPayload) {
        let details = NSAlert()
        details.messageText = videoName(payload)
        let reportedSize = payload.reportedSize.map { DownloadItem.byteCount($0) } ?? "Not supplied by the server"
        let disposition = payload.contentDisposition ?? "Not supplied"
        let referrer = payload.referrer ?? "Not supplied"
        let tab = payload.tabID ?? "Not supplied"
        details.informativeText = """
        Type: \(payload.contentType ?? "Not supplied")
        Classified as: \(payload.mediaKind)
        Reported size: \(reportedSize)
        Byte-range support: \(payload.acceptsByteRanges ? "Yes" : "Not reported")
        Content-Disposition: \(disposition)
        Referrer: \(referrer)
        Browser tab: \(tab)
        Source: \(payload.url.absoluteString)

        Cookies and authorization headers are used only for the download request and are never displayed. Resolution and codec are not provided by the original extension; those require parsing the actual stream or manifest.
        """
        details.addButton(withTitle: "OK")
        details.runModal()
    }

    private var selectedItem: DownloadItem? {
        let row = tableView.selectedRow
        guard visibleItems.indices.contains(row) else { return nil }
        return visibleItems[row]
    }

    private var propertiesItem: DownloadItem? {
        guard let propertiesItemID else { return nil }
        return downloads.items.first { $0.id == propertiesItemID }
    }

    private func videoPreviewURL(for item: DownloadItem) -> URL? {
        guard category(for: item) == "Video" else { return nil }
        if let finishedFileURL = item.finishedFileURL { return finishedFileURL }
        guard let workspaceURL = item.temporaryWorkspaceURL,
              let parts = try? FileManager.default.contentsOfDirectory(
                at: workspaceURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }
        return parts
            .filter { $0.lastPathComponent.hasPrefix("00-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private func withSelectedItem(_ action: (DownloadItem) -> Void) {
        guard let item = selectedItem else { return }
        action(item)
    }

    private func withSelectedFile(_ action: (URL) -> Void) {
        guard let fileURL = selectedItem?.finishedFileURL else { return }
        action(fileURL)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == detectedVideosTable { return visibleVideoOptions.count }
        return visibleItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == detectedVideosTable {
            guard visibleVideoOptions.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
            let payload = visibleVideoOptions[row]
            let reuseID = NSUserInterfaceItemIdentifier("video-cell-\(identifier)")
            let cell = tableView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView ?? {
                let newCell = NSTableCellView()
                newCell.identifier = reuseID
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingMiddle
                label.translatesAutoresizingMaskIntoConstraints = false
                newCell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
                ])
                return newCell
            }()
            let label = cell.subviews.compactMap { $0 as? NSTextField }.first
            switch identifier {
            case "video-Name": label?.stringValue = "\(isBestVariant(payload) ? "Best · " : "")\(videoName(payload))"
            case "video-Resolution": label?.stringValue = videoResolution(payload)
            case "video-Size": label?.stringValue = payload.reportedSize.map(DownloadItem.byteCount) ?? "Unknown"
            default: label?.stringValue = payload.mediaKind
            }
            return cell
        }
        guard visibleItems.indices.contains(row) else { return nil }
        let item = visibleItems[row]
        let identifier = NSUserInterfaceItemIdentifier("downloadCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let newCell = NSTableCellView()
            newCell.identifier = identifier
            let label = NSTextField(wrappingLabelWithString: "")
            label.tag = 100
            label.translatesAutoresizingMaskIntoConstraints = false
            newCell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
            ])
            return newCell
        }()
        let label = cell.viewWithTag(100) as? NSTextField
        label?.stringValue = "\(item.fileName)  ·  \(category(for: item))\n\(item.state.rawValue) — \(item.detail)"
        return cell
    }

    private var visibleItems: [DownloadItem] {
        downloads.items.filter { item in
            let stateMatches: Bool
            switch stateFilter {
            case .all: stateMatches = true
            case .active: stateMatches = [.queued, .downloading, .merging, .paused].contains(item.state)
            case .completed: stateMatches = item.state == .completed
            }
            let selectedCategory = categoryMenu.titleOfSelectedItem
            let categoryMatches = selectedCategory == nil || selectedCategory == "All categories" || category(for: item) == selectedCategory
            let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches = query.isEmpty || item.fileName.localizedCaseInsensitiveContains(query) || item.sourceURL.absoluteString.localizedCaseInsensitiveContains(query)
            return stateMatches && categoryMatches && searchMatches
        }
    }

    private func category(for item: DownloadItem) -> String {
        let fileExtension = URL(fileURLWithPath: item.fileName).pathExtension.lowercased()
        let extensionToClassify = fileExtension.isEmpty ? item.sourceURL.pathExtension.lowercased() : fileExtension
        switch extensionToClassify {
        case "mp4", "m4v", "mov", "mkv", "webm", "avi": return "Video"
        case "mp3", "m4a", "aac", "flac", "wav", "ogg": return "Music"
        case "zip", "rar", "7z", "tar", "gz", "xz", "dmg": return "Compressed"
        case "pdf", "doc", "docx", "txt", "rtf", "pages": return "Documents"
        case "pkg", "app", "exe", "msi", "iso": return "Programs"
        default: return "Other"
        }
    }
}

@main
@MainActor
enum XDMTestMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
